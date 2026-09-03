#!/usr/bin/env python3
"""Writes the fixture the Swift boundary code is checked against.

    scripts/sentence-probe-reference.py readings   -> tests/sentence-boundary-cases.json

It needs the release binary and the Qwen model on disk. It runs
`--sentence-probe --bench` over a sample of the boundary bench and stores what
came back, so the fixture is by construction what the binary produces. Point
--data at the bench directory; its files hold `left` and `right` already
windowed to +-12 words, which is the window the app builds.

Four sets, two marks. --count rows come from the period pair and --questions
rows from the question pair, so raising one does not resample the other. Each
row carries the mark its boundary is written with.

Real endings carrying a hand label are left out. `join` means the period is
wrong, `drop` that the row is not a dictation, and `tie` that both readings are
right — none of the three is a real ending a join would spoil.
"""
import argparse
import json
import os

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def readings(args):
    """A sample of the bench, scored by the release binary."""
    import subprocess
    import tempfile

    labelled = set()
    labels_path = os.path.join(args.data, "en_real_labels.json")
    if os.path.exists(labels_path):
        labels = json.load(open(labels_path))
        for key in ("join", "drop", "tie"):
            labelled |= set(labels.get(key, []))

    sets = (
        ("en_real.json", ".", labelled, args.count // 2),
        ("en_cuts.json", ".", set(), args.count // 2),
        ("enq_real.json", "?", set(), args.questions // 2),
        ("enq_cuts_hard.json", "?", set(), args.questions // 2),
    )

    out = []
    for name, mark, skip, take in sets:
        entries = json.load(open(os.path.join(args.data, name)))
        wanted = [i for i in range(len(entries)) if i not in skip]
        step = max(1, len(wanted) // take)
        wanted = wanted[::step][:take]
        rows = [
            {"left": entries[i]["left"], "right": entries[i]["right"], "mark": mark}
            for i in wanted
        ]
        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as work:
            cases = os.path.join(work, "cases.json")
            scored = os.path.join(work, "scored.json")
            json.dump(rows, open(cases, "w"))
            subprocess.run(
                [args.binary, "--sentence-probe", "--bench", cases, "--out", scored],
                check=True, stdout=subprocess.DEVNULL,
            )
            for row in json.load(open(scored)):
                out.append({
                    "set": name,
                    "mark": mark,
                    "left": rows[row["i"]]["left"],
                    "right": rows[row["i"]]["right"],
                    "winner": row["winner"],
                    "mean": {k: round(v, 4) for k, v in sorted(row["mean"].items())},
                })
    write(args.out or os.path.join(HERE, "tests/sentence-boundary-cases.json"), out)


def write(path, rows):
    with open(path, "w") as handle:
        json.dump(rows, handle, ensure_ascii=False, indent=1)
        handle.write("\n")
    print(f"{len(rows)} cases -> {path}")


parser = argparse.ArgumentParser()
parser.add_argument("what", choices=("readings",))
parser.add_argument("--data", default=".")
parser.add_argument("--binary", default=os.path.join(HERE, ".build/release/ParrotFlow"))
parser.add_argument("--count", type=int, default=40)
parser.add_argument("--questions", type=int, default=20)
parser.add_argument("--out")
readings(parser.parse_args())
