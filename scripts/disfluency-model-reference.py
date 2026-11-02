#!/usr/bin/env python3
"""Write tests/disfluency-model-parity.json: what the PyTorch tree cutter and cut filter answer.

    python scripts/disfluency-model-reference.py --reference <syntax-parser dir> [--out FILE] [--batch FILE]

<syntax-parser dir> holds the training code the pass was measured with
(cut_check, filter_vectors, cue_rule, cv_first_pass) and its artifacts: the
t-silver 42 checkpoint and filter_vectors' clf-parser.pt. Run it with that
directory's venv. `--batch` reads [{"id", "text"}] instead of the built-in
inputs, for a local run on text that may not be committed.

Inputs are the disfluency cases and the sentences below, all written for this
repository. No treebank, CV or dictation text.

One line per case: the input, the filler view the parser reads, every
candidate (filler-view word indices, P(real), kept), the cut as indices of the
input's whitespace words, and the output text.
"""
import argparse
import json
import math
import os
import re
import sys
import unicodedata
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
T42 = "artifacts/tree-retrain/runs/t-silver-seed42/best.pt"
FILTER = "artifacts/filter-vectors/clf-parser.pt"
THRESHOLD = 0.80
# A candidate this close to the threshold can flip on float16 noise alone, so
# its case is left out rather than compared.
MARGIN = 2e-3

FILLERS = [
    re.compile(r"[,]?\s*\b(?:uh-huh|mm-hmm|erm|mhm|um|uh|hm)\b[,]?", re.IGNORECASE),
    re.compile(r"[,]?\s*\bu+[hm]+\b[,]?", re.IGNORECASE),
]
TIDY = [
    (re.compile(r"[ \t]{2,}"), " "),
    (re.compile(r" +([,.;:!?])"), r"\1"),
    (re.compile(r"([,;:]) *([,.;:])"), r"\2"),
    (re.compile(r"^[ \t]+"), ""),
]

SENTENCES = [
    "I went, I go to the store every Friday.",
    "Can you, could you send me the report?",
    "We should ship it on Monday, no, on Tuesday.",
    "Send the invoice to Mark, sorry, to Julia before noon.",
    "The meeting is at three, I mean at four.",
    "Book a table for two, for three people tonight.",
    "I think we, we need a bigger room.",
    "She told me that he, that the manager left early.",
    "Put the boxes in the, in the garage.",
    "We were going to, we decided to stay home.",
    "Let's meet at the cafe, at the library instead.",
    "Please call the, call the client back today.",
    "It was red, no, blue with white stripes.",
    "Do you want, would you like some coffee?",
    "The train leaves at seven, actually at seven thirty.",
    "I need, um, I need the keys to the van.",
    "We should, uh, we can ship it, um, on Friday.",
    "Um, so the plan is to, uh, test it first.",
    "Uh, can you, could you, um, check the logs?",
    "He said that, um, that it works now.",
    "Our team met, our whole team met yesterday.",
    "Tell Anna the deadline moved to, to next week.",
    "Is the build, is the build green yet?",
    "I'll send it to you, I'll send it tonight.",
    "The price is twenty, twenty five dollars.",
    "First open the file, then save it, then close it.",
    "We fixed the bug in the parser and the tests pass now.",
    "Thank you, thank you everyone for coming.",
    "Very, very good work on the release.",
    "I can't, I won't do that again.",
    "Don’t, don’t worry, it’s the last one.",
    "The client wants the report by Monday, I mean",
    "Remind me to call mom, to call dad tomorrow, sorry.",
    "Move the meeting to Tuesday. No, Wednesday. Thanks.",
    "Check the oil level. Scratch that. Check the coolant level.",
    "We need milk, eggs, no, bread and butter.",
    "The server in Frankfurt, the one in Paris is down.",
    "Hello 👋🏽 we, we shipped it!",
    "So yeah, I mean, we could try that.",
    "um uh",
    "",
    "   ",
    "OK.",
]

LONG = (
    "When the dictation ends, the app reads the transcript once more before it pastes anything, "
    "and I think, I believe it should keep the original whenever a step is unsure. "
    "We talked about the staging server in Frankfurt, the one in Paris, three pull requests, "
    "and a coffee order, and then we, we decided to move the release to Thursday, no, to Friday. "
    "Long dictations are the hard case: a person who talks for a minute about release notes, "
    "flaky tests, um, the build cache and the logs produces far more subwords than a sentence, "
    "so the app must, the app has to split the text into windows that fit and parse each one. "
    "Nobody wants a tool that drops the end of a thought, least of all someone dictating a careful "
    "reply to a colleague late on a Friday afternoon, so can you, could you check every window? "
    "Send the notes to Mark, sorry, to Julia, and put the boxes in the, in the garage before noon. "
    "The count comes first, then the parse, and the rest of the text is left exactly as it came in. "
    "After that we, we read the cut filter's answer for every candidate and keep only the likely ones, "
    "because a wrong cut costs the user a word they meant, while a missed one costs a second of editing. "
    "On Monday, no, on Tuesday the team will check the numbers again on a fresh build, "
    "and if the median at sixty words stays under the line, the pass can ship behind its flag."
)

RUN_ON = " ".join(
    ["and then we went to the shop and we bought the bread and the milk and the eggs"] * 16
    + ["and we, we forgot the butter again"]
)


def filler_view(text):
    """The built-in `fillers` table over text, then Replacements.tidy when it deleted anything."""
    out = text
    for pattern in FILLERS:
        out = pattern.sub("", out)
    if out == text:
        return out
    for pattern, template in TIDY:
        out = pattern.sub(template, out)
    out = strip_whitespace(out)
    if out[:1].islower():
        out = out[:1].upper() + out[1:]
    return out


def strip_whitespace(text):
    """Swift's `trimmingCharacters(in: .whitespaces)`: tab and the Unicode space separators."""
    blank = lambda c: c == "\t" or unicodedata.category(c) == "Zs"
    start, end = 0, len(text)
    while start < end and blank(text[start]):
        start += 1
    while end > start and blank(text[end - 1]):
        end -= 1
    return text[start:end]


def align(original, view, norm):
    """View word index -> original word index, matched in order on norm forms. None when a view word has no match."""
    mapping, j = [], 0
    for i, word in enumerate(original):
        if j < len(view) and norm(word) == norm(view[j]):
            mapping.append(i)
            j += 1
    return mapping if j == len(view) else None


def items(args):
    if args.batch:
        return [(it["id"], it["text"]) for it in json.loads(Path(args.batch).read_text())]
    cases = yaml.safe_load((ROOT / "built-in/transforms/disfluency/cases.yaml").read_text())
    out = [(f"case-{i}", c["input"]) for i, c in enumerate(cases["cases"])]
    out += [(f"sentence-{i}", t) for i, t in enumerate(SENTENCES)]
    out += [("long-over-256", LONG), ("run-on-over-256", RUN_ON)]
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--reference", type=Path, required=True)
    ap.add_argument("--out", type=Path, default=ROOT / "tests" / "disfluency-model-parity.json")
    ap.add_argument("--batch", type=Path)
    args = ap.parse_args()
    todo = items(args)
    args.reference, args.out = args.reference.resolve(), args.out.resolve()
    os.chdir(args.reference)
    sys.path.insert(0, str(args.reference))
    sys.dont_write_bytecode = True
    import torch

    import cue_rule.parse as cue_parse
    cue_parse.CHECKPOINTS["t42"] = T42
    from cut_check.candidates import of_clip
    from cut_check.clf import text_features
    from cut_check.vec import of_cand, word_vectors
    from cv_first_pass.labels import assemble, norm, words
    from cv_first_pass.stages import parse_texts
    from filter_vectors.vec import Block11

    torch.set_num_threads(4)
    weights = torch.load(FILTER, weights_only=True)
    views = {key: filler_view(text) for key, text in todo}
    parses = parse_texts("t42", views)
    encoder = Block11()

    def p_real(c, vec):
        x = (torch.tensor(text_features(c) + vec.float().flatten().tolist(), dtype=torch.float64)
             - weights["mu"]) / weights["sd"]
        return float(torch.sigmoid(x.float() @ weights["w"] + weights["b"]))

    lines, margin, windows, close = [], [], 0, []
    for key, text in todo:
        view = views[key]
        original = [w for w, _, _ in words(text)]
        mapping = align(original, [w for w, _, _ in words(view)], norm)
        item = dict(id=key, text=text, view=view, candidates=[], cut=[], output=text)
        if mapping is None:
            lines.append(dict(item, abstain="filler view"))
            continue
        p = parses[key]
        windows += len(p["windows"]) > 1
        cands = of_clip(p, view) if p["words"] else []
        if cands:
            w, cnt = word_vectors(encoder, p, len(view.split()))
        cut = set()
        for c in cands:
            score = p_real(c, of_cand(w, cnt, c["a"], c["b"]))
            kept = score >= THRESHOLD
            margin.append((abs(score - THRESHOLD), key))
            item["candidates"].append(dict(words=c["words"], p_real=round(score, 6), kept=kept))
            if kept:
                span = sorted(mapping[j] for j in c["words"])
                kept_words = set(mapping)
                inside = {i for i in range(span[0] + 1, span[-1]) if i not in kept_words}
                cut |= set(span) | inside
        item["cut"] = sorted(cut)
        item["output"] = assemble(text, cut) if cut else text
        if any(abs(c["p_real"] - THRESHOLD) < MARGIN for c in item["candidates"]):
            close.append(key)
            continue
        lines.append(item)

    args.out.write_text("[\n" + ",\n".join(json.dumps(i, ensure_ascii=False, separators=(",", ":")) for i in lines)
                        + "\n]\n")
    cands = sum(len(i["candidates"]) for i in lines)
    kept = sum(c["kept"] for i in lines for c in i["candidates"])
    print(f"{len(lines)} items, {cands} candidates, {kept} kept, {windows} split into windows -> {args.out}")
    print("left out, a candidate within", MARGIN, "of the threshold:", close)
    print("closest kept in:", [(round(d, 4), k) for d, k in sorted(m for m in margin if m[1] not in close)[:3]])
    assert all(math.isfinite(c["p_real"]) for i in lines for c in i["candidates"])


if __name__ == "__main__":
    main()
