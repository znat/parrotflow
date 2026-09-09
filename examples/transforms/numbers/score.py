#!/usr/bin/env python3
"""Score and audit the `numbers` transform without building the app.

    examples/transforms/numbers/score.py            # score the case set
    examples/transforms/numbers/score.py --verbose  # and show the passing ones
    examples/transforms/numbers/score.py --text "two hundred forty-three"
    examples/transforms/numbers/score.py --text "cent euros" --lang fr
    examples/transforms/numbers/score.py --gate     # print the `when:` regex

`ParrotFlow --eval numbers` answers a different question. `--eval` scores the
copy **installed** at `~/.config/parrotflow/transforms/examples/numbers/`,
which is the user's and may be older, and it runs the whole pipeline step —
including language detection, which is `NLLanguageRecognizer` and has no
Python. This scores the copy in the repo, beside it.

So `--eval` says what your machine is running, and this says what the tree
says. Use this for the loop where you are editing a word table and do not want
to rebuild Swift between tries.

**Detection is the one thing this cannot do.** A case with `lang:` pins that
grammar and nothing else is tried, which is what the old `check-numbers.sh`
did. A case without one is given the first configured language as the detected
one — what the app does below four words — and the whole list to fall through.
That stand-in gets every case in this set right, but it is a stand-in. Run
`ParrotFlow --eval numbers` to score what detection really does; the
`auto_collide` cases are the ones it decides.

**The gate is checked too.** Every case that must change has to match the
regex `numbers.py --when` prints, because that regex is what the pipeline step
carries as `when:`. A gate that misses a word is a silent miss: the stage does
not run, the number stays a word, and nothing shows it happened. The regex is
read from the script, never from the config, so this fails when the two drift.

The transform is loaded from `numbers.py` beside this file rather than
reimplemented here. A runner that reimplements the thing it scores drifts from
it, and the number then describes code nobody ships.

**No model call anywhere in this file.**
"""
import argparse
import importlib.util
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("pip install pyyaml")

HERE = Path(__file__).resolve().parent
TRANSFORM = HERE / "numbers.py"
CASES = HERE / "cases.yaml"

_spec = importlib.util.spec_from_file_location("numbers", TRANSFORM)
numbers = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(numbers)

# `transcription.languages` in config.example.yaml, most spoken first. Stated
# rather than read off this machine: a case file scored against whichever
# languages the machine happens to have configured describes that machine, not
# the tree. That mistake once cost this set six cases.
LANGUAGES = ["en", "fr"]


def run(text, lang, languages):
    """One line, the way the case says to read it.

    `lang` pins one grammar and nothing else is tried. No `lang` means the
    first configured language stands in for the detected one, and the rest of
    the list is the fallback the multi-language rule walks.
    """
    if lang:
        return numbers.read(text, lang, [lang])[0]
    return numbers.read(text, languages[0], languages)[0]


def score(verbose, languages):
    """The two failure kinds counted apart, because they cost differently."""
    cases = yaml.safe_load(CASES.read_text())["cases"]
    gate = re.compile(numbers.gate())
    passed = missed = damaged = wrong = ungated = 0
    by_probe = {}

    for case in cases:
        lang = case.get("lang")
        got = run(case["input"], lang, languages)
        # No `expect` means "comes back exactly as it went in" — the --eval
        # contract, in docs/cli.md.
        keep = "expect" not in case
        want = case["input"] if keep else str(case["expect"])
        probe = case.get("probe", "")
        seen, ok = by_probe.get(probe, (0, 0))

        if got == want:
            passed += 1
            by_probe[probe] = (seen + 1, ok + 1)
            if verbose:
                print(f"  ✓ [{lang or 'auto'}] {case['input']}")
        else:
            by_probe[probe] = (seen + 1, ok)
            if keep:
                damaged += 1
                mark = "wrote digits into a sentence that was right"
            elif got == case["input"]:
                missed += 1
                mark = "left as words"
            else:
                wrong += 1
                mark = "wrong number"
            print(f"  ✗ [{lang or 'auto'}] {case['input']}\n      got   {got}"
                  f"\n      want  {want}\n      ({mark})")

        # The gate only has to let the changing cases through. A `keep` case
        # that the gate skips is a `keep` case that came back unchanged, which
        # is the right answer by a shorter route.
        if not keep and not gate.search(case["input"]):
            ungated += 1
            print(f"  ✗ [{lang or 'auto'}] {case['input']}\n"
                  "      (the `when:` gate does not match — this stage would"
                  " never run on it)")

    total = len(cases)
    keeps = sum(1 for c in cases if "expect" not in c)
    changes = total - keeps
    print(f"\n  {passed}/{total}   change {changes - missed - wrong}/{changes}"
          f"   keep {keeps - damaged}/{keeps}")
    for probe in sorted(by_probe):
        seen, ok = by_probe[probe]
        print(f"    {probe or '(none)':16} {ok}/{seen}")
    if missed:
        print(f"    {missed} left as words")
    if wrong:
        print(f"    {wrong} wrong number")
    if damaged:
        print(f"    {damaged} wrote digits into a sentence that was right"
              "  ← the costly one")
    if ungated:
        print(f"    {ungated} would never reach the stage — the `when:` gate"
              " misses a word")
    return passed == total and ungated == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--text", help="run the pass on one string")
    parser.add_argument("--lang", help="pin one grammar, or a comma-separated list")
    parser.add_argument("--gate", action="store_true", help="print the `when:` regex")
    parser.add_argument("--verbose", action="store_true", help="show passing cases")
    args = parser.parse_args()

    languages = ([code.strip() for code in args.lang.split(",") if code.strip()]
                 if args.lang else LANGUAGES)

    if args.gate:
        print(numbers.gate())
    elif args.text:
        out, read_by, count = numbers.read(args.text, languages[0], languages)
        print(out)
        print(f"  {read_by}, {count} written", file=sys.stderr)
    else:
        sys.exit(0 if score(args.verbose, languages) else 1)


if __name__ == "__main__":
    main()
