#!/usr/bin/env python3
"""Score and audit the `dates_*` transforms, from the tree.

    ./score.py                              # every language
    ./score.py --lang fr                    # one of them
    ./score.py --verbose                    # and show the rules
    ./score.py --text "at ten fifteen" --lang en
    ./score.py --corpus                     # every edit it would make to the
                                            # archive

A language is a file: `<lang>.py` beside this one, with `cases-<lang>.yaml` next
to it. `cases-<lang>-clock.yaml`, when it is there, is scored too: its cases
carry a `now:`, which this puts in `PARROTFLOW_NOW` for that case alone so the
wall-clock rule has a fixed answer. `--eval` never reads that file — it runs
against the real clock, and `cases-<lang>.yaml` is clock-free for that reason.

`ParrotFlow --eval dates_en` scores the copy the app resolves from the config,
through the real command runner. This scores the copy in the repo, and it is
the only one that can do `--corpus`. No model call in this file.
"""
import argparse
import importlib.util
import json
import os
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("pip install pyyaml")

HERE = Path(__file__).resolve().parent
TRACE = Path.home() / "Recordings/ParrotFlow/trace.jsonl"
sys.path.insert(0, str(HERE))
import engine  # noqa: E402 — the path above is what makes it importable


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def languages():
    """Every `<lang>.py` beside this file, by its two-letter code.

    A language is a file, so this is a directory listing. `engine.py` and this
    script are the two that are not languages.
    """
    found = {}
    for path in sorted(HERE.glob("*.py")):
        if path.stem in ("engine", "score") or len(path.stem) != 2:
            continue
        found[path.stem] = load(path.stem, path)
    return found


def written(module, text):
    """The rewrite, and the rules the module named itself into."""
    applied = []
    return engine.rewrite(text, module.RULES, applied), applied


def cases_for(lang):
    """Every case of `lang`, the clock set after the clock-free one."""
    found = yaml.safe_load((HERE / f"cases-{lang}.yaml").read_text())["cases"]
    clock = HERE / f"cases-{lang}-clock.yaml"
    if clock.exists():
        found += yaml.safe_load(clock.read_text())["cases"]
    return found


def score_language(lang, module, verbose):
    """The two failure kinds counted apart, because they cost differently."""
    cases = cases_for(lang)
    passed = missed = damaged = wrong = 0

    for case in cases:
        if case.get("now"):
            os.environ["PARROTFLOW_NOW"] = case["now"]
        else:
            os.environ.pop("PARROTFLOW_NOW", None)
        got, applied = written(module, case["input"])
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
    print(f"  {lang}   {passed}/{total}   change {changes - missed - wrong}/{changes}"
          f"   keep {keeps - damaged}/{keeps}")
    if missed:
        print(f"    {missed} left the date or the time in words")
    if wrong:
        print(f"    {wrong} wrote the wrong date or time")
    if damaged:
        print(f"    {damaged} rewrote text that was already right"
              "  ← the costly one")
    return passed == total


def corpus(modules):
    """Every edit these stages would make to the archive, for reading by eye.

    The case sets say they are right on the cases someone thought of. This says
    what they do to real dictations, which is the only place an unguarded rule
    shows itself.
    """
    if not TRACE.exists():
        sys.exit(f"no trace at {TRACE}")

    seen = {}
    for line in TRACE.read_text().splitlines():
        if not line.strip():
            continue
        record = json.loads(line)
        if (record.get("asr") or {}).get("text"):
            seen[record["wav"]] = record["asr"]["text"]

    changed = 0
    for wav, text in sorted(seen.items()):
        out, applied = text, []
        for lang, module in modules.items():
            out, fired = written(module, out)
            applied += [f"{lang}: {name}" for name in fired]
        if out == text:
            continue
        changed += 1
        print(f"\n{wav}  [{', '.join(dict.fromkeys(applied))}]")
        for before, after in zip(text.split(". "), out.split(". ")):
            if before != after:
                print(f"  -  {before}")
                print(f"  +  {after}")
    print(f"\n  {len(seen)} clips, {changed} changed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lang", help="one language; every one by default")
    parser.add_argument("--text", help="run one language on one string")
    parser.add_argument("--corpus", action="store_true",
                        help="every edit to the archive")
    parser.add_argument("--verbose", action="store_true",
                        help="show passing cases")
    args = parser.parse_args()

    modules = languages()
    if args.lang:
        if args.lang not in modules:
            sys.exit(f"no {args.lang}.py beside score.py — have: "
                     + ", ".join(sorted(modules)))
        modules = {args.lang: modules[args.lang]}

    if args.text:
        text = args.text
        for lang, module in sorted(modules.items()):
            text, applied = written(module, text)
            if applied:
                print(f"  {lang}: " + ", ".join(dict.fromkeys(applied)),
                      file=sys.stderr)
        print(text)
    elif args.corpus:
        corpus(modules)
    else:
        ok = all([score_language(lang, module, args.verbose)
                  for lang, module in sorted(modules.items())])
        sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
