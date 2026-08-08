#!/usr/bin/env python3
"""What today's dictations produced then, and what they produce now.

    scripts/before-after.py [--limit N] [--runs N]

`before` is the transcript the app actually delivered when the clip was
recorded, read from `trace.jsonl`. `after` is what the current build makes of
the same audio. `said` is the hand label in `tests/menu-cases.yaml`.

Four outcomes, and only two of them are interesting:

    FIXED      wrong then, right now
    BROKEN     wrong then, wrong still
    REGRESSED  right then, wrong now
    KEPT       right both times

A clip that was already right is not evidence about this work in either
direction, which is why they are counted and not listed.

**`after` is a replay, and a replay is noisy (F12a).** The same clip decoded
twice can score up to 5 nats apart, so a clip near a floor lands in FIXED on
one run and BROKEN on the next. `--runs N` decodes each clip N times, keeps the
majority verdict, and counts the clips that did not agree with themselves. The
default is 1. Never call a REGRESSED row new on one run; re-run it with
`--runs 3` and quote the flip count.
"""
import argparse
import json
import sys
from pathlib import Path
from importlib.machinery import SourceFileLoader

ROOT = Path(__file__).resolve().parent.parent
recall = SourceFileLoader("recall", str(ROOT / "scripts/menu-recall.py")).load_module()
TRACE = Path.home() / "Recordings/ParrotFlow Dev/trace.jsonl"


def originals():
    """The transcript each clip delivered on the day it was recorded.

    The *first* entry per clip, not the last. `trace.jsonl` is append-only and
    every `--transcribe` re-run adds a fresh row, so taking the newest one made
    `before` and `after` the same measurement wearing two labels — this file
    reported eleven unchanged failures and zero of anything else.
    """
    out = {}
    for line in TRACE.read_text().splitlines():
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if entry.get("wav") and entry.get("final"):
            out.setdefault(Path(entry["wav"]).name, entry["final"].strip())
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--runs", type=int, default=1,
                    help="decode each clip N times; keep the majority verdict "
                         "and count the clips that flipped (F12a)")
    args = ap.parse_args()
    if args.runs < 1:
        print("✗ --runs must be at least 1")
        return 2

    was = originals()
    rows = {"FIXED": [], "BROKEN": [], "REGRESSED": [], "KEPT": []}
    cases = recall.load_cases()
    if args.limit:
        cases = cases[:args.limit]

    flipped = []
    for wav, said in cases:
        if not said or wav not in was:
            continue
        truth = recall.normalise(said)
        runs = []
        for _ in range(args.runs):
            _, after = recall.run(wav, None)
            runs.append((recall.normalise(after or "") == truth, after))
        seen = [ok for ok, _ in runs]
        after_ok, moved = recall.majority(seen)
        before_ok = recall.normalise(was[wav]) == truth
        key = ("KEPT" if after_ok else "REGRESSED") if before_ok else \
              ("FIXED" if after_ok else "BROKEN")
        # The `after:` line has to be evidence for the verdict above it, so it
        # comes from a run that agreed with the majority. Printing the last
        # run instead put a correct transcript under BROKEN whenever the clip
        # flipped on its final replay.
        after = next(text for ok, text in runs if ok == after_ok)
        rows[key].append((wav, said, was[wav], after))
        if moved:
            flipped.append((wav, sum(seen), args.runs))
        note = f"  (flipped: right on {sum(seen)}/{args.runs} runs)" if moved else ""
        print(f"  {key:<10} {wav}{note}", file=sys.stderr)

    for key in ("FIXED", "REGRESSED", "BROKEN"):
        if not rows[key]:
            continue
        print(f"\n{'=' * 72}\n{key}  ({len(rows[key])})\n{'=' * 72}")
        for wav, said, before, after in rows[key]:
            print(f"\n{wav[22:-4]}")
            print(f"  said:   {said}")
            print(f"  before: {before}")
            print(f"  after:  {after}")
    print(f"\n  fixed {len(rows['FIXED'])}   broken {len(rows['BROKEN'])}"
          f"   regressed {len(rows['REGRESSED'])}   already right {len(rows['KEPT'])}")
    if args.runs == 1:
        print("  one decode per clip — these verdicts carry replay noise"
              " (F12a); confirm any REGRESSED row with --runs 3")
    else:
        print(f"  majority of {args.runs} runs;"
              f" {len(flipped)} clip(s) changed outcome between runs (F12a)")
        for wav, right, total in flipped:
            print(f"    {wav}  right on {right}/{total}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
