"""Train/dev-only diagnostics: memorization, token alignment, and layer ablation."""
import argparse
import hashlib
import json
import os
import random
import time
from pathlib import Path

os.environ.setdefault("HF_HOME", str(Path("artifacts/hf-cache").resolve()))
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

import torch

from data import RELATIONS, read_prepared, write_json
from features import encode_words, load_encoder, load_features
from model import ParserHead, batch_rows, loss_for
from train import evaluate


def overfit(config, output):
    rows, _ = load_features("artifacts/features", "train")
    rng = random.Random(42)
    selected = []
    for language in ("en", "fr", "es"):
        selected += rng.sample([r for r in rows if r["language"] == language and 3 <= len(r["words"]) <= 25], 16)
    torch.manual_seed(42)
    head = ParserHead(384, RELATIONS, dropout=0)
    optimizer = torch.optim.AdamW(head.parameters(), lr=0.003)
    history = [{"step": 0, "metrics": evaluate(head, selected, 16, "cpu")}]
    for step in range(1, 1001):
        head.train()
        batch = rng.sample(selected, 16)
        x, mask, heads, labels = batch_rows(batch, "cpu")
        optimizer.zero_grad()
        arcs, relations = head(x, mask, gold_heads=heads)
        loss = loss_for(arcs, relations, heads, labels, mask)
        loss.backward()
        torch.nn.utils.clip_grad_norm_(head.parameters(), 5)
        optimizer.step()
        if step % 100 == 0:
            metrics = evaluate(head, selected, 16, "cpu")
            history.append({"step": step, "loss": loss.item(), "metrics": metrics})
            print(f"Overfit {step}: UAS={metrics['all']['uas']:.4f}, LAS={metrics['all']['las']:.4f}", flush=True)
            if metrics["all"]["las"] >= 0.995:
                break
    write_json(output / "overfit.json", {"criterion": "at least 99.5% nonpunctuation LAS on memorized training examples",
               "passed": history[-1]["metrics"]["all"]["las"] >= 0.995,
               "sentences": [{"treebank": r["treebank"], "id": r["id"]} for r in selected], "history": history})


def collect(config, output):
    manifest = read_prepared("artifacts/data")
    tokenizer, encoder = load_encoder(config, "cpu")
    rng = random.Random(42)
    rows = {"train": [], "dev": []}
    for item in manifest["files"]:
        split = item["split"]
        if split not in rows or item["treebank"] in config["evaluation_only"]:
            continue
        candidates = [json.loads(line) for line in (Path("artifacts/data") / item["path"]).read_text().splitlines()]
        rng.shuffle(candidates)
        for row in candidates:
            if len(tokenizer(row["words"], is_split_into_words=True)["input_ids"]) <= config["max_subwords"]:
                row["relation_names"] = RELATIONS
                rows[split].append(row)
                if sum(r["treebank"] == item["treebank"] for r in rows[split]) == (128 if split == "train" else 64):
                    break
    # Hook numbered block outputs explicitly. The production control uses
    # last_hidden_state, which also includes ModernBERT's learned final norm.
    captured = {}
    handles = []
    for block in (6, 11, 16):
        def capture(module, args, value, block=block):
            captured[block] = value.detach()
        handles.append(encoder.layers[block - 1].register_forward_hook(capture))
    variants = ["block6", "block11", "block16", "last"]
    caches = {name: {split: [] for split in rows} for name in variants}
    audit = {"sentences": 0, "words": 0, "missing_words": 0, "nonmonotonic_word_ids": 0,
             "decode_mismatches": 0, "mismatch_examples": [], "unknown_subwords": 0,
             "joined_text_token_id_mismatches": 0}
    for split, selected in rows.items():
        for start in range(0, len(selected), 4):
            batch = selected[start:start + 4]
            encoded = tokenizer([r["words"] for r in batch], is_split_into_words=True,
                                padding=True, return_tensors="pt")
            with torch.inference_mode():
                last = encoder(**encoded).last_hidden_state
                states = {"last": last, **{f"block{b}": captured[b] for b in (6, 11, 16)}}
                for i, row in enumerate(batch):
                    ids = encoded.word_ids(i)
                    positions = [[j for j, w in enumerate(ids) if w == word] for word in range(len(row["words"]))]
                    audit["sentences"] += 1
                    audit["words"] += len(positions)
                    audit["missing_words"] += sum(not p for p in positions)
                    present = [w for w in ids if w is not None]
                    audit["nonmonotonic_word_ids"] += present != sorted(present)
                    if any(not p for p in positions):
                        raise ValueError("Missing word alignment")
                    actual = encoded["input_ids"][i][encoded["attention_mask"][i].bool()].tolist()
                    joined = tokenizer(" ".join(row["words"]))["input_ids"]
                    audit["joined_text_token_id_mismatches"] += actual != joined
                    for word, pos in zip(row["words"], positions):
                        word_ids = encoded["input_ids"][i, pos].tolist()
                        decoded = tokenizer.decode(word_ids).strip()
                        audit["unknown_subwords"] += word_ids.count(tokenizer.unk_token_id)
                        if decoded != word:
                            audit["decode_mismatches"] += 1
                            if len(audit["mismatch_examples"]) < 20:
                                audit["mismatch_examples"].append({"word": word, "decoded": decoded, "treebank": row["treebank"], "id": row["id"]})
                    for name, state in states.items():
                        feature = torch.stack([state[i, pos].mean(0) for pos in positions]).cpu().half()
                        caches[name][split].append({**row, "features": feature})
            if start % 200 == 0:
                print(f"Layer features {split}: {start}/{len(selected)}", flush=True)
    for handle in handles:
        handle.remove()
    # Cross-check the production feature path against diagnostic last-layer pooling.
    check = rows["dev"][:4]
    direct = encode_words(tokenizer, encoder, [r["words"] for r in check], config["max_subwords"], "cpu")
    audit["production_pooling_max_error_fp16"] = max((a.half() - b["features"]).abs().max().item() for a, b in zip(direct, caches["last"]["dev"][:4]))
    audit["layer_mean_rms"] = {name: sum(r["features"].float().square().mean().sqrt().item() for r in cache["train"]) / len(cache["train"]) for name, cache in caches.items()}
    write_json(output / "alignment.json", audit)
    write_json(output / "selection.json", {split: [{"treebank": r["treebank"], "id": r["id"]} for r in data] for split, data in rows.items()})
    for name, cache in caches.items():
        torch.save(cache, output / f"{name}-features.pt")
    print("Alignment:", json.dumps(audit), flush=True)
    return caches


def compare_layers(config, caches, output, seed=42, epochs=15):
    results = {}
    for name, cache in caches.items():
        torch.manual_seed(seed)
        head = ParserHead(384, RELATIONS, arc_dim=config["arc_dim"], label_dim=config["label_dim"], dropout=config["dropout"])
        optimizer = torch.optim.AdamW(head.parameters(), lr=config["learning_rate"])
        rows = cache["train"]
        counts = {lang: sum(r["language"] == lang for r in rows) for lang in ("en", "fr", "es")}
        weights = torch.tensor([1 / counts[r["language"]] for r in rows], dtype=torch.double)
        history = []
        best = -1
        started = time.perf_counter()
        for epoch in range(1, epochs + 1):
            head.train()
            indices = torch.multinomial(weights, len(rows), replacement=True).tolist()
            losses = []
            for start in range(0, len(rows), 16):
                batch = [rows[i] for i in indices[start:start + 16]]
                x, mask, parents, labels = batch_rows(batch, "cpu")
                optimizer.zero_grad()
                arcs, relations = head(x, mask, gold_heads=parents)
                loss = loss_for(arcs, relations, parents, labels, mask)
                loss.backward()
                torch.nn.utils.clip_grad_norm_(head.parameters(), 5)
                optimizer.step()
                losses.append(loss.item())
            metrics = evaluate(head, cache["dev"], 16, "cpu")
            history.append({"epoch": epoch, "loss": sum(losses) / len(losses), "dev": metrics})
            if metrics["macro_language_las"] > best:
                best = metrics["macro_language_las"]
                torch.save({"head": head.state_dict(), "settings": head.settings,
                            "layer_recipe": name, "epoch": epoch, "config": config}, output / f"{name}-pilot.pt")
            if epoch % 5 == 0:
                print(f"{name} epoch {epoch}: dev macro LAS={metrics['macro_language_las']:.4f}", flush=True)
        results[name] = {"seed": seed, "seconds": time.perf_counter() - started, "history": history,
                         "best": max(history, key=lambda x: x["dev"]["macro_language_las"])}
        write_json(output / "layers.json", results)
    return results


def controls(config, source, output):
    source = Path(source)
    caches = {name: torch.load(source / f"{name}-features.pt", weights_only=True)
              for name in ("block11", "last")}
    second = output / "second-seed"
    second.mkdir()
    write_json(second / "experiment.json", {"seed": 43, "source": str(source)})
    compare_layers(config, caches, second, seed=43)
    normalized = {}
    for name, cache in caches.items():
        normalized[name + "-unitrms"] = {}
        for split, rows in cache.items():
            normalized[name + "-unitrms"][split] = []
            for row in rows:
                feature = row["features"].float()
                feature = feature / feature.square().mean(-1, keepdim=True).sqrt().clamp_min(1e-8)
                normalized[name + "-unitrms"][split].append({**row, "features": feature.half()})
    scale = output / "scale-control"
    scale.mkdir()
    write_json(scale / "experiment.json", {"seed": 42, "source": str(source),
               "normalization": "divide each word vector by its RMS; no centering or learned weights"})
    compare_layers(config, normalized, scale, seed=42)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default="artifacts/diagnostics")
    parser.add_argument("--controls-from", help="Reuse a diagnostic feature cache for second-seed and RMS controls")
    args = parser.parse_args()
    torch.set_num_threads(4)
    config = json.loads(Path("config.json").read_text())
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=False)
    if args.controls_from:
        controls(config, args.controls_from, output)
        return
    write_json(output / "experiment.json", {"config": config, "train_per_treebank": 128,
               "dev_per_treebank": 64, "seed": 42, "epochs": 15,
               "layer_recipe": "raw outputs after blocks 6/11/16 versus production last_hidden_state after final norm",
               "source_sha256": {p: hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in ("diagnose.py", "features.py", "model.py", "train.py")}})
    overfit(config, output)
    caches = collect(config, output)
    compare_layers(config, caches, output)


if __name__ == "__main__":
    main()
