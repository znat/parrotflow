#!/usr/bin/env python3
"""Score and audit the `disfluency` transform without building the app.

    built-in/transforms/disfluency/score.py            # score the case set
    built-in/transforms/disfluency/score.py --verbose  # and show the passes
    built-in/transforms/disfluency/score.py --text "the the prompt"
    built-in/transforms/disfluency/score.py --corpus   # every edit it would
                                                        # make to the archive
    built-in/transforms/disfluency/score.py --record .build/debug/ParrotFlow

`ParrotFlow --eval disfluency` answers a different question, and the numbers
differ for a reason worth knowing: `--eval` scores the copy **installed** at
`~/.config/parrotflow/transforms/disfluency/`, which is the user's and may be
older. This scores the copy in the repo, beside it. Measured on 2026-08-19 the
installed set had 60 cases and this one 65.

So `--eval` says what your machine is running, and this says what the tree
says. Use this for the loop where you are editing a stop list and do not want
to rebuild Swift between tries, and for `--corpus`, which `--eval` cannot do.

The transform is loaded from `disfluency.py` beside this file rather than
reimplemented here. A runner that reimplements the thing it scores
drifts from it, and the number then describes code nobody ships.

The filler rule and the tree cutter read the syrinx parse. Every case is
scored with its parse in `parses.json`, vectors included, as `parse: vectors`
hands it over. `--record` writes it with the binary's `--parse --batch
--vectors`, so this runs anywhere and skips nothing. Record again after
changing a case or the parser.

**No model call anywhere in this file**, except the binary `--record` runs.
"""
import argparse
import json
import math
import os
import subprocess
import sys
import tempfile
from pathlib import Path
import importlib.util

try:
    import yaml
except ImportError:
    sys.exit("pip install pyyaml")

# Everything is found beside this file, so the folder stays the one thing you
# copy: the transform, its cases and the runner that scores them.
HERE = Path(__file__).resolve().parent
TRANSFORM = HERE / "disfluency.py"
CASES = HERE / "cases.yaml"
PARSES = HERE / "parses.json"
# What the filler rule and the tree cutter read of a parse word.
FIELDS = ("text", "upos", "head", "deprel", "tags", "vector")
TRACE = Path.home() / "Recordings/ParrotFlow/trace.jsonl"

_spec = importlib.util.spec_from_file_location("disfluency", TRANSFORM)
disfluency = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(disfluency)

def language(case):
    return case.get("lang") or case.get("language") or "en"


def collapsed(text, lang="en", parse=None):
    """The transform's own entry point, and the passes it named itself into.

    `applied` is how a case can be checked for the right reason rather than
    only the right answer — a cut made by the wrong pass still prints the
    string you wanted.
    """
    out, applied, _ = disfluency.clean(text, lang, parse)
    return out, applied


def record(binary):
    """The parse of every case, as the envelope carries it."""
    langs = {c["input"]: language(c) for c in yaml.safe_load(CASES.read_text())["cases"]}
    inputs = sorted(langs)
    items = [{"id": str(i), "language": langs[t], "text": t} for i, t in enumerate(inputs)]
    # A scratch config: the binary loads one, and prunes its transforms/built-in.
    with tempfile.NamedTemporaryFile("w", suffix=".json") as batch, \
            tempfile.TemporaryDirectory() as config:
        json.dump(items, batch)
        batch.flush()
        run = subprocess.run([binary, "--parse", "--batch", batch.name, "--vectors"],
                             capture_output=True, text=True, check=False,
                             env={**os.environ, "PARROTFLOW_CONFIG_DIR": config})
    rows = {}
    for line in run.stdout.splitlines():
        row = json.loads(line) if line.startswith("{") else {}
        if "words" in row:
            for word in row["words"]:
                # The envelope rounds the tags to 4 places; the batch does not.
                word["tags"] = [math.floor(p * 10_000 + 0.5) / 10_000 for p in word["tags"]]
            rows[inputs[int(row["id"])]] = {
                "language": row["language"], "tag_names": row["tag_names"],
                "words": [{k: w[k] for k in FIELDS} for w in row["words"]]}
    missing = [t for t in inputs if t not in rows]
    if missing:
        sys.exit(f"{binary} --parse gave nothing for {len(missing)} of {len(inputs)}:\n"
                 + run.stdout[-2000:] + run.stderr[-2000:])
    PARSES.write_text("{\n" + ",\n".join(
        f"{json.dumps(t, ensure_ascii=False)}: {json.dumps(rows[t], ensure_ascii=False)}"
        for t in inputs) + "\n}\n")
    print(f"  {len(rows)} parses written to {PARSES.name}")


def score(verbose):
    """The two failure kinds counted apart, because they cost differently."""
    cases = yaml.safe_load(CASES.read_text())["cases"]
    parses = json.loads(PARSES.read_text())
    passed = missed = damaged = wrong = known = 0
    unparsed = {"change": 0, "keep": 0}

    for case in cases:
        if case["input"] not in parses:
            # A failure, not a skip: a skipped case once printed "keep 44/44"
            # on a machine where eight of those keeps never ran.
            unparsed["keep" if "expect" not in case else "change"] += 1
            print(f"  ✗ {case['input']}\n      (no parse recorded — run --record)")
            continue
        got, applied = collapsed(case["input"], language(case), parses.get(case["input"]))
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

        # A cut the parse does not support, named in the case with the output
        # it gives instead. Any other output fails. Never a keep: those are the
        # costly half.
        if case.get("misses") and not keep and got == case.get("got"):
            known += 1
            print(f"  ~ {case['input']}\n      got   {got}\n      want  {want}"
                  f"\n      (known miss: {case['misses']})")
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
    print(f"\n  {passed}/{total}   collapse {changes - missed - wrong - known - unparsed['change']}/{changes}"
          f"   keep {keeps - damaged - unparsed['keep']}/{keeps}")
    if known:
        print(f"    {known} known miss(es), named in cases.yaml")
    if sum(unparsed.values()):
        print(f"    {sum(unparsed.values())} case(s) with no parse recorded")
    if missed:
        print(f"    {missed} left the stutter in")
    if wrong:
        print(f"    {wrong} collapsed the wrong thing")
    if damaged:
        print(f"    {damaged} collapsed a repetition the speaker meant  ← the costly one")
    return passed + known == total


def corpus():
    """Every edit this pass would make to the archive, for reading by eye.

    The case set says it is right on the cases someone thought of. This says
    what it does to 281 real dictations, which is the only place an unguarded
    rule shows itself. The trace holds no parse, so the filler rule is skipped.
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
    parser.add_argument("--record", metavar="BINARY",
                        help="write parses.json with this ParrotFlow binary's --parse")
    args = parser.parse_args()

    if args.record:
        record(args.record)
    elif args.text:
        parse = json.loads(PARSES.read_text()).get(args.text)
        out, applied, declined = disfluency.clean(
            args.text, (parse or {}).get("language", "en"), parse)
        print(out)
        if applied:
            print("  " + ", ".join(dict.fromkeys(applied)), file=sys.stderr)
        if declined:
            print("  " + declined, file=sys.stderr)
    elif args.corpus:
        corpus()
    else:
        sys.exit(0 if score(args.verbose) else 1)


if __name__ == "__main__":
    main()
