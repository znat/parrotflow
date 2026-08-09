#!/usr/bin/env python3
"""Collect the ways this speaker's names actually come out of the decoder.

    scripts/mine-pronunciations.py            # write the table
    scripts/mine-pronunciations.py --audio    # and cut a wav per rendering

The pronunciation lists were written by hand, one entry at a time, as somebody
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
touched it, with the time of every word. Since PR 5 the app prints it above the
pass's own guards (F11), so a clip where nothing fired still contributes — the
deep misses are exactly the clips this exists for, and they were the ones it
could never see.

Everything is written into `voice/`, beside the config, and nothing goes into
the repository:

    voice/pronunciations.yaml         term -> renderings, in the schema
                                      `vocabulary.yaml` takes, ready to paste
    voice/observations.jsonl          one line per rendering seen
    voice/samples/<Term>/*.wav        the audio of each, with --audio

`PARROTFLOW_CONFIG_DIR` moves all of it, which is how this runs against a
scratch directory without touching anyone's real config.

**The microphone is part of an observation and this archive straddles two.**
Nothing on disk records which clip came off which, so `--mic` is how a person
who knows says so. Left out, `mic` is null, which means unknown rather than
"the one plugged in today".
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
from datetime import datetime, timezone
from pathlib import Path
from importlib.machinery import SourceFileLoader

ROOT = Path(__file__).resolve().parent.parent
recall = SourceFileLoader("recall", str(ROOT / "scripts/menu-recall.py")).load_module()
CLIPS = Path.home() / "Recordings/ParrotFlow Dev"


def config_dir():
    """Where the app would read its config from — the same seam it uses."""
    override = os.environ.get("PARROTFLOW_CONFIG_DIR", "").strip()
    if override:
        return Path(override).expanduser()
    return Path.home() / ".config/parrotflow-dev"


def terms(vocabulary):
    """Term names, from the one indentation level `terms:` entries sit at."""
    if not vocabulary.exists():
        return []
    return [m.group(1) for m in
            re.finditer(r"^  ([A-Z][\w'-]+):\s*$", vocabulary.read_text(), re.M)]


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


def languages():
    """Which language each clip was dictated in, from `trace.jsonl`.

    The first entry per clip, which is the decode the speaker got. Free here and
    unrecoverable later, which is the whole argument for writing it: this
    speaker dictates in two languages and one name has two pronunciations, so a
    mined row without it cannot say which way the name was said.
    """
    out = {}
    path = CLIPS / "trace.jsonl"
    if not path.exists():
        return out
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get("kind", "dictation") != "dictation":
            continue
        wav = row.get("wav")
        if wav and wav not in out:
            out[wav] = row.get("lang")
    return out


def build():
    """The build stamp of the app these words came out of.

    Same reason as the language: a row cut by a build whose span logic later
    changes is a row you cannot trust, and afterwards there is no telling which
    build wrote it. `--version` is where the app prints it.
    """
    try:
        done = subprocess.run([recall.APP, "--version"], capture_output=True,
                              text=True, timeout=30)
        stamped = done.stdout.strip()
        return stamped or None
    except (OSError, subprocess.SubprocessError):
        return None


def stamp(wav):
    """The moment the clip was recorded, from its own name, as ISO 8601.

    The filename is the only record of when a rendering was actually said. A
    row stamped with the moment it was mined would sort every clip of the
    archive into one second.
    """
    m = re.search(r"(\d{4}-\d{2}-\d{2})T(\d{2})-(\d{2})-(\d{2})", wav)
    if m:
        return f"{m.group(1)}T{m.group(2)}:{m.group(3)}:{m.group(4)}"
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--audio", action="store_true")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--mic", default=None,
                    help="the input device these clips were recorded on; "
                         "left out, mic is null, which means unknown")
    args = ap.parse_args()

    voice = config_dir() / "voice"
    vocabulary = config_dir() / "vocabulary.yaml"
    out = voice / "pronunciations.yaml"
    observations = voice / "observations.jsonl"
    samples = voice / "samples"

    known = {t.lower(): t for t in terms(vocabulary)}
    if not known:
        print(f"✗ no terms in {vocabulary}", file=sys.stderr)
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

    voice.mkdir(parents=True, exist_ok=True)
    lines = [
        "# Pronunciations mined from the archive by scripts/mine-pronunciations.py.",
        "#",
        "# Each entry is a spelling the decoder actually produced where this term",
        "# was said, with how many clips produced it. Paste a block under its term",
        "# in vocabulary.yaml: each rendering is matched exactly as a rule, and its",
        "# sound is searched for in the audio, which is how a rendering no number",
        "# can reach still finds its term.",
        "#",
        "# This is one person's voice. It does not belong in a git repository.",
        "",
    ]
    for term in sorted(found):
        lines.append(f"  {term}:")
        lines.append("    pronunciations:")
        for rendering, n in found[term].most_common():
            lines.append(f"      - heard: {json.dumps(rendering)}")
            lines.append(f"        seen: {n}")
            lines.append("        from: mined")
    out.write_text("\n".join(lines) + "\n")

    # One line per rendering seen, appended. The sample path is written whether
    # or not --audio cut one, so a later run can fill the gap without rewriting
    # rows; a reader checks the file exists.
    #
    # A rendering already on file is not written again. `observations.jsonl` is
    # append-only and a count is derived from it, so a second mining run over
    # the same archive would say every rendering had been seen twice — a number
    # PR 8 prunes on, doubled by re-running a script. A row is the same row when
    # it names the same clip, the same span and the same spelling.
    already = set()
    if observations.exists():
        for line in observations.read_text(encoding="utf-8").splitlines():
            try:
                was = json.loads(line)
            except ValueError:
                continue
            already.add((was.get("wav"), tuple(was.get("span") or ()),
                         was.get("term"), was.get("heard")))

    rows = []
    spoken = languages()
    stamped = build()
    for term, items in sorted(spans.items()):
        for n, (wav, start, end, rendering) in enumerate(items):
            span = (round(start, 3), round(end, 3))
            if (wav, span, term, rendering) in already:
                continue
            relative = f"samples/{term}/{n:02d}-{bare(rendering)}.wav"
            rows.append({
                "at": stamp(wav), "term": term, "heard": rendering,
                "from": "mined", "score": None, "mic": args.mic,
                "span": list(span),
                "sample": relative if args.audio else None,
                "wav": wav,
                # On every row, not only a correction's. A bank where half the
                # entries know their provenance is a bank you cannot filter.
                "lang": spoken.get(wav),
                "build": stamped,
                # Mining only ever produces positives: it looks for a term in a
                # decode and cuts where it found it. Written out anyway, because
                # a row whose meaning has to be inferred from which script wrote
                # it is a row somebody will eventually infer wrongly.
                "polarity": "positive",
            })
    with observations.open("a", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")

    if args.audio:
        for term, items in spans.items():
            for n, (wav, start, end, rendering) in enumerate(items):
                try:
                    cut(wav, start, end, samples / term / f"{n:02d}-{bare(rendering)}.wav")
                except (wave.Error, OSError) as problem:
                    print(f"  ✗ {wav}: {problem}", file=sys.stderr)

    total = sum(len(v) for v in found.values())
    print(f"\n  {total} distinct rendering(s) across {len(found)} term(s) -> {out}")
    print(f"  {len(rows)} observation(s) appended to {observations}"
          f" ({len(already)} already on file)")
    for term in sorted(found):
        print(f"    {term:<10} {len(found[term]):>2} rendering(s), "
              f"{sum(found[term].values())} occurrence(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
