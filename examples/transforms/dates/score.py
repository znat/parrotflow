#!/usr/bin/env python3
"""Score and audit the `dates` transform without building the app.

    examples/transforms/dates/score.py            # score the case set
    examples/transforms/dates/score.py --verbose  # and show the rules
    examples/transforms/dates/score.py --text "at ten fifteen" --lang en
    examples/transforms/dates/score.py --corpus   # every edit it would make
                                                  # to the archive

`ParrotFlow --eval examples/transforms/dates/cases.yaml` answers a different
question. It runs the copy the app resolves from the config, through the real
command runner; this runs the copy in the repo, beside it. Use this for the
loop where you are editing a guard and do not want to rebuild Swift between
tries, and for `--corpus`, which `--eval` cannot do.

The transform is loaded from `dates.py` beside this file rather than
reimplemented here. A runner that reimplements the thing it scores drifts from
it, and the number then describes code nobody ships. `dates.py` in turn loads
`../numbers/numbers.py` for its number words, so this needs both folders.

Two checks beyond the cases:

- **Every `change` case must match `dates.py --when`.** A case the gate rejects
  never reaches the script in the app, so it would pass here and do nothing in
  a real dictation.
- **How many `keep` cases the gate lets through** is printed too, and should be
  most of them. A keep case the gate rejects tests no guard.

**No model call anywhere in this file.**
"""
import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("pip install pyyaml")

HERE = Path(__file__).resolve().parent
TRANSFORM = HERE / "dates.py"
CASES = HERE / "cases.yaml"
TRACE = Path.home() / "Recordings/ParrotFlow/trace.jsonl"

_spec = importlib.util.spec_from_file_location("dates", TRANSFORM)
dates = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(dates)

if dates.numbers is None:
    sys.exit(dates.MISSING)


def written(text, language):
    """The transform's own entry point, and the rules it named itself into."""
    applied = []
    return dates.rewrite(text, language, applied), applied


def gate():
    """The `when:` regex, without its slashes, compiled."""
    pattern = dates.when().strip("/")
    return re.compile(pattern, re.I)


def score(verbose):
    """The two failure kinds counted apart, because they cost differently."""
    cases = yaml.safe_load(CASES.read_text())["cases"]
    opens = gate()
    passed = missed = damaged = wrong = ungated = 0
    keeps_gated = 0

    for case in cases:
        got, applied = written(case["input"], case.get("lang"))
        # No `expect` means "comes back exactly as it went in" — the --eval
        # contract, in docs/cli.md.
        keep = "expect" not in case
        want = case["input"] if keep else case["expect"]
        through = bool(opens.search(case["input"]))

        if keep and through:
            keeps_gated += 1
        if not keep and not through:
            ungated += 1
            print(f"  ✗ {case['input']}\n      the when: regex does not match it,"
                  " so the app would never run the script")

        if got == want:
            passed += 1
            if verbose:
                names = ", ".join(dict.fromkeys(applied))
                print(f"  ✓ {case['input']}" + (f"  [{names}]" if names else ""))
            continue

        if keep:
            damaged += 1
            mark = "rewrote text that was already right"
        elif got == case["input"]:
            missed += 1
            mark = "left the date or the time in words"
        else:
            wrong += 1
            mark = "wrote the wrong date or time"
        print(f"  ✗ {case['input']}\n      got   {got}\n      want  {want}\n"
              f"      ({mark})")

    total = len(cases)
    keeps = sum(1 for c in cases if "expect" not in c)
    changes = total - keeps
    print(f"\n  {passed}/{total}   change {changes - missed - wrong}/{changes}"
          f"   keep {keeps - damaged}/{keeps}")
    print(f"  when: lets through {changes - ungated}/{changes} change"
          f" and {keeps_gated}/{keeps} keep cases")
    if missed:
        print(f"    {missed} left the date or the time in words")
    if wrong:
        print(f"    {wrong} wrote the wrong date or time")
    if damaged:
        print(f"    {damaged} rewrote text that was already right"
              "  ← the costly one")
    if ungated:
        print(f"    {ungated} change case(s) the when: regex rejects"
              "  ← the script never runs on them")
    return passed == total and ungated == 0


def corpus():
    """Every edit this stage would make to the archive, for reading by eye.

    The case set says it is right on the cases someone thought of. This says
    what it does to real dictations, which is the only place an unguarded rule
    shows itself. The gate is applied first, so the count of opened clips is
    what the `when:` line actually costs.
    """
    if not TRACE.exists():
        sys.exit(f"no trace at {TRACE}")

    opens = gate()
    seen = {}
    for line in TRACE.read_text().splitlines():
        if not line.strip():
            continue
        record = json.loads(line)
        if (record.get("asr") or {}).get("text"):
            seen[record["wav"]] = (record["asr"]["text"], record.get("lang"))

    through = changed = 0
    for wav, (text, language) in sorted(seen.items()):
        if not opens.search(text):
            continue
        through += 1
        out, applied = written(text, language)
        if out == text:
            continue
        changed += 1
        print(f"\n{wav}  [{', '.join(dict.fromkeys(applied))}]")
        for before, after in zip(text.split(". "), out.split(". ")):
            if before != after:
                print(f"  -  {before}")
                print(f"  +  {after}")
    print(f"\n  {through} of {len(seen)} clips opened the gate,"
          f" {changed} were changed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--text", help="run the stage on one string")
    parser.add_argument("--lang", help="en or fr; both grammars when absent")
    parser.add_argument("--corpus", action="store_true",
                        help="every edit to the archive")
    parser.add_argument("--when", action="store_true",
                        help="print the when: regex and stop")
    parser.add_argument("--verbose", action="store_true",
                        help="show passing cases")
    args = parser.parse_args()

    if args.when:
        print(dates.when())
    elif args.text:
        out, applied = written(args.text, args.lang)
        print(out)
        if applied:
            print("  " + ", ".join(dict.fromkeys(applied)), file=sys.stderr)
    elif args.corpus:
        corpus()
    else:
        sys.exit(0 if score(args.verbose) else 1)


if __name__ == "__main__":
    main()
