"""Pinned HF Parquet ingestion; basic UD words, never MWT surface rows."""
import hashlib
import json
from collections import Counter
from pathlib import Path

RELATIONS = sorted("acl advcl advmod amod appos aux case cc ccomp clf compound conj cop csubj dep det discourse dislocated expl fixed flat goeswith iobj list mark nmod nsubj nummod obj obl orphan parataxis punct reparandum root vocative xcomp".split())


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def valid_tree(heads):
    n = len(heads)
    if heads.count(0) != 1:
        return False
    for word in range(1, n + 1):
        seen = set()
        while word:
            if word in seen or not 1 <= word <= n:
                return False
            seen.add(word)
            word = heads[word - 1]
    return True


def normalize(row, treebank):
    words = row["tokens"]
    heads = [int(h) for h in row["head"]]
    labels = [r.split(":", 1)[0] for r in row["deprel"]]
    if not words or len({len(words), len(heads), len(labels), len(row["upos"])}) != 1:
        raise ValueError("unaligned or empty sentence")
    if not valid_tree(heads):
        raise ValueError("invalid gold tree")
    if any(r not in RELATIONS or ((h == 0) != (r == "root")) for h, r in zip(heads, labels)):
        raise ValueError("invalid relation or root label")
    return {"id": row["sent_id"], "treebank": treebank, "language": treebank.split("_")[0],
            "text": row["text"], "words": words, "heads": heads, "labels": labels,
            "upos": row["upos"], "mwt": row.get("mwt", [])}


def prepare(config, output):
    from huggingface_hub import hf_hub_download
    import pyarrow.parquet as pq

    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    kwargs = dict(repo_id=config["dataset_id"], repo_type="dataset", revision=config["dataset_revision"])
    metadata = json.loads(Path(hf_hub_download(filename="metadata.json", **kwargs)).read_text())
    manifest = {"dataset_id": config["dataset_id"], "revision": config["dataset_revision"],
                "relations": RELATIONS, "label_policy": "base UD relations; subtypes collapsed", "files": []}
    for treebank in config["treebanks"]:
        meta = metadata[treebank]
        if meta.get("blocked"):
            raise ValueError(f"Dataset blocked: {treebank}")
        for split in meta["splits"]:
            if treebank in config["evaluation_only"] and split != "test":
                continue
            name = f"parquet/{treebank}/{split}.parquet"
            source = Path(hf_hub_download(filename=name, **kwargs))
            rows = []
            for row in pq.read_table(source).to_pylist():
                try:
                    rows.append(normalize(row, treebank))
                except (ValueError, TypeError) as exc:
                    raise ValueError(f"{treebank}/{split}/{row.get('sent_id')}: {exc}") from exc
            dest = output / f"{treebank}-{split}.jsonl"
            dest.write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows))
            entry = {"path": dest.name, "treebank": treebank, "split": split, "sentences": len(rows),
                     "license": meta["license"], "source": name,
                     "sha256": hashlib.sha256(dest.read_bytes()).hexdigest(),
                     "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                     "relations": dict(Counter(r for row in rows for r in row["labels"]))}
            manifest["files"].append(entry)
            print(f"{treebank}/{split}: {len(rows)} sentences, {entry['relations'].get('reparandum', 0)} reparandum arcs", flush=True)
    write_json(output / "manifest.json", manifest)


def read_prepared(directory):
    directory = Path(directory)
    manifest = json.loads((directory / "manifest.json").read_text())
    for item in manifest["files"]:
        path = directory / item["path"]
        if hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
            raise ValueError(f"Prepared data changed: {path}")
    return manifest
