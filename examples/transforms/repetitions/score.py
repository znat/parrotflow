#!/usr/bin/env python3
"""Score and audit the `repetitions` transform without building the app.

    examples/transforms/repetitions/score.py            # score the case set
    examples/transforms/repetitions/score.py --verbose  # and show the passes
    examples/transforms/repetitions/score.py --text "the the prompt"
    examples/transforms/repetitions/score.py --corpus   # every edit it would
                                                        # make to the archive

`ParrotFlow --eval repetitions` answers a different question, and the numbers
differ for a reason worth knowing: `--eval` scores the copy **installed** at
`~/.config/parrotflow/transforms/repetitions/`, which is the user's and may be
older. This scores the copy in the repo, beside it. Measured on 2026-08-19 the
installed set had 60 cases and this one 65.

So `--eval` says what your machine is running, and this says what the tree
says. Use this for the loop where you are editing a stop list and do not want
to rebuild Swift between tries, and for `--corpus`, which `--eval` cannot do.

The transform is loaded from `repetitions.py` beside this file rather than
reimplemented here. A runner that reimplements the thing it scores
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

# Everything is found beside this file, so the folder stays the one thing you
# copy: the transform, its cases and the runner that scores them.
HERE = Path(__file__).resolve().parent
TRANSFORM = HERE / "repetitions.py"
CASES = HERE / "cases.yaml"
TRACE = Path.home() / "Recordings/ParrotFlow/trace.jsonl"

repetitions = SourceFileLoader("repetitions", str(TRANSFORM)).load_module()

def collapsed(text):
    """The transform's own entry point, and the passes it named itself into.

    `applied` is how a case can be checked for the right reason rather than
    only the right answer — a cut made by the wrong pass still prints the
    string you wanted.
    """
    applied = []
    return repetitions.collapse(text, applied), applied


def score(verbose):
    """The two failure kinds counted apart, because they cost differently."""
    cases = yaml.safe_load(CASES.read_text())["cases"]
    passed = missed = damaged = wrong = 0

    for case in cases:
        got, applied = collapsed(case["input"])
        # No `expect` means "comes back exactly as it went in" — the --eval
        # contract, in docs/cli.md.
        keep = "expect" not in case
        want = case["input"] if keep else case["expect"]

        if got == want:
            passed += 1
            if verbose:
                names = ", ".join(dict.fromkeys(applied))
                print(f"  ✓ {case['input']}" + (f"  [{names}]" if names else ""))
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
        out, _ = collapsed(text)
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
        out, applied = collapsed(args.text)
        print(out)
        if applied:
            print("  " + ", ".join(dict.fromkeys(applied)), file=sys.stderr)
    elif args.corpus:
        corpus()
    else:
        sys.exit(0 if score(args.verbose) else 1)


if __name__ == "__main__":
    main()
