"""Matched 2,000-train / 500-dev English layer comparison; no test evaluation."""
import argparse
import hashlib
import json
import os
import random
from collections import Counter
from pathlib import Path

os.environ.setdefault("HF_HOME", str(Path("artifacts/hf-cache").resolve()))
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

import torch

from data import RELATIONS, read_prepared, write_json
from diagnose import compare_layers
from features import load_encoder
from model import ParserHead, decode


def select_rows(tokenizer, config):
    manifest = read_prepared("artifacts/data")
    rng = random.Random(42)
    selected, counts = {}, {}
    seen = set()
    for split, size in (("train", 2000), ("dev", 500)):
        pool = []
        for item in manifest["files"]:
            if item["treebank"] in ("en_ewt", "en_eslspok") and item["split"] == split:
                pool.extend(json.loads(line) for line in (Path("artifacts/data") / item["path"]).read_text().splitlines())
        rng.shuffle(pool)
        rows, exclusions = [], Counter()
        for row in pool:
            key = tuple(row["words"])
            if key in seen:
                exclusions["duplicate_word_sequence"] += 1
                continue
            if len(tokenizer(row["words"], is_split_into_words=True)["input_ids"]) > config["max_subwords"]:
                exclusions["overlength"] += 1
                continue
            seen.add(key)
            rows.append({**row, "relation_names": RELATIONS})
            if len(rows) == size:
                break
        if len(rows) != size:
            raise ValueError(f"Not enough {split} examples")
        selected[split] = rows
        counts[split] = {"sentences": len(rows), "treebanks": dict(Counter(r["treebank"] for r in rows)),
                         "relations": dict(Counter(label for r in rows for label in r["labels"])),
                         "exclusions_before_quota": dict(exclusions)}
    assert not ({tuple(r["words"]) for r in selected["train"]} & {tuple(r["words"]) for r in selected["dev"]})
    return selected, counts


def encode_pair(tokenizer, encoder, rows, limit):
    captured = {}
    def capture(module, args, value):
        captured["block11"] = value.detach()
    handle = encoder.layers[10].register_forward_hook(capture)
    result = {name: [] for name in ("block11", "last")}
    try:
        for start in range(0, len(rows), 4):
            batch = rows[start:start + 4]
            encoded = tokenizer([r["words"] for r in batch], is_split_into_words=True,
                                padding=True, truncation=False, return_tensors="pt")
            if encoded["input_ids"].size(1) > limit:
                raise ValueError("Never truncate a dependency tree")
            with torch.inference_mode():
                last = encoder(**encoded).last_hidden_state
                for i, row in enumerate(batch):
                    ids = encoded.word_ids(i)
                    positions = [[j for j, word in enumerate(ids) if word == k] for k in range(len(row["words"]))]
                    if any(not p for p in positions):
                        raise ValueError("Missing word alignment")
                    for name, states in (("block11", captured["block11"]), ("last", last)):
                        features = torch.stack([states[i, p].mean(0) for p in positions]).cpu().half()
                        result[name].append({**row, "features": features})
            if start % 400 == 0:
                print(f"Encoded {start}/{len(rows)} sentences", flush=True)
    finally:
        handle.remove()
    return result


def probe_examples(tokenizer, encoder, config, output):
    examples = [{"words": words, "name": name} for name, words in (
        ("noun_repair", ["the", "cat", "the", "dog", "is", "eating"]),
        ("verb_repair", ["I", "want", "to", "write", "to", "edit", "the", "code"]),
    )]
    features = encode_pair(tokenizer, encoder, examples, config["max_subwords"])
    results = {}
    for name, rows in features.items():
        checkpoint = torch.load(output / f"{name}-pilot.pt", weights_only=True)
        head = ParserHead(**checkpoint["settings"])
        head.load_state_dict(checkpoint["head"])
        head.eval()
        results[name] = []
        with torch.inference_mode():
            for row in rows:
                words = row["words"]
                arcs, labels = head(row["features"].float().unsqueeze(0), torch.ones(1, len(words), dtype=torch.bool))
                parents, relations = decode(arcs[0], labels[0], len(words), RELATIONS)
                results[name].append({"name": row["name"], "words": words, "heads": parents, "relations": relations})
    write_json(output / "examples.json", results)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default="artifacts/english-pilot")
    args = parser.parse_args()
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=False)
    torch.set_num_threads(4)
    config = json.loads(Path("config.json").read_text())
    config["epochs"] = 10
    config["treebanks"] = ["en_ewt", "en_eslspok"]
    tokenizer, encoder = load_encoder(config, "cpu")
    rows, counts = select_rows(tokenizer, config)
    write_json(output / "experiment.json", {"config": config, "counts": counts, "seed": 42,
               "source_sha256": {p: hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in
                                  ("english_pilot.py", "diagnose.py", "model.py", "features.py", "train.py")},
               "selection": {split: [{"treebank": r["treebank"], "id": r["id"]} for r in data] for split, data in rows.items()},
               "recipes": {"block11": "raw output after block 11", "last": "last_hidden_state after final norm"},
               "checkpoint_selection": "best dev LAS within ten epochs, independently for each variant"})
    print("Selection:", json.dumps(counts), flush=True)
    caches = {name: {} for name in ("block11", "last")}
    for split, data in rows.items():
        for name, features in encode_pair(tokenizer, encoder, data, config["max_subwords"]).items():
            caches[name][split] = features
    for name, cache in caches.items():
        torch.save(cache, output / f"{name}-features.pt")
    compare_layers(config, caches, output, seed=42, epochs=10)
    probe_examples(tokenizer, encoder, config, output)


if __name__ == "__main__":
    main()
