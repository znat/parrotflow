#!/usr/bin/env python3
"""Does a span of audio sound like a recording of the term it was offered?

    scripts/reference-matching.py                  # the report
    scripts/reference-matching.py --table FILE     # the per-proposal distances
    scripts/reference-matching.py --source round6  # only round 6's recordings

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
import json
import os
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
    args = ap.parse_args()
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
