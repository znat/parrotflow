#!/usr/bin/env bash
# A capital with no mark in front of it: is it a name, or a pause?
#
#   scripts/check-bare-capital.sh
#
# The readings the boundary gets here are the period, the text as decoded, and
# the join. The comma is not among them: nothing is written unless `join` wins,
# so a comma win is a veto rather than a decision. The cases below are the ones
# that veto used to swallow — mined from real dictation and labelled by hand.
#
# Not in `make test`: it needs the 320 MB sentence model. Run it after touching
# SentenceReadings or the bare half of SentenceJoin.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN=""
for candidate in "$ROOT/.build/release/ParrotFlow" "$ROOT/.build/debug/ParrotFlow"; do
  [ -x "$candidate" ] || continue
  if [ -z "$BIN" ] || [ "$candidate" -nt "$BIN" ]; then BIN="$candidate"; fi
done
[ -n "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

CASES="$ROOT/tests/bare-capital-cases.json"
WORK="$(mktemp -d -t parrotflow-bare-capital)"
trap 'rm -rf "$WORK"' EXIT

# The bench reads left, right and mark and ignores the rest, so the labels
# travel in the same file as the cases they label.
"$BIN" --sentence-probe --bench "$CASES" --out "$WORK/out.json" >/dev/null 2>&1 \
  || { echo "  ✗ the bench did not run"; exit 1; }

python3 - "$CASES" "$WORK/out.json" <<'PY'
import json, sys
cases = json.load(open(sys.argv[1]))
out = json.load(open(sys.argv[2]))
rows = out if isinstance(out, list) else out.get("results", [])
if len(rows) != len(cases):
    print(f"  ✗ {len(rows)} results for {len(cases)} cases"); sys.exit(1)
ok = bad = cost = 0
for case, row in zip(cases, rows):
    joined = row["winner"] == "join"
    right = joined == (case["want"] == "lower")
    got = "lower" if joined else "keep"
    if case.get("cost"):
        # The measured price of dropping the comma, not a regression. Printed
        # so it stays visible, and it fails the run only if it stops being a
        # price — a case that starts passing is a better rule, not a broken one.
        cost += 1
        print(f"  ·  {case['word']:12} want {case['want']:5} got {got:5} — {case['why']}")
        continue
    ok, bad = ok + right, bad + (not right)
    if not right:
        print(f"  ✗  {case['word']:12} want {case['want']:5} got {got:5} — {case['why']}")
print()
print(f"  {ok}/{len(cases) - cost}  and {cost} known costs  (tests/bare-capital-cases.json)")
sys.exit(0 if bad == 0 else 1)
PY
