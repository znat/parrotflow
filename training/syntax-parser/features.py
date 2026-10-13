"""Cache frozen, unmasked encoder states once; preserve complete word alignment."""
import hashlib
import json
from pathlib import Path

import torch

from data import RELATIONS, fingerprint, read_prepared, write_json


def load_encoder(config, device):
    from transformers import AutoModel, AutoTokenizer
    kwargs = dict(revision=config["model_revision"], trust_remote_code=False)
    tokenizer = AutoTokenizer.from_pretrained(config["model_id"], use_fast=True, **kwargs)
    encoder = AutoModel.from_pretrained(config["model_id"], attn_implementation="eager", **kwargs)
    encoder.requires_grad_(False)
    encoder.eval().to(device)
    return tokenizer, encoder


def encode_words(tokenizer, encoder, sentences, max_subwords, device):
    encoded = tokenizer(sentences, is_split_into_words=True, padding=True,
                        truncation=False, return_tensors="pt")
    if encoded["input_ids"].shape[1] > max_subwords:
        raise ValueError("sentence exceeds max_subwords; never truncate a dependency tree")
    word_ids = [encoded.word_ids(i) for i in range(len(sentences))]
    with torch.inference_mode():
        hidden = encoder(**{k: v.to(device) for k, v in encoded.items()}).last_hidden_state
        pooled = []
        for row, (words, ids) in enumerate(zip(sentences, word_ids)):
            positions = [[j for j, wid in enumerate(ids) if wid == i] for i in range(len(words))]
            if any(not indices for indices in positions):
                raise ValueError("tokenizer lost a UD word")
            pooled.append(torch.stack([hidden[row, indices].mean(0) for indices in positions]).cpu().float())
    return pooled


def cache_features(config, data_dir, output, device, limit=0, splits=("train", "dev")):
    data_manifest = read_prepared(data_dir)
    if data_manifest["revision"] != config["dataset_revision"]:
        raise ValueError("data revision differs from config")
    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    tokenizer, encoder = load_encoder(config, device)
    provenance = {"model_id": config["model_id"], "model_revision": config["model_revision"],
                  "pooling": "mean subwords, last layer", "max_subwords": config["max_subwords"],
                  "dataset_manifest": fingerprint(data_manifest), "limit_per_treebank_split": limit,
                  "relations": RELATIONS, "hidden_size": encoder.config.hidden_size}
    manifest = {"provenance": provenance, "files": []}
    for item in data_manifest["files"]:
        if item["split"] not in splits:
            continue
        source = [json.loads(line) for line in (Path(data_dir) / item["path"]).read_text().splitlines()]
        selected = source[:limit] if limit else source
        kept, skipped = [], []
        for row in selected:
            length = len(tokenizer(row["words"], is_split_into_words=True)["input_ids"])
            if length > config["max_subwords"]:
                skipped.append({"id": row["id"], "subwords": length})
            else:
                kept.append(row)
        for start in range(0, len(kept), 4):
            batch = kept[start:start + 4]
            features = encode_words(tokenizer, encoder, [r["words"] for r in batch], config["max_subwords"], device)
            for row, feature in zip(batch, features):
                row["features"] = feature.half()
                row["relation_names"] = RELATIONS
            if start % 400 == 0:
                print(f"{item['treebank']}/{item['split']}: {start}/{len(kept)} encoded", flush=True)
        filename = item["path"].replace(".jsonl", ".pt")
        torch.save(kept, output / filename)
        manifest["files"].append({"path": filename, "treebank": item["treebank"], "split": item["split"],
                                  "sha256": hashlib.sha256((output / filename).read_bytes()).hexdigest(),
                                  "available": len(source), "selected": len(selected), "encoded": len(kept),
                                  "skipped_long": skipped})
        print(f"{filename}: {len(kept)} encoded, {len(skipped)} skipped long", flush=True)
    write_json(output / "manifest.json", manifest)


def load_features(directory, split):
    directory = Path(directory)
    manifest = json.loads((directory / "manifest.json").read_text())
    rows = []
    for item in manifest["files"]:
        if item["split"] == split:
            path = directory / item["path"]
            if hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
                raise ValueError(f"Feature cache changed: {path}")
            rows.extend(torch.load(path, map_location="cpu", weights_only=True))
    if not rows:
        raise ValueError(f"No {split} features in {directory}")
    return rows, manifest
