#!/usr/bin/env bash
# Scores where an instruction begins inside a dictation, against
# tests/split-cases.txt.
#
#   scripts/check-split.sh
#
# Not to be confused with scripts/check-inplace.sh, which is about writing into
# a field that refuses accessibility writes. This one is about a sentence that
# carries its own instruction:
#
#   "there is a bug in get username by the way parrot format the function"
#
# Deterministic: no model is consulted to find the split, only to act on it,
# and acting on it is scored by tests/routing-cases.yaml.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

pass=0; total=0; failed=""
while IFS='~' read -r phrases input wantText wantInstruction; do
  case "$phrases" in \#*) continue;; esac
  [ -z "$input" ] && continue
  total=$((total + 1))

  out="$("$BIN" --command "$input" --phrases "$phrases" 2>/dev/null)"
  gotText="$(printf '%s' "$out" | sed -n 's/^text:        "\(.*\)"$/\1/p')"
  gotInstruction="$(printf '%s' "$out" | sed -n 's/^instruction: "\(.*\)"$/\1/p')"
  if [ -z "$gotText" ]; then
    got="NONE~"
  else
    got="$gotText~$gotInstruction"
  fi

  if [ "$got" = "$wantText~$wantInstruction" ]; then
    pass=$((pass + 1))
    printf '  ✓ %s\n' "$input"
  else
    failed="$failed
      $input"
    printf '  ✗ %s\n      got   %s\n      want  %s\n' \
      "$input" "$got" "$wantText~$wantInstruction"
  fi
done < "$ROOT/tests/split-cases.txt"

echo
echo "  $pass/$total$failed"
[ "$pass" = "$total" ]
