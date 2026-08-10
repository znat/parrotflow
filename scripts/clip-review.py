#!/usr/bin/env python3
"""Review a term's recordings by ear, in groups. PR 6c.

    scripts/clip-review.py                       # the report, every term
    scripts/clip-review.py --term Vercel         # one term
    scripts/clip-review.py --concat DIR          # one wav per group, to play
    scripts/clip-review.py --mark Vercel/g4      # mark a group not counted
    scripts/clip-review.py --unmark Vercel/g4    # and take it back
    scripts/clip-review.py --veto                # what a mark does to the rule
    scripts/clip-review.py --falsify             # the accuracy number

**This never writes to the voice store.** It reads `voice/samples/` and
`voice/observations.jsonl` and writes nothing back — not a marking, not a move,
not a rename. A mark goes to a separate file (`--marks`), so a mistake is
undone by deleting a line. `PARROTFLOW_CONFIG_DIR` moves the store the same way
it does for every other harness here.

**Why this is not a pruner, and this is the whole design.** 6a measured what
the old 6c proposed. Bad clips arrive in groups and vouch for each other, so
the statistic that would drive an automatic pruner — leave-one-out distance
from the pack — points at real recordings. `Tasmeen`'s leave-one-out maximum is
held by `01-tasmin.wav`, a genuine recording; the bad `06-that'smeanssend.wav`
is 5th of 8. Removing `Vercel/09-brazil.wav` makes that term's spread *worse*,
3.178 to 3.235, and costs 6 true rejections, because the bad clip was another
recording's nearest neighbour. So distance from the pack is not a ranking, and
nothing here deletes a file.

What is left is two signals with no geometry in them, and one use for the
geometry that is not ranking:

    provenance  `Observation.from` — `correction`, `mined`, `calibration` or
                `legacy`. A correction is vouched for by the speaker. A mined
                clip is only as good as the decode that produced it, and both
                clips PR 6c names as bad are mined.
    duration    `Observation.span` — a cut much longer or much shorter than the
                term's typical span is a bad cut, not a bad pronunciation. PR 4
                found 2 of 60 correction spans over 2s, worst 6.4s, where a word
                timing swallowed the pause after it.
    groups      the geometry decides what is played *together*, not what is
                suspected. Four half-second clips is under three seconds, so a
                group is one question instead of four.

**A group's tightness says how much of the reviewer's attention to ask for. It
is not proof the group is one thing.** One mispronunciation can sit inside a
tight group by accident, which is exactly what `Tasmeen` does — the four
mutually-near clips there include `06-that'smeanssend`. Tight means "answer it
as a unit"; loose means "play it clip by clip". Neither means "it is fine".

The MFCC and the DTW are `scripts/reference-matching.py`'s, imported rather
than copied, so a distance printed here is the same number 6a and 6e printed.
numpy only. No app, no model, no Ollama, no decode.
"""
import argparse
import datetime
import hashlib
import importlib.util
import json
import math
import random
import shlex
import statistics
import sys
import wave
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent


def reference_matching():
    """`scripts/reference-matching.py`, whose name is not an identifier.

    Everything acoustic in this file is that module's: `read`, `mfcc`, `dtw`,
    `quantile`, `auc`, and the voice-store paths. Two copies of a DTW would
    drift, and then a distance here would not be a distance there.
    """
    path = ROOT / "scripts/reference-matching.py"
    spec = importlib.util.spec_from_file_location("reference_matching", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


RM = reference_matching()

# How much a cut may differ from the term's median cut before it is called out.
# 1.5× either way. A name is about half a second in this archive, so this is
# 0.75s against 0.43s on a 0.64s median — well outside the jitter of a word
# boundary, and well inside the 6.4s cut PR 4 found.
RATIO = 1.5

# A cut exactly at the band edge counts as outside it. Cut lengths in this
# archive are multiples of 0.08s, so exact ratios of 1.5 happen — 0.48s against
# a 0.72s median is one, and `Vercel/09-brazil.wav` is that clip. Without the
# tolerance the last bit of a float decides whether it is surfaced, which is a
# coin flip and not a rule. Erring towards surfacing is the right side for a
# tool whose output a person reads.
EDGE = 1.0 - 1e-9

# What each provenance is worth, as risk: 0 is vouched for, 1 is not vouched
# for at all. `correction` is the speaker confirming the word. `calibration` is
# a read line, so the word is known but nobody checked the cut. `legacy`
# predates the field. `mined` is a guess from a decode that may itself have
# been wrong, which is what both clips PR 6c names as bad are.
RISK = {"correction": 0.0, "calibration": 0.3, "legacy": 0.6, "mined": 1.0}
UNKNOWN = 1.0

# Clips per group, and the most a group may hold. Four half-second clips is
# under three seconds with the gaps, which is the point: a group is one
# question. Six is the ceiling, so a big bank gets more groups rather than one
# unplayable one.
TARGET = 4
MAX_GROUP = 6

# 6e's abstain point. Under five counted recordings a bank throws away over
# half of the term's own correct spans too often to be allowed to decide.
# Marking is the fastest way to walk a bank off that edge, so this is checked
# at the moment a mark is made.
FLOOR = 5


# --------------------------------------------------------------- the clip bank

def load_clips():
    """Every recording in the voice store, with what is known about it.

    `observations.jsonl` is the only place provenance and the span live, so a
    wav with no row is loaded anyway and reported as unlabelled rather than
    dropped. Its duration comes off the file, which is the same number for
    every other clip: `mine-pronunciations.py` writes exactly the span it
    records.
    """
    voice = RM.voice_dir()
    samples = voice / "samples"
    if not samples.exists():
        print(f"✗ no recordings under {samples}", file=sys.stderr)
        return []
    rows = {}
    log = voice / "observations.jsonl"
    if log.exists():
        for line in log.read_text(encoding="utf-8").splitlines():
            try:
                row = json.loads(line)
            except ValueError:
                continue
            name = (row.get("sample") or "").replace("samples/", "")
            if name:
                rows[name] = row
    clips = []
    for path in sorted(samples.rglob("*.wav")):
        name = f"{path.parent.name}/{path.name}"
        row = rows.get(name, {})
        span = row.get("span") or []
        samples_read = RM.read(path)
        clips.append({
            "name": name,
            "term": path.parent.name,
            "path": path,
            "from": row.get("from"),
            "seconds": (span[1] - span[0]) if len(span) == 2
                       else samples_read.size / RM.RATE,
            "timed": len(span) == 2,
            "heard": row.get("heard"),
            "wav": row.get("wav"),
            "at": row.get("at"),
            "mfcc": RM.mfcc(samples_read),
        })
    kept = [c for c in clips if c["mfcc"] is not None]
    if len(kept) != len(clips):
        print(f"  {len(clips) - len(kept)} clip(s) are shorter than one MFCC "
              "frame and cannot be compared", file=sys.stderr)
    return kept


def fingerprint(clips):
    """A digest of the exact audio the cached matrix was computed from.

    Names and counts are not enough — a recording can be replaced without its
    path changing. So the MFCCs themselves go in, in order, with the name of
    the row they belong to. This is `reference-matching.py`'s rule and the
    reason for it is the same: anything the cache cannot vouch for is rebuilt.
    """
    digest = hashlib.sha256()
    for c in clips:
        digest.update(f"C|{c['name']}|".encode())
        digest.update(np.ascontiguousarray(c["mfcc"], dtype=np.float64).tobytes())
    return digest.hexdigest()


def distances(clips, cache):
    """Every recording-to-recording DTW distance, once.

    122 recordings is 7381 pairs and about thirty seconds. Every arm after
    that — grouping, marking, the falsifier's twelve hundred injections — is
    indexing this matrix.
    """
    stamp = fingerprint(clips)
    if cache and Path(cache).exists():
        # No pickle: this reads a cache this script wrote and nothing else.
        blob = np.load(cache)
        if {"stamp", "ee"} <= set(blob.files) and str(blob["stamp"]) == stamp:
            return blob["ee"]
        print("  the cache does not match this audio; rebuilding", file=sys.stderr)
    n = len(clips)
    ee = np.zeros((n, n))
    for i in range(n):
        for j in range(i + 1, n):
            ee[i, j] = ee[j, i] = RM.dtw(clips[i]["mfcc"], clips[j]["mfcc"])
        print(f"  recordings {i + 1}/{n}", end="\r", file=sys.stderr)
    if cache:
        np.savez(cache, stamp=stamp, ee=ee,
                 names=np.array([c["name"] for c in clips]))
    return ee


# ------------------------------------------------------------------ the groups

def group(bank, ee, target=TARGET, cap=MAX_GROUP):
    """Average-linkage groups of `bank`, no bigger than `cap`.

    Average linkage, not single linkage: single linkage chains, and a bank with
    almost no cluster structure — which is what these are, see the report's own
    separation number — chains into one group and a pile of singletons.

    The cut is a count, not a distance, and that is deliberate. A distance cut
    needs a threshold, the distance scale differs per term (part 1 §3), and on
    these banks any threshold near the bulk of the distribution produces mostly
    singletons. A count produces a bounded review whatever the geometry does.
    The cost is that the groups are always *something*; the separation number
    printed beside them is what says whether they are anything.
    """
    if not bank:
        return []
    want = max(1, math.ceil(len(bank) / target))
    groups = [[i] for i in bank]
    while len(groups) > want:
        best = None
        for a in range(len(groups)):
            for b in range(a + 1, len(groups)):
                if len(groups[a]) + len(groups[b]) > cap:
                    continue
                d = sum(ee[i][j] for i in groups[a] for j in groups[b])
                d /= len(groups[a]) * len(groups[b])
                if best is None or d < best[0]:
                    best = (d, a, b)
        if best is None:
            break                      # every legal merge would break the cap
        _, a, b = best
        groups[a] = groups[a] + groups[b]
        groups.pop(b)
    return sorted(groups, key=lambda g: (-len(g), g[0]))


def leave_one_out(members, ee):
    """Each member's distance to its nearest other member.

    `ReferenceMatch.verdict` step 2, computed over whatever set it is given.
    Over a whole bank its maximum is `spread`. Over a group it is the group's
    tightness, which is the same number asking a smaller question.
    """
    if len(members) < 2:
        return []
    return [min(ee[i][j] for j in members if j != i) for i in members]


def spread(members, ee, robust=False):
    """The width of the cloud: the maximum, or 6b's 90th percentile."""
    loo = leave_one_out(members, ee)
    if not loo:
        return float("nan")
    return RM.quantile(loo, 0.9) if robust else max(loo)


def separation(groups, ee):
    """AUC(a between-group distance > a within-group distance).

    0.500 means the groups are a review order and nothing else. 1.000 means
    they never touch. This is the honest label on the grouping, and it is the
    same check 6a ran on `Matthieu`'s two renderings, where it came back 0.513.
    """
    within = [ee[i][j] for g in groups for a, i in enumerate(g) for j in g[a + 1:]]
    between = [ee[i][j] for x, g in enumerate(groups)
               for h in groups[x + 1:] for i in g for j in h]
    return RM.auc(between, within)


# -------------------------------------------------------------- the suspicions

def duration_risk(clip, median):
    """How far outside the term's typical cut this one is, in units of RATIO.

    1.0 is exactly at the band edge. The log makes twice as long and half as
    long the same size of oddity, which is what they are: both are the cut
    being wrong, not the pronunciation.
    """
    if not (median > 0) or not (clip["seconds"] > 0):
        return float("nan")
    return abs(math.log(clip["seconds"] / median)) / math.log(RATIO)


def score_bank(bank, clips):
    """Provenance and duration risk for every clip in one term's bank.

    Both are computed against the bank the clip sits in, never against the
    archive: `Arexvy` is a longer name than `Claude`, so a cut is long or short
    only relative to its own term.
    """
    median = statistics.median([clips[i]["seconds"] for i in bank])
    kinds = {clips[i]["from"] for i in bank}
    # A signal that is the same on every clip in the bank ranks nothing. Say so
    # rather than flagging all of them, which is the same as flagging none.
    informative = len(kinds) > 1
    out = {}
    for i in bank:
        c = clips[i]
        out[i] = {
            "duration": duration_risk(c, median),
            "provenance": RISK.get(c["from"], UNKNOWN),
            "provenance_ranks": informative,
        }
    return out, median, informative


def group_reasons(members, scores, tightness, term_spread):
    """Why this group is worth a person's time, in the order they should read.

    Provenance first — it is the strongest signal and it involves no geometry
    at all. Then duration. Then the two things about the group itself, which
    say how to review it rather than whether to.
    """
    reasons = []
    ranks = any(scores[i]["provenance_ranks"] for i in members)
    worst_provenance = max(scores[i]["provenance"] for i in members)
    if ranks and worst_provenance >= RISK["mined"]:
        n = sum(1 for i in members if scores[i]["provenance"] >= RISK["mined"])
        reasons.append(f"provenance: {n} of {len(members)} mined, "
                       "not confirmed by the speaker")
    odd = [i for i in members if scores[i]["duration"] == scores[i]["duration"]
           and scores[i]["duration"] >= EDGE]
    if odd:
        reasons.append(f"duration: {len(odd)} cut(s) outside ×{RATIO} of the "
                       "term's median")
    if len(members) == 1:
        reasons.append("singleton: no other recording in the bank vouches for it")
    elif tightness == tightness and term_spread == term_spread \
            and tightness >= term_spread:
        reasons.append("loose: no tighter than the whole bank — play it clip "
                       "by clip")
    return reasons


def group_key(members, scores):
    """The review order. Provenance, then duration. No geometry in it.

    6a is the reason: the geometric statistic points at real recordings, so it
    orders the review by the wrong thing.
    """
    provenance = max(scores[i]["provenance"] for i in members) \
        if any(scores[i]["provenance_ranks"] for i in members) else 0.0
    risks = [scores[i]["duration"] for i in members
             if scores[i]["duration"] == scores[i]["duration"]]
    return (-provenance, -(max(risks) if risks else 0.0))


# ------------------------------------------------------------------- the marks

def load_marks(path):
    if not path or not Path(path).exists():
        return []
    try:
        blob = json.loads(Path(path).read_text())
    except ValueError:
        print(f"✗ {path} is not readable JSON", file=sys.stderr)
        return []
    return blob.get("not_counted", [])


def save_marks(path, marks):
    Path(path).write_text(json.dumps({"not_counted": marks}, indent=2) + "\n")


def marked_names(marks):
    """Every clip any mark covers.

    A mark stores the clip names, not the group id. Group ids are positions in
    a grouping and they move the moment a recording is added; a clip name does
    not. So a mark made today still names the same audio tomorrow.
    """
    return {name for m in marks for name in m.get("clips", [])}


# ------------------------------------------------------------------- the report

def playback(clips, members):
    """A line to paste. `afplay` takes one file, so this is a chain of them.

    `shlex.quote`, because `Tasmeen/06-that'smeanssend.wav` is a real filename
    in this archive and a naive single quote around it ends the quoting halfway
    through the word. What comes out is safe in bash, zsh and fish.
    """
    return "; ".join(f"afplay {shlex.quote(str(clips[i]['path']))}"
                     for i in members)


def concat(clips, members, out, label, gap=0.25):
    """One wav per group, so a group is one keystroke instead of four.

    Written to `out`, which is never the archive. The gap is what makes four
    clips hearable as four clips rather than one smear.
    """
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    silence = np.zeros(int(gap * RM.RATE), dtype=np.int16)
    data = []
    for k, i in enumerate(members):
        if k:
            data.append(silence)
        data.append(RM.read(clips[i]["path"]).astype(np.int16))
    joined = np.concatenate(data) if data else np.zeros(0, dtype=np.int16)
    path = out / f"{clips[members[0]]['term']}-{label}.wav"
    with wave.open(str(path), "wb") as dst:
        dst.setnchannels(1)
        dst.setsampwidth(2)
        dst.setframerate(RM.RATE)
        dst.writeframes(joined.astype("<i2").tobytes())
    return path


def report(clips, ee, terms, marks, out_dir, robust):
    excluded = marked_names(marks)
    by_term = defaultdict(list)
    for i, c in enumerate(clips):
        by_term[c["term"]].append(i)

    kinds = Counter(c["from"] or "unlabelled" for c in clips)
    print(f"\n=== the bank ===  {len(clips)} recordings over "
          f"{len(by_term)} terms, {RM.voice_dir()}")
    print("  provenance across the whole archive:")
    for kind, n in kinds.most_common():
        print(f"    {kind:<14} {n:>4}  ({n / len(clips) * 100:.0f}%)")
    if len(kinds) == 1:
        only = next(iter(kinds))
        print(f"\n  Every clip is `{only}`, so provenance ranks nothing today.")
        print("  It is the strongest of the two signals and it is the one this")
        print("  archive cannot use yet: PR 4 is what writes `correction` on a")
        print("  clip the speaker confirmed. Until corrections land, the whole")
        print("  ranking below rests on duration.")
    if excluded:
        print(f"\n  {len(excluded)} clip(s) marked not counted in {out_dir}")

    total_groups = 0
    for term in terms:
        bank = [i for i in by_term[term] if clips[i]["name"] not in excluded]
        dropped = [i for i in by_term[term] if clips[i]["name"] in excluded]
        if not bank:
            print(f"\n=== {term} ===  every clip is marked not counted")
            continue
        scores, median, _ = score_bank(bank, clips)
        groups = group(bank, ee)
        total_groups += len(groups)
        term_spread = spread(bank, ee, robust)
        sep = separation(groups, ee) if len(groups) > 1 else float("nan")
        where = "90th percentile" if robust else "maximum"
        print(f"\n=== {term} ===  {len(bank)} clips, {len(groups)} groups, "
              f"spread {term_spread:.3f} ({where})")
        if dropped:
            print(f"  {len(dropped)} clip(s) not counted: "
                  f"{', '.join(clips[i]['name'].split('/')[-1] for i in dropped)}")
        print(f"  median cut {median:.2f}s; provenance "
              f"{', '.join(f'{k} {v}' for k, v in sorted(Counter(clips[i]['from'] or 'unlabelled' for i in bank).items()))}")
        print(f"  group separation AUC "
              f"{format(sep, '.3f') if sep == sep else '  -  '}"
              "   0.500 is one cluster cut in pieces, 1.000 is groups that "
              "never touch")

        ordered = sorted(groups, key=lambda g: group_key(g, scores))
        labels = {id(g): f"g{n + 1}" for n, g in enumerate(groups)}
        for g in ordered:
            tight = spread(g, ee, robust)
            reasons = group_reasons(g, scores, tight, term_spread)
            members = sorted(g, key=lambda i: -(scores[i]["duration"]
                                                if scores[i]["duration"] == scores[i]["duration"]
                                                else -1))
            seconds = sum(clips[i]["seconds"] for i in g)
            print(f"\n  {labels[id(g)]}  {len(g)} clip(s), {seconds:.1f}s of audio, "
                  f"tightness {format(tight, '.3f') if tight == tight else '  -  '}")
            for i in members:
                s = scores[i]
                ratio = clips[i]["seconds"] / median if median else float("nan")
                flag = "  <- cut" if s["duration"] == s["duration"] \
                    and s["duration"] >= EDGE else ""
                print(f"      {clips[i]['name'].split('/')[-1]:<26} "
                      f"{clips[i]['seconds']:.2f}s ×{ratio:.2f}  "
                      f"{clips[i]['from'] or 'unlabelled':<12}{flag}")
            for r in reasons:
                print(f"      why: {r}")
            print(f"      play: {playback(clips, members)}")
            if out_dir:
                path = concat(clips, members, out_dir, labels[id(g)])
                print(f"      or:   afplay {shlex.quote(str(path))}")
            print(f"      mark: scripts/clip-review.py --mark "
                  f"{term}/{labels[id(g)]}")

    print(f"\n=== the review ===  {total_groups} groups over {len(terms)} terms")
    print("  A group is one question. Tightness says how much attention to ask")
    print("  for, not whether the group is one thing: a mispronunciation can")
    print("  sit inside a tight group, which is what Tasmeen does.")
    return total_groups


# ------------------------------------------------------- what a mark would cost

def effect(clips, ee, marks, terms, veto_cache, robust):
    """What marking a group not-counted does, so the decision has a consequence.

    Two levels. The spread is computable from the clips alone and is always
    printed. The veto is the rule's own decision and needs labelled spans, so
    it needs the harness data `reference-matching.py` uses; without it the
    section says so and stops.
    """
    excluded = marked_names(marks)
    if not excluded:
        print("\n=== the effect of the marks ===  nothing is marked")
        return
    by_term = defaultdict(list)
    for i, c in enumerate(clips):
        by_term[c["term"]].append(i)
    where = "90th percentile" if robust else "maximum"
    print(f"\n=== the effect of the marks ===  spread is the {where} of the")
    print("  leave-one-out distances, which is what `ReferenceMatch.verdict`")
    print("  compares a span against. Nothing is deleted: these clips are still")
    print("  on disk and unmarking puts them back.")
    print(f"\n  {'term':<12} {'clips':>11}  {'spread':>17}")
    for term in terms:
        bank = by_term[term]
        kept = [i for i in bank if clips[i]["name"] not in excluded]
        if len(kept) == len(bank):
            continue
        before, after = spread(bank, ee, robust), spread(kept, ee, robust)
        print(f"  {term:<12} {len(bank):>4} -> {len(kept):<4}  "
              f"{before:>7.3f} -> {after:<7.3f}")

    print("\n  and what that does to the rule, on the labelled spans")
    got = veto_arms(clips, marks, veto_cache, robust)
    if got is None:
        return
    print(f"\n  {'term':<12} {'veto B (the rule working)':<28} "
          f"{'veto A (the rule costing)':<24}")
    for term, before, after in got:
        b0, b1 = before["veto"]["B"], after["veto"]["B"]
        a0, a1 = before["veto"]["A"], after["veto"]["A"]
        # "abstains", not "-". A zero denominator means the bank fell under the
        # abstain floor and stopped deciding at all, which is a different thing
        # from deciding and rejecting nothing.
        rate = lambda p: f"{p[0]}/{p[1]}" if p[1] else "abstains"
        print(f"  {term:<12} {rate(b0):>8} -> {rate(b1):<8}          "
              f"{rate(a0):>6} -> {rate(a1):<6}")
    print("\n  B is a span where the name was NOT said, so dropping it is the")
    print("  rule working. A is the name really being said, so dropping it is")
    print("  the cost. These are rejection counts on 6a's spans, not the")
    print("  141-clip ablation, and they do not say what the app would write.")


def veto_arms(clips, marks, cache, robust):
    """`ReferenceMatch.verdict`'s own counts, before and after the marks.

    Straight out of `reference-matching.py`: the same spans, the same per-clip
    hold-out, the same abstain floor. Only the bank changes.
    """
    try:
        exemplars, spans = RM.poison_rows("all")
        span_census(spans)
        se, ee = RM.poison_matrices(exemplars, spans, cache)
    except Exception as error:                       # noqa: BLE001 — reported
        print(f"\n  the labelled spans are not available here: {error}")
        print("  they need ~/Recordings/ParrotFlow Dev/ and round 5's cached")
        print("  proposals, which is harness data and not part of the voice")
        print("  store. The spread above needs neither.")
        return None
    excluded = marked_names(marks)
    by_term = RM.banks(exemplars)
    out = []
    for term in sorted(by_term):
        bank = by_term[term]
        kept = [i for i in bank if exemplars[i]["name"] not in excluded]
        if len(kept) == len(bank):
            continue
        before = RM.arm(bank, exemplars, spans, se, ee, term, robust)
        after = RM.arm(kept, exemplars, spans, se, ee, term, robust)
        out.append((term, before, after))
    return out


def per_cluster_veto(clips, ee, cache, robust):
    """6b's third change, and PR 6c's third verification criterion.

    §7 argues the spread must be computed per cluster, because one number over
    two pronunciations describes neither. That needs 6c's grouping, so it is
    measured here. The criterion it answers is the sharp one: **a term that
    keeps all its clips and rejects nothing has failed.** Keeping every clip is
    what this tool does by default, so the question is whether the term still
    vetoes — under the per-term spread it has, and under the per-cluster spread
    6b proposes.
    """
    try:
        exemplars, spans = RM.poison_rows("all")
    except Exception as error:                       # noqa: BLE001 — reported
        print(f"\n=== per-cluster spread ===  not available here: {error}")
        return
    span_census(spans)
    se, ee_ref = RM.poison_matrices(exemplars, spans, cache)
    # The grouping is computed on this script's own clip list, so it has to be
    # carried across by name. Anything the two disagree about is skipped and
    # counted rather than guessed at.
    index = {e["name"]: i for i, e in enumerate(exemplars)}
    mine = {c["name"]: i for i, c in enumerate(clips)}
    by_term = RM.banks(exemplars)
    where = "90th percentile" if robust else "maximum"
    print(f"\n=== per-cluster spread ===  6b's third change, on 6c's groups.")
    print(f"  spread is the {where} of the leave-one-out distances, taken over")
    print("  the whole bank on the left and over the group the span is nearest")
    print("  on the right. Tolerance 1.0, abstain under 3 usable recordings.")
    print(f"\n  {'term':<12} {'groups':>6}  {'veto B per-term':>16} "
          f"{'per-cluster':>12}  {'veto A per-term':>16} {'per-cluster':>12}")
    totals = [0, 0, 0, 0]
    for term in sorted(by_term):
        bank = by_term[term]
        # Group in this script's index space, then translate to the reference
        # module's. A name in one and not the other drops the whole term rather
        # than silently grouping a subset.
        names = [exemplars[i]["name"] for i in bank]
        if any(n not in mine for n in names):
            print(f"  {term:<12} skipped: a recording is not in both banks")
            continue
        groups = group([mine[n] for n in names], ee)
        clusters = [[index[clips[i]["name"]] for i in g] for g in groups]
        flat = RM.arm(bank, exemplars, spans, se, ee_ref, term, robust)
        split = cluster_arm(clusters, exemplars, spans, se, ee_ref, term, robust)
        rate = lambda p: f"{p[0]}/{p[1]}" if p[1] else "abstains"
        print(f"  {term:<12} {len(clusters):>6}  {rate(flat['veto']['B']):>16} "
              f"{rate(split['veto']['B']):>12}  {rate(flat['veto']['A']):>16} "
              f"{rate(split['veto']['A']):>12}")
        totals = [totals[0] + flat["veto"]["B"][0], totals[1] + split["veto"]["B"][0],
                  totals[2] + flat["veto"]["A"][0], totals[3] + split["veto"]["A"][0]]
    print(f"  {'all terms':<12} {'':>6}  {totals[0]:>16} {totals[1]:>12}  "
          f"{totals[2]:>16} {totals[3]:>12}")
    print("\n  A term whose per-cluster column is 0 on B keeps every clip and")
    print("  rejects nothing, which PR 6c calls a failure.")


def cluster_arm(clusters, exemplars, spans, se, ee, term, robust,
                tolerance=1.0, floor=3):
    """`ReferenceMatch.verdict` with the spread taken inside one cluster.

    The span picks its cluster the same way it picks its recording — the
    nearest one — and is then compared against that cluster's own width. The
    per-clip hold-out runs first, so a cluster can lose a member to the span it
    is judging and fall under the abstain floor, in which case it does not
    decide and the next-nearest cluster that can decide does.
    """
    veto = {"A": [0, 0], "B": [0, 0]}
    for k, s in enumerate(spans):
        if s["set"] == "scripted":
            group_name = "A" if s["stem"] == term else "B"
        elif s["stem"] == term:
            group_name = s["group"]
        else:
            continue
        usable = []
        for c in clusters:
            keep = [i for i in c if exemplars[i]["from"] != s["wav"]]
            if len(keep) >= floor:
                usable.append(keep)
        if not usable:
            continue
        best = min(usable, key=lambda c: min(se[k][i] for i in c))
        distance = min(se[k][i] for i in best)
        width = spread_over(best, ee, robust)
        if not (width > 0):
            continue
        veto[group_name][1] += 1
        if distance > tolerance * width:
            veto[group_name][0] += 1
    return {"veto": veto}


def span_census(spans):
    """What the veto arms are actually scoring, said out loud.

    Both span sets come from files outside the voice store — the clip archive
    and round 5's cached proposals. When one is missing it does not raise: the
    set silently shrinks and the rejection counts come out lower, which reads
    as the rule getting worse rather than as the measurement changing. So the
    count is printed every time and a missing set is named.
    """
    kinds = Counter(s["set"] for s in spans)
    print(f"  scoring {len(spans)} span(s): {kinds['scripted']} from the 48 "
          f"scripted clips, {kinds['proposals']} from round 5's proposals")
    for name, where in (("scripted", "~/Recordings/ParrotFlow Dev/"),
                        ("proposals", "tests/raw-score-separation.json")):
        if not kinds[name]:
            print(f"  ⚠ no {name} spans. {where} is missing, so these counts "
                  "are not comparable with 6a's.")


def spread_over(members, ee, robust):
    loo = [min(ee[i][j] for j in members if j != i) for i in members] \
        if len(members) > 1 else []
    if not loo:
        return float("nan")
    return RM.quantile(loo, 0.9) if robust else max(loo)


# --------------------------------------------------------------- the falsifier

def falsify(clips, ee, donors, seed):
    """Does this ranking find a clip that is known to be wrong?

    6a's `--poison` arm is what makes a labelled bad clip: take a recording of
    one term, put it in another term's folder, and it is by construction not
    that term. Two arms, because they are not the same claim:

        cross-term   every recording of another term, injected into each bank.
                     A thousand-odd labelled bad clips, and the only accuracy
                     number this data can produce.
        known bad    the two clips PR 6c names, injected into the nine folders
                     that have no known bad clip. 6a's exact arm.

    **Read the cross-term number with its flaw.** A `Claude` clip is short and
    an `Arexvy` clip is long, so part of what duration catches there is that
    different names take different times to say. That is a real property of a
    bad cut — a cut of the wrong word is the wrong length — but it flatters the
    number, and the known-bad arm is the one with no such help.

    Reported beside it: how often the injected clip lands in a group of its
    own. That is the geometric signal, and 6a is the reason it is a contrast
    and not the method.
    """
    by_term = defaultdict(list)
    for i, c in enumerate(clips):
        by_term[c["term"]].append(i)

    print("\n=== the falsifier ===  labelled bad clips, from 6a's --poison")
    print("  A method that finds these at chance is falsified. Chance is the")
    print("  share of genuine clips the same rule flags, printed beside it.")

    # The base rate for the geometric contrast: how often a *genuine* clip is
    # alone in its group with nothing injected. Without it "44% land alone"
    # is a number with no scale.
    alone_base = sum(1 for term in by_term
                     for g in group(by_term[term], ee) if len(g) == 1)
    print(f"\n  base rates on the untouched archive: {alone_base} of "
          f"{len(clips)} genuine clips "
          f"({alone_base / len(clips) * 100:.1f}%) are alone in their group")
    named = {"Vercel/09-brazil.wav", "Tasmeen/06-that'smeanssend.wav"}
    for name in sorted(named):
        home = name.split("/")[0]
        if home not in by_term:
            continue
        index = {clips[i]["name"]: i for i in by_term[home]}
        if name not in index:
            continue
        mine = next(g for g in group(by_term[home], ee) if index[name] in g)
        print(f"  in its own folder {name} sits in a group of {len(mine)}")
    print("  — which is 6a's finding through a different statistic: a bad clip")
    print("  with company is invisible to any per-clip geometry.")

    for label, pairs in (("cross-term", cross_term(by_term, donors, seed)),
                         ("known bad", known_bad(clips, by_term))):
        rows = []
        for term, donor in pairs:
            bank = by_term[term] + [donor]
            scores, median, _ = score_bank(bank, clips)
            groups = group(bank, ee)
            home = next(g for g in groups if donor in g)
            rows.append({
                "term": term,
                "donor": clips[donor]["name"],
                "risk": scores[donor]["duration"],
                "flagged": scores[donor]["duration"] >= EDGE,
                "genuine": [scores[i]["duration"] for i in by_term[term]],
                "genuine_flagged": sum(1 for i in by_term[term]
                                       if scores[i]["duration"] >= EDGE),
                "genuine_n": len(by_term[term]),
                "alone": len(home) == 1,
                "rank": rank_of(donor, bank, scores),
            })
        if not rows:
            print(f"\n  {label}: no injections available")
            continue
        flagged = sum(1 for r in rows if r["flagged"]) / len(rows) * 100
        base = (sum(r["genuine_flagged"] for r in rows)
                / sum(r["genuine_n"] for r in rows) * 100)
        value = RM.auc([r["risk"] for r in rows],
                       [d for r in rows for d in r["genuine"]])
        alone = sum(1 for r in rows if r["alone"]) / len(rows) * 100
        median_rank = statistics.median(r["rank"] for r in rows)
        print(f"\n  {label}: {len(rows)} injections over "
              f"{len({r['term'] for r in rows})} terms")
        print(f"    flagged by duration        {flagged:5.1f}%")
        print(f"    the same rule on genuine   {base:5.1f}%   <- chance")
        print(f"    AUC(bad vs genuine)        {value:.3f}   0.500 is chance")
        print(f"    median rank in the review  {median_rank:.2f}   "
              "0.00 is first, 1.00 is last, 0.50 is chance")
        print(f"    lands in a group of one    {alone:5.1f}%   <- the geometric")
        print("                                       signal, for contrast only")
        if label == "known bad":
            for r in sorted(rows, key=lambda r: r["rank"]):
                print(f"      {r['donor']:<32} into {r['term']:<10} "
                      f"risk {r['risk']:.2f}  rank {r['rank']:.2f}"
                      f"{'  flagged' if r['flagged'] else ''}")


def rank_of(donor, bank, scores):
    """Where the donor sits in the review order, 0 first and 1 last.

    Ties share the middle of the block they are in, so a clip that is
    indistinguishable from four others does not get credit for being first.
    """
    risk = lambda i: (scores[i]["duration"]
                      if scores[i]["duration"] == scores[i]["duration"] else -1.0)
    mine = risk(donor)
    above = sum(1 for i in bank if risk(i) > mine)
    tied = sum(1 for i in bank if risk(i) == mine)
    middle = above + (tied - 1) / 2.0
    return middle / max(1, len(bank) - 1)


def cross_term(by_term, donors, seed):
    """Every recording of another term, injected into each bank."""
    rng = random.Random(seed)
    pairs = []
    for term in sorted(by_term):
        pool = [i for other, bank in by_term.items() if other != term
                for i in bank]
        if donors and donors < len(pool):
            pool = rng.sample(pool, donors)
        pairs += [(term, i) for i in sorted(pool)]
    return pairs


def known_bad(clips, by_term):
    """PR 6c's two clips, into the nine folders that have no known bad one."""
    named = ["Vercel/09-brazil.wav", "Tasmeen/06-that'smeanssend.wav"]
    index = {c["name"]: i for i, c in enumerate(clips)}
    pairs = []
    for name in named:
        if name not in index:
            continue
        home = name.split("/")[0]
        for term in sorted(by_term):
            if term != home:
                pairs.append((term, index[name]))
    return pairs


# ---------------------------------------------------------------------- the CLI

def resolve(clips, ee, marks, spec):
    """`Term/g2` to the clips that group holds, in the current grouping."""
    if "/" not in spec:
        return None, f"{spec!r} is not <Term>/<group>, e.g. Vercel/g4"
    term, label = spec.split("/", 1)
    excluded = marked_names(marks)
    bank = [i for i, c in enumerate(clips)
            if c["term"] == term and c["name"] not in excluded]
    if not bank:
        known = sorted({c["term"] for c in clips})
        return None, f"no unmarked clips for {term!r}. Terms: {', '.join(known)}"
    groups = group(bank, ee)
    labels = {f"g{n + 1}": g for n, g in enumerate(groups)}
    if label not in labels:
        return None, (f"{term} has {len(groups)} group(s): "
                      f"{', '.join(sorted(labels))}")
    return [clips[i]["name"] for i in labels[label]], None


def main():
    ap = argparse.ArgumentParser(
        description="Review a term's recordings by ear, in groups. PR 6c.")
    ap.add_argument("--term", action="append",
                    help="only this term; repeatable. Default is every term")
    ap.add_argument("--marks", default="clip-review-marks.json",
                    help="where groups marked not-counted are recorded. This "
                         "file, and never the voice store")
    ap.add_argument("--mark", help="mark <Term>/<group> not counted")
    ap.add_argument("--unmark",
                    help="take a mark back, by the id --mark printed "
                         "or by any clip name the mark covers")
    ap.add_argument("--why", default="", help="a note to store with a --mark")
    ap.add_argument("--concat", metavar="DIR",
                    help="write one wav per group here, so a group is one "
                         "keystroke. Never the archive")
    ap.add_argument("--cache", default=None,
                    help="npz for the recording-to-recording distances")
    ap.add_argument("--veto-cache", default=None,
                    help="npz for reference-matching.py's span distances, "
                         "used by --veto and --clusters")
    ap.add_argument("--veto", action="store_true",
                    help="what the marks do to ReferenceMatch.verdict's own "
                         "rejection counts")
    ap.add_argument("--clusters", action="store_true",
                    help="6b's per-cluster spread on 6c's groups, and PR 6c's "
                         "third verification criterion")
    ap.add_argument("--falsify", action="store_true",
                    help="the accuracy number: inject labelled bad clips and "
                         "measure whether the ranking finds them")
    ap.add_argument("--donors", type=int, default=0,
                    help="--falsify: cap the donors per term. 0 is all of them")
    ap.add_argument("--seed", default="6c-2026-08-10",
                    help="--falsify: the sampling seed, when --donors caps")
    ap.add_argument("--robust", action="store_true",
                    help="6b's statistic: the 90th percentile of the "
                         "leave-one-out distances instead of the maximum")
    args = ap.parse_args()

    clips = load_clips()
    if not clips:
        return 2
    ee = distances(clips, args.cache)
    marks = load_marks(args.marks)

    if args.unmark:
        # Resolved against the marks file, never against a fresh grouping.
        # Marking takes clips out of the bank, so the bank regroups and the
        # `g3` that exists after a mark is not the `g3` that was marked.
        # Matching what was recorded is the only reading that means what the
        # user typed. A clip name works too, for a mark whose label has since
        # been reused.
        keep = [m for m in marks if args.unmark != m.get("id")
                and args.unmark not in m.get("clips", [])]
        if len(keep) == len(marks):
            print(f"✗ nothing marked as {args.unmark!r}.", file=sys.stderr)
            print(f"  marked: {', '.join(m.get('id', '?') for m in marks) or 'nothing'}",
                  file=sys.stderr)
            return 2
        gone = sum(len(m.get("clips", [])) for m in marks if m not in keep)
        marks = keep
        save_marks(args.marks, marks)
        print(f"unmarked {gone} clip(s); they count again")
        effect(clips, ee, marks, sorted({c["term"] for c in clips}),
               args.veto_cache, args.robust)
        return 0

    if args.mark:
        spec = args.mark
        names, error = resolve(clips, ee, marks, spec)
        if error:
            print(f"✗ {error}", file=sys.stderr)
            return 2
        # A label is a position in the current grouping, and the grouping moves
        # every time something is marked. So the same label can name two
        # different groups over a session; the id keeps them apart, and it is
        # what `--unmark` takes.
        taken = {m.get("id") for m in marks}
        mark_id = spec
        n = 1
        while mark_id in taken:
            n += 1
            mark_id = f"{spec}#{n}"
        marks.append({"id": mark_id, "group": spec, "clips": sorted(names),
                      "why": args.why,
                      "at": datetime.datetime.now().isoformat(timespec="seconds")})
        print(f"marked {len(names)} clip(s) not counted, in {args.marks}")
        print(f"undo with: scripts/clip-review.py --unmark {mark_id}")
        term = spec.split("/")[0]
        left = sum(1 for c in clips if c["term"] == term
                   and c["name"] not in marked_names(marks))
        if left < FLOOR:
            # 6e measured this: under five recordings a bank throws away over
            # half the term's own correct spans too often to be allowed to
            # decide. Marking is the fastest way to walk a bank off that edge,
            # so say it at the moment it happens rather than in a table later.
            print(f"⚠ {term} is down to {left} counted clip(s). 6e puts the "
                  f"abstain floor at {FLOOR}, so this term will stop deciding.")
        save_marks(args.marks, marks)
        print("Nothing was deleted. The wavs are where they were.")
        print(f"In production this file is `voice/excluded.json` beside "
              f"`observations.jsonl`, read by whatever builds a bank.")
        effect(clips, ee, marks, sorted({c["term"] for c in clips}),
               args.veto_cache, args.robust)
        return 0

    terms = sorted({c["term"] for c in clips})
    if args.term:
        wanted = set(args.term)
        missing = wanted - set(terms)
        if missing:
            print(f"✗ no clips for {', '.join(sorted(missing))}. "
                  f"Terms: {', '.join(terms)}", file=sys.stderr)
            return 2
        terms = [t for t in terms if t in wanted]

    if args.falsify:
        falsify(clips, ee, args.donors, args.seed)
        return 0
    if args.clusters:
        per_cluster_veto(clips, ee, args.veto_cache, args.robust)
        return 0

    report(clips, ee, terms, marks, args.concat, args.robust)
    if marks or args.veto:
        effect(clips, ee, marks, terms, args.veto_cache, args.robust)
    return 0


if __name__ == "__main__":
    sys.exit(main())
