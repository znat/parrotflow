#!/usr/bin/env bash
# Scores the sentence join against tests/sentence-boundary-cases.json.
#
#   scripts/check-sentence-join.sh
#
# Half the cases are real sentence endings and half are pauses that cut one
# sentence in two, in both the period and the question-mark shape. Two numbers
# decide per shape: how many cuts were repaired, and how many real endings were
# joined by mistake. A joined real ending is a sentence nobody wrote, with
# nothing on screen to say so, so one of those fails the run.
#
# Each case also carries the readings measured when the set was built. This
# compares the binary's against them. That is what says the app reads a boundary
# the same way the measurement did; without it the counts describe some other
# pipeline.
#
# Not in `make test` and not in CI: it needs the 320 MB model, which CI has no
# business downloading. Run it by hand after touching `SentenceJoin`. Nothing is
# downloaded here either — with no cached model every case comes back untouched
# and the run says so.
#
# Runs against a scratch PARROTFLOW_CONFIG_DIR, so the marks are the shipped
# defaults rather than whatever this machine is tuned to.
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
# the window the app builds. Glued back into one text with the case's own mark,
# the boundary the app finds is the one the set is about.
def mark_of(case):
    return case.get("mark", ".")


def text_of(case):
    return case["left"].rstrip(".?!") + mark_of(case) + " " + case["right"]


# The boundary this case is about, not the first one printed. Several of the
# left halves carry a period of their own, so the app finds two or three
# boundaries in the glued text and only one of them is the measured one. It is
# named by the word each side of it.
def block_of(out, case):
    wanted = "%s%s %s ->" % (
        case["left"].rstrip(".?!").split()[-1], mark_of(case), case["right"].split()[0])
    block, mine = None, None
    for line in out.splitlines():
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        if parts[0] == "boundary":
            block = {"boundary": parts[1].strip(), "mean": {}}
            mine = block if parts[1].strip().startswith(wanted) else None
        elif block is None:
            continue
        elif parts[0] == "reading":
            key, mean, _ = parts[1].split()
            block["mean"][key] = float(mean)
        elif parts[0] == "winner":
            block["winner"] = parts[1].strip()
            if mine is not None:
                return mine
    return None

DRIFT = 0.05
tally = {name: {} for name in
         ("en_real.json", "en_cuts.json", "enq_real.json", "enq_cuts_hard.json")}
drifted = []

for case in cases:
    out = subprocess.run(
        [binary, "--sentence-join", text_of(case)],
        capture_output=True, text=True,
    ).stdout
    block = block_of(out, case)
    if not block:
        print("  ✗ the measured boundary was not found in: " + text_of(case))
        sys.exit(1)
    winner = block["winner"]
    counts = tally[case["set"]]
    counts[winner] = counts.get(winner, 0) + 1
    gap = max(abs(block["mean"].get(k, 0) - v) for k, v in case["mean"].items())
    mark = " "
    if gap > DRIFT:
        drifted.append((text_of(case), case["winner"], winner, gap))
        mark = "✗"
    print("  %s  %-10s %-5s stored %-5s  gap %.4f  %s" % (
        mark, case["set"].removeprefix("en").removeprefix("_").removesuffix(".json"),
        winner, case["winner"], gap, case["left"][:44]))

def row(name, key):
    counts = tally[key]
    total = sum(counts.values())
    listed = ", ".join("%d %s" % (n, k) for k, n in sorted(counts.items()))
    print("  %-16s %s  (of %d)" % (name, listed, total))
    return counts, total

print()
shapes = (
    ("period", "en_cuts.json", "en_real.json"),
    ("question", "enq_cuts_hard.json", "enq_real.json"),
)
false_joins = 0
for shape, cut_key, real_key in shapes:
    cuts, cut_total = row(shape + " cuts", cut_key)
    real, real_total = row(shape + " real", real_key)
    if not cut_total or not real_total:
        print("  ✗ no %s cases read from tests/sentence-boundary-cases.json" % shape)
        sys.exit(1)
    wrong = real.get("join", 0)
    false_joins += wrong
    print("  %d%% of %s cuts repaired, %.1f false joins per 100 real endings" % (
        round(100 * cuts.get("join", 0) / cut_total), shape,
        100 * wrong / real_total))
    print()

if drifted:
    print()
    print("  ✗ %d case(s) read differently from the stored measurement:" % len(drifted))
    for text, want, got, gap in drifted:
        print("      stored %-5s got %-5s gap %.4f   %s" % (want, got, gap, text))

sys.exit(1 if drifted or false_joins else 0)
PY
