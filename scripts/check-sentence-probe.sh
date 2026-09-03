#!/usr/bin/env bash
# Compares the Swift readings against the stored ones, case by case.
#
#   scripts/check-sentence-probe.sh [tolerance]
#
# tests/sentence-boundary-cases.json holds 40 boundaries from a scored set of
# the user's own dictation, half real periods and half pauses that cut one
# sentence in two, with the per-token score of every reading and the winner.
# This answers "does this build still read a boundary the same way": the window,
# the three continuations, the padded batch, the log-softmax and the argmax.
# Regenerate it with scripts/sentence-probe-reference.py readings.
#
# One loaded process for all 40, through `--sentence-probe --bench`. A process
# per case would pay the 1.3s model load forty times.
#
# Not in `make test`: it needs the 320 MB model, which CI has no business
# downloading. Run it by hand after touching SentenceReadings.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

TOLERANCE="${1:-0.05}"
WORK="$(mktemp -d -t parrotflow-sentence-probe)"
trap 'rm -rf "$WORK"' EXIT
# The shipped marks, not whatever this machine is tuned to.
export PARROTFLOW_CONFIG_DIR="$WORK/config"

python3 -c '
import json, sys
cases = json.load(open(sys.argv[1]))
json.dump([{"left": c["left"], "right": c["right"]} for c in cases], open(sys.argv[2], "w"))
' "$ROOT/tests/sentence-boundary-cases.json" "$WORK/cases.json" || {
  echo "  ✗ tests/sentence-boundary-cases.json could not be read"; exit 1; }

"$BIN" --sentence-probe --bench "$WORK/cases.json" --out "$WORK/scored.json" \
  || { echo "  ✗ the binary could not score the cases"; exit 1; }

exec python3 - "$ROOT" "$WORK/scored.json" "$TOLERANCE" <<'PY'
import json, sys
from pathlib import Path

root, scored, tolerance = Path(sys.argv[1]), sys.argv[2], float(sys.argv[3])
cases = json.load(open(root / "tests/sentence-boundary-cases.json"))
got = {row["i"]: row for row in json.load(open(scored))}

passed, worst, worst_case = 0, 0.0, ""
for i, case in enumerate(cases):
    row = got.get(i)
    if row is None:
        print("  ✗ not scored: " + case["left"])
        continue
    gap = max(abs(row["mean"][k] - v) for k, v in case["mean"].items())
    if gap > worst:
        worst, worst_case = gap, case["left"]
    if gap <= tolerance and row["winner"] == case["winner"]:
        passed += 1
    else:
        print("  ✗ %s. %s" % (case["left"].rstrip("."), case["right"].split()[0]))
        print("      winner %s, stored %s   gap %.4f" % (
            row["winner"], case["winner"], gap))

print()
print("  %d/%d within %s  (tests/sentence-boundary-cases.json)" % (
    passed, len(cases), tolerance))
print("  worst gap %.4f  %s" % (worst, worst_case))
sys.exit(0 if passed == len(cases) else 1)
PY
