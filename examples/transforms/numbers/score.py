#!/usr/bin/env python3
"""Score every language of the `numbers` transform without building the app.

    examples/transforms/numbers/score.py               # every language
    examples/transforms/numbers/score.py --lang fr     # one of them
    examples/transforms/numbers/score.py --verbose     # and the passing cases
    examples/transforms/numbers/score.py --text "cent euros" --lang fr
    examples/transforms/numbers/score.py --gate --lang en

A language is a file: `<code>.py` beside this one, with `cases-<code>.yaml`
next to it. Both are found by looking, so adding a language adds nothing here.

`ParrotFlow --eval numbers_en` and `--eval numbers_fr` answer a different
question. They score the copy **installed** at
`~/.config/parrotflow/transforms/examples/numbers/`, which is the user's and
may be older, and they run the real pipeline step. This scores the copy in the
repo. Use it for the loop where you are editing a word table and do not want to
rebuild Swift between tries.

**Two things this cannot score, on purpose.** Language detection is
`NLLanguageRecognizer` and has no Python; and the cross-language guard is a
fact about a whole pipeline — which script goes first, and what the one after
it sees. Both are scored by `scripts/check-pipeline.sh` against
`tests/pipelines/numbers.yaml`. Every case here pins its own language with
`lang:`, so what is measured is the grammar.

**The gate is checked too.** Every case that must change has to match the regex
`<code>.py --when` prints, because that regex is what the pipeline step carries
as `when:`. A gate that misses a word is a silent miss: the step does not run,
the number stays a word, and nothing shows it happened. The regex is read from
the script, never from the config, so this fails when the two drift.

The languages are loaded from the files beside this one rather than
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
# Everything that is not the engine, the scorer or a dotfile.
NOT_A_LANGUAGE = {"engine.py", "score.py"}


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


engine = load(HERE / "engine.py", "engine")


def languages():
    """`[(code, grammar, cases path)]`, one per language file in the folder."""
    found = []
    for path in sorted(HERE.glob("*.py")):
        if path.name in NOT_A_LANGUAGE or path.name.startswith("_"):
            continue
        module = load(path, path.stem)
        grammar = getattr(module, "GRAMMAR", None)
        if grammar is None:
            continue
        found.append((grammar.code, grammar, HERE / f"cases-{grammar.code}.yaml"))
    return found


def score_one(code, grammar, cases_path, verbose):
    """The two failure kinds counted apart, because they cost differently."""
    if not cases_path.exists():
        print(f"  ✗ {code}: no {cases_path.name} beside {code}.py")
        return 0, 1
    cases = yaml.safe_load(cases_path.read_text())["cases"]
    gate = re.compile(engine.gate(grammar))
    passed = missed = damaged = wrong = ungated = 0
    by_probe = {}

    for case in cases:
        # `lang:` pins the language, so the cross-language guard is off.
        got, _ = engine.read(case["input"], grammar, case.get("lang", code))
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
                print(f"  ✓ [{code}] {case['input']}")
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
            print(f"  ✗ [{code}] {case['input']}\n      got   {got}"
                  f"\n      want  {want}\n      ({mark})")

        # The gate only has to let the changing cases through. A `keep` case
        # the gate skips is a `keep` case that came back unchanged, which is
        # the right answer by a shorter route.
        if not keep and not gate.search(case["input"]):
            ungated += 1
            print(f"  ✗ [{code}] {case['input']}\n"
                  "      (the `when:` gate does not match — this step would"
                  " never run on it)")

    total = len(cases)
    keeps = sum(1 for c in cases if "expect" not in c)
    changes = total - keeps
    print(f"\n  {code}  {passed}/{total}   change {changes - missed - wrong}/{changes}"
          f"   keep {keeps - damaged}/{keeps}")
    for probe in sorted(by_probe):
        seen, ok = by_probe[probe]
        print(f"      {probe or '(none)':12} {ok}/{seen}")
    if missed:
        print(f"      {missed} left as words")
    if wrong:
        print(f"      {wrong} wrong number")
    if damaged:
        print(f"      {damaged} wrote digits into a sentence that was right"
              "  ← the costly one")
    if ungated:
        print(f"      {ungated} would never reach the step — the `when:` gate"
              " misses a word")
    return passed, total - passed + ungated


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lang", help="one language code; default is all of them")
    parser.add_argument("--text", help="run the pass on one string")
    parser.add_argument("--gate", action="store_true", help="print the `when:` regex")
    parser.add_argument("--verbose", action="store_true", help="show passing cases")
    args = parser.parse_args()

    found = languages()
    if args.lang:
        found = [entry for entry in found if entry[0] == args.lang]
        if not found:
            sys.exit(f"no {args.lang}.py beside {HERE}")

    if args.gate:
        for code, grammar, _ in found:
            print(engine.gate(grammar))
        return
    if args.text:
        for code, grammar, _ in found:
            out, count = engine.read(args.text, grammar, code)
            print(f"{code}  {out}" if len(found) > 1 else out)
        return

    passed = failed = 0
    for code, grammar, cases in found:
        ok, bad = score_one(code, grammar, cases, args.verbose)
        passed += ok
        failed += bad
        print()
    print(f"  {passed}/{passed + failed} over {len(found)} language(s)")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
