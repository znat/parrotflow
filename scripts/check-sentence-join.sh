#!/usr/bin/env bash
# Scores the two tiers of the sentence join, against
# tests/sentence-boundary-cases.json.
#
#   scripts/check-sentence-join.sh
#
# Half the cases are real periods and half are pauses that cut one sentence in
# two. Three numbers decide: how many cuts were repaired with nothing asked,
# how many real periods were joined by mistake, and how many cuts the offer
# tier would have caught. The false joins are the ones that matter — a silent
# rewrite that is wrong is worse than a stage that does nothing.
#
# Each case also carries the score the probe measured when the set was built.
# This compares the binary's score against it. That is what says the app reads
# a boundary the same way the measurement did; without it the tier counts
# describe some other pipeline.
#
# Needs the 300 MB sentence model. `make test` and CI both fetch it first with
# `--sentence-model`; nothing is downloaded here. With no cached model
# `--sentence-join` prints no boundary block at all, so the first case fails
# on "the measured boundary was not found". No separate guard for that: the
# stored per-case score is one, and a model that never ran cannot match it.
#
# Runs against a scratch PARROTFLOW_CONFIG_DIR, so the thresholds are the
# shipped defaults rather than whatever this machine is tuned to.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -x "$ROOT/.build/release/ParrotFlow" ] || {
  echo "build first: swift build -c release"; exit 1; }

WORK="$(mktemp -d -t parrotflow-sentence-join)"
trap 'rm -rf "$WORK"' EXIT
export PARROTFLOW_CONFIG_DIR="$WORK"

exec python3 - "$ROOT" <<'PY'
import json, subprocess, sys
from pathlib import Path

root = Path(sys.argv[1])
binary = root / ".build/release/ParrotFlow"
cases = json.load(open(root / "tests/sentence-boundary-cases.json"))

# The set stores the two halves already windowed to twelve words each, which is
# what `SentenceProbe.radius` keeps. Glued back into one text, the boundary the
# app finds is the one the set is about.
def text_of(case):
    return case["left"].rstrip(".") + ". " + case["right"]


# The boundary this case is about, not the first one printed. Several of the
# left halves carry a period of their own, so the app finds two or three
# boundaries in the glued text and only one of them is the measured one. It is
# named by the word each side of it.
def reading(out, case):
    wanted = "%s. %s ->" % (case["left"].rstrip(".").split()[-1], case["right"].split()[0])
    block = {}
    for line in out.splitlines():
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        if parts[0] == "boundary":
            block = {"boundary": parts[1].strip()}
        elif block:
            block[parts[0]] = parts[1].strip()
        if block.get("boundary", "").startswith(wanted) and "tier" in block:
            return block
    return {}

DRIFT = 0.05
tally = {"en_real.json": {}, "en_cuts.json": {}}
drifted = []

for case in cases:
    out = subprocess.run(
        [binary, "--sentence-join", text_of(case)],
        capture_output=True, text=True,
    ).stdout
    block = reading(out, case)
    if not block:
        print("  ✗ the measured boundary was not found in: " + text_of(case))
        sys.exit(1)
    tier, score = block["tier"], block["score"]
    counts = tally[case["set"]]
    counts[tier] = counts.get(tier, 0) + 1
    delta = float(score) - case["score"]
    mark = " "
    if abs(delta) > DRIFT:
        drifted.append((text_of(case), case["score"], float(score)))
        mark = "✗"
    print("  %s  %-9s %8.3f  %-5s  stored %8.3f" % (
        mark, case["set"].removeprefix("en_").removesuffix(".json"),
        float(score), tier, case["score"]))

def row(name, key):
    counts = tally[key]
    total = sum(counts.values())
    print("  %-13s %2d joined, %2d offered, %2d left alone  (of %d)" % (
        name, counts.get("join", 0), counts.get("offer", 0),
        counts.get("leave", 0), total))
    return counts, total

print()
cuts, cut_total = row("cuts", "en_cuts.json")
real, real_total = row("real periods", "en_real.json")

if not cut_total or not real_total:
    print("  ✗ no cases read from tests/sentence-boundary-cases.json")
    sys.exit(1)

joined = cuts.get("join", 0)
offered = cuts.get("offer", 0)
false_joins = real.get("join", 0)
print()
print("  join tier      %d%% of cuts repaired, %.1f false joins per 100 real periods" % (
    round(100 * joined / cut_total), 100 * false_joins / real_total))
print("  offer tier     %d%% more cuts caught, %.1f per 100 real periods offered" % (
    round(100 * offered / cut_total), 100 * real.get("offer", 0) / real_total))

if drifted:
    print()
    print("  ✗ %d case(s) scored differently from the stored measurement:" % len(drifted))
    for text, want, got in drifted:
        print("      want %8.3f  got %8.3f   %s" % (want, got, text))

# A joined real period is a sentence nobody wrote, with nothing on screen to
# say so. It fails the run on its own.
sys.exit(1 if drifted or false_joins else 0)
PY
