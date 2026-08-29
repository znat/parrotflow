#!/usr/bin/env python3
"""Writes the two fixtures the Swift sentence probe is checked against.

    scripts/sentence-probe-reference.py tokens          -> tests/tokenizer-cases.json
    scripts/sentence-probe-reference.py scores <n>      -> tests/sentence-boundary-cases.json

`tokens` needs the `tokenizers` package and `tokenizer.json`. `scores` also
needs `coremltools` and the `.mlpackage`, and runs the same weights Swift runs
so a disagreement is Swift's packing, not a conversion difference.

Boundaries come from a scored set of the user's own dictation. Point --data at
its directory; the file holds `left` and `right` already windowed to +-12
words, which is what `SentenceProbe.read` reproduces.
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOKENIZER = os.path.expanduser(
    "~/Library/Application Support/ParrotFlow/models/modernbert-base-64/tokenizer.json"
)
LENGTH = 64
RADIUS = 12

# Every class the Swift tokenizer can get wrong on its own: the byte alphabet,
# the merge order, the NFC normaliser, the added tokens, and the empty string.
CASES = [
    "we have to do it. That works well",
    "The capital of Ireland is Dublin",
    "we have to do it [MASK] that works well",
    "Naïve café résumé, don't you think",
    "ParrotFlow—the dictation app—works offline (mostly)",
    "  double  spaces   here",
    "It cost $1,234.56 on 2026-08-30 at 07:15",
    '"quoted" \'single\' `backtick` <angle> {brace}',
    "CamelCaseIdentifier snake_case_name kebab-case",
    "emoji 🚀 and fi ligature",
    "日本語のテキストです",
    "",
    " a",
    "a ",
    ".",
    " .",
    "That",
    " That",
    " ".join(["antidisestablishmentarianism unwieldy paraphernalia"] * 12),
]


def load_tokenizer(path):
    from tokenizers import Tokenizer
    return Tokenizer.from_file(path)


def tokens(args):
    tk = load_tokenizer(args.tokenizer)
    out = []
    for text in CASES:
        encoded = tk.encode(text, add_special_tokens=False)
        out.append({"text": text, "ids": encoded.ids, "tokens": encoded.tokens})
    long_case = max(len(case["ids"]) for case in out)
    if long_case <= LENGTH:
        sys.exit(f"no case is longer than {LENGTH} tokens (longest is {long_case})")
    write(args.out or os.path.join(HERE, "tests/tokenizer-cases.json"), out)


def build(tk, left, right):
    """The text and the two ids, exactly as `SentenceProbe.read` builds them."""
    words = left.rstrip(".").split()[-RADIUS:]
    after = right.split()
    if not after or not words:
        return None
    nxt = after[0][0].lower() + after[0][1:]
    after = ([nxt] + after[1:])[:RADIUS]
    head = tk.encode(" ".join(words), add_special_tokens=False).ids
    tail = tk.encode(" " + " ".join(after), add_special_tokens=False).ids
    while len(head) + len(tail) > LENGTH - 3:
        if len(head) >= len(tail):
            head = head[1:]
        else:
            tail = tail[:-1]
    ids = [tk.token_to_id("[CLS]")] + head + [tk.token_to_id("[MASK]")] + tail
    ids += [tk.token_to_id("[SEP]")]
    mask_at = 1 + len(head)
    ids += [tk.token_to_id("[PAD]")] * (LENGTH - len(ids))
    nid = tk.encode(" " + nxt, add_special_tokens=False).ids
    if not nid:
        return None
    return ids, mask_at, nid[0], " ".join(words) + " [MASK] " + " ".join(after)


def scores(args):
    import coremltools as ct
    import numpy as np

    tk = load_tokenizer(args.tokenizer)
    model = ct.models.MLModel(args.package)
    dot = tk.token_to_id(".")

    data = []
    for name in ("en_real.json", "en_cuts.json"):
        entries = json.load(open(os.path.join(args.data, name)))
        step = max(1, len(entries) // (args.count // 2))
        data += [(name, e) for e in entries[::step]][: args.count // 2]

    out = []
    for name, entry in data:
        built = build(tk, entry["left"], entry["right"])
        if built is None:
            continue
        ids, mask_at, nid, text = built
        logits = model.predict(
            {"input_ids": np.array([ids], dtype=np.int32)}
        )["logits"][0, mask_at]
        logits = logits.astype(np.float64)
        top = logits.max()
        norm = top + np.log(np.exp(logits - top).sum())
        period = float(logits[dot] - norm)
        following = float(logits[nid] - norm)
        out.append({
            "set": name,
            "left": entry["left"],
            "right": entry["right"],
            "text": text,
            "period": round(period, 4),
            "next": round(following, 4),
            "score": round(period - following, 4),
        })
    write(args.out or os.path.join(HERE, "tests/sentence-boundary-cases.json"), out)


def write(path, rows):
    with open(path, "w") as handle:
        json.dump(rows, handle, ensure_ascii=False, indent=1)
        handle.write("\n")
    print(f"{len(rows)} cases -> {path}")


parser = argparse.ArgumentParser()
parser.add_argument("what", choices=("tokens", "scores"))
parser.add_argument("--tokenizer", default=TOKENIZER)
parser.add_argument("--package", default="ModernBERT-base-64.mlpackage")
parser.add_argument("--data", default=".")
parser.add_argument("--count", type=int, default=40)
parser.add_argument("--out")
args = parser.parse_args()
(tokens if args.what == "tokens" else scores)(args)
