#!/usr/bin/env python3
"""Score and audit the `dates_*` transforms without building the app.

    examples/transforms/dates/score.py             # every language
    examples/transforms/dates/score.py --lang fr   # one of them
    examples/transforms/dates/score.py --verbose   # and show the rules
    examples/transforms/dates/score.py --text "at ten fifteen" --lang en
    examples/transforms/dates/score.py --corpus    # every edit it would make
                                                   # to the archive

Every `<lang>.py` beside this file is a language, and `cases-<lang>.yaml` is
its set. Adding a language adds nothing here.

`ParrotFlow --eval dates_en` answers a different question. It runs the copy the
app resolves from the config, through the real command runner; this runs the
copy in the repo, beside it. Use this for the loop where you are editing a
guard and do not want to rebuild Swift between tries, and for `--corpus`, which
`--eval` cannot do.

The language modules are loaded from their own files rather than reimplemented
here. A runner that reimplements the thing it scores drifts from it, and the
number then describes code nobody ships.

Three checks beyond the cases:

- **Every `change` case must match that language's `--when`.** A case the gate
  rejects never reaches the script in the app, so it would pass here and do
  nothing in a real dictation.
- **How many `keep` cases the gate lets through** is printed too. A keep case
  the gate rejects tests the script and not the pipeline, which is safe but
  worth knowing.
- **The `when:` lines in config.example.yaml must be the ones `--when`
  prints.** They are generated, so they go stale when a cue word moves and
  nothing else would say so.

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


def gate(module):
    """That language's `when:` regex, without its slashes, compiled."""
    return re.compile(engine.when(module).strip("/"), re.I)


def score_language(lang, module, verbose):
    """The two failure kinds counted apart, because they cost differently."""
    cases = yaml.safe_load((HERE / f"cases-{lang}.yaml").read_text())["cases"]
    opens = gate(module)
    passed = missed = damaged = wrong = ungated = keeps_gated = 0

    for case in cases:
        got, applied = written(module, case["input"])
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
    print(f"  {lang}   {passed}/{total}   change {changes - missed - wrong}/{changes}"
          f"   keep {keeps - damaged}/{keeps}"
          f"   when: {changes - ungated}/{changes} change"
          f" and {keeps_gated}/{keeps} keep through the gate")
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


def wired_when_is_stale(modules):
    """The languages whose `when:` line in config.example.yaml is out of date.

    Only in a checkout — the folder is copied to `~/.config/parrotflow/` on its
    own, and there is no config.example.yaml above it there.
    """
    example = HERE.parents[2] / "config.example.yaml"
    if not example.exists():
        return []
    written_config = example.read_text()
    return [lang for lang, module in modules.items()
            if engine.when(module) not in written_config]


def corpus(modules):
    """Every edit these stages would make to the archive, for reading by eye.

    The case sets say they are right on the cases someone thought of. This says
    what they do to real dictations, which is the only place an unguarded rule
    shows itself. Each language's gate is applied first, so the count of opened
    clips is what the `when:` lines actually cost.
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

    gates = {lang: gate(module) for lang, module in modules.items()}
    through = {lang: 0 for lang in modules}
    changed = 0
    for wav, text in sorted(seen.items()):
        out, applied = text, []
        for lang, module in modules.items():
            if not gates[lang].search(out):
                continue
            through[lang] += 1
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
    opened = "; ".join(f"{lang} {n}" for lang, n in sorted(through.items()))
    print(f"\n  {len(seen)} clips: gate opened on {opened}."
          f" {changed} clip(s) changed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lang", help="one language; every one by default")
    parser.add_argument("--text", help="run one language on one string")
    parser.add_argument("--corpus", action="store_true",
                        help="every edit to the archive")
    parser.add_argument("--when", action="store_true",
                        help="print the when: regex per language and stop")
    parser.add_argument("--verbose", action="store_true",
                        help="show passing cases")
    args = parser.parse_args()

    modules = languages()
    if args.lang:
        if args.lang not in modules:
            sys.exit(f"no {args.lang}.py beside score.py — have: "
                     + ", ".join(sorted(modules)))
        modules = {args.lang: modules[args.lang]}

    if args.when:
        for lang, module in sorted(modules.items()):
            print(f"{lang}: {engine.when(module)}")
    elif args.text:
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
        stale = wired_when_is_stale(modules)
        if stale:
            print("  ✗ config.example.yaml carries a different when: line for "
                  + ", ".join(sorted(stale))
                  + " — paste `<lang>.py --when` over it")
        sys.exit(0 if ok and not stale else 1)


if __name__ == "__main__":
    main()
