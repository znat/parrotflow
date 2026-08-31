#!/usr/bin/env bash
# What the slot says about each rewrite, case by case.
#
#   scripts/check-slot-gap.sh
#
# The vocabulary pass proposes a rewrite from spelling alone. This asks
# ModernBERT what belongs in the slot and measures both readings against the
# answer. Below `SlotReference.floor` the rewrite is refused.
#
# tests/slot-gap-cases.yaml scores the decision, not the number: the gap moves
# with the Core ML conversion of ModernBERT, and every case here sits well clear
# of the line — a refusal below -0.30, a no-opinion above -0.05.
#
# Not in `make test`: it needs the 300 MB sentence model and the 400 MB
# word-vector model, which CI has no business downloading. Run it by hand after
# touching SlotReference or WordVectors.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The newer of the two, not release first. A stale release binary does not know
# the flag, and a flag it does not know used to start the app instead of failing.
BIN=""
for candidate in "$ROOT/.build/release/ParrotFlow" "$ROOT/.build/debug/ParrotFlow"; do
  [ -x "$candidate" ] || continue
  if [ -z "$BIN" ] || [ "$candidate" -nt "$BIN" ]; then BIN="$candidate"; fi
done
[ -n "$BIN" ] || { echo "build first: swift build"; exit 1; }

CASES="$ROOT/tests/slot-gap-cases.yaml"
failed=0
seen=0

while IFS=$'\t' read -r said heard term expect; do
  seen=$((seen + 1))
  out="$("$BIN" --slot-gap "$said" "$heard" "$term" 2>/dev/null | tail -1)"
  gap="$(printf '%s' "$out" | sed -n 's/^gap  *\([+-][0-9.]*\).*/\1/p')"
  got="$(printf '%s' "$out" | sed -n 's/^gap  *[+-][0-9.]*  *\(.*\)$/\1/p')"

  if [ -z "$gap" ]; then
    printf '  ✗ %s -> %s: no gap (%s)\n' "$heard" "$term" "${out:-no output}"
    failed=1
  elif [ "$got" != "$expect" ]; then
    printf '  ✗ %s -> %s: %s at %s, expected %s\n' "$heard" "$term" "$got" "$gap" "$expect"
    failed=1
  else
    printf '  ✓ %-13s -> %-13s %s   %s\n' "$heard" "$term" "$gap" "$got"
  fi
done < <(python3 -c '
import sys, yaml
for c in yaml.safe_load(open(sys.argv[1]))["cases"]:
    print("\t".join([c["said"], c["heard"], c["term"], c["expect"]]))
' "$CASES")

if [ "$seen" -eq 0 ]; then
  echo "Failed: slot-gap — no case was read from $CASES"
  exit 1
fi
[ "$failed" -eq 0 ] && echo "Every check passed." || echo "Failed: slot-gap"
exit "$failed"
