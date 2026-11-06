#!/usr/bin/env python3
"""Score `sentence_repair` against cases.yaml, from the tree.

    built-in/transforms/sentence_repair/score.py            # score the cases
    built-in/transforms/sentence_repair/score.py --verbose  # and the passes
    built-in/transforms/sentence_repair/score.py --record .build/release/ParrotFlow

Each case is scored with the envelope the app hands the transform: the syrinx
parse, Qwen's readings and the abbreviation list, recorded in `envelopes.json`.
So this runs in CI, where neither model is. `--record` writes the file through
the binary's `--eval`, one process for every case, with a script that only
saves what it is handed. It needs both models on disk. Record again after
changing a case, the parser or the sentence model.

A case may carry `written:`, the words the `vocabulary` stage wrote before
this one ran. `--eval` has no vocabulary stage, so only this file reads it.
`protected:` sets the raw value that stage published, in place of `written:`.

No model call anywhere in this file, except the binary `--record` runs.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import TYPE_CHECKING, cast

if TYPE_CHECKING:
    from collections.abc import Iterable
    from importlib.abc import Loader
    from importlib.machinery import ModuleSpec
    from typing import Literal, TypedDict

    from envelope import Envelope, Readings, Scalar
    from sentence_repair import Edit
    from typing_extensions import NotRequired

    class Case(TypedDict):
        input: str
        expect: NotRequired[str]
        lang: NotRequired[str]
        language: NotRequired[str]
        written: NotRequired[list[str]]
        protected: NotRequired[Scalar]

    Field = Literal["text", "upos", "head", "deprel", "ner"]

    class RecordedWord(TypedDict):
        text: str
        upos: str
        head: int
        deprel: str
        ner: str | None

    class RecordedParse(TypedDict):
        language: str
        words: list[RecordedWord]

    class Recorded(TypedDict):
        """What envelopes.json keeps of an envelope."""
        language: str | None
        abbreviations: Scalar | None
        parse: RecordedParse | None
        readings: Readings | None

    class ReplayedCtx(TypedDict):
        language: str | None
        vars: dict[str, dict[str, Scalar | None]]

    class Replayed(TypedDict):
        """An envelope rebuilt from a `Recorded`: no tokens, no `aligned`."""
        text: str
        ctx: ReplayedCtx
        parse: RecordedParse | None
        readings: Readings | None

try:
    import yaml
except ImportError:
    sys.exit("pip install pyyaml")

HERE = Path(__file__).resolve().parent
CASES = HERE / "cases.yaml"
ENVELOPES = HERE / "envelopes.json"
PARSE_FIELDS: tuple[Field, ...] = ("text", "upos", "head", "deprel", "ner")

_spec = cast("ModuleSpec", importlib.util.spec_from_file_location("sentence_repair", HERE / "sentence_repair.py"))
sentence_repair = importlib.util.module_from_spec(_spec)
cast("Loader", _spec.loader).exec_module(sentence_repair)

SAVE = r'''#!/usr/bin/env python3
import json, os, sys
envelope = json.load(sys.stdin)
with open(os.environ["SENTENCE_REPAIR_RECORD"], "a") as f:
    f.write(json.dumps(envelope, ensure_ascii=False) + "\n")
print("{}")
'''


def language(case: Case) -> str:
    return case.get("lang") or case.get("language") or "en"


def envelopes(binary: str, inputs: list[tuple[str, str]], strict: bool = True) -> dict[str, Recorded]:
    """What the app hands the transform for each (text, language), by text."""
    work: str | Path
    with tempfile.TemporaryDirectory() as work:
        work = Path(work)
        (work / "save.py").write_text(SAVE)
        (work / "save.py").chmod(0o755)
        (work / "cases.yaml").write_text(yaml.safe_dump({
            "transform": "save",
            "transforms": [{"name": "save", "description": "saves the envelope",
                            "command": str(work / "save.py"), "returns": "json",
                            "parse": True, "readings": True}],
            "cases": [{"input": text, "lang": lang} for text, lang in inputs],
        }, allow_unicode=True))
        record = work / "record.jsonl"
        (work / "config").mkdir()
        run = subprocess.run(
            [binary, "--eval", str(work / "cases.yaml")], capture_output=True, text=True,
            stdin=subprocess.DEVNULL, timeout=540,
            env={**os.environ, "PARROTFLOW_CONFIG_DIR": str(work / "config"),
                 "SENTENCE_REPAIR_RECORD": str(record)})
        saved: list[Envelope] = [json.loads(line) for line in record.read_text().splitlines()] \
            if record.exists() else []
    found: dict[str, Recorded] = {}
    for envelope in saved:
        parse = envelope.get("parse")
        found[envelope["text"]] = {
            "language": envelope["ctx"].get("language"),
            "abbreviations": envelope["ctx"]["vars"].get("lists", {}).get("abbreviations"),
            "parse": parse and cast("RecordedParse", {"language": parse["language"], "words": [
                {k: w[k] for k in PARSE_FIELDS} for w in parse["words"]]}),
            "readings": envelope.get("readings"),
        }
    missing = [text for text, _ in inputs if text not in found]
    if missing and strict:
        sys.exit(f"{binary} --eval handed nothing over for {len(missing)} of {len(inputs)}:\n"
                 + run.stdout[-2000:] + run.stderr[-2000:])
    return found


def through(binary: str, inputs: list[tuple[str, str]]) -> dict[str, tuple[str, list[Edit], Recorded]]:
    """Each (text, language) through the transform, with the envelope the
    binary hands it: text -> (repaired, edits, recorded envelope). A text the
    app hands no transform, a spoken command, is left out."""
    found = envelopes(binary, inputs, strict=False)
    if inputs and not found:
        sys.exit(f"{binary} --eval handed the transform nothing for {len(inputs)} text(s)")
    out: dict[str, tuple[str, list[Edit], Recorded]] = {}
    for text, _ in inputs:
        if text not in found:
            continue
        got, edits, _ = sentence_repair.repair(text, envelope_of(text, found[text]))
        out[text] = (got, edits, found[text])
    return out


def record(binary: str) -> None:
    cases: list[Case] = yaml.safe_load(CASES.read_text())["cases"]
    inputs = sorted({(case["input"], language(case)) for case in cases})
    found = envelopes(binary, inputs)
    unread = [t for t, e in found.items()
              if not e["parse"] or not e["readings"] or e["readings"].get("missing")]
    if unread:
        sys.exit(f"  ✗ {len(unread)} case(s) recorded without a parse or readings;"
                 " is each model on disk?")
    ENVELOPES.write_text("{\n" + ",\n".join(
        f"{json.dumps(t, ensure_ascii=False)}: {json.dumps(found[t], ensure_ascii=False)}"
        for t, _ in inputs) + "\n}\n")
    print(f"  {len(found)} envelopes written to {ENVELOPES.name}")


def envelope_of(text: str, recorded: Recorded, written: Iterable[str] = (),
                protected: Scalar | None = None) -> Replayed:
    """The envelope the app would hand over, from what was recorded."""
    return {
        "text": text,
        "ctx": {"language": recorded["language"], "vars": {
            "lists": {"abbreviations": recorded["abbreviations"]},
            "vocabulary": {"protected": "; ".join(written) if protected is None else protected},
        }},
        "parse": recorded["parse"],
        "readings": recorded["readings"],
    }


def score(verbose: bool) -> bool:
    cases: list[Case] = yaml.safe_load(CASES.read_text())["cases"]
    recorded: dict[str, Recorded] = json.loads(ENVELOPES.read_text())
    failed = 0
    for case in cases:
        want = case.get("expect", case["input"])
        if case["input"] not in recorded:
            failed += 1
            print(f"  ✗ {case['input']}\n      (no envelope recorded — run --record)")
            continue
        got, edits, declined = sentence_repair.repair(
            case["input"], envelope_of(case["input"], recorded[case["input"]],
                                       case.get("written", ()), case.get("protected")))
        rules = ", ".join(sorted({e.rule for e in edits}))
        if got == want and not declined:
            if verbose:
                print(f"  ✓ {case['input']}" + (f"  [{rules}]" if rules else ""))
            continue
        failed += 1
        print(f"  ✗ {case['input']}\n      got   {got}\n      want  {want}"
              + (f"\n      declined: {declined}" if declined else ""))
    keeps = sum(1 for c in cases if "expect" not in c)
    print(f"\n  {len(cases) - failed}/{len(cases)}   ({len(cases) - keeps} change, {keeps} keep)")
    return failed == 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--record", metavar="BINARY")
    args = parser.parse_args()
    if args.record:
        record(args.record)
        return 0
    return 0 if score(args.verbose) else 1


if __name__ == "__main__":
    raise SystemExit(main())
