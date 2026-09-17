#!/usr/bin/env python3
"""Score every language of the `numbers` transform, from the tree.

    ./score.py                                  # every language
    ./score.py --lang fr                        # one of them
    ./score.py --verbose                        # and the passing cases
    ./score.py --text "cent euros" --lang fr    # one line

A language is a file: `<code>.py` beside this one, with `cases-<code>.yaml`
next to it. Both are found by looking, so adding a language adds nothing here.
Every case pins its language with `lang:`, so what is scored is the grammar.

`ParrotFlow --eval numbers_en` scores the copy installed under
`~/.config/parrotflow/transforms/`, through the real pipeline step. This scores
the copy in the repo, for the loop where a word table changes and rebuilding
Swift between tries is the slow part.

The order of the steps and the cross-language guard are facts about a whole
pipeline; `scripts/check-pipeline.sh` scores those. No model call in this file.
"""
import argparse
import importlib.util
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
    passed = missed = damaged = wrong = 0
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
    return passed, total - passed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lang", help="one language code; default is all of them")
    parser.add_argument("--text", help="run the pass on one string")
    parser.add_argument("--verbose", action="store_true", help="show passing cases")
    args = parser.parse_args()

    found = languages()
    if args.lang:
        found = [entry for entry in found if entry[0] == args.lang]
        if not found:
            sys.exit(f"no {args.lang}.py beside {HERE}")

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
