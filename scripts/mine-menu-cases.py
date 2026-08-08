#!/usr/bin/env python3
"""Build a labelling sheet for `menu-recall.py` out of the archive.

    scripts/mine-menu-cases.py [--limit 60] > tests/menu-cases.yaml
    scripts/mine-menu-cases.py --random 20 >> tests/menu-cases.yaml

Every dictation that touched the vocabulary is already on disk twice: the clip
in `~/Recordings`, and what the app made of it in `trace.jsonl`. What is
missing is the one thing no machine has — what was actually said.

So this writes the transcript into `said:` as a first draft. Labelling is then
correcting the wrong ones rather than typing every sentence, and a clip the app
got right needs no edit at all. That is the difference between a set somebody
finishes and one they abandon.

Clips are selected when the vocabulary was involved: a term in the finished
text, a known mis-rendering from the `heard:` lists, or a name close enough to
a term to have been a near miss. A dictation that never went near the
vocabulary teaches this harness nothing.

    - wav: parrotflow-….wav
      # app: Let's praise the work Prissy has done.
      said: "Let's praise the work Prissy has done."     <- fix this line

Leave `said` blank to skip a clip. Delete the ones that are not about names.

**That filter flatters recall (F11).** It admits a clip only when the app's own
output already looks like a term, so a deep miss can never enter the set:
"Versailles" is 0.40 from "Vercel", below the 0.55 gate, and a clip where the
name vanished entirely has nothing to match on. Whatever the app misses hardest
is exactly what this filter hides. `--random N` samples N clips with no filter
at all — most will be about nothing, and the few that are not are the cases the
filtered pass cannot reach.

The other bias is `said:` itself. It is pre-filled with the app's own output,
so a label left untouched agrees with the app by construction. Correcting the
sheet by hand is not optional.
"""
import argparse
import json
import random
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLIPS = Path.home() / "Recordings/ParrotFlow Dev"
TRACE = CLIPS / "trace.jsonl"
VOCAB = Path.home() / ".config/parrotflow-dev/vocabulary.yaml"


def vocabulary():
    """Terms and their known mis-renderings, without a YAML dependency."""
    terms, heard, current = [], [], None
    if not VOCAB.exists():
        return terms, heard
    for line in VOCAB.read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        name = re.match(r"^  ([A-Za-z][\w'-]*):\s*$", line)
        if name:
            current = name.group(1)
            terms.append(current)
            continue
        listed = re.search(r"heard:\s*\[(.*)", line)
        if listed and current:
            heard.extend(w.strip().strip("]") for w in listed.group(1).split(","))
    return terms, [h for h in heard if h]


def levenshtein(a, b):
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(current[-1] + 1, previous[j] + 1,
                               previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


def near(word, terms):
    """Close enough to a term to have been a near miss, glued and lowercased."""
    w = re.sub(r"[^a-z0-9]", "", word.lower())
    if len(w) < 4:
        return None
    for term in terms:
        t = term.lower()
        if w == t:
            return term
        if 1 - levenshtein(w, t) / max(len(w), len(t)) >= 0.55:
            return term
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=60)
    ap.add_argument("--random", type=int, default=0, metavar="N",
                    help="sample N clips with no trigger filter; N replaces "
                         "--limit and the newest-first order (F11)")
    ap.add_argument("--seed", type=int, default=0,
                    help="seed for --random, so a sheet can be rebuilt")
    args = ap.parse_args()

    terms, heard = vocabulary()
    if not terms and not args.random:
        print(f"✗ no terms in {VOCAB}", file=sys.stderr)
        return 2
    lowered = {h.lower() for h in heard}

    picked, seen = [], set()
    for line in TRACE.read_text().splitlines():
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        wav, final = entry.get("wav"), (entry.get("final") or "").strip()
        if not wav or not final:
            continue
        name = Path(wav).name
        if name in seen or not (CLIPS / name).exists():
            continue

        if args.random:
            # No filter at all. The point of this mode is the clips the
            # filter below can never admit (F11), so nothing is asked of the
            # text — not even that it mention a name.
            seen.add(name)
            picked.append((name, final, "sampled at random, unfiltered"))
            continue

        words = re.findall(r"[\w'-]+", final)
        why = None
        if any(w.lower() in lowered for w in words):
            why = "a known mis-rendering"
        elif any(near(w, terms) for w in words):
            why = "a term or something near one"
        if not why:
            continue
        seen.add(name)
        picked.append((name, final, why))

    if args.random:
        pool = len(picked)
        random.Random(args.seed).shuffle(picked)
        picked = picked[:args.random]
        order = "sampled at random"
    else:
        # Newest first: recent clips are the ones whose wording is still
        # rememberable, and a label nobody can verify is worse than no label.
        picked.reverse()
        picked = picked[:args.limit]
        pool = len(seen)
        order = "newest first"

    print(f"# Menu cases mined from {pool} candidate clips"
          f" — {len(picked)} written, {order}.")
    print("#")
    print("# WARNING: `said` below is pre-filled with the app's OWN OUTPUT.")
    print("# A line left as it is agrees with the app by construction, and a")
    print("# set built that way measures nothing. Correct every line by hand")
    print("# against the audio, blank the ones you cannot remember, and delete")
    print("# any clip that is not about a name. See scripts/menu-recall.py.")
    if args.random:
        print("#")
        print("# These clips were sampled with no trigger filter, so most will")
        print("# be about nothing. That is the point: the filtered pass admits")
        print("# a clip only when the app's output already looks like a term,")
        print("# so it cannot show a name the app missed completely (F11).")
    print()
    print("cases:")
    for name, final, why in picked:
        print(f"  - wav: {name}")
        print(f"    # picked up: {why}")
        print(f'    said: "{final.replace(chr(34), chr(39))}"')
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
