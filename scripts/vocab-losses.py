#!/usr/bin/env python3
"""The clips the vocabulary pass took away, written out one by one.

    scripts/vocab-losses.py <ablation.json> [--out tests/vocabulary-losses.txt]

Reads what `scripts/vocab-ablation.py --out` wrote and prints every loss — a
clip the app got right with the pass off and wrong with it on — with the hand
label, the vocab-off transcript and the vocab-on transcript.

Each loss is also classed. **Overwrite** means a vocabulary term stands in the
vocab-on transcript that is not in what the speaker said: the pass wrote a name
over an ordinary word. Anything else is **other**, and other is worth reading
twice — it is the class where the pass broke a clip without writing a term
into it, which no floor and no judge prompt can reach.
"""
import argparse
import json
import re
import sys
from pathlib import Path
from importlib.machinery import SourceFileLoader

ROOT = Path(__file__).resolve().parent.parent
recall = SourceFileLoader("recall", str(ROOT / "scripts/menu-recall.py")).load_module()


def terms_of(vocabulary_yaml):
    """The term names, read off the `terms:` block by indentation."""
    names, inside = [], False
    for line in Path(vocabulary_yaml).read_text().splitlines():
        if line.startswith("terms:"):
            inside = True
            continue
        if inside:
            m = re.match(r"  (\w[\w.'-]*):\s*$", line)
            if m:
                names.append(m.group(1))
            elif line and not line.startswith(" "):
                break
    return names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rows")
    ap.add_argument("--vocabulary", required=True)
    ap.add_argument("--out", default="")
    args = ap.parse_args()

    rows = json.loads(Path(args.rows).read_text())
    names = terms_of(args.vocabulary)

    def wrote_a_term(row, text):
        """Terms in the transcript that are not in what the speaker said."""
        said = recall.normalise(row["said"])
        got = recall.normalise(text)
        return [n for n in names
                if re.search(rf"\b{n.lower()}\b", got)
                and not re.search(rf"\b{n.lower()}\b", said)]

    def pick(row, arm, want):
        """A transcript from a run that agreed with the majority verdict."""
        truth = recall.normalise(row["said"])
        for text in row[arm]:
            if (recall.normalise(text) == truth) == want:
                return text
        return row[arm][0]

    losses = [r for r in rows if r["off_ok"] and not r["on_ok"]]
    wins = [r for r in rows if r["on_ok"] and not r["off_ok"]]

    out = []
    out.append("Every clip the vocabulary pass took away.")
    out.append("")
    out.append("`off` is the transcript with the whole pass switched off — no acoustic")
    out.append("search, no `heard:` rules, no judge. `on` is the shipped pass. Both are")
    out.append("replays of the same audio through the same build, majority of 3 runs.")
    out.append("Written by scripts/vocab-losses.py.")
    out.append("")
    out.append(f"{len(losses)} losses, against {len(wins)} wins over {len(rows)} clips.")
    out.append("")

    overwrites, others = [], []
    for row in losses:
        on_text = pick(row, "on", False)
        off_text = pick(row, "off", True)
        written = wrote_a_term(row, on_text)
        (overwrites if written else others).append((row, on_text, off_text, written))

    out.append(f"{len(overwrites)} overwrites — a term written over a word the speaker meant.")
    out.append(f"{len(others)} other — the pass broke the clip without writing a term in.")
    out.append("")

    for title, group in (("OVERWRITES", overwrites), ("OTHER", others)):
        if not group:
            continue
        out.append("=" * 72)
        out.append(f"{title}  ({len(group)})")
        out.append("=" * 72)
        for row, on_text, off_text, written in group:
            klass = "term" if row["term"] else "control"
            out.append("")
            out.append(f"{row['wav']}  [{klass}]"
                       + (f"  wrote: {', '.join(written)}" if written else ""))
            out.append(f"  said: {row['said']}")
            out.append(f"  off:  {off_text}")
            out.append(f"  on:   {on_text}")
        out.append("")

    text = "\n".join(out) + "\n"
    if args.out:
        Path(args.out).write_text(text)
        print(f"wrote {args.out}  ({len(losses)} losses)")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
