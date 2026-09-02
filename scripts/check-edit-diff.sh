#!/usr/bin/env bash
# One word changed by hand, told apart from a rewrite.
#
#   scripts/check-edit-diff.sh
#
# `EditWatch.change` decides whether a field that no longer says what was
# dictated holds a correction worth learning from. A rewrite read as a
# correction teaches a vocabulary term the wrong sentence, and that sentence
# then decides other dictations — so the strict half of this is the half that
# matters. No accessibility, no timing, no model.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN=""
for candidate in "$ROOT/.build/release/ParrotFlow" "$ROOT/.build/debug/ParrotFlow"; do
  [ -x "$candidate" ] || continue
  if [ -z "$BIN" ] || [ "$candidate" -nt "$BIN" ]; then BIN="$candidate"; fi
done
[ -n "$BIN" ] || { echo "build first: swift build"; exit 1; }

failed=0
seen=0
while IFS=$'\t' read -r written now want; do
  seen=$((seen + 1))
  got="$("$BIN" --edit-diff "$written" "$now" 2>/dev/null | grep -vE "^  in: " \
    | paste -sd '|' - | sed 's/|/ | /g')"
  [ "$want" = "none" ] && want="no single change"
  if [ "$got" = "$want" ]; then
    printf '  ✓ %s\n' "$got"
  else
    printf '  ✗ %s: got "%s", expected "%s"\n' "${written:0:34}" "$got" "$want"
    failed=1
  fi
done < <(python3 -c '
import sys, yaml
for c in yaml.safe_load(open(sys.argv[1]))["cases"]:
    print("\t".join([c["written"], c["now"], str(c["expect"])]))
' "$ROOT/tests/edit-diff-cases.yaml")

if [ "$seen" -eq 0 ]; then echo "Failed: edit-diff — no case was read"; exit 1; fi
[ "$failed" -eq 0 ] && echo "Every check passed." || echo "Failed: edit-diff"
exit "$failed"
