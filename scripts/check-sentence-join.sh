#!/usr/bin/env bash
# Scores the sentence join against tests/sentence-boundary-cases.json.
#
#   scripts/check-sentence-join.sh
#
# Half the cases are real periods and half are pauses that cut one sentence in
# two. Two numbers decide: how many cuts were repaired, and how many real
# periods were joined by mistake. A joined real period is a sentence nobody
# wrote, with nothing on screen to say so, so one of those fails the run.
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
# the window the app builds. Glued back into one text, the boundary the app
# finds is the one the set is about.
def text_of(case):
    return case["left"].rstrip(".") + ". " + case["right"]


# The boundary this case is about, not the first one printed. Several of the
# left halves carry a period of their own, so the app finds two or three
# boundaries in the glued text and only one of them is the measured one. It is
# named by the word each side of it.
def block_of(out, case):
    wanted = "%s. %s ->" % (case["left"].rstrip(".").split()[-1], case["right"].split()[0])
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
tally = {"en_real.json": {}, "en_cuts.json": {}}
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
    print("  %s  %-5s %-5s stored %-5s  gap %.4f  %s" % (
        mark, case["set"].removeprefix("en_").removesuffix(".json"),
        winner, case["winner"], gap, case["left"][:48]))

def row(name, key):
    counts = tally[key]
    total = sum(counts.values())
    listed = ", ".join("%d %s" % (n, k) for k, n in sorted(counts.items()))
    print("  %-13s %s  (of %d)" % (name, listed, total))
    return counts, total

print()
cuts, cut_total = row("cuts", "en_cuts.json")
real, real_total = row("real periods", "en_real.json")

if not cut_total or not real_total:
    print("  ✗ no cases read from tests/sentence-boundary-cases.json")
    sys.exit(1)

joined = cuts.get("join", 0)
false_joins = real.get("join", 0)
print()
print("  %d%% of cuts repaired, %.1f false joins per 100 real periods" % (
    round(100 * joined / cut_total), 100 * false_joins / real_total))

if drifted:
    print()
    print("  ✗ %d case(s) read differently from the stored measurement:" % len(drifted))
    for text, want, got, gap in drifted:
        print("      stored %-5s got %-5s gap %.4f   %s" % (want, got, gap, text))

sys.exit(1 if drifted or false_joins else 0)
PY
