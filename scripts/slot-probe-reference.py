#!/usr/bin/env python3
"""Writes the fixture the Swift slot tokenizer is checked against.

    scripts/slot-probe-reference.py            -> tests/slot-tokenizer-cases.json

Needs the `tokenizers` package and mmBERT-small's `tokenizer.json`. The Swift
side reads that same file through `swift-transformers`, so a disagreement is
`SlotTokenizer`, not the file.

`tokenizers` and not `transformers.AutoTokenizer`. The two disagree on one
thing: `tokenizer_config.json` marks `<mask>` `lstrip`, which `transformers`
applies and the file's own `added_tokens` does not carry. So `"it <mask> that"`
is `it`, `<mask>`, `that` under `transformers` and `it`, `▁`, `<mask>`, `that`
here and in Swift. The app never encodes `<mask>` as text — `SlotProbe.at` puts
the id in — so this fixture describes the path the app takes.
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOKENIZER = os.path.expanduser(
    "~/Library/Application Support/ParrotFlow/models/mmbert-small-64/tokenizer.json"
)
LENGTH = 64

# Every class this tokenizer can be got wrong on: the `▁` word-start marker and
# its prefix space, byte fallback, NFC, the added tokens, the two halves
# `SlotProbe.at` encodes (a left with no trailing space, a right with one), and
# the empty string, which must encode to nothing rather than to a lone `▁`.
CASES = [
    "we have to do it. That works well",
    "The capital of Ireland is Dublin",
    "we have to do it <mask> that works well",
    "Naïve café résumé, don't you think",
    "Le château de Versailles, ça vaut le déplacement",
    "ParrotFlow—the dictation app—works offline (mostly)",
    "  double  spaces   here",
    "It cost $1,234.56 on 2026-08-30 at 07:15",
    '"quoted" \'single\' `backtick` <angle> {brace}',
    "CamelCaseIdentifier snake_case_name kebab-case",
    "emoji 🚀 and ﬁ ligature",
    "日本語のテキストです",
    "",
    " a",
    "a ",
    ".",
    " .",
    "That",
    " That",
    "Praisy's suggestion",
    " ".join(["antidisestablishmentarianism unwieldy paraphernalia"] * 12),
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tokenizer", default=TOKENIZER)
    parser.add_argument("--out")
    args = parser.parse_args()

    from tokenizers import Tokenizer
    tk = Tokenizer.from_file(args.tokenizer)

    out = []
    for text in CASES:
        encoded = tk.encode(text, add_special_tokens=False)
        out.append({"text": text, "ids": encoded.ids, "tokens": encoded.tokens})
    longest = max(len(case["ids"]) for case in out)
    if longest <= LENGTH:
        sys.exit(f"no case is longer than {LENGTH} tokens (longest is {longest})")

    path = args.out or os.path.join(HERE, "tests/slot-tokenizer-cases.json")
    with open(path, "w") as handle:
        json.dump(out, handle, ensure_ascii=False, indent=1)
        handle.write("\n")
    print(f"{len(out)} cases -> {path}")


if __name__ == "__main__":
    main()
