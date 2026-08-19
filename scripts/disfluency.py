#!/usr/bin/env python3
"""Score and audit the `repetitions` transform without building the app.

    scripts/disfluency.py                    # score the transform's case set
    scripts/disfluency.py --verbose          # and show the passes too
    scripts/disfluency.py --text "the the prompt"
    scripts/disfluency.py --corpus           # every edit it would make to the archive

`ParrotFlow --eval repetitions` is the authority: it runs the deployed command
through the real pipeline. This is the same set scored in-process, for the loop
where you are editing a stop list and do not want to rebuild Swift between
tries — and for `--corpus`, which `--eval` cannot do.

The transform is loaded from `examples/transforms/repetitions/repetitions.py`
rather than reimplemented here. A runner that reimplements the thing it scores
drifts from it, and the number then describes code nobody ships.

**No model call anywhere in this file.**
"""
import argparse
import json
import sys
from pathlib import Path
from importlib.machinery import SourceFileLoader

try:
    import yaml
except ImportError:
    sys.exit("pip install pyyaml")

ROOT = Path(__file__).resolve().parent.parent
TRANSFORM = ROOT / "examples/transforms/repetitions/repetitions.py"
CASES = ROOT / "examples/transforms/repetitions/cases.yaml"
TRACE = Path.home() / "Recordings/ParrotFlow/trace.jsonl"

repetitions = SourceFileLoader("repetitions", str(TRANSFORM)).load_module()

# Re-exported so scripts/disfluency-signals.py can ask the same questions of
# the same code.
collapse = repetitions.collapse
protected = repetitions.protected
WORD = repetitions.WORD


def score(verbose):
    """The two failure kinds counted apart, because they cost differently."""
    cases = yaml.safe_load(CASES.read_text())["cases"]
    passed = missed = damaged = wrong = 0

    for case in cases:
        got = collapse(case["input"])
        # No `expect` means "comes back exactly as it went in" — the --eval
        # contract, in docs/cli.md.
        keep = "expect" not in case
        want = case["input"] if keep else case["expect"]

        if got == want:
            passed += 1
            if verbose:
                print(f"  ✓ {case['input']}")
            continue

        if keep:
            damaged += 1
            mark = "collapsed a repetition the speaker meant"
        elif got == case["input"]:
            missed += 1
            mark = "left the stutter in"
        else:
            wrong += 1
            mark = "collapsed the wrong thing"
        print(f"  ✗ {case['input']}\n      got   {got}\n      want  {want}\n      ({mark})")

    total = len(cases)
    keeps = sum(1 for c in cases if "expect" not in c)
    changes = total - keeps
    print(f"\n  {passed}/{total}   collapse {changes - missed - wrong}/{changes}"
          f"   keep {keeps - damaged}/{keeps}")
    if missed:
        print(f"    {missed} left the stutter in")
    if wrong:
        print(f"    {wrong} collapsed the wrong thing")
    if damaged:
        print(f"    {damaged} collapsed a repetition the speaker meant  ← the costly one")
    return passed == total


def corpus():
    """Every edit this pass would make to the archive, for reading by eye.

    The case set says it is right on the cases someone thought of. This says
    what it does to 281 real dictations, which is the only place an unguarded
    rule shows itself.
    """
    if not TRACE.exists():
        sys.exit(f"no trace at {TRACE}")

    by_wav = {}
    for line in TRACE.read_text().splitlines():
        if not line.strip():
            continue
        record = json.loads(line)
        if (record.get("asr") or {}).get("text"):
            by_wav[record["wav"]] = record["asr"]["text"]

    changed = 0
    for wav, text in sorted(by_wav.items()):
        out = collapse(text)
        if out == text:
            continue
        changed += 1
        print(f"\n{wav}")
        for before, after in zip(text.split(". "), out.split(". ")):
            if before != after:
                print(f"  -  {before}")
                print(f"  +  {after}")
    print(f"\n  {changed} of {len(by_wav)} clips changed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--text", help="run the pass on one string")
    parser.add_argument("--corpus", action="store_true", help="every edit to the archive")
    parser.add_argument("--verbose", action="store_true", help="show passing cases")
    args = parser.parse_args()

    if args.text:
        print(collapse(args.text))
    elif args.corpus:
        corpus()
    else:
        sys.exit(0 if score(args.verbose) else 1)


if __name__ == "__main__":
    main()
