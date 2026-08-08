#!/usr/bin/env python3
"""Did the true sentence reach the judge, and did the judge take it?

    scripts/menu-recall.py [--floor -5.5] [--limit N] [--runs N]

Two numbers, deliberately separate:

    recall   the menu held the sentence the speaker actually said
    picked   the judge chose it

A transcript shows neither. It shows the end of the chain, and a wrong end has
two causes that want opposite fixes — propose more, or ask better. Tuning the
proposal floor against transcript accuracy optimises the sum of the two and
moves whichever happens to be cheaper.

Ground truth comes from `tests/menu-cases.yaml`, written by hand. A case with
no `said` is skipped and counted, rather than guessed at.

Comparison ignores case, punctuation and runs of spaces. The judge picks whole
sentences from a list this harness did not build, so an exact match on words is
the question; a full stop is not.

**A single run carries replay noise (F12a).** Replaying one clip twice can give
different CTC scores — measured spread up to 5 nats on an 18-second clip — so
the same audio can land on either side of a floor from one run to the next. One
score is not a measurement. `--runs N` replays every clip N times and reports
the per-clip majority, plus how many clips changed outcome between runs. The
default is 1, which keeps the cost of a routine run where it was; use `--runs
3` whenever a number is within about two cases of the one it is compared with.
"""
import argparse
import os
import re
import subprocess
import tempfile
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CASES = ROOT / "tests/menu-cases.yaml"
# The freshly built app when there is one, the installed app otherwise. Every
# measurement in this file is of code being changed, and `make app` writes here
# while `make install` writes to /Applications — reading the wrong one scored a
# stale binary and reported no change from work that had landed.
_BUILT = ROOT / ".build/ParrotFlowDev.app/Contents/MacOS/ParrotFlow"
APP = str(_BUILT) if _BUILT.exists() else "/Applications/ParrotFlowDev.app/Contents/MacOS/ParrotFlow"
CLIPS = Path.home() / "Recordings/ParrotFlow Dev"


def normalise(text):
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s']", "", text or "")).strip().lower()


def load_cases():
    """The two fields, without a YAML dependency this repo does not have."""
    text = CASES.read_text()
    cases, wav, said = [], None, None
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("- wav:"):
            if wav:
                cases.append((wav, said))
            wav, said = stripped.split(":", 1)[1].strip(), None
        elif stripped.startswith("said:"):
            body = stripped.split(":", 1)[1].split("#")[0].strip()
            said = body.strip('"') or None
        elif said is not None and stripped and not stripped.startswith("#"):
            # A folded continuation line of `said:`.
            said = said + " " + stripped.strip('"')
    if wav:
        cases.append((wav, said))
    return cases


def run(wav, floor):
    """One clip through the app, with the menu captured off stderr."""
    environment = dict(os.environ)
    dump = Path(tempfile.mkdtemp()) / "menu.txt"
    environment["PARROTFLOW_JUDGE_DUMP"] = str(dump)
    if floor is not None:
        environment["PARROTFLOW_SPOTTER_FLOOR"] = str(floor)
    done = subprocess.run(
        [APP, "--transcribe", str(CLIPS / wav)],
        capture_output=True, text=True, env=environment, timeout=180,
    )
    blob = done.stdout + done.stderr
    written = dump.read_text() if dump.exists() else ""
    menu = [m.group(1) for m in re.finditer(r"^MENU [A-Z]\. (.*)$", written, re.M)]
    final = None
    lines = blob.splitlines()
    for i, line in enumerate(lines):
        if "transcript" in line and "─" in line and i + 1 < len(lines):
            final = lines[i + 1].strip()
    return menu, final


def majority(outcomes):
    """The outcome most runs agreed on, and whether they disagreed at all.

    A tie goes to the worse outcome. An even number of runs that split down
    the middle has not shown the clip working; it has shown the clip is noise
    (F12a), and a gate should not be handed the flattering half.
    """
    yes = sum(1 for o in outcomes if o)
    return yes * 2 > len(outcomes), 0 < yes < len(outcomes)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--floor", default=None,
                    help="PARROTFLOW_SPOTTER_FLOOR for this run")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--runs", type=int, default=1,
                    help="replay each clip N times; report the majority and "
                         "how many clips flipped between runs (F12a)")
    args = ap.parse_args()
    if args.runs < 1:
        print("✗ --runs must be at least 1")
        return 2

    if not Path(APP).exists():
        print(f"✗ {APP} not found — run `make install` first")
        return 2

    cases = load_cases()
    if args.limit:
        cases = cases[:args.limit]

    scored = unlabelled = recalled = picked = flipped = 0
    for wav, said in cases:
        if not said:
            unlabelled += 1
            print(f"  ·  {wav}  no `said` — skipped")
            continue
        truth = normalise(said)
        seen_menu, seen_final = [], []
        for _ in range(args.runs):
            menu, final = run(wav, args.floor)
            # No menu means no proposal was made anywhere. The decoder's own
            # text is then the only reading there was, and it counts as
            # recalled when the decoder was already right.
            offered = [normalise(o) for o in menu] or [normalise(final)]
            seen_menu.append(truth in offered)
            seen_final.append(normalise(final) == truth)
        in_menu, menu_moved = majority(seen_menu)
        took_it, final_moved = majority(seen_final)

        scored += 1
        recalled += in_menu
        picked += took_it
        flipped += menu_moved or final_moved
        mark = "✓" if took_it else ("~" if in_menu else "✗")
        wobble = ""
        if menu_moved or final_moved:
            wobble = (f"   flipped: recall {sum(seen_menu)}/{args.runs},"
                      f" picked {sum(seen_final)}/{args.runs}")
        print(f"  {mark}  {wav}  menu {len(menu) or 1}{wobble}")
        if not took_it:
            print(f"        said:  {said.strip()}")
            print(f"        got:   {final}")
            if not in_menu:
                print("        the true reading was never offered")
                for i, option in enumerate(menu):
                    print(f"        offered {chr(65+i)}. {option}")

    if not scored:
        print("\nnothing scored — fill in `said` in tests/menu-cases.yaml")
        return 1
    how = "" if args.runs == 1 else f", majority of {args.runs} runs"
    print(f"\n  recall  {recalled}/{scored}   the true sentence was on the menu{how}")
    print(f"  picked  {picked}/{scored}   the judge chose it{how}")
    if args.runs == 1:
        print("  one run per clip — these numbers carry replay noise (F12a);"
              " use --runs 3 before quoting them against a gate")
    else:
        print(f"  {flipped}/{scored} clip(s) changed outcome between runs (F12a)")
    if unlabelled:
        print(f"  ({unlabelled} clip(s) unlabelled)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
