"""Head-only training and gold-word evaluation. Test data never selects checkpoints."""
import json
import random
import time
from collections import defaultdict
from pathlib import Path

import torch

from data import fingerprint, write_json
from features import load_features
from model import ParserHead, batch_rows, decode, loss_for


def score_counts(row, heads, labels):
    counts = dict(tokens=0, uas=0, las=0, repair_gold=0, repair_predicted=0, repair_correct=0)
    for gold_h, gold_r, pred_h, pred_r, pos in zip(row["heads"], row["labels"], heads, labels, row["upos"]):
        if pos != "PUNCT":
            counts["tokens"] += 1
            counts["uas"] += pred_h == gold_h
            counts["las"] += pred_h == gold_h and pred_r == gold_r
        counts["repair_gold"] += gold_r == "reparandum"
        counts["repair_predicted"] += pred_r == "reparandum"
        counts["repair_correct"] += gold_r == pred_r == "reparandum" and gold_h == pred_h
    return counts


def summarize(counts):
    def ratio(numerator, denominator):
        return numerator / denominator if denominator else None
    return {**counts, "uas": ratio(counts["uas"], counts["tokens"]),
            "las": ratio(counts["las"], counts["tokens"]),
            "repair_precision": ratio(counts["repair_correct"], counts["repair_predicted"]),
            "repair_recall": ratio(counts["repair_correct"], counts["repair_gold"]),
            "repair_f1": ratio(2 * counts["repair_correct"], counts["repair_predicted"] + counts["repair_gold"])}


@torch.inference_mode()
def evaluate(head, rows, batch_size, device):
    head.eval()
    groups = defaultdict(lambda: defaultdict(int))
    for start in range(0, len(rows), batch_size):
        batch = rows[start:start + batch_size]
        words, mask, _, _ = batch_rows(batch, device)
        arcs, labels = head(words, mask)
        for i, row in enumerate(batch):
            parents, relations = decode(arcs[i], labels[i], len(row["words"]), head.settings["relations"])
            counts = score_counts(row, parents, relations)
            for group in ("all", row["language"], row["treebank"]):
                for key, value in counts.items():
                    groups[group][key] += value
    result = {key: summarize(value) for key, value in groups.items()}
    languages = sorted({row["language"] for row in rows})
    result["macro_language_las"] = sum(result[lang]["las"] for lang in languages) / len(languages)
    return result


def run_training(config, feature_dir, output, device, max_steps=0):
    random.seed(config["seed"])
    torch.manual_seed(config["seed"])
    train_rows, manifest = load_features(feature_dir, "train")
    dev_rows, _ = load_features(feature_dir, "dev")
    provenance = manifest["provenance"]
    for key in ("model_id", "model_revision", "max_subwords"):
        if config[key] != provenance[key]:
            raise ValueError(f"Feature/config mismatch: {key}")
    if any(row["treebank"] in config["evaluation_only"] for row in train_rows + dev_rows):
        raise ValueError("Evaluation-only treebank leaked into training/development")
    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    settings = {key: config[key] for key in ("arc_dim", "label_dim", "dropout")}
    head = ParserHead(provenance["hidden_size"], provenance["relations"], **settings).to(device)
    optimizer = torch.optim.AdamW(head.parameters(), lr=config["learning_rate"])
    # Equal expected mass for each language; natural corpus frequencies within languages.
    language_counts = {lang: sum(row["language"] == lang for row in train_rows) for lang in {r["language"] for r in train_rows}}
    weights = torch.tensor([1 / language_counts[row["language"]] for row in train_rows], dtype=torch.double)
    history = []
    baseline = evaluate(head, dev_rows, config["batch_size"], device)
    history.append({"epoch": 0, "dev": baseline})
    best = baseline["macro_language_las"]

    def save(epoch):
        torch.save({"head": {k: v.detach().cpu() for k, v in head.state_dict().items()},
                    "settings": head.settings, "provenance": provenance, "config": config,
                    "feature_manifest_hash": fingerprint(manifest), "epoch": epoch,
                    "dev_macro_language_las": best}, output / "best.pt")
    save(0)
    write_json(output / "run.json", {"config": config, "feature_manifest": manifest,
                                    "max_steps_per_epoch": max_steps, "parameters": sum(p.numel() for p in head.parameters()),
                                    "device": device, "threads": torch.get_num_threads(), "torch_version": torch.__version__})
    print(f"Before training: dev macro LAS={best:.4f}", flush=True)
    for epoch in range(1, config["epochs"] + 1):
        started = time.perf_counter()
        head.train()
        indices = torch.multinomial(weights, len(train_rows), replacement=True).tolist()
        losses = []
        for step, start in enumerate(range(0, len(indices), config["batch_size"]), 1):
            batch = [train_rows[i] for i in indices[start:start + config["batch_size"]]]
            words, mask, parents, relations = batch_rows(batch, device)
            optimizer.zero_grad(set_to_none=True)
            arcs, labels = head(words, mask, gold_heads=parents)
            loss = loss_for(arcs, labels, parents, relations, mask)
            if not torch.isfinite(loss):
                raise ValueError("Non-finite training loss")
            loss.backward()
            torch.nn.utils.clip_grad_norm_(head.parameters(), 5.0)
            optimizer.step()
            losses.append(loss.item())
            if step % 500 == 0:
                print(f"Epoch {epoch}: {start + len(batch)}/{len(indices)} samples, loss={sum(losses) / len(losses):.4f}", flush=True)
            if max_steps and step >= max_steps:
                break
        metrics = evaluate(head, dev_rows, config["batch_size"], device)
        history.append({"epoch": epoch, "loss": sum(losses) / len(losses),
                        "seconds": time.perf_counter() - started, "dev": metrics})
        if metrics["macro_language_las"] > best:
            best = metrics["macro_language_las"]
            save(epoch)
        write_json(output / "history.json", history)
        print(f"Epoch {epoch}: loss={history[-1]['loss']:.4f}, dev macro LAS={metrics['macro_language_las']:.4f}", flush=True)


def load_head(checkpoint, device):
    checkpoint = torch.load(checkpoint, map_location="cpu", weights_only=True)
    head = ParserHead(**checkpoint["settings"])
    head.load_state_dict(checkpoint["head"])
    return head.eval().to(device), checkpoint
