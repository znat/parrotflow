#!/usr/bin/env python3
"""Did the true sentence reach the judge, and did the judge take it?

    scripts/menu-recall.py [--floor -5.5] [--limit N]

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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--floor", default=None,
                    help="PARROTFLOW_SPOTTER_FLOOR for this run")
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()

    if not Path(APP).exists():
        print(f"✗ {APP} not found — run `make install` first")
        return 2

    cases = load_cases()
    if args.limit:
        cases = cases[:args.limit]

    scored = unlabelled = recalled = picked = 0
    for wav, said in cases:
        if not said:
            unlabelled += 1
            print(f"  ·  {wav}  no `said` — skipped")
            continue
        menu, final = run(wav, args.floor)
        truth = normalise(said)
        # No menu means no proposal was made anywhere. The decoder's own text
        # is then the only reading there was, and it counts as recalled when
        # the decoder was already right.
        offered = [normalise(o) for o in menu] or [normalise(final)]
        in_menu = truth in offered
        took_it = normalise(final) == truth

        scored += 1
        recalled += in_menu
        picked += took_it
        mark = "✓" if took_it else ("~" if in_menu else "✗")
        print(f"  {mark}  {wav}  menu {len(menu) or 1}")
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
    print(f"\n  recall  {recalled}/{scored}   the true sentence was on the menu")
    print(f"  picked  {picked}/{scored}   the judge chose it")
    if unlabelled:
        print(f"  ({unlabelled} clip(s) unlabelled)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
