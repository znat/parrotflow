#!/usr/bin/env python3
"""Replay archived dictations through the trunk Python `disfluency` and this
tree's native stage, and print every dictation where they differ.

    ~/Library/Application\\ Support/ParrotFlow/python/bin/python3 \\
        scripts/replay-disfluency.py [--trace PATH] [--limit N] [--binary PATH]

Run it with the interpreter that has spaCy, or trunk cannot judge a marker and
the comparison is void; the script refuses in that case. Build first with
`swift build -c release`.

The input of each dictation is the text the `disfluency` stage was handed,
rebuilt from the trace: `asr.text` with the edits of every earlier stage
applied. Only `source: live` records count, one per clip.

It reads the trace and writes nothing under ~/.config. The binary runs with a
scratch PARROTFLOW_CONFIG_DIR. It loads the parser from the app's model cache,
and fetches it there (519 MB) if it is missing.

Every changed dictation is printed with trunk and head, in three groups. Read
KEEP-looking first: the two differ by more than a marker, or head cut a marker
in a shape that is often a real verb ("let you know", "would like"). The other
two differ only by "I mean", "you know" or "like", commas and case, and say
which side cut it.
"""
import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TRUNK_REF = "origin/main"
MARKER = re.compile(r"\b(?:i\s+mean|you\s+know|like)\b", re.I)
# A marker after or before one of these is often the verb, not a filler.
KEEP_SHAPES = [
    re.compile(r"\b(?:let|do|don't|did|didn't|as|if|sure)\s+you\s+know\b", re.I),
    re.compile(r"\bi\s+mean\s+(?:it|that|what|who|how|when|where|why)\b", re.I),
    re.compile(r"\b(?:would|'d|i|you|we|they|to|look|looks|looked|feel|feels|felt|something)\s+like\b", re.I),
]


def trunk_module():
    source = subprocess.run(
        ["git", "-C", str(ROOT), "show", f"{TRUNK_REF}:built-in/transforms/disfluency/disfluency.py"],
        capture_output=True, text=True, check=True).stdout
    path = Path(tempfile.mkdtemp()) / "disfluency_trunk.py"
    path.write_text(source)
    spec = importlib.util.spec_from_file_location("disfluency_trunk", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if module.spacy_or_none() is None:
        sys.exit("spaCy is not importable from this python, so trunk cannot judge a marker. "
                 "Run with ~/Library/Application Support/ParrotFlow/python/bin/python3.")
    return module


def applied(text, edits):
    for edit in sorted(edits, key=lambda e: e.get("at", 0), reverse=True):
        at, was = edit.get("at", 0), edit.get("was", "")
        if text[at:at + len(was)] != was:
            return None
        text = text[:at] + edit.get("now", "") + text[at + len(was):]
    return text


def stage_input(record):
    """The text `disfluency` was handed, or None when the trace cannot say."""
    text = (record.get("asr") or {}).get("text")
    for stage in record.get("stages") or []:
        if text is None:
            return None
        if stage.get("name") == "transform disfluency":
            return stage.get("before", text)
        if "edits" in stage:
            text = applied(text, stage.get("edits") or [])
        elif "after" in stage:
            text = stage["after"]
    return None


def dictations(trace, limit):
    by_wav, skipped = {}, 0
    for line in trace.read_text(encoding="utf-8").splitlines():
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if record.get("kind", "dictation") != "dictation" or record.get("source", "live") != "live":
            continue
        text = stage_input(record)
        if text and "\n" not in text:
            by_wav[record.get("wav")] = (text, record.get("lang") or "en")
        elif any(s.get("name") == "transform disfluency" for s in record.get("stages") or []):
            skipped += 1
    items = sorted(by_wav.items())
    return (items[-limit:] if limit else items), skipped


def head_outputs(binary, items):
    """Every text through the native stage in one `--eval` run, so the parser loads once."""
    work = Path(tempfile.mkdtemp(prefix="replay-disfluency-"))
    cases = work / "cases.yaml"
    with cases.open("w", encoding="utf-8") as out:
        out.write("transform: disfluency\ntransforms:\n  - name: disfluency\n    description: replay\n"
                  "    native: disfluency\n    fillers: [i mean, you know, like]\ncases:\n")
        for i, (_, (text, lang)) in enumerate(items):
            out.write(f"  - name: r{i}\n    lang: {lang}\n    input: {json.dumps(text, ensure_ascii=False)}\n")
    env = dict(os.environ, PARROTFLOW_CONFIG_DIR=str(work / "config"))
    run = subprocess.run([binary, "--eval", str(cases), "--verbose"],
                         capture_output=True, text=True, encoding="utf-8", env=env)
    if "parser   parrot-syrinx" not in run.stdout:
        sys.exit("the native stage did not load the parser:\n" + run.stdout + run.stderr)
    overall = re.search(r"overall  (\d+)/(\d+)", run.stdout)
    got, name = {}, None
    for line in run.stdout.splitlines():
        found = re.match(r"  ✗ (r\d+)  \[", line)
        if found:
            name = found.group(1)
        elif name and line.startswith("      got   "):
            got[int(name[1:])] = line[len("      got   "):]
            name = None
    if not overall or int(overall.group(2)) != len(items) or len(got) != len(items) - int(overall.group(1)):
        sys.exit("the eval report does not account for every dictation:\n" + run.stdout)
    return [got.get(i, text) for i, (_, (text, _)) in enumerate(items)]


def marker_only(a, b):
    def bare(s):
        return re.sub(r"\s+", " ", MARKER.sub(" ", s).replace(",", " ")).strip().lower()
    return bare(a) == bare(b)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--trace", type=Path, default=Path.home() / ".config/parrotflow/recordings/trace.jsonl")
    parser.add_argument("--limit", type=int, default=0, help="only the last N dictations")
    parser.add_argument("--binary", default=str(ROOT / ".build/release/ParrotFlow"))
    args = parser.parse_args()

    trunk = trunk_module()
    items, skipped = dictations(args.trace, args.limit)
    heads = head_outputs(args.binary, items)
    groups = {"KEEP-looking": [], "head cuts a marker trunk kept": [], "head keeps a marker trunk cut": []}
    for (wav, (text, lang)), head in zip(items, heads):
        old = trunk.clean(text, lang)[0]
        if old == head:
            continue
        cuts_more = len(head) < len(old)
        if not marker_only(old, head) or (cuts_more and any(p.search(text) for p in KEEP_SHAPES)):
            group = "KEEP-looking"
        else:
            group = "head cuts a marker trunk kept" if cuts_more else "head keeps a marker trunk cut"
        groups[group].append((wav, text, old, head))

    for title, rows in groups.items():
        print(f"\n== {title}: {len(rows)}")
        for wav, text, old, head in rows:
            print(f"\n{wav}\n  in     {text}\n  trunk  {old}\n  head   {head}")
    print(f"\n{sum(map(len, groups.values()))} of {len(items)} dictations differ: "
          + ", ".join(f"{len(rows)} {title}" for title, rows in groups.items()))
    if skipped:
        print(f"{skipped} dictation(s) skipped: the trace could not rebuild what `disfluency` was handed,"
              " or it held a line break")


if __name__ == "__main__":
    main()
