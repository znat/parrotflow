#!/usr/bin/env python3
"""Does the vocabulary pass pay for itself?

    scripts/vocab-ablation.py [--runs N] [--limit N] [--out FILE]

Replays every labelled clip in `tests/menu-cases.yaml` twice: once with the
vocabulary pass on, once with the whole pass off. Both arms are replays of the
same audio through the same build on the same day, so the only difference is
the pass.

Four numbers, fixed before the run:

    wins    vocab-on right, vocab-off wrong
    losses  vocab-off right, vocab-on wrong
    net     wins - losses
    split   term clips and controls, reported separately

## Switching the pass off honestly

`--transcribe --no-vocab` is not the off arm. It sets `vocabulary.acoustic =
false` and nothing else, so the `heard:` lists still become `replacements`
rules (`Config.vocabularyRules`), those rules still raise `vocabulary.count`
(`Pipeline.swift`), and the `vocabulary:` judge stage still fires. It disables
the acoustic third of a three-part pass.

The off arm is a scratch `PARROTFLOW_CONFIG_DIR` whose `vocabulary.yaml` has
an empty `terms:`. No terms means no acoustic context, no rules, and
`vocabulary.count == 0`, so the judge stage's `when:` skips it. Everything
else — the replacement table in `config.yaml`, the pipeline, the model — is
the same file in both arms.

## The split

Read off the case file, not guessed from the text. Every clip carries a
`# picked up:` line saying how it entered the set, and the 73 controls say so
in words: "No vocabulary term, a control". That is the same 73 that
`docs/proposals/vocabulary-v2.md` recorded, and the other 68 are the term
clips — its 54, plus the 14 labelled clips block 3 added.

## Noise

Replay is nondeterministic (F12a), so `--runs N` replays each clip N times per
arm and keeps the majority. A clip that did not agree with itself in either
arm is counted as a flip, and the flip count is what says whether a small net
means anything.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from importlib.machinery import SourceFileLoader

ROOT = Path(__file__).resolve().parent.parent
recall = SourceFileLoader("recall", str(ROOT / "scripts/menu-recall.py")).load_module()
CASES = ROOT / "tests/menu-cases.yaml"
CLIPS = Path.home() / "Recordings/ParrotFlow Dev"


def cases_with_class():
    """(wav, said, is_term) for every labelled clip, in file order."""
    out, cur = [], None
    for line in CASES.read_text().splitlines():
        s = line.strip()
        if s.startswith("- wav:"):
            if cur:
                out.append(cur)
            cur = {"wav": s.split(":", 1)[1].strip(),
                   "control": False, "said": None, "open": False}
        elif cur is not None and s.startswith("# picked up:"):
            # Every clip carries this line and it names its own class. The
            # 73 controls say so in words — "No vocabulary term, a control" —
            # which is the split `docs/proposals/vocabulary-v2.md` recorded.
            cur["control"] = "a control" in s
        elif cur is not None and s.startswith("said:"):
            body = s.split(":", 1)[1].split("#")[0].strip()
            cur["said"] = body.strip('"') or None
            cur["open"] = True
        elif cur is not None and cur["open"] and s and not s.startswith("#"):
            cur["said"] = (cur["said"] or "") + " " + s.strip('"')
    if cur:
        out.append(cur)
    return [(c["wav"], c["said"].strip(), not c["control"])
            for c in out if c["said"]]


def transcribe(wav, config_dir):
    """One clip through the app with a given config directory."""
    environment = dict(os.environ)
    environment["PARROTFLOW_CONFIG_DIR"] = str(config_dir)
    dump = Path(tempfile.mkdtemp()) / "menu.txt"
    environment["PARROTFLOW_JUDGE_DUMP"] = str(dump)
    done = subprocess.run(
        [recall.APP, "--transcribe", str(CLIPS / wav)],
        capture_output=True, text=True, env=environment, timeout=300,
    )
    blob = done.stdout + done.stderr
    lines = blob.splitlines()
    final = None
    for i, line in enumerate(lines):
        if "transcript" in line and "─" in line and i + 1 < len(lines):
            final = lines[i + 1].strip()
    return final or ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--on", required=True, help="PARROTFLOW_CONFIG_DIR, pass on")
    ap.add_argument("--off", required=True, help="PARROTFLOW_CONFIG_DIR, pass off")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--out", default="", help="write per-clip JSON here")
    args = ap.parse_args()

    if not Path(recall.APP).exists():
        print(f"✗ {recall.APP} not found — run `make app` first")
        return 2

    cases = cases_with_class()
    if args.limit:
        cases = cases[:args.limit]

    rows = []
    for n, (wav, said, is_term) in enumerate(cases, 1):
        truth = recall.normalise(said)
        row = {"wav": wav, "said": said, "term": is_term, "on": [], "off": []}
        for arm, cfg in (("on", args.on), ("off", args.off)):
            for _ in range(args.runs):
                text = transcribe(wav, cfg)
                row[arm].append(text)
        row["on_ok"], row["on_moved"] = recall.majority(
            [recall.normalise(t) == truth for t in row["on"]])
        row["off_ok"], row["off_moved"] = recall.majority(
            [recall.normalise(t) == truth for t in row["off"]])
        rows.append(row)
        mark = {(True, False): "WIN", (False, True): "LOSS"}.get(
            (row["on_ok"], row["off_ok"]), "same")
        print(f"  {n:>3}/{len(cases)}  {mark:<5} {wav}"
              f"{'  flipped' if row['on_moved'] or row['off_moved'] else ''}",
              file=sys.stderr, flush=True)

    if args.out:
        Path(args.out).write_text(json.dumps(rows, indent=1))

    def report(name, subset):
        wins = [r for r in subset if r["on_ok"] and not r["off_ok"]]
        losses = [r for r in subset if r["off_ok"] and not r["on_ok"]]
        flips = [r for r in subset if r["on_moved"] or r["off_moved"]]
        print(f"\n{name}  ({len(subset)} clips)")
        print(f"  wins    {len(wins)}")
        print(f"  losses  {len(losses)}")
        print(f"  net     {len(wins) - len(losses):+d}")
        print(f"  flips   {len(flips)}")
        return wins, losses

    report("ALL", rows)
    report("about a term", [r for r in rows if r["term"]])
    report("controls", [r for r in rows if not r["term"]])
    return 0


if __name__ == "__main__":
    sys.exit(main())
