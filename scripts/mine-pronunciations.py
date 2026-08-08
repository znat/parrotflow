#!/usr/bin/env python3
"""Collect the ways this speaker's names actually come out of the decoder.

    scripts/mine-pronunciations.py            # write the table
    scripts/mine-pronunciations.py --audio    # and cut a wav per rendering

The `heard:` lists were written by hand, one entry at a time, as somebody
noticed a name coming out wrong. That is a slow way to learn something the
archive already knows: every clip whose true sentence is written down carries a
rendering of every term in it, and the decoder produced that rendering itself.

So this aligns the raw decode against the hand label, takes the words standing
where a term should be, and counts them. What comes out is a pronunciation
table — several spellings per name, weighted by how often the decoder produced
each — and, with `--audio`, the clip of the speaker saying it.

The raw decode is read from the word dump rather than from `--transcribe
--no-vocab`, which still runs the `replacements` stage and so returns text a
rule has already corrected. The dump is what the decoder wrote before anything
touched it, with the time of every word.

Output:

    tests/pronunciations.yaml            term -> renderings, with counts
    tests/acoustic/<Term>/<n>.wav        the audio of each, with --audio
"""
import argparse
import difflib
import json
import os
import re
import subprocess
import sys
import wave
from collections import Counter, defaultdict
from pathlib import Path
from importlib.machinery import SourceFileLoader

ROOT = Path(__file__).resolve().parent.parent
recall = SourceFileLoader("recall", str(ROOT / "scripts/menu-recall.py")).load_module()
CLIPS = Path.home() / "Recordings/ParrotFlow Dev"
VOCAB = Path.home() / ".config/parrotflow-dev/vocabulary.yaml"
OUT = ROOT / "tests/pronunciations.yaml"
AUDIO = ROOT / "tests/acoustic"


def terms():
    return [m.group(1) for m in re.finditer(r"^  ([A-Z][\w'-]+):\s*$", VOCAB.read_text(), re.M)]


def decoded(wav):
    """The words the decoder wrote, with the time it wrote each one at."""
    environment = dict(os.environ, PARROTFLOW_SPOTTER_DUMP="1")
    done = subprocess.run(
        [recall.APP, "--transcribe", str(CLIPS / wav)],
        capture_output=True, text=True, env=environment, timeout=180)
    out = []
    for m in re.finditer(r"word (\S+) ([0-9.]+)-([0-9.]+)", done.stdout + done.stderr):
        out.append((m.group(1), float(m.group(2)), float(m.group(3))))
    return out


def bare(word):
    return re.sub(r"[^\w']", "", word).lower()


def cut(wav, start, end, target):
    """The span, padded a little — a word's edges are where it is least clear."""
    with wave.open(str(CLIPS / wav), "rb") as src:
        rate, width, channels = src.getframerate(), src.getsampwidth(), src.getnchannels()
        first = max(0, int((start - 0.05) * rate))
        last = min(src.getnframes(), int((end + 0.05) * rate))
        src.setpos(first)
        frames = src.readframes(last - first)
    target.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(target), "wb") as dst:
        dst.setnchannels(channels)
        dst.setsampwidth(width)
        dst.setframerate(rate)
        dst.writeframes(frames)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--audio", action="store_true")
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()

    known = {t.lower(): t for t in terms()}
    if not known:
        print(f"✗ no terms in {VOCAB}", file=sys.stderr)
        return 2

    found = defaultdict(Counter)
    spans = defaultdict(list)
    cases = recall.load_cases()
    if args.limit:
        cases = cases[:args.limit]

    for wav, said in cases:
        if not said or not (CLIPS / wav).exists():
            continue
        words = decoded(wav)
        if not words:
            continue
        truth = re.findall(r"[\w'-]+", said)

        # Word-level alignment. Where the two disagree and the truth side names
        # a term, the decoder's side is a rendering of it.
        matcher = difflib.SequenceMatcher(
            a=[bare(w) for w in truth],
            b=[bare(w[0]) for w in words], autojunk=False)
        for tag, i1, i2, j1, j2 in matcher.get_opcodes():
            if tag == "equal":
                continue
            wanted = [t for t in truth[i1:i2] if bare(t) in known]
            if len(wanted) != 1 or j1 == j2:
                continue
            term = known[bare(wanted[0])]
            rendering = " ".join(w[0] for w in words[j1:j2]).strip(".,?!;:")
            if not rendering or bare(rendering) == term.lower():
                continue
            found[term][rendering] += 1
            spans[term].append((wav, words[j1][1], words[j2 - 1][2], rendering))
        print(f"  {wav}", file=sys.stderr)

    lines = [
        "# Pronunciations mined from the archive by scripts/mine-pronunciations.py.",
        "#",
        "# Each entry is a spelling the decoder actually produced where this term",
        "# was said, with how many clips produced it. Feed them to the vocabulary",
        "# as `heard:` and they become CTC search targets — the spotter looks for",
        "# the sound of the rendering and reports the term.",
        "",
    ]
    for term in sorted(found):
        listed = ", ".join(f"{r} ({n})" for r, n in found[term].most_common())
        lines.append(f"  {term}:  # {listed}")
        lines.append("    heard: [" + ", ".join(found[term]) + "]")
    OUT.write_text("\n".join(lines) + "\n")

    if args.audio:
        for term, items in spans.items():
            for n, (wav, start, end, rendering) in enumerate(items):
                try:
                    cut(wav, start, end, AUDIO / term / f"{n:02d}-{bare(rendering)}.wav")
                except (wave.Error, OSError) as problem:
                    print(f"  ✗ {wav}: {problem}", file=sys.stderr)

    total = sum(len(v) for v in found.values())
    print(f"\n  {total} distinct rendering(s) across {len(found)} term(s) -> "
          f"{OUT.relative_to(ROOT)}")
    for term in sorted(found):
        print(f"    {term:<10} {len(found[term]):>2} rendering(s), "
              f"{sum(found[term].values())} occurrence(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
