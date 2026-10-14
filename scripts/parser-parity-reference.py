#!/usr/bin/env python3
"""Write tests/parser-parity.json: what the PyTorch reference parser answers.

    python scripts/parser-parity-reference.py --reference <syntax-parser dir> [--out tests/parser-parity.json]

<syntax-parser dir> holds swift_export_check.py (the reference parser, rebuilt
from the exported weights) and ud_split_en.py (the English splitter). Run it
with that directory's venv, which has torch, stanza and tokenizers.

Inputs are the disfluency cases and the sentences below, all written for this
repository. No treebank text: most of it is CC BY-SA.
"""
import argparse
import json
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent

SENTENCES = [
    "I mean we can try",
    "don't you know it's fine",
    "We can't, won't and shouldn't ship it before Friday.",
    "I'm sure we'll be gonna need the logs, John's too.",
    "She said “it’s done” and left 👍🏽 right after.",
    "The family 👨‍👩‍👧 emoji is one grapheme but five scalars.",
    "Le café est fermé, so we met at the other café.",
    "Send it to dev@example.com or check https://example.com/docs?id=4 first.",
    "Dr. Smith arrived at 9 a.m. with the U.S. team, e.g. Ana and Li.",
    "It costs $5, or €20 if you pay late!!!",
    "Wait... what?! (Really?)",
    "¿Qué pasa? Nothing much, just the usual.",
    "The pop-up shows a state-of-the-art progress bar.",
    "Ship the build, then tell the team on Slack.",
    "We played rock'n'roll's best hits all night.",
]

WORD_LISTS = [
    dict(id="fr-words", language="fr", words=["Je", "pense", "qu'", "il", "viendra", "demain", "."]),
    dict(id="es-words", language="es", words=["Mañana", "vamos", "a", "el", "mercado", "con", "ella", "."]),
]

PARAGRAPH = (
    "When the dictation ends, the app reads the transcript once more before it pastes anything. "
    "It splits the text into words, asks the parser which word depends on which, and keeps the "
    "original whenever a step is unsure, because a wrong edit costs the user more than a missed one. "
    "The parser runs two passes over the same subwords, one for grammar and one for syntax, then a "
    "small decoder picks the single best tree with one root. Long dictations are the hard case: a "
    "person who talks for a minute about release notes, flaky tests, the staging server in Frankfurt, "
    "three pull requests and a coffee order produces far more subwords than a sentence, and the model "
    "only reads two hundred and fifty six of them, so the app must notice the overflow and step aside "
    "rather than cut the text and guess. Nobody wants a tool that silently drops the end of a thought, "
    "least of all someone dictating a careful reply to a colleague late on a Friday afternoon. "
    "So the rule is simple to state and dull to test: count first, parse only what fits, and when "
    "the count is over, return the text exactly as it came in, with every comma, every repeated word "
    "and every half-finished clause still where the speaker left it, so that the person can fix it "
    "by hand if they care, and nothing they said has quietly disappeared on the way to the screen."
)


def utf16(text, start, end):
    return [len(text[:start].encode("utf-16-le")) // 2, len(text[:end].encode("utf-16-le")) // 2]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--reference", type=Path, required=True)
    ap.add_argument("--out", type=Path, default=ROOT / "tests" / "parser-parity.json")
    args = ap.parse_args()
    sys.path.insert(0, str(args.reference))
    sys.dont_write_bytecode = True
    import torch
    from swift_export_check import Exported
    from ud_split_en import Unsupported, split

    model = Exported()
    cases = yaml.safe_load((ROOT / "built-in/transforms/disfluency/cases.yaml").read_text())
    texts = [(f"case-{i}", c["input"]) for i, c in enumerate(cases["cases"])]
    texts += [(f"sentence-{i}", t) for i, t in enumerate(SENTENCES)]

    def subwords(words):
        return 2 + sum(len(model.tokenizer.encode(w, add_special_tokens=False).ids) for w in words)

    paragraph = split(PARAGRAPH)["words"]
    assert subwords(paragraph) > model.limit
    fit = 0
    while subwords(paragraph[: fit + 1]) <= model.limit:
        fit += 1
    near = paragraph[:fit]

    items = []
    with torch.inference_mode():
        def parsed(item, words):
            item["ids"] = model.tokenize(words)[0]
            p = model.predict(words)
            item["heads"], item["labels"] = p["heads"], p["labels"]
            tags = model.inventory[0]["values"]
            item["upos"] = [tags[i] for i in p["grammar_probs"][:, : len(tags)].argmax(-1).tolist()]
            return item

        for key, text in texts + [("long-over-256", PARAGRAPH)]:
            item = dict(id=key, text=text, language="en")
            try:
                s = split(text)
            except Unsupported:
                items.append(item | dict(abstain="split"))
                continue
            item["words"] = s["words"]
            item["utf16"] = [utf16(text, a, b) for a, b in s["spans"]]
            try:
                items.append(parsed(item, s["words"]))
            except ValueError:
                items.append(item | dict(ids=None, abstain="subwords"))
        items.append(parsed(dict(id="long-near-256", words=near, language="en"), near))
        for entry in WORD_LISTS:
            items.append(parsed(dict(entry), entry["words"]))

    near_count = len(next(i for i in items if i["id"] == "long-near-256")["ids"])
    assert near_count <= model.limit and any(i.get("abstain") == "subwords" for i in items)
    args.out.write_text(json.dumps(items, ensure_ascii=False, indent=1) + "\n")
    print(f"{len(items)} items, long-near-256 has {near_count} subwords -> {args.out}")


if __name__ == "__main__":
    main()
