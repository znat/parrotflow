#!/usr/bin/env python3
"""The clips the vocabulary pass took away, written out one by one.

    scripts/vocab-losses.py <ablation.json> --vocabulary FILE \\
        [--off off] [--on today] [--out tests/vocabulary-losses.txt]

Reads what `scripts/vocab-ablation.py --out` wrote and prints every loss — a
clip the app got right under the `--off` arm and wrong under the `--on` arm —
with the hand label, both transcripts, and which terms were written in.

A total says how many clips an arm cost. It does not say what the arm did to
them, and the remedy depends on that. So each loss is also classed.
**Overwrite** means a vocabulary term stands in the `--on` transcript that is
not in what the speaker said: the pass wrote a name over an ordinary word.
Anything else is **other**, and other is worth reading twice — it is the class
where the pass broke a clip without writing a term into it, which no floor and
no judge prompt can reach.

Ported from `origin/experiment/does-vocabulary-pay`, where the harness had one
pair of arms and this script knew their names. It now takes them, because
`vocab-ablation.py` runs any number.
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
    ap.add_argument("rows", help="the JSON `vocab-ablation.py --out` wrote")
    ap.add_argument("--vocabulary", required=True,
                    help="the vocabulary.yaml the `--on` arm ran with")
    ap.add_argument("--off", default="off", help="the arm that is the baseline")
    ap.add_argument("--on", default="today", help="the arm being scored")
    ap.add_argument("--out", default="")
    args = ap.parse_args()

    rows = json.loads(Path(args.rows).read_text())
    if not rows:
        print(f"✗ {args.rows} has no clips in it")
        return 2
    for arm in (args.off, args.on):
        if arm not in rows[0]["runs"]:
            print(f"✗ no arm named {arm} in {args.rows} — it has "
                  + ", ".join(rows[0]["runs"]))
            return 2
    names = terms_of(args.vocabulary)

    def wrote_a_term(row, text):
        """Terms in the transcript that are not in what the speaker said."""
        said = recall.normalise(row["said"])
        got = recall.normalise(text)
        return [n for n in names
                if re.search(rf"\b{n.lower()}\b", got)
                and not re.search(rf"\b{n.lower()}\b", said)]

    def pick(row, arm, want):
        """A transcript from a run that agreed with the majority verdict.

        The transcript printed has to be evidence for the verdict beside it. A
        clip that flipped has runs on both sides, and the flattering one is not
        the one the reader should act on.
        """
        truth = recall.normalise(row["said"])
        for text in row["runs"][arm]["texts"]:
            if (recall.normalise(text) == truth) == want:
                return text
        return row["runs"][arm]["texts"][0]

    def ok(row, arm):
        return row["runs"][arm]["ok"]

    losses = [r for r in rows if ok(r, args.off) and not ok(r, args.on)]
    wins = [r for r in rows if ok(r, args.on) and not ok(r, args.off)]

    out = []
    out.append("Every clip the vocabulary pass took away.")
    out.append("")
    out.append(f"`{args.off}` is the baseline arm and `{args.on}` is the arm being")
    out.append("scored. Both are replays of the same audio through the same build,")
    out.append("majority of the runs `scripts/vocab-ablation.py` was given.")
    out.append("Written by scripts/vocab-losses.py.")
    out.append("")
    out.append(f"{len(losses)} losses, against {len(wins)} wins over {len(rows)} clips.")
    out.append("")

    overwrites, others = [], []
    for row in losses:
        on_text = pick(row, args.on, False)
        off_text = pick(row, args.off, True)
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
            out.append(f"  {args.off + ':':<8}{off_text}")
            out.append(f"  {args.on + ':':<8}{on_text}")
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
