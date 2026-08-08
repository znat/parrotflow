#!/usr/bin/env python3
"""What today's dictations produced then, and what they produce now.

    scripts/before-after.py [--limit N]

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
    args = ap.parse_args()

    was = originals()
    rows = {"FIXED": [], "BROKEN": [], "REGRESSED": [], "KEPT": []}
    cases = recall.load_cases()
    if args.limit:
        cases = cases[:args.limit]

    for wav, said in cases:
        if not said or wav not in was:
            continue
        _, after = recall.run(wav, None)
        truth = recall.normalise(said)
        before_ok = recall.normalise(was[wav]) == truth
        after_ok = recall.normalise(after or "") == truth
        key = ("KEPT" if after_ok else "REGRESSED") if before_ok else \
              ("FIXED" if after_ok else "BROKEN")
        rows[key].append((wav, said, was[wav], after))
        print(f"  {key:<10} {wav}", file=sys.stderr)

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
    return 0


if __name__ == "__main__":
    sys.exit(main())
