#!/usr/bin/env python3
"""Do the metadata signals the literature reports show up in this speaker?

    scripts/disfluency-signals.py

**No model call anywhere in this file.** Every number is arithmetic over
`~/Recordings/ParrotFlow/trace.jsonl`, which is already on disk.

A research summary handed over on 2026-08-11 makes several claims that decide
whether confidence and timing are worth plumbing into the pipeline. Three of
them are testable here, on 281 clips of one person's speech, before anything is
built on them. `scripts/gap-signal.py` is the precedent: ask whether the
evidence carries signal before tuning a threshold against it.

    1. The gap *after* a filled pause is near zero (0.00-0.08s), because the
       filler itself holds the floor and the repair launches immediately. Only
       the gap *before* the interruption point is diagnostic.

    2. In a disfluent repetition the first copy is drawled — "R1 >= 150% vs
       norm" — while an intentional repetition ("very very") accents the
       second copy instead. This is offered as the way to tell them apart,
       since pause cannot.

    3. A deletion gate of `confidence <= 0.80` keeps content-word
       over-deletion under 0.20%.

Claim 2 is the valuable one. `scripts/disfluency.py` currently separates
disfluent from intentional repetition with a hand-written stop list. If token
duration separates them on its own, that list stops being the only thing
standing between the pass and a deleted word.

What the run decided, 2026-08-11, 281 clips and 9014 words: the notes at the
bottom of this file. Two of the three claims do not reproduce here.
"""
import json
import re
import statistics
import sys
from pathlib import Path
from importlib.machinery import SourceFileLoader

ROOT = Path(__file__).resolve().parent.parent
TRACE = Path.home() / "Recordings/ParrotFlow/trace.jsonl"

disfluency = SourceFileLoader(
    "disfluency", str(ROOT / "scripts/disfluency.py")
).load_module()

FILLER = re.compile(r"^(u+h+|u+m+|e+u+h+|erm+|hmm+|mm+)$", re.I)
# A word that carries meaning, for the over-deletion question. Function words
# are excluded because deleting "the" is a grammar error you can see, while
# deleting a name or a number is the failure that does not announce itself.
FUNCTION = {
    "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "at", "for",
    "is", "it", "that", "this", "we", "i", "you", "so", "be", "as", "with",
    "le", "la", "les", "de", "du", "et", "un", "une", "que", "qui", "je",
}


def bare(word):
    return re.sub(r"[^\w'À-ɏ-]", "", word).lower()


def load():
    """One record per wav. The archive holds two sweeps of the same clips."""
    by_wav = {}
    for line in TRACE.read_text().splitlines():
        if not line.strip():
            continue
        record = json.loads(line)
        if (record.get("asr") or {}).get("words"):
            by_wav[record["wav"]] = record
    return list(by_wav.values())


def describe(name, values, unit=""):
    if not values:
        print(f"  {name:34s} (none)")
        return None
    ordered = sorted(values)
    median = statistics.median(ordered)
    print(f"  {name:34s} n={len(ordered):5d}  median={median:5.2f}{unit}"
          f"  mean={statistics.fmean(ordered):5.2f}{unit}")
    return median


records = load()
clips = len(records)
allwords = [w for r in records for w in r["asr"]["words"]]
print(f"{clips} clips, {len(allwords)} words\n")


# --- claim 1: is the gap after a filler really near zero? -------------------

print("1. Gap around a filled pause")
before, after, baseline = [], [], []
for record in records:
    words = record["asr"]["words"]
    for i, word in enumerate(words[:-1]):
        gap = round(words[i + 1]["start"] - word["end"], 3)
        baseline.append(gap)
        if FILLER.match(bare(word["word"])):
            after.append(gap)
        if FILLER.match(bare(words[i + 1]["word"])):
            before.append(gap)

describe("all word pairs", baseline, "s")
describe("before the filler (pre-IP)", before, "s")
describe("after the filler", after, "s")
print("   claim: after ~= 0.00-0.08s, and only the pre-IP gap is diagnostic.\n")


# --- claim 2: is the first copy of a repetition drawled? --------------------
#
# Three durations per repeat. R1 and R2 are the two copies. `norm` is the
# median duration of that same word everywhere else in the archive, which is
# the speaker-normalised baseline the claim is stated against — and which one
# speaker's own corpus can supply directly, with no duration model to fit.

print("2. Token duration across a repetition")
norms = {}
for word in allwords:
    norms.setdefault(bare(word["word"]), []).append(word["end"] - word["start"])
norms = {k: statistics.median(v) for k, v in norms.items() if len(v) >= 5}

ratios = {"disfluent": [], "intentional": []}
r1_vs_r2 = {"disfluent": [], "intentional": []}
for record in records:
    words = record["asr"]["words"]
    tokens = [bare(w["word"]) for w in words]
    text = " ".join(w["word"] for w in words)
    spans = list(disfluency.WORD.finditer(text))
    if len(spans) != len(words):
        # The rebuild has to line up token for token or the protection check
        # is being asked about a different word than the duration is.
        continue
    for i in range(len(tokens) - 1):
        if not tokens[i] or tokens[i] != tokens[i + 1]:
            continue
        kind = ("intentional"
                if disfluency.protected(tokens, i, 1, text, spans)
                else "disfluent")
        d1 = words[i]["end"] - words[i]["start"]
        d2 = words[i + 1]["end"] - words[i + 1]["start"]
        if d2 > 0:
            r1_vs_r2[kind].append(d1 / d2)
        norm = norms.get(tokens[i])
        if norm:
            ratios[kind].append(d1 / norm)

for kind in ("disfluent", "intentional"):
    describe(f"{kind}: R1 / its own median", ratios[kind], "x")
    describe(f"{kind}: R1 / R2", r1_vs_r2[kind], "x")
print("   claim: disfluent R1 >= 1.50x norm; intentional accents R2 instead.\n")


# --- claim 3: what does a confidence <= 0.80 gate actually delete? ----------

print("3. A confidence <= 0.80 deletion gate, on this speaker")
GATE = 0.80
fillers = [w for w in allwords if FILLER.match(bare(w["word"]))]
content = [w for w in allwords
           if not FILLER.match(bare(w["word"])) and bare(w["word"]) not in FUNCTION]

caught = sum(1 for w in fillers if w["confidence"] <= GATE)
lost = sum(1 for w in content if w["confidence"] <= GATE)
print(f"  fillers under the gate            {caught}/{len(fillers)}"
      f"  = {caught / max(len(fillers), 1):.1%} recall")
print(f"  content words under the gate      {lost}/{len(content)}"
      f"  = {lost / max(len(content), 1):.2%} over-deletion")
print("   claim: content-word over-deletion stays under 0.20%.")

worst = sorted(content, key=lambda w: w["confidence"])[:12]
print("\n  the content words a bare confidence gate would delete first:")
for word in worst:
    print(f"    {word['confidence']:.2f}  {word['word']}")


# --- what this measured, 2026-08-11 ----------------------------------------
#
# 281 clips, 9014 words, one speaker. Run it again before trusting any of it
# on a different voice or a different decoder.
#
# **Claim 1, half right.** The direction holds and the magnitude does not.
# The pre-IP gap is the larger of the two (0.40s median against 0.24s), so
# "before is stronger" reproduces. But the gap *after* a filler is 0.24s here,
# not the 0.00-0.08s claimed — three frames of silence, against a 0.00s
# baseline for ordinary word pairs. Both sides carry signal.
#
# The likely reconciliation: the claim describes a filler acting as the
# interregnum of a *repair*, where the speaker already knows the replacement
# and launches it immediately. Most fillers here are not in a repair at all.
# They are standalone hesitation, and the thinking continues after the "uh".
# So the shape of the post-filler gap depends on what the filler is doing,
# which is the thing the gap was going to be used to work out.
#
# **Claim 2 does not reproduce, and this is the load-bearing one.** No drawl,
# in either group:
#
#     R1 / that word's own median      disfluent 1.00x     intentional 1.00x
#     R1 / R2                          disfluent 1.00x     intentional 1.00x
#
# Against a claimed 1.50x for disfluent first copies. Not a resolution
# problem: the median word is four 80ms frames, a 50% drawl would be two extra
# frames, and 23 of the 43 repeats do differ in frame count. There is room to
# see the effect and it is not there.
#
# Small groups — 26 disfluent, 11 intentional — so a subtle effect would be
# invisible. An effect the size of the one claimed would not be.
#
# The consequence for `scripts/disfluency.py`: **the stop list stays.** There
# is no measurement available to replace it with. Distinguishing "blah blah
# blah" from "the the" is a lexical judgement on this decoder's metadata, and
# the report's own architecture table agrees on the mechanism — the cues it
# names for repetition are F0 step-down and glottalisation, and TDT exposes
# neither. Pitch is not in `asr.words` and nothing in FluidAudio surfaces it.
#
# **Claim 3 fails by two orders of magnitude, taken alone.** A bare
# `confidence <= 0.80` gate deletes 19.38% of content words here, not 0.20%,
# and catches only 69.2% of fillers. The gate the report actually specifies is
# a conjunction — text probability >= 0.94 AND confidence <= 0.80 AND a
# duration innovation — so this is not a refutation of the report so much as a
# measurement of what the confidence term contributes on its own, which is:
# nothing safe.
#
# The actionable form of that: **do not add a confidence condition to the
# shipped `fillers` transform.** That transform deletes a closed list of
# spellings, which is already safe by construction — "um" is never a content
# word. Requiring `confidence <= 0.80` on top would stop it deleting 31% of
# the fillers it removes today and would buy no safety at all. Confidence is a
# veto to hang on an *open*-class decision, and the only open-class decision in
# reach is the polysemous marker set ("enfin", "like", "actually"), which is
# not built.
