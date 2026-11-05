#!/usr/bin/env python3
"""Score and audit the `money_*` transforms, from the tree.

    ./score.py                              # every language
    ./score.py --lang fr                    # one of them
    ./score.py --verbose                    # and show the rules
    ./score.py --text "20 dollars" --lang en
    ./score.py --cross                      # each script on the other's cases
    ./score.py --corpus                     # every edit it would make to the
                                            # archive

A language is a file: `<lang>.py` beside this one, with `cases-<lang>.yaml`
next to it.

The inputs are what `numbers_<lang>` writes, not what was dictated: this stage
runs below it in the pipeline. "twenty dollars" is not a case; "20 dollars" is.

`--cross` is the check nothing else makes. `dollars` and `euros` are spelled
the same in both languages, so the two scripts can fight over one transcript in
a way no pair of `dates` files can. It runs each script over the other
language's case inputs with `ctx.language` set to that other language, and
wants zero changes.

`ParrotFlow --eval money_en` scores the copy the app resolves from the config,
through the real command runner. This scores the copy in the repo. No model
call in this file.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path
from typing import TYPE_CHECKING, cast

try:
    import yaml
except ImportError:
    sys.exit("pip install pyyaml")

HERE = Path(__file__).resolve().parent
TRACE = Path.home() / "Recordings/ParrotFlow/trace.jsonl"
sys.path.insert(0, str(HERE))
import engine  # noqa: E402 — the path above is what makes it importable

if TYPE_CHECKING:
    from importlib.abc import Loader
    from importlib.machinery import ModuleSpec
    from types import ModuleType
    from typing import Any, TypedDict

    from typing_extensions import NotRequired

    from engine import Language

    class Case(TypedDict):
        input: str
        expect: NotRequired[str]
        lang: NotRequired[str]


def load(name: str, path: Path) -> ModuleType:
    spec = cast("ModuleSpec", importlib.util.spec_from_file_location(name, path))
    module = importlib.util.module_from_spec(spec)
    cast("Loader", spec.loader).exec_module(module)
    return module


def languages() -> dict[str, Language]:
    """Every `<lang>.py` beside this file, by its two-letter code."""
    found: dict[str, Language] = {}
    for path in sorted(HERE.glob("*.py")):
        if path.stem in ("engine", "score") or len(path.stem) != 2:
            continue
        found[path.stem] = load(path.stem, path)
    return found


def written(module: Language, text: str, language: str | None = None) -> tuple[str, list[str]]:
    """The rewrite, and the rules the module named itself into.

    `language` is `ctx.language`, and the guard it feeds is part of what is
    being scored, so this is the same path `engine.main` takes.
    """
    applied: list[str] = []
    if engine.declines(module.CODE, language, text):
        return text, applied
    return engine.rewrite(text, module.RULES, applied), applied


def cases_for(lang: str) -> list[Case]:
    cases: list[Case] = yaml.safe_load((HERE / f"cases-{lang}.yaml").read_text())["cases"]
    return cases


def score_language(lang: str, module: Language, verbose: bool) -> bool:
    """The two failure kinds counted apart, because they cost differently."""
    cases = cases_for(lang)
    passed = missed = damaged = wrong = 0

    for case in cases:
        got, applied = written(module, case["input"], case.get("lang"))
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
            mark = "left the amount in words"
        else:
            wrong += 1
            mark = "wrote the wrong amount"
        print(f"  ✗ {case['input']}\n      got   {got}\n      want  {want}\n"
              f"      ({mark})")

    total = len(cases)
    keeps = sum(1 for c in cases if "expect" not in c)
    changes = total - keeps
    print(f"  {lang}   {passed}/{total}   change {changes - missed - wrong}/{changes}"
          f"   keep {keeps - damaged}/{keeps}")
    if missed:
        print(f"    {missed} left the amount in words")
    if wrong:
        print(f"    {wrong} wrote the wrong amount")
    if damaged:
        print(f"    {damaged} rewrote text that was already right"
              "  ← the costly one")
    return passed == total


def cross(modules: dict[str, Language]) -> bool:
    """Each script over every other language's inputs. Zero changes is a pass.

    The guard is on, which is the point: this is what stops `money_en` from
    writing "$20" into a French transcript.
    """
    bad = 0
    total = 0
    for lang, module in sorted(modules.items()):
        for other in sorted(modules):
            if other == lang:
                continue
            for case in cases_for(other):
                text = case["input"]
                total += 1
                got, _ = written(module, text, case.get("lang", other))
                if got != text:
                    bad += 1
                    print(f"  ✗ {lang}.py on {other}: {text}\n      got   {got}")
    print(f"  cross   {total - bad}/{total} unchanged")
    return bad == 0


def corpus(modules: dict[str, Language]) -> None:
    """Every edit these stages would make to the archive, for reading by eye.

    Each clip is run at the language the app detected for it, which the trace
    stores in `lang`. Dropping it would turn the cross-language guard off and
    let `en.py` write a French "20 euros" as "$20" — the very thing the guard
    exists to stop, reported as if the pipeline did it. A clip with no `lang`
    is counted and named, not chained: there is nothing to run it as.
    """
    if not TRACE.exists():
        sys.exit(f"no trace at {TRACE}")

    seen: dict[str, tuple[str, str | None]]
    seen, unknown = {}, 0
    for line in TRACE.read_text().splitlines():
        if not line.strip():
            continue
        record: dict[str, Any] = json.loads(line)
        if (record.get("asr") or {}).get("text"):
            seen[record["wav"]] = (record["asr"]["text"], record.get("lang"))

    changed = 0
    for wav, (text, lang) in sorted(seen.items()):
        if not lang:
            unknown += 1
            continue
        applied: list[str]
        out, applied = text, []
        for code, module in modules.items():
            out, fired = written(module, out, lang)
            applied += [f"{code}: {name}" for name in fired]
        if out == text:
            continue
        changed += 1
        print(f"\n{wav}  [{lang}]  [{', '.join(dict.fromkeys(applied))}]")
        for before, after in zip(text.split(". "), out.split(". ")):
            if before != after:
                print(f"  -  {before}")
                print(f"  +  {after}")
    print(f"\n  {len(seen)} clips, {changed} changed"
          + (f", {unknown} skipped with no language" if unknown else ""))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lang", help="one language; every one by default")
    parser.add_argument("--text", help="run one language on one string")
    parser.add_argument("--cross", action="store_true",
                        help="each script on the other language's cases")
    parser.add_argument("--corpus", action="store_true",
                        help="every edit to the archive")
    parser.add_argument("--verbose", action="store_true",
                        help="show passing cases")
    args = parser.parse_args()

    modules = languages()
    if args.lang and not args.cross:
        if args.lang not in modules:
            sys.exit(f"no {args.lang}.py beside score.py — have: "
                     + ", ".join(sorted(modules)))
        modules = {args.lang: modules[args.lang]}

    if args.text:
        text = args.text
        for lang, module in sorted(modules.items()):
            text, applied = written(module, text, args.lang)
            if applied:
                print(f"  {lang}: " + ", ".join(dict.fromkeys(applied)),
                      file=sys.stderr)
        print(text)
    elif args.cross:
        sys.exit(0 if cross(modules) else 1)
    elif args.corpus:
        corpus(modules)
    else:
        ok = all([score_language(lang, module, args.verbose)
                  for lang, module in sorted(modules.items())])
        ok = cross(modules) and ok
        sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
