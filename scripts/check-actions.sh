#!/usr/bin/env bash
# Scores the on-screen action decider against a saved window.
#
#   scripts/check-actions.sh <snapshot.json> [cases file]
#
# Every case is a real call to the decider, which sends that window's contents
# to whatever `actions.decider.endpoint` names. One call at a time, about
# 0.7 s each.
#
# The snapshot is yours to supply — see the header of tests/act-cases.txt and
# docs/actions.md. Without the one the numbers in that file came from, this
# scores your window against your own answers, which is the point.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || BIN="$ROOT/.build/debug/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build"; exit 1; }

SNAP="${1:-}"
CASES="${2:-$ROOT/tests/act-cases.txt}"
[ -f "$SNAP" ] || { echo "usage: $0 <snapshot.json> [cases file]"; exit 1; }
[ -f "$CASES" ] || { echo "no cases file at $CASES"; exit 1; }

pass=0; total=0; wrongAction=0; wrongTarget=0
while IFS='|' read -r utterance wantAction wantTarget; do
  case "$utterance" in ''|'#'*) continue ;; esac
  total=$((total + 1))
  line="$("$BIN" --act "$utterance" --snapshot "$SNAP" 2>/dev/null | grep '^decided')"
  gotAction="$(printf '%s' "$line" | awk '{print $2}')"
  gotTarget="$(printf '%s' "$line" | awk -F'target ' '{print $2}' | awk '{print $1}')"

  if [ "$gotAction" = "$wantAction" ] && [ "$gotTarget" = "$wantTarget" ]; then
    pass=$((pass + 1))
    printf '  ✓ %-38s %s %s\n' "$utterance" "$gotAction" "$gotTarget"
  elif [ "$gotAction" != "$wantAction" ]; then
    wrongAction=$((wrongAction + 1))
    printf '  ✗ %-38s action %s, want %s\n' "$utterance" "${gotAction:-none at all}" "$wantAction"
  else
    wrongTarget=$((wrongTarget + 1))
    printf '  ✗ %-38s %s on %s, want %s\n' "$utterance" "$gotAction" "$gotTarget" "$wantTarget"
  fi
done < "$CASES"

echo
echo "  $pass/$total — $wrongAction wrong action, $wrongTarget wrong target"
# A wrong action does something else entirely; a wrong target does the right
# thing to the wrong thing. The second is the one that sends a message to the
# wrong person, so neither is allowed to pass quietly.
[ "$pass" = "$total" ]
