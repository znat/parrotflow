#!/usr/bin/env bash
# Scores the replacement passes against tests/replacement-cases.txt.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

pass=0; total=0; failed=""
while IFS='|' read -r input want; do
  case "$input" in \#*|"") continue;; esac
  total=$((total + 1))
  got="$("$BIN" --replace "$input" 2>/dev/null)"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$input"
  else
    printf '  ✗ %s\n      got  %s\n      want %s\n' "$input" "$got" "$want"
    failed="$failed
      $input"
  fi
done < "$ROOT/tests/replacement-cases.txt"
echo
# The failing cases go on the summary too, not only above it. Twice this set
# has come back 19/20 and refused to do it again, and both times the run had
# been read through `tail` — so the score survived and the case that produced
# it did not. An intermittent failure you cannot name is one you cannot fix.
echo "  $pass/$total$failed"
[ "$pass" = "$total" ]
