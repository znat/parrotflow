#!/usr/bin/env python3
"""Does a span of audio sound like a recording of the term it was offered?

    scripts/reference-matching.py                  # the report
    scripts/reference-matching.py --table FILE     # the per-proposal distances
    scripts/reference-matching.py --source round6  # only round 6's recordings
    scripts/reference-matching.py --poison         # PR 6a, below
    scripts/reference-matching.py --subsample      # PR 6e, below

**PR 6e lives under `--subsample`.** It asks how many recordings a bank needs
before it may decide. For each term it draws random subsets of that term's
folder at n = 2, 3, 5, 8, 12 and re-scores the same spans against the smaller
bank, many draws per n, and reports the median and the range. It reports the
AUC and the rule's own veto counts side by side, because 6a found the AUC
cannot see the threshold: `spread` is one number per term, so it divides out
of any ranking inside that term. The veto counts are what an abstain rule is
about. Subsampling measures how *this* bank degrades — not how a new term with
n clips behaves, which nothing here can measure.

**PR 6a lives at the bottom of this file, under `--poison`.** It asks a
different question from the rest: not how well the distance separates, but how
much of the *rule* one bad recording destroys. `ReferenceMatch.verdict` sets
`spread` to the largest leave-one-out distance between a term's recordings, so
one clip that is not the term widens the cloud for every proposal of that term.
`--poison` adds such a clip to each folder and re-measures; where a folder
already holds one it takes it out instead. `--robust` swaps the maximum for the
90th percentile, which is what PR 6b proposes. Nothing is written to the voice
store: point `PARROTFLOW_CONFIG_DIR` at a copy.

Everything acoustic tried so far scores a *spelling* against audio. Round 5
measured that and it is inverted: AUC 0.318 separating "the term was said"
from "the term was not said". This asks the other question. Compare the span
to **real recordings of the speaker saying the term**, and skip the model's
opinion about the spelling entirely.

    A   the term was said       the label puts the term at this span
    B   the term was NOT said   the label puts an ordinary word there

Both groups come from `tests/raw-score-separation.json`, condition `cbw0`
(vocabulary bonus at zero), deduplicated the same way round 5 deduplicates:
one row per clip, term stem, word range and proposal kind, so three replays
of the same proposal count once.

The recordings come from the voice store, `voice/samples/<Term>/`, mined by
`scripts/mine-pronunciations.py`. Round 6 had four terms with any recording —
Praisy (17), Vercel (7), Matthieu (2), Supabase (1) — and dropped every other
term, including the two that actually cost clips. Round 7 has eleven terms,
from two sources:

    spontaneous   mined from the archive of ordinary dictation
    scripted      mined from 48 lines read from a script on 2026-08-09

`--source` picks between them. `all` is the default, `scripted` and
`spontaneous` isolate one, and `round6` reads `tests/acoustic/` off the frozen
branch instead, which is what round 6 measured. Read speech is more careful
than dictation, so `scripted` against `spontaneous` on the terms both cover is
the honest way to ask whether the new recordings flatter the result.

The measurement, per proposal:

    1. cut the span out of its clip, padded 0.05s each side, the same cut
       mine-pronunciations.py makes — a word's edges are where it is least
       clear;
    2. MFCCs for the span and for every exemplar;
    3. DTW distance to each exemplar, take the nearest.

**The exemplars were mined from these same clips**, so an exemplar can be the
very span it is being compared to. Any exemplar from the proposal's own clip is
held out. Without that the A group scores against copies of itself.

The hold-out needs to know which clip each exemplar came from.
`voice/observations.jsonl` records it, one row per sample. The frozen
`tests/acoustic/` predates that file, so those are traced the way round 6
traced them: the cut copies frames straight out of the clip, so the exemplar's
bytes appear verbatim in exactly one archive file.

The hold-out still bites. The scripted recordings come from clips the proposal
set does not contain, so nothing there can compare against itself — but the
spontaneous ones are mined from the very archive the proposals come from, and
without the hold-out Praisy and Vercel would score against copies of
themselves. It is checked and reported below, per source.

The control that decides whether the headline means anything is the distance
to exemplars of a *different* term. If a Praisy span sits as close to Vercel
recordings as to Praisy recordings there is no discrimination and the A/B
number was luck.

numpy only. The MFCC and the DTW are written out below rather than pulled in
from librosa: forty lines against a heavy dependency for a spike.

**No model call anywhere.** No app, no decoder, no Ollama. Reads wavs.
"""
import argparse
import hashlib
import itertools
import json
import math
import os
import random
import re
import statistics
import subprocess
import sys
import wave
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
CLIPS = Path.home() / "Recordings/ParrotFlow Dev"
CACHE = ROOT / "tests/raw-score-separation.json"
CACHE_REF = "origin/spike/raw-score-separation:tests/raw-score-separation.json"
FROZEN = ROOT / "tests/acoustic"             # gitignored: this is a voice
FROZEN_REF = "origin/feat/vocabulary-skills-only"
CONDITION = "cbw0"
PAD = 0.05
RATE = 16000
# The day the 48 lines were read from the script. Everything mined from a clip
# recorded that day is read speech; everything else is dictation.
SCRIPTED_DAY = "2026-08-09"


def config_dir():
    override = os.environ.get("PARROTFLOW_CONFIG_DIR", "").strip()
    if override:
        return Path(override).expanduser()
    return Path.home() / ".config/parrotflow-dev"


def voice_dir():
    return config_dir() / "voice"


# ------------------------------------------------------------------- the cache

def norm(word):
    return re.sub(r"[^\w']", "", word or "").lower()


def stem(word):
    """A term and its possessive or plural are the same name."""
    w = norm(word)
    for suffix in ("'s", "s'", "s"):
        if len(w) > 3 and w.endswith(suffix):
            return w[: -len(suffix)]
    return w


def load_proposals():
    """Round 5's A and B rows, deduplicated round 5's way."""
    if not CACHE.exists():
        blob = subprocess.run(["git", "show", CACHE_REF], cwd=ROOT,
                              capture_output=True, text=True)
        if blob.returncode:
            print(f"✗ no {CACHE} and no {CACHE_REF}", file=sys.stderr)
            return []
        CACHE.write_text(blob.stdout)
    block = json.loads(CACHE.read_text())["proposals"]
    rows = [dict(zip(block["columns"], r)) for r in block["rows"]]
    seen = {}
    for r in rows:
        if r["condition"] != CONDITION or r["kind"] == "wider":
            continue
        if r.get("spot") is None:
            continue
        key = (r["wav"], stem(r["term"]), r["first"], r["last"], r["kind"])
        seen.setdefault(key, []).append(r)
    return [group[0] for group in seen.values()]


def load_frozen():
    """Round 6's recordings: tests/acoustic/ off the frozen branch, once."""
    if not FROZEN.exists():
        listed = subprocess.run(
            ["git", "ls-tree", "-r", "--name-only", FROZEN_REF, "tests/acoustic/"],
            cwd=ROOT, capture_output=True, text=True)
        for name in listed.stdout.split():
            if not name.endswith(".wav"):
                continue
            blob = subprocess.run(["git", "show", f"{FROZEN_REF}:{name}"],
                                  cwd=ROOT, capture_output=True)
            target = ROOT / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(blob.stdout)
    out = []
    for path in sorted(FROZEN.rglob("*.wav")):
        out.append({"term": stem(path.parent.name), "source": "round6",
                    "name": f"{path.parent.name}/{path.name}",
                    "from": None, "samples": read(path)})
    return out


def load_voice():
    """The voice store, with the clip each sample was cut from.

    `observations.jsonl` names it, so nothing has to be searched for. A row
    whose sample was never cut, or was cut and then deleted, is skipped.
    """
    voice = voice_dir()
    log = voice / "observations.jsonl"
    if not log.exists():
        return []
    out = []
    for line in log.read_text(encoding="utf-8").splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        relative = row.get("sample")
        if not relative or not (voice / relative).exists():
            continue
        out.append({"term": stem(row["term"]),
                    "source": "scripted" if SCRIPTED_DAY in (row.get("wav") or "")
                              else "spontaneous",
                    "name": relative.replace("samples/", ""),
                    "from": row.get("wav"),
                    "samples": read(voice / relative)})
    return out


def load_exemplars(source):
    if source == "round6":
        return load_frozen()
    got = load_voice()
    if source != "all":
        got = [e for e in got if e["source"] == source]
    return got


def read(path, start=None, end=None):
    """int16 mono samples, optionally the span between two times in seconds."""
    with wave.open(str(path), "rb") as src:
        rate, frames = src.getframerate(), src.getnframes()
        first = 0 if start is None else max(0, int(start * rate))
        last = frames if end is None else min(frames, int(end * rate))
        if last <= first:
            return np.zeros(0, dtype=np.float64)
        src.setpos(first)
        raw = src.readframes(last - first)
    data = np.frombuffer(raw, dtype="<i2").astype(np.float64)
    if src.getnchannels() > 1:
        data = data.reshape(-1, src.getnchannels()).mean(axis=1)
    return data


def provenance(exemplars, wavs):
    """Which clip each exemplar was cut from, by searching for its samples.

    mine-pronunciations.py copies frames straight out of the clip, so the
    exemplar's bytes appear verbatim in exactly one archive file. Only the
    frozen `tests/acoustic/` needs this: the voice store records the clip in
    `observations.jsonl` and is already answered. Without one or the other an
    exemplar can be compared against itself.
    """
    exemplars = [e for e in exemplars if not e.get("from")]
    if not exemplars:
        return {}
    source = {}
    buffers = {}
    for wav in wavs:
        path = CLIPS / wav
        if path.exists():
            with wave.open(str(path), "rb") as src:
                buffers[wav] = src.readframes(src.getnframes())
    for ex in exemplars:
        needle = ex["samples"].astype("<i2").tobytes()
        for wav, buf in buffers.items():
            if buf.find(needle) >= 0:
                source[ex["name"]] = wav
                break
    return source


# -------------------------------------------------------------------- the MFCC

def mel(hz):
    return 2595.0 * np.log10(1.0 + hz / 700.0)


def hz(m):
    return 700.0 * (10.0 ** (m / 2595.0) - 1.0)


def filterbank(count=26, nfft=512, rate=RATE, low=0.0, high=None):
    high = high or rate / 2
    points = hz(np.linspace(mel(low), mel(high), count + 2))
    bins = np.floor((nfft + 1) * points / rate).astype(int)
    bank = np.zeros((count, nfft // 2 + 1))
    for i in range(count):
        left, middle, right = bins[i], bins[i + 1], bins[i + 2]
        for k in range(left, middle):
            bank[i, k] = (k - left) / max(1, middle - left)
        for k in range(middle, right):
            bank[i, k] = (right - k) / max(1, right - middle)
    return bank


BANK = filterbank()
DCT = np.cos(np.pi / 26 * (np.arange(26) + 0.5)[None, :] * np.arange(13)[:, None])


def mfcc(samples, rate=RATE, window=0.025, hop=0.010, keep=12):
    """13 cepstra, c0 dropped, mean and variance normalised over the segment.

    c0 is loudness. Two recordings of the same word at different distances
    from the microphone differ in it and in nothing that matters here, so it
    goes. The normalisation does the same job for the rest: it takes out the
    channel, and leaves the shape of the spectrum over time.
    """
    if samples.size < int(window * rate):
        return None
    emphasised = np.append(samples[0], samples[1:] - 0.97 * samples[:-1])
    length, step = int(window * rate), int(hop * rate)
    count = 1 + (emphasised.size - length) // step
    index = np.arange(length)[None, :] + step * np.arange(count)[:, None]
    frames = emphasised[index] * np.hamming(length)
    power = np.abs(np.fft.rfft(frames, 512)) ** 2 / 512
    energy = np.log(np.maximum(power @ BANK.T, 1e-10))
    cepstra = (energy @ DCT.T)[:, 1:keep + 1]
    cepstra = cepstra - cepstra.mean(axis=0)
    spread = cepstra.std(axis=0)
    return cepstra / np.where(spread < 1e-6, 1.0, spread)


def dtw(a, b):
    """Normalised DTW distance between two MFCC sequences.

    Symmetric step pattern, diagonal weighted 2, so the accumulated cost
    divides exactly by n + m and sequences of different length compare.
    """
    cost = np.sqrt(np.maximum(
        (a * a).sum(1)[:, None] + (b * b).sum(1)[None, :] - 2 * a @ b.T, 0.0))
    n, m = cost.shape
    total = np.full((n + 1, m + 1), np.inf)
    total[0, 0] = 0.0
    for i in range(1, n + 1):
        row, previous, here = total[i], total[i - 1], cost[i - 1]
        for j in range(1, m + 1):
            row[j] = min(previous[j] + here[j - 1],
                         row[j - 1] + here[j - 1],
                         previous[j - 1] + 2 * here[j - 1])
    return total[n, m] / (n + m)


# --------------------------------------------------------------- the statistics

def quantile(values, q):
    if not values:
        return float("nan")
    ordered = sorted(values)
    position = q * (len(ordered) - 1)
    low = int(position)
    high = min(low + 1, len(ordered) - 1)
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def describe(name, values):
    if not values:
        return f"  {name:<30} n=0"
    return ("  {:<30} n={:<4} min {:>6.3f}  q1 {:>6.3f}  med {:>6.3f}  "
            "q3 {:>6.3f}  max {:>6.3f}".format(
                name, len(values), min(values), quantile(values, .25),
                statistics.median(values), quantile(values, .75), max(values)))


def auc(positive, negative):
    """P(a random positive scores above a random negative). Ties count half."""
    if not positive or not negative:
        return float("nan")
    wins = 0.0
    for p in positive:
        for n in negative:
            wins += 1.0 if p > n else (0.5 if p == n else 0.0)
    return wins / (len(positive) * len(negative))


def conditional(positive, negative, score, hold, tol):
    """AUC over only the pairs whose `hold` values agree to within `tol`.

    The way to ask whether a rival explanation is doing the work: keep the
    rival fixed inside each pair, and see what is left of the separation.
    """
    pairs = wins = 0.0
    for p in positive:
        for n in negative:
            if abs(hold(p) - hold(n)) > tol:
                continue
            pairs += 1
            wins += 1.0 if score(p) > score(n) else (
                0.5 if score(p) == score(n) else 0.0)
    return (wins / pairs if pairs else float("nan")), int(pairs)


# -------------------------------------------------- the scripted clips as a set

# The words the vocabulary pass actually wrote a term over in the 48 scripted
# clips, with the term it wrote. Read off `trace.jsonl`: these are live
# overwrites, not negatives anybody chose. They are the hardest kind, because
# the app already mistook each of them for the name.
OVERWRITTEN = [
    ("parrotflow-2026-08-09T14-02-01.wav", "slide", "claude"),
    ("parrotflow-2026-08-09T14-02-28.wav", "ready", "arexvy"),
    ("parrotflow-2026-08-09T14-02-49.wav", "already", "arexvy"),
    ("parrotflow-2026-08-09T14-04-51.wav", "update", "supabase"),
    ("parrotflow-2026-08-09T14-04-55.wav", "general", "redcrawl"),
    ("parrotflow-2026-08-09T14-05-08.wav", "train", "praisy"),
    ("parrotflow-2026-08-09T14-05-15.wav", "retry", "arexvy"),
    ("parrotflow-2026-08-09T14-05-15.wav", "crawl", "redcrawl"),
]


def scripted_spans(exemplars):
    """Every span in the scripted clips, with the term it is or is not.

    The proposal set round 5 built has no A row for Redcrawl at all: the
    vocabulary pass never once offered Redcrawl where Redcrawl was said, so
    however many recordings the term now has there is no pair to rank. The
    scripted clips answer that directly. The label says where each name is, so
    A and B can be read off it without any proposal, and without a model.

        A(term)   the spans of that name
        B(term)   the spans of the other ten names, and the ordinary words the
                  app wrote a name over

    Nothing easy is in B. Every negative is either a name in its own right or a
    word the spotter has already confused with one, so `redrock` is a negative
    for `redcrawl` and `praise` is a negative for `praisy`.
    """
    spans = []
    for ex in exemplars:
        if ex["source"] != "scripted" or not ex.get("from"):
            continue
        spans.append({"wav": ex["from"], "stem": ex["term"],
                      "heard": ex["name"].split("/")[-1],
                      "samples": ex["samples"], "kind": "name"})
    words = decoder_words()
    for wav, word, term in OVERWRITTEN:
        for token, start, end in words.get(wav, []):
            if re.sub(r"[^\w']", "", token).lower() == word:
                spans.append({"wav": wav, "stem": f"~{word}", "heard": word,
                              "samples": read(CLIPS / wav, start - PAD, end + PAD),
                              "kind": "ordinary", "wrote": term})
                break
    return spans


def decoder_words():
    """Word times from `trace.jsonl`, first line per clip. No app, no decode."""
    out = {}
    path = CLIPS / "trace.jsonl"
    if not path.exists():
        return out
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        wav = row.get("wav")
        got = (row.get("asr") or {}).get("words") or []
        if wav and got and wav not in out:
            out[wav] = [(w["word"], float(w["start"]), float(w["end"]))
                        for w in got if w.get("word")]
    return out


def measure_scripted(source_name):
    exemplars = load_exemplars(source_name)
    for ex in exemplars:
        ex["mfcc"] = mfcc(ex["samples"])
    spans = scripted_spans(load_exemplars("all"))
    for s in spans:
        s["mfcc"] = mfcc(s["samples"])
    spans = [s for s in spans if s["mfcc"] is not None]

    terms = sorted({e["term"] for e in exemplars})
    rows = []
    for term in terms:
        for s in spans:
            # The same hold-out, by clip and for both groups. A recording cut
            # from this clip is the same speech in the same session; comparing
            # a span to it measures the file, not the name.
            usable = [e for e in exemplars if e["term"] == term
                      and e["mfcc"] is not None and e["from"] != s["wav"]]
            if not usable:
                continue
            other = [e for e in exemplars if e["term"] != term
                     and e["mfcc"] is not None and e["from"] != s["wav"]]
            matched = min(dtw(s["mfcc"], e["mfcc"]) for e in usable)
            row = {"term": term, "wav": s["wav"], "heard": s["heard"],
                   "group": "A" if s["stem"] == term else "B",
                   "kind": s["kind"], "matched": matched,
                   "exemplars": len(usable),
                   "seconds": s["samples"].size / RATE}
            if other:
                row["mismatched"] = min(dtw(s["mfcc"], e["mfcc"]) for e in other)
            rows.append(row)
    return rows


def report_scripted(rows, source_name):
    have = recordings(source_name)
    A = [r for r in rows if r["group"] == "A"]
    B = [r for r in rows if r["group"] == "B"]
    print(f"\n=== the scripted set ===  source {source_name}, "
          f"{len(rows)} span-term pairs over "
          f"{len({r['wav'] for r in rows})} clips")
    print("  A is the name said, B is one of the other names or a word the app")
    print("  wrote a name over. Every recording from the span's own clip is out.")
    print(f"\n  {'term':<12} {'rec':>4} {'A':>4} {'B':>4}   AUC")
    overall = auc([-r["matched"] for r in A], [-r["matched"] for r in B])
    for term in sorted({r["term"] for r in rows}):
        a = [-r["matched"] for r in A if r["term"] == term]
        b = [-r["matched"] for r in B if r["term"] == term]
        got = auc(a, b)
        counts = have.get(term, Counter())
        print(f"  {term:<12} {sum(counts.values()):>4} {len(a):>4} {len(b):>4}   "
              f"{format(got, '.3f') if got == got else 'no pair'}")
    print(f"  {'pooled':<12} {'':>4} {len(A):>4} {len(B):>4}   {overall:.3f}")
    print("\n    0.500  chance")
    print("    0.812  round 6, on round 5's proposals, four terms")

    print("\n=== the control: matched term against mismatched term ===")
    for name, group in (("A", A), ("B", B)):
        both = [r for r in group if "mismatched" in r]
        if not both:
            continue
        closer = sum(1 for r in both if r["matched"] < r["mismatched"])
        print(f"  group {name}, n={len(both)}   "
              f"AUC(matched vs mismatched) "
              f"{auc([-r['matched'] for r in both], [-r['mismatched'] for r in both]):.3f}"
              f"   matched closer {closer}/{len(both)} "
              f"({closer / len(both) * 100:.0f}%)")
    print("  A should sit closer to its own name, B should not. B at about 50%")
    print("  is the control passing, not failing.")

    print("\n=== is it length? ===")
    print(f"  AUC(A vs B) on span duration alone   "
          f"{auc([r['seconds'] for r in A], [r['seconds'] for r in B]):.3f}")

    print("\n=== the ordinary words the app wrote a name over ===")
    print("  each against the very name the app wrote, and where it ranks")
    print("  among that name's own spans")
    for r in sorted(rows, key=lambda r: (r["heard"], r["term"])):
        if r["kind"] != "ordinary":
            continue
        own = sorted(x["matched"] for x in rows
                     if x["term"] == r["term"] and x["group"] == "A")
        if not own:
            continue
        worse = sum(1 for d in own if d < r["matched"])
        print(f"  {r['heard']:<10} as {r['term']:<10} {r['matched']:.3f}   "
              f"nearer than {len(own) - worse}/{len(own)} real ones")

    print("\n=== the distances ===")
    print(describe("A  nearest matched", [r["matched"] for r in A]))
    print(describe("B  nearest matched", [r["matched"] for r in B]))
    return 0


# ------------------------------------------------------------------- the measure

def measure(source_name="all"):
    proposals = load_proposals()
    exemplars = load_exemplars(source_name)
    if not exemplars:
        where = FROZEN if source_name == "round6" else voice_dir() / "samples"
        print(f"✗ no exemplars under {where}", file=sys.stderr)
        return None, None
    terms = {ex["term"] for ex in exemplars}
    traced = provenance(exemplars, sorted({p["wav"] for p in proposals}))

    for ex in exemplars:
        ex["mfcc"] = mfcc(ex["samples"])
        if not ex.get("from"):
            ex["from"] = traced.get(ex["name"])

    kept, dropped = [], []
    for p in proposals:
        term = stem(p["term"])
        row = {"wav": p["wav"], "term": p["term"], "stem": term,
               "group": p["group"], "kind": p["kind"], "heard": p["heard"],
               "start": p["start"], "end": p["end"], "spot": p["spot"]}
        if p["group"] not in ("A", "B"):
            continue                                    # `unclear`, not a group
        if term not in terms:
            dropped.append(dict(row, why="no exemplar for the term"))
            continue
        path = CLIPS / p["wav"]
        if not path.exists():
            dropped.append(dict(row, why="clip missing from the archive"))
            continue
        if p["start"] is None or p["end"] is None or p["end"] <= p["start"]:
            dropped.append(dict(row, why="no usable span"))
            continue
        samples = read(path, p["start"] - PAD, p["end"] + PAD)
        span = mfcc(samples)
        if span is None:
            dropped.append(dict(row, why="span shorter than one frame"))
            continue
        row["seconds"] = samples.size / RATE

        usable = [e for e in exemplars
                  if e["mfcc"] is not None and e["from"] != p["wav"]]
        matched = [(dtw(span, e["mfcc"]), e["name"])
                   for e in usable if e["term"] == term]
        other = [(dtw(span, e["mfcc"]), e["name"])
                 for e in usable if e["term"] != term]
        if not matched:
            dropped.append(dict(row, why="every exemplar is from this clip"))
            continue
        row["lengths"] = min(
            abs(row["seconds"] - e["samples"].size / RATE)
            for e in usable if e["term"] == term)
        row["matched"], row["nearest"] = min(matched)
        row["matched_mean"] = sum(d for d, _ in matched) / len(matched)
        row["exemplars"] = len(matched)
        row["held_out"] = sum(1 for e in exemplars
                              if e["term"] == term and e["from"] == p["wav"])
        if other:
            row["mismatched"], row["nearest_other"] = min(other)
        kept.append(row)
    return kept, dropped


def recordings(source_name):
    """How many recordings each term has, and where they came from."""
    counts = defaultdict(Counter)
    for ex in load_exemplars(source_name):
        counts[ex["term"]][ex["source"]] += 1
    return counts


def report(kept, dropped, source_name="all"):
    A = [r for r in kept if r["group"] == "A"]
    B = [r for r in kept if r["group"] == "B"]
    have = recordings(source_name)

    print(f"\n=== the set ===  condition {CONDITION}, source {source_name}, "
          f"{len(kept)} proposals over {len({r['wav'] for r in kept})} clips")
    print(f"  {'term':<12} {'rec':>4} {'spont':>6} {'script':>7} "
          f"{'A':>4} {'B':>4}   in after the hold-out")
    for term in sorted(set(have) | {r["stem"] for r in kept}):
        a = [r for r in A if r["stem"] == term]
        b = [r for r in B if r["stem"] == term]
        held = sorted({r["exemplars"] for r in a + b}) or [0]
        counts = have.get(term, Counter())
        print(f"  {term:<12} {sum(counts.values()):>4} "
              f"{counts['spontaneous'] + counts['round6']:>6} "
              f"{counts['scripted']:>7} {len(a):>4} {len(b):>4}   "
              f"{held[0] if len(held) == 1 else f'{held[0]}-{held[-1]}'}")
    print(f"  {'total':<12} {sum(sum(c.values()) for c in have.values()):>4} "
          f"{'':>6} {'':>7} {len(A):>4} {len(B):>4}")

    lost = sum(r["held_out"] for r in kept)
    print(f"\n  the hold-out removed {lost} exemplar-comparison(s) over "
          f"{sum(1 for r in kept if r['held_out'])} proposal(s)")
    print("  a proposal never scores against a recording cut from its own clip")

    print("\n=== dropped ===")
    for why, n in Counter(r["why"] for r in dropped).most_common():
        rows = [r for r in dropped if r["why"] == why]
        groups = Counter(r["group"] for r in rows)
        print(f"  {n:>4}  {why:<34} A {groups['A']:>2}  B {groups['B']:>2}")
    if not dropped:
        print("  none")

    print("\n=== the headline: nearest matched exemplar, A against B ===")
    print("  a term that was said should sit closer to recordings of itself")
    value = auc([-r["matched"] for r in A], [-r["matched"] for r in B])
    print(f"\n  AUC(A vs B), nearest exemplar      {value:.3f}")
    print(f"  AUC(A vs B), mean over exemplars   "
          f"{auc([-r['matched_mean'] for r in A], [-r['matched_mean'] for r in B]):.3f}")
    print("\n    0.500  chance")
    print("    0.318  the raw acoustic score, round 5, over all 33 A / 66 B")
    print("    0.812  round 6, four terms, 27 recordings")
    print("    0.814  the spotter score on its own path, round 5")
    print(f"    {auc([r['spot'] for r in A], [r['spot'] for r in B]):.3f}  "
          "the raw acoustic score on these same rows — like for like")

    print("\n  per term (rec, A n / B n). A term with no A row or no B row has")
    print("  no pair to rank, so it has no AUC however many recordings it has")
    for term in sorted({r["stem"] for r in kept}):
        a = [-r["matched"] for r in A if r["stem"] == term]
        b = [-r["matched"] for r in B if r["stem"] == term]
        got = auc(a, b)
        counts = have.get(term, Counter())
        print(f"    {term:<12} {sum(counts.values()):>3} rec  "
              f"{len(a):>3} / {len(b):<3}  "
              f"{'AUC ' + format(got, '.3f') if got == got else 'no pair'}")

    print("\n=== the control: matched term against mismatched term ===")
    print("  if a Praisy span sits as close to Vercel recordings as to Praisy")
    print("  recordings, the headline was luck")
    for name, rows in (("A", A), ("B", B)):
        both = [r for r in rows if "mismatched" in r]
        if not both:
            continue
        closer = sum(1 for r in both if r["matched"] < r["mismatched"])
        print(f"\n  group {name}, n={len(both)}")
        print(f"    AUC(matched vs mismatched)       "
              f"{auc([-r['matched'] for r in both], [-r['mismatched'] for r in both]):.3f}")
        print(f"    matched is the closer of the two {closer}/{len(both)} "
              f"({closer / len(both) * 100:.0f}%, chance is 50%)")
        delta = [r["mismatched"] - r["matched"] for r in both]
        print(describe("    mismatched - matched", delta))

    print("\n=== blending the two acoustic numbers ===")
    print("  the raw score is inverted here, so averaging can only cost")
    order = lambda values: [sorted(values).index(v) / max(1, len(values) - 1)
                            for v in values]
    both = A + B
    blend = [a + b for a, b in zip(order([-r["matched"] for r in both]),
                                   order([r["spot"] for r in both]))]
    print(f"  AUC(A vs B) on rank(-distance) + rank(score)  "
          f"{auc(blend[:len(A)], blend[len(A):]):.3f}")

    print("\n=== two rival explanations ===")
    print("  1. the span is just cleaner speech, and any recording would do")
    mA = [r for r in A if "mismatched" in r]
    mB = [r for r in B if "mismatched" in r]
    print(f"     AUC(A vs B) on the mismatched distance   "
          f"{auc([-r['mismatched'] for r in mA], [-r['mismatched'] for r in mB]):.3f}")
    print(f"     AUC(A vs B) on mismatched minus matched  "
          f"{auc([r['mismatched'] - r['matched'] for r in mA], [r['mismatched'] - r['matched'] for r in mB]):.3f}")
    print("     the second number is term-specific by construction: the generic")
    print("     part of the distance cancels in the subtraction")

    print("\n  2. it is length. DTW pays for stretching, and a name has a length")
    print(f"     AUC(A vs B) on span duration alone       "
          f"{auc([r['seconds'] for r in A], [r['seconds'] for r in B]):.3f}")
    print(f"     AUC(A vs B) on |span - nearest exemplar| "
          f"{auc([-r['lengths'] for r in A], [-r['lengths'] for r in B]):.3f}")
    got, n = conditional(A, B, lambda r: -r["matched"], lambda r: r["lengths"], 0.05)
    print(f"     AUC(matched), length gap held equal ±.05s   {got:.3f}  ({n} pairs)")
    got, n = conditional(A, B, lambda r: -r["lengths"], lambda r: r["matched"], 0.10)
    print(f"     AUC(length gap), distance held equal ±.10   {got:.3f}  ({n} pairs)")

    print("\n=== the distances ===")
    print(describe("A  nearest matched", [r["matched"] for r in A]))
    print(describe("B  nearest matched", [r["matched"] for r in B]))
    print(describe("A  nearest mismatched",
                   [r["mismatched"] for r in A if "mismatched" in r]))
    print(describe("B  nearest mismatched",
                   [r["mismatched"] for r in B if "mismatched" in r]))
    for term in sorted({r["stem"] for r in kept}):
        print(describe(f"A  {term}",
                       [r["matched"] for r in A if r["stem"] == term]))
        print(describe(f"B  {term}",
                       [r["matched"] for r in B if r["stem"] == term]))

    print("\n=== does the nearest exemplar's identity carry anything? ===")
    print("  do A spans land on the same few recordings, or spread out?")
    for name, rows in (("A", A), ("B", B)):
        by_term = defaultdict(Counter)
        for r in rows:
            by_term[r["stem"]][r["nearest"]] += 1
        for term in sorted(by_term):
            counts = by_term[term]
            top = ", ".join(f"{k.split('/')[-1]} ×{v}"
                            for k, v in counts.most_common(3))
            print(f"  {name} {term:<10} {sum(counts.values()):>3} spans over "
                  f"{len(counts):>2} exemplars   {top}")
    return 0


def table(kept, dropped, path):
    lines = ["# Every proposal, with its distance to the nearest recording",
             "",
             "Produced by `scripts/reference-matching.py --table`. Read the",
             "round in [judge-framings.md](judge-framings.md) first — this",
             "file is the evidence under it, not an argument.",
             "",
             "`matched` is the DTW distance from the span to the nearest",
             "recording of the same term, over MFCCs, with any recording cut",
             "from this same clip held out. `mismatched` is the same number",
             "against recordings of every other term. Lower is nearer.",
             "`held` is how many recordings of the term survived the hold-out.",
             "",
             "| clip | group | kind | term | heard | span | held | matched | "
             "nearest | mismatched |",
             "|---|---|---|---|---|---|---|---|---|---|"]
    short = lambda w: w.replace("parrotflow-2026-08-", "").replace(".wav", "")
    for r in sorted(kept, key=lambda r: (r["group"], r["stem"], r["matched"])):
        lines.append(
            f"| {short(r['wav'])} | {r['group']} | {r['kind']} | {r['term']} "
            f"| {(r['heard'] or '').replace('|', '/')} "
            f"| {r['start']:.2f}-{r['end']:.2f} | {r['exemplars']} "
            f"| {r['matched']:.3f} | {r['nearest'].split('/')[-1]} "
            f"| {'' if 'mismatched' not in r else format(r['mismatched'], '.3f')} |")
    lines += ["", "## Dropped", "",
              "| clip | group | term | why |", "|---|---|---|---|"]
    for r in sorted(dropped, key=lambda r: (r["why"], r["group"], r["wav"])):
        lines.append(f"| {short(r['wav'])} | {r['group']} | {r['term']} "
                     f"| {r['why']} |")
    Path(path).write_text("\n".join(lines) + "\n")
    print(f"wrote {path}")
    return 0


# -------------------------------------------------------------- the poison arm

# The two recordings the archive already holds that are not the term at all,
# both mined automatically. `ReferenceMatch.swift` names them in its own
# comment as the reason its tolerance cannot be 1.0.
BAD = {"vercel": "Vercel/09-brazil.wav",
       "tasmeen": "Tasmeen/06-that'smeanssend.wav"}


def poison_rows(source_name="all"):
    """Every scored span, the term it is scored against, and its group.

    Two sets, because neither alone covers the eleven terms. The scripted set
    reads A and B off the labels, so every term with a scripted recording has
    an A row. `Praisy` and `Vercel` have no scripted recording and so no A row
    there; the proposal set is the only place they can be ranked.
    """
    exemplars = [e for e in load_exemplars(source_name)]
    for ex in exemplars:
        ex["mfcc"] = mfcc(ex["samples"])
    exemplars = [e for e in exemplars if e["mfcc"] is not None]

    spans = []
    for s in scripted_spans(load_exemplars("all")):
        s["set"] = "scripted"
        spans.append(s)
    for p in load_proposals():
        if p["group"] not in ("A", "B"):
            continue
        path = CLIPS / p["wav"]
        if not path.exists() or p["start"] is None or p["end"] is None:
            continue
        if p["end"] <= p["start"]:
            continue
        spans.append({"wav": p["wav"], "stem": stem(p["term"]), "set": "proposals",
                      "heard": p["heard"], "group": p["group"],
                      "samples": read(path, p["start"] - PAD, p["end"] + PAD)})
    for s in spans:
        s["mfcc"] = mfcc(s["samples"])
    spans = [s for s in spans if s["mfcc"] is not None]
    return exemplars, spans


def fingerprint(exemplars, spans):
    """A hash of the exact audio these matrices were computed from.

    Names and counts are not enough. A recording can be replaced without its
    path changing, and a span can move without the number of spans changing;
    either would make a cached matrix describe different audio while still
    looking valid. So the MFCCs themselves go into the digest, in order, with
    the identity of the row they belong to. Any change anywhere rebuilds.
    """
    digest = hashlib.sha256()
    for e in exemplars:
        digest.update(f"E|{e['name']}|{e['term']}|{e['from']}|".encode())
        digest.update(np.ascontiguousarray(e["mfcc"], dtype=np.float64).tobytes())
    for s in spans:
        digest.update(
            f"S|{s['wav']}|{s['set']}|{s['stem']}|{s.get('group', '')}|".encode())
        digest.update(np.ascontiguousarray(s["mfcc"], dtype=np.float64).tobytes())
    return digest.hexdigest()


def poison_matrices(exemplars, spans, cache):
    """Every span-to-recording and recording-to-recording distance, once.

    A poison arm only ever adds a recording to a folder or takes one out. It
    never changes a distance. So both matrices are computed once and every arm
    after that is indexing, which is what makes twenty-odd arms affordable.
    """
    names = [e["name"] for e in exemplars]
    stamp = fingerprint(exemplars, spans)
    if cache and Path(cache).exists():
        # No pickle: everything in here is a number or a fixed-width unicode
        # array, so this reads a cache written by this script and nothing else.
        blob = np.load(cache)
        # A cache written before the fingerprint existed has no `stamp`, and
        # asking for one raises rather than rebuilding. Anything this script
        # cannot vouch for is rebuilt, never trusted.
        if {"stamp", "se", "ee"} <= set(blob.files) and str(blob["stamp"]) == stamp:
            return blob["se"], blob["ee"]
        print("  the cache does not match this audio; rebuilding", file=sys.stderr)
    se = np.zeros((len(spans), len(exemplars)))
    for i, s in enumerate(spans):
        for j, e in enumerate(exemplars):
            se[i, j] = dtw(s["mfcc"], e["mfcc"])
        print(f"  spans {i + 1}/{len(spans)}", end="\r", file=sys.stderr)
    ee = np.zeros((len(exemplars), len(exemplars)))
    for i in range(len(exemplars)):
        for j in range(i + 1, len(exemplars)):
            ee[i, j] = ee[j, i] = dtw(exemplars[i]["mfcc"], exemplars[j]["mfcc"])
        print(f"  recordings {i + 1}/{len(exemplars)}", end="\r", file=sys.stderr)
    if cache:
        np.savez(cache, stamp=stamp, names=np.array(names), spans=len(spans),
                 se=se, ee=ee)
    return se, ee


def summarise(values, robust):
    """The width of the cloud: `nearest.max()`, or the 90th percentile of it.

    `ReferenceMatch.verdict` step 3 takes the maximum, so one recording sets
    it. 6b's proposal is to take a high quantile instead.
    """
    if not values:
        return float("nan")
    return quantile(values, 0.9) if robust else max(values)


def arm(bank, exemplars, spans, se, ee, term, robust, tolerance=1.0, floor=3):
    """One term, one bank of recordings: its AUC, its spread and its veto.

    `bank` is the list of exemplar indices that count as recordings of the
    term. The per-clip hold-out is applied inside, the same way
    `measure_scripted` and `ReferenceMatch.verdict` apply it: a span never
    scores against a recording cut from its own clip.

    `floor` is the abstain rule: under this many usable recordings the bank
    does not decide and the span is scored by nobody. `ReferenceMatch.verdict`
    abstains under three, which is the default here. 6e sweeps it, so it is a
    parameter and not a literal — a curve of what the rule does at n=2 cannot
    be drawn by a rule that refuses to run at n=2.
    """
    out = {"term": term, "recordings": len(bank)}
    # The spread over the whole bank, with nothing held out. This is the number
    # the app computes on live dictation, where the audio has no clip name.
    loo = [min(ee[i][j] for j in bank if j != i) for i in bank] if len(bank) > 1 else []
    out["spread"] = summarise(loo, robust)

    rows = {"scripted": {"A": [], "B": []}, "proposals": {"A": [], "B": []}}
    veto = {"A": [0, 0], "B": [0, 0]}
    # Most spans hold nothing out, so most of them share one `usable` set and
    # one width. 6e calls this function tens of thousands of times; recomputing
    # an O(n²) leave-one-out per span is the whole cost. Same numbers, memoised.
    widths = {}
    for k, s in enumerate(spans):
        if s["set"] == "scripted":
            group = "A" if s["stem"] == term else "B"
        elif s["stem"] == term:
            group = s["group"]
        else:
            continue
        usable = [i for i in bank if exemplars[i]["from"] != s["wav"]]
        if not usable:
            continue
        distance = min(se[k][i] for i in usable)
        rows[s["set"]][group].append(distance)
        if len(usable) < floor:
            continue                       # the bank abstains: too few clips
        key = tuple(usable)
        if key not in widths:
            held = [min(ee[i][j] for j in usable if j != i) for i in usable]
            widths[key] = summarise(held, robust)
        width = widths[key]
        if not (width > 0):
            continue
        veto[group][1] += 1
        if distance > tolerance * width:
            veto[group][0] += 1

    for name in ("scripted", "proposals"):
        a = [-d for d in rows[name]["A"]]
        b = [-d for d in rows[name]["B"]]
        out[f"auc_{name}"] = auc(a, b)
        out[f"n_{name}"] = (len(a), len(b))
    out["veto"] = veto
    out["A"] = rows["scripted"]["A"] + rows["proposals"]["A"]
    out["B"] = rows["scripted"]["B"] + rows["proposals"]["B"]
    return out


def banks(exemplars):
    by_term = defaultdict(list)
    for i, e in enumerate(exemplars):
        by_term[e["term"]].append(i)
    return by_term


def poison_report(source_name, cache, robust, injected):
    exemplars, spans = poison_rows(source_name)
    index = {e["name"]: i for i, e in enumerate(exemplars)}
    if injected not in index:
        # `--source` drops recordings, and `--inject` is a path somebody typed.
        # Say which one is wrong rather than raising a KeyError halfway through
        # a nine-minute run.
        print(f"✗ no recording {injected} under source {source_name}.",
              file=sys.stderr)
        print(f"  {len(index)} recording(s) are in scope. `--source all` keeps "
              "every one of them.", file=sys.stderr)
        return None
    poison = index[injected]           # checked above; never looked up again
    se, ee = poison_matrices(exemplars, spans, cache)
    by_term = banks(exemplars)
    where = "the 90th percentile" if robust else "the maximum"

    print(f"\n=== 6a: what one bad clip costs ===  spread is {where} of the")
    print("  leave-one-out distances. `veto B` is spans the rule drops where the")
    print("  term was NOT said — the rule working. `veto A` is the same rule")
    print("  dropping a span where the term WAS said. Tolerance 1.0 throughout.")
    print(f"  {len(exemplars)} recordings, {len(spans)} spans, source {source_name}.")

    def fmt(v):
        return f"{v:.3f}" if v == v else "  -  "

    def rate(pair):
        return f"{pair[0]}/{pair[1]}" if pair[1] else "-"

    print(f"\n  {'term':<26} {'rec':>7}  {'AUC scripted':^16}  "
          f"{'AUC proposals':^16}  {'spread':^16}")
    rows = []
    for term in sorted(by_term):
        base = arm(by_term[term], exemplars, spans, se, ee, term, robust)
        bad = BAD.get(term)
        if bad and bad in [exemplars[i]["name"] for i in by_term[term]]:
            # The bad clip is already in this folder, so the experiment runs
            # backwards: take it out and see what the term gets back.
            keep = [i for i in by_term[term] if exemplars[i]["name"] != bad]
            after = arm(keep, exemplars, spans, se, ee, term, robust)
            label, moved = f"{term} - {Path(bad).name[:14]}", bad
        elif poison in by_term[term]:
            # Injecting a recording the folder already holds would put the same
            # index in the bank twice, and a leave-one-out distance cannot see
            # the difference between the copy and the original.
            print(f"  {term:<26} skipped: {injected} is already in this folder")
            continue
        else:
            after = arm(by_term[term] + [poison], exemplars, spans,
                        se, ee, term, robust)
            label, moved = f"{term} + {Path(injected).name[:14]}", injected
        print(f"  {label:<26} {base['recordings']:>3}->{after['recordings']:<3}  "
              f"{fmt(base['auc_scripted'])} -> {fmt(after['auc_scripted'])}  "
              f"{str(base['n_scripted']):>8}  "
              f"{fmt(base['auc_proposals'])} -> {fmt(after['auc_proposals'])}  "
              f"{base['spread']:.3f} -> {after['spread']:.3f}")
        rows.append((term, base, after, moved))

    print("\n  the same arms, as the rule's own decision at tolerance 1.0")
    print(f"\n  {'term':<26} {'veto B  (the rule working)':<30} "
          f"{'veto A  (the rule costing)':<26}")
    print("  a veto count pools both sets: every span the term is scored")
    print("  against, from the 48 scripted clips and from round 5's proposals")
    totals = [0, 0, 0, 0, 0, 0]
    for term, base, after, _ in rows:
        b0, b1 = base["veto"]["B"], after["veto"]["B"]
        a0, a1 = base["veto"]["A"], after["veto"]["A"]
        totals = [totals[0] + b0[0], totals[1] + b1[0], totals[2] + b0[1],
                  totals[3] + a0[0], totals[4] + a1[0], totals[5] + a0[1]]
        share = lambda p: f"{p[0] / p[1] * 100:3.0f}%" if p[1] else "   -"
        print(f"  {term:<26} {rate(b0):>7} ({share(b0)}) -> {rate(b1):>7} "
              f"({share(b1)})   {rate(a0):>6} -> {rate(a1):>6}")
    print(f"  {'all eleven arms':<26} {totals[0]:>7}        -> {totals[1]:>7}"
          f"          {totals[3]:>6} -> {totals[4]:>6}")
    # §2: build the stupid control. Rejecting every span takes every B and
    # every A with it, so it is the ceiling on one column and the floor on
    # the other.
    print(f"  {'reject everything':<26} {totals[2]:>7}        -> {totals[2]:>7}"
          f"          {totals[5]:>6} -> {totals[5]:>6}")

    print("\n  which recording holds the leave-one-out maximum — the clip that")
    print("  sets `spread` in `ReferenceMatch.verdict` — and where the clip this")
    print("  arm added or removed ranks among the same distances")
    for term, base, _, moved in rows:
        bank = by_term[term]
        loo = sorted(((min(ee[i][j] for j in bank if j != i), exemplars[i]["name"])
                      for i in bank), reverse=True)
        names = [name for _, name in loo]
        if moved in names:
            rank = names.index(moved)
            note = (f"{Path(moved).name} is #{rank + 1} of {len(loo)} "
                    f"at {loo[rank][0]:.3f}")
        else:
            note = "the injected clip is not in this bank"
        print(f"  {term:<12} spread {loo[0][0]:.3f} set by "
              f"{names[0].split('/')[-1]:<24} {note}")
    return rows, exemplars, spans, se, ee


def pronunciation_split(exemplars):
    """The two ways this speaker says `Matthieu`, as far as the data can say.

    PR 4 is what would put `lang` on an observation, and it is not built, so
    there is no language tag on any recording. The tag would not have helped:
    all eleven `Matthieu` clips come from dictations `trace.jsonl` marks `en`,
    including the one sentence where the speaker says the name both ways.

    What the archive does carry is what the decoder wrote, in the sample's own
    filename. `matthew`, `matsu` and `match's` are anglicised renderings;
    `mathieu` is the French one. That is a proxy — a decoder's opinion about a
    sound, not a label anybody checked — so the arm prints the within-group and
    between-group distances beside it. If the two groups are not two clusters,
    the split is not real and the arm says nothing.
    """
    french, english = [], []
    for e in exemplars:
        if e["term"] != "matthieu":
            continue
        heard = e["name"].split("/")[-1].split("-", 1)[-1].replace(".wav", "")
        (french if heard.startswith("mathieu") else english).append(e["name"])
    return {"first": sorted(english), "second": sorted(french),
            "first_label": "anglicised", "second_label": "French",
            "why": "labelled by what the decoder wrote, not by `lang`"}


def cluster_check(exemplars, ee, split):
    """Are the two labelled groups actually two clusters?"""
    index = {e["name"]: i for i, e in enumerate(exemplars)}
    first = [index[n] for n in split["first"]]
    second = [index[n] for n in split["second"]]
    within = [ee[i][j] for g in (first, second) for i in g for j in g if i < j]
    between = [ee[i][j] for i in first for j in second]
    print(f"  within a group  n={len(within):<3} mean {sum(within)/len(within):.3f}"
          f"   between groups n={len(between):<3} "
          f"mean {sum(between)/len(between):.3f}")
    print(f"  AUC(between > within) {auc(between, within):.3f}  "
          "0.500 is one cluster, 1.000 is two that never touch")


def poison_pronunciation(exemplars, spans, se, ee, robust, split):
    """The second-pronunciation arm, on `Matthieu`.

    §7 predicts a thin second cluster inflates `spread` the same way a bad clip
    does, and that the damage peaks at one or two clips and falls away as the
    cluster fills. `split` names the recordings of the second pronunciation.
    """
    index = {e["name"]: i for i, e in enumerate(exemplars)}
    first = [index[n] for n in split["first"]]
    second = [index[n] for n in split["second"]]
    print(f"\n=== 6a: the second pronunciation ===  {split['why']}")
    cluster_check(exemplars, ee, split)
    print(f"  bank starts as {len(first)} × {split['first_label']}; "
          f"{split['second_label']} clips are added one at a time")
    print(f"\n  {'bank':<34} {'rec':>3}  {'AUC':>6}  {'spread':>6}  "
          f"{'veto B':>9}  {'veto A':>7}")
    for take in range(len(second) + 1):
        bank = first + second[:take]
        got = arm(bank, exemplars, spans, se, ee, "matthieu", robust)
        label = f"{len(first)} {split['first_label']} + {take} {split['second_label']}"
        auc_value = got["auc_scripted"]
        print(f"  {label:<34} {got['recordings']:>3}  "
              f"{format(auc_value, '.3f') if auc_value == auc_value else '   -  '}  "
              f"{got['spread']:.3f}  "
              f"{got['veto']['B'][0]}/{got['veto']['B'][1]:<7} "
              f"{got['veto']['A'][0]}/{got['veto']['A'][1]}")


# --------------------------------------------------- the subsample arm, PR 6e

def subsets(count, size, draws, rng):
    """`draws` distinct subsets of `size` indices out of `count`.

    Exhaustive when there are few enough. `Claude` has six recordings, so at
    n=5 there are six possible banks in total; drawing 200 of them would
    report the same six subsets with invented weights. Above the cut it
    samples without replacement, so no bank is counted twice.
    """
    total = math.comb(count, size)
    if total <= draws:
        return [list(pick) for pick in itertools.combinations(range(count), size)]
    seen, out = set(), []
    while len(out) < draws:
        pick = tuple(sorted(rng.sample(range(count), size)))
        if pick in seen:
            continue
        seen.add(pick)
        out.append(list(pick))
    return out


def band(values):
    """median and range, the only honest summary of a set of draws.

    §2's rule about single runs applies to sampling too. Which two clips you
    happen to pick decides the answer at n=2, so one draw is worth nothing.
    """
    got = [v for v in values if v == v]
    if not got:
        return float("nan"), float("nan"), float("nan")
    return statistics.median(got), min(got), max(got)


def inner(values):
    """The 10th and 90th percentile of the draws, beside the outer range.

    A min-max range over 200 draws is set by two draws. It says how bad it can
    get, which is the question here, but it says nothing about how often. The
    inner band says that.
    """
    got = [v for v in values if v == v]
    if not got:
        return float("nan"), float("nan")
    return quantile(got, 0.1), quantile(got, 0.9)


def share(values, test):
    """What fraction of the draws satisfy `test`, as a percentage."""
    got = [v for v in values if v == v]
    if not got:
        return float("nan")
    return sum(1 for v in got if test(v)) / len(got) * 100


def subsample_report(source_name, cache, robust, ns, draws, seed, floor,
                     tolerance, csv=None):
    """6e: per-term AUC and per-term veto against the number of recordings.

    For each term, take random subsets of its bank at each n, and score the
    same spans against the smaller bank. The per-clip hold-out runs inside
    `arm` exactly as before, so a subsampled bank can still lose a recording
    to the span it is judging.

    Two numbers per point, because 6a found they disagree. The AUC ranks spans
    inside one term, and `spread` is a constant inside one term, so the AUC
    cannot see the threshold at all. The veto counts are the rule's own
    decision, and they are what an abstain rule is for.
    """
    exemplars, spans = poison_rows(source_name)
    se, ee = poison_matrices(exemplars, spans, cache)
    by_term = banks(exemplars)
    where = "the 90th percentile" if robust else "the maximum"

    print(f"\n=== 6e: the abstain curve ===  spread is {where} of the")
    print("  leave-one-out distances. `veto B` is spans the rule drops where the")
    print("  term was NOT said — true rejections, the rule working. `veto A` is")
    print("  the same rule dropping a span where the term WAS said — false")
    print(f"  rejections, the rule costing. Tolerance {tolerance}, abstain under")
    print(f"  {floor} usable recordings, seed {seed}, up to {draws} draws per point.")
    print(f"  {len(exemplars)} recordings, {len(spans)} spans, source {source_name}.")
    print("\n  Every cell is a median over the draws with a band, never one draw.")
    print("  AUC carries its full range. The veto rates carry the inner 10–90")
    print("  band, because a min-max over 200 draws is set by two of them.")
    print(f"  `dis` is how often a draw leaves the rule disarmed — under "
          f"{DISARMED:.0f}% of the")
    print("  true rejections it should make. `cost` is how often a draw throws")
    print(f"  away more than {OVERCOST:.0f}% of the spans where the term really "
          "was said.")

    curves = defaultdict(dict)               # term -> n -> list of AUCs
    vetoes = defaultdict(dict)               # term -> n -> list of arm results
    full_bank = {}
    sizes = {}
    for term in sorted(by_term):
        bank = by_term[term]
        sizes[term] = len(bank)
        full = arm(bank, exemplars, spans, se, ee, term, robust,
                   tolerance=tolerance, floor=floor)
        # `Praisy` and `Vercel` have no scripted recording and so no A row on
        # the scripted set. The proposal set is the only place they rank at all.
        which = "scripted" if full["n_scripted"][0] else "proposals"
        full_bank[term] = (full, which)
        print(f"\n  {term}  —  {len(bank)} recordings, AUC on the {which} set, "
              f"{full['n_' + which][0]} A / {full['n_' + which][1]} B at full bank")
        print(f"  {'n':>4} {'draws':>6}  {'AUC med [min-max]':^25}  "
              f"{'veto B %':^22} {'dis':>4}  {'veto A %':^22} {'cost':>4}  "
              f"{'spread':^9}")
        # The whole bank is the row 6a reports, and it is the reference every
        # subsample is read against. Adding it twice when it is already in `ns`
        # would print the same single draw as if it were two measurements.
        for n in sorted({x for x in ns if x <= len(bank)} | {len(bank)}):
            rng = random.Random(f"{seed}|{term}|{n}")
            picks = subsets(len(bank), n, draws, rng)
            got = [arm([bank[i] for i in pick], exemplars, spans, se, ee, term,
                       robust, tolerance=tolerance, floor=floor)
                   for pick in picks]
            aucs = [g[f"auc_{which}"] for g in got]
            curves[term][n] = aucs
            vetoes[term][n] = got
            label = f"{n}" + ("*" if n == len(bank) else "")
            print(f"  {label:>4} {len(picks):>6}  "
                  f"{fmt_band(band(aucs), '.3f'):<25}  "
                  f"{fmt_veto(got, 'B')}  {fmt_veto(got, 'A')}  "
                  f"{fmt_one(band([g['spread'] for g in got])[0], '.3f'):>9}")
        print("  * the whole bank: one draw, and the row 6a's tables report")

    print("\n=== the cohorts ===  a mean over a changing set of terms is not a")
    print("  curve. These are fixed sets: every term in a cohort reaches every n")
    print("  in its row, so the columns compare.")
    # One block per distinct set of terms, not one per n. Every n between 2 and
    # 5 keeps the same eleven terms, so they are one cohort with four rows and
    # not four cohorts. The block is labelled by the largest n they all reach.
    seen = {}
    for floor_n in ns:
        members = tuple(sorted(t for t in sizes if sizes[t] >= floor_n))
        if members:
            seen[members] = floor_n
    for members, floor_n in seen.items():
        print(f"\n  the {len(members)} terms with at least {floor_n} recordings: "
              f"{', '.join(members)}")
        print(f"  {'n':>4}  {'mean per-term AUC over the cohort':^25}")
        for n in [x for x in ns if x <= floor_n]:
            # One draw index per term, averaged. A term with fewer draws than
            # the widest cycles, so every draw of the small bank is used and
            # none is used twice before all of them are used once.
            width = max(len(curves[t][n]) for t in members)
            means = []
            for r in range(width):
                take = [curves[t][n][r % len(curves[t][n])] for t in members]
                take = [v for v in take if v == v]
                if take:
                    means.append(sum(take) / len(take))
            print(f"  {n:>4}  {fmt_band(band(means), '.3f')}")

    print("\n=== the same cohorts, as the rule's own decision ===  6a's table,")
    print("  one row per n. A whole cohort's banks are cut to n at once and the")
    print("  rejections are summed, so this is directly comparable to 6a's")
    print("  '554 true rejections' — and to the blind control under it.")
    for members, floor_n in seen.items():
        print(f"\n  the {len(members)} terms with at least {floor_n} recordings")
        print(f"  {'n':>4}  {'true rejections (B)':^26}  "
              f"{'false rejections (A)':^26}")
        for n in [x for x in ns if x <= floor_n] + ["all"]:
            pick = (lambda t: vetoes[t][sizes[t]]) if n == "all" \
                else (lambda t: vetoes[t][n])
            width = max(len(pick(t)) for t in members)
            sums = {"A": [], "B": [], "dA": [], "dB": []}
            for r in range(width):
                draw = [pick(t)[r % len(pick(t))] for t in members]
                for group in ("A", "B"):
                    sums[group].append(sum(g["veto"][group][0] for g in draw))
                    sums["d" + group].append(
                        sum(g["veto"][group][1] for g in draw))
            print(f"  {str(n):>4}  "
                  f"{fmt_total(sums['B'], sums['dB']):^26}  "
                  f"{fmt_total(sums['A'], sums['dA']):^26}")
        print("  'all' is every term at its whole bank — the 6a row, one draw.")
        print("  The denominator is the blind control: reject every span.")

    print("\n=== the smallest n a term is safe at ===  safe means the rule is")
    print(f"  disarmed in at most {SAFE_DIS:.0f}% of draws and throws away over "
          f"{OVERCOST:.0f}% of")
    print(f"  the true spans in at most {SAFE_COST:.0f}% of them, at this n and "
          "every larger n")
    print("  measured. Those two shares are a convention; the per-draw rates are")
    print("  in the tables above and can be read against another one.")
    print(f"\n  {'term':<10} {'rec':>4} {'safe n':>7}  {'full-bank AUC':>13}  "
          f"{'full-bank spread':>17}")
    safe = {}
    for term in sorted(sizes):
        got = [n for n in sorted(curves[term]) if n <= max(ns)]
        answer = None
        for i, n in enumerate(got):
            if all(is_safe(vetoes[term][m]) for m in got[i:]):
                answer = n
                break
        safe[term] = answer
        full, which = full_bank[term]
        print(f"  {term:<10} {sizes[term]:>4} "
              f"{(str(answer) if answer else '> ' + str(max(got))):>7}  "
              f"{fmt_one(full[f'auc_{which}'], '.3f'):>13}  "
              f"{full['spread']:>17.3f}")
    ranked = [t for t in sorted(sizes) if safe[t]]
    if len(ranked) > 2:
        counts = Counter(safe[t] for t in ranked)
        print("\n  safe n takes "
              f"{', '.join(f'{v} term(s) at {k}' for k, v in sorted(counts.items()))}")
        print("  what predicts it, over the terms that reach a safe n:")
        print(f"    Spearman(safe n, recordings)        "
              f"{spearman([safe[t] for t in ranked], [sizes[t] for t in ranked]):+.2f}")
        print(f"    Spearman(safe n, full-bank spread)  "
              f"{spearman([safe[t] for t in ranked], [full_bank[t][0]['spread'] for t in ranked]):+.2f}")
        print("  Read those two numbers as nothing. Safe n is nearly a constant")
        print("  here, so almost every pair is a tie and the rank correlation is")
        print("  carried by the one or two terms that differ. There is no")
        print("  per-term threshold to predict, which is the result.")

    if csv:
        # The printed tables are for reading. This is for building the result
        # block out of, so no number in it is transcribed by hand.
        lines = ["statistic,term,recordings,n,draws,auc_set,auc_median,auc_min,"
                 "auc_max,veto_b_median,veto_b_min,veto_b_max,veto_b_scored,"
                 "veto_b_rate,veto_b_disarmed,veto_a_median,veto_a_min,"
                 "veto_a_max,veto_a_scored,veto_a_rate,veto_a_overcost,spread"]
        for term in sorted(sizes):
            for n in sorted(curves[term]):
                got = vetoes[term][n]
                row = [where.split()[-1], term, sizes[term], n, len(got),
                       full_bank[term][1]]
                row += [f"{v:.4f}" for v in band(curves[term][n])]
                for group, test in (("B", lambda r: r < DISARMED),
                                    ("A", lambda r: r > OVERCOST)):
                    counts = band([g["veto"][group][0] for g in got])
                    scored = [g["veto"][group][1] for g in got]
                    rates = [g["veto"][group][0] / g["veto"][group][1] * 100
                             for g in got if g["veto"][group][1]]
                    row += [f"{v:.0f}" for v in counts]
                    row += [f"{statistics.median(scored):.0f}",
                            f"{statistics.median(rates):.1f}" if rates else "",
                            f"{share(rates, test):.1f}" if rates else ""]
                row.append(f"{band([g['spread'] for g in got])[0]:.4f}")
                lines.append(",".join(str(v) for v in row))
        Path(csv).write_text("\n".join(lines) + "\n")
        print(f"\n  wrote {csv}")


# `safe` in the last table: the rule is disarmed in at most SAFE_DIS% of draws
# and over-rejects in at most SAFE_COST% of them.
SAFE_DIS = 10.0
SAFE_COST = 5.0


def is_safe(got):
    rates = lambda group: [g["veto"][group][0] / g["veto"][group][1] * 100
                           for g in got if g["veto"][group][1]]
    b, a = rates("B"), rates("A")
    if not b or not a:
        return False
    return (share(b, lambda r: r < DISARMED) <= SAFE_DIS
            and share(a, lambda r: r > OVERCOST) <= SAFE_COST)


def spearman(x, y):
    """Rank correlation, ties averaged. Eleven points, so read the sign."""
    def ranks(values):
        order = sorted(range(len(values)), key=lambda i: values[i])
        out = [0.0] * len(values)
        i = 0
        while i < len(order):
            j = i
            while j + 1 < len(order) and values[order[j + 1]] == values[order[i]]:
                j += 1
            for k in range(i, j + 1):
                out[order[k]] = (i + j) / 2.0
            i = j + 1
        return out
    rx, ry = ranks(x), ranks(y)
    mx, my = sum(rx) / len(rx), sum(ry) / len(ry)
    top = sum((a - mx) * (b - my) for a, b in zip(rx, ry))
    left = sum((a - mx) ** 2 for a in rx) ** 0.5
    right = sum((b - my) ** 2 for b in ry) ** 0.5
    return top / (left * right) if left and right else float("nan")


def fmt_total(counts, denominators):
    got = band(counts)
    return (f"{got[0]:.0f} [{got[1]:.0f}–{got[2]:.0f}] of "
            f"{statistics.median(denominators):.0f}")


# A draw is "disarmed" when the rule drops under this share of the spans it
# should drop, and "costing" when it drops over this share of the spans where
# the term really was said. Both are read off the rule's own decision, which is
# the number 6a found an AUC cannot see. The thresholds are conventions, so the
# per-draw rates are printed beside them and can be re-read against others.
DISARMED = 25.0
OVERCOST = 50.0


def fmt_one(value, spec):
    return format(value, spec) if value == value else "  -  "


def fmt_band(triple, spec):
    median, low, high = triple
    if median != median:
        return f"{'-':^25}"
    return (f"{format(median, spec):>6} "
            f"[{format(low, spec)}–{format(high, spec)}]")


def fmt_veto(got, group):
    """The rule's own decision at this n: how much it rejects, and how surely.

    The denominator moves between draws, because the per-clip hold-out can take
    a subsampled bank under the abstain floor and then that span is judged by
    nobody. So the rate is computed inside each draw and summarised after,
    never as one ratio of two medians.
    """
    scored = [g["veto"][group][1] for g in got]
    if not any(scored):
        return f"{'abstained':^22} {'-':>4}"
    rates = [g["veto"][group][0] / g["veto"][group][1] * 100
             for g in got if g["veto"][group][1]]
    counts = band([g["veto"][group][0] for g in got])
    low, high = inner(rates)
    body = (f"{statistics.median(rates):>3.0f} [{low:.0f}-{high:.0f}] "
            f"{counts[0]:.0f}/{statistics.median(scored):.0f}")
    test = (lambda r: r < DISARMED) if group == "B" else (lambda r: r > OVERCOST)
    return f"{body:^22} {share(rates, test):>3.0f}%"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--table", metavar="FILE", help="write the per-proposal table")
    ap.add_argument("--source", default="all",
                    choices=["all", "scripted", "spontaneous", "round6"],
                    help="which recordings to compare against")
    ap.add_argument("--set", default="proposals",
                    choices=["proposals", "scripted"],
                    help="proposals: round 5's A and B rows, what round 6 "
                         "measured. scripted: A and B read off the labels of "
                         "the 48 scripted clips, which is the only set with an "
                         "A row for Redcrawl")
    ap.add_argument("--poison", action="store_true",
                    help="6a: add one clip of the wrong word to each term's "
                         "folder and re-measure. Where the folder already "
                         "holds a bad clip the arm runs backwards and takes "
                         "it out")
    ap.add_argument("--robust", action="store_true",
                    help="6b's statistic: the 90th percentile of the "
                         "leave-one-out distances instead of the maximum")
    ap.add_argument("--inject", default="Vercel/09-brazil.wav",
                    help="the recording to inject as the bad clip")
    ap.add_argument("--cache", default=None,
                    help="npz file for the two distance matrices")
    ap.add_argument("--pronunciation", action="store_true",
                    help="6a's second arm: fill a thin second pronunciation "
                         "cluster one clip at a time")
    ap.add_argument("--subsample", action="store_true",
                    help="6e: subsample each term's bank at several sizes and "
                         "report AUC and veto against the number of recordings")
    ap.add_argument("--ns", default="2,3,5,8,12",
                    help="6e: the bank sizes to draw, comma separated")
    ap.add_argument("--draws", type=int, default=200,
                    help="6e: how many distinct subsets per point. Fewer are "
                         "used when the bank has fewer subsets than that, and "
                         "then every subset is measured")
    ap.add_argument("--seed", default="6e-2026-08-10",
                    help="6e: the sampling seed. Recorded in the output")
    ap.add_argument("--floor", type=int, default=2,
                    help="abstain under this many usable recordings. "
                         "ReferenceMatch uses 3; 6e uses 2 so that n=2 has a "
                         "decision to report at all. Two is the arithmetic "
                         "minimum: one recording has no leave-one-out distance")
    ap.add_argument("--tolerance", type=float, default=1.0,
                    help="reject when distance > tolerance × spread")
    ap.add_argument("--csv", default=None,
                    help="6e: write every number in the tables to this file")
    args = ap.parse_args()
    if args.subsample:
        if args.floor < 2:
            print("✗ --floor must be at least 2: a bank of one recording has "
                  "no leave-one-out distance and so no spread", file=sys.stderr)
            return 2
        try:
            ns = sorted({int(x) for x in args.ns.split(",") if x.strip()})
        except ValueError:
            print(f"✗ --ns wants integers, got {args.ns!r}", file=sys.stderr)
            return 2
        if not ns or ns[0] < 2:
            print("✗ --ns wants sizes of 2 or more", file=sys.stderr)
            return 2
        subsample_report(args.source, args.cache, args.robust, ns, args.draws,
                         args.seed, args.floor, args.tolerance, args.csv)
        return 0
    if args.poison or args.pronunciation:
        got = poison_report(args.source, args.cache, args.robust, args.inject)
        if got is None:
            return 2
        _, exemplars, spans, se, ee = got
        if args.pronunciation:
            poison_pronunciation(exemplars, spans, se, ee, args.robust,
                                 pronunciation_split(exemplars))
        return 0
    if args.set == "scripted":
        return report_scripted(measure_scripted(args.source), args.source)
    kept, dropped = measure(args.source)
    if kept is None:
        return 2
    if args.table:
        return table(kept, dropped, args.table)
    return report(kept, dropped, args.source)


if __name__ == "__main__":
    sys.exit(main())
