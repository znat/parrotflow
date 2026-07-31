#!/usr/bin/env bash
# Scores the grammar prompt against tests/grammar-cases.yaml.
#
# Counts the two failures separately, because they are not the same problem.
# Leaving an error in is a miss. Changing something that was already fine is a
# rewrite, and that is the one this prompt exists to prevent — it costs you
# your own wording, silently.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

INSTRUCTION="${1:-fix the grammar and punctuation}"

pass=0; total=0; missed=0; rewrote=0
started=$(date +%s)

while IFS='|' read -r input want; do
  [ -z "$input" ] && continue
  total=$((total + 1))
  got="$("$BIN" --prompt grammar "$INSTRUCTION" "$input" --quiet 2>/dev/null | tail -1)"

  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    printf '  ✓ %s\n' "$input"
  else
    if [ "$input" = "$want" ]; then
      rewrote=$((rewrote + 1)); mark="rewrote something correct"
    else
      missed=$((missed + 1)); mark="not the minimal fix"
    fi
    printf '  ✗ %s\n      got  %s\n      want %s\n      (%s)\n' "$input" "$got" "$want" "$mark"
  fi
done < <(python3 -c '
import sys, yaml
for case in yaml.safe_load(open(sys.argv[1]))["cases"]:
    print(str(case["input"]) + "|" + str(case["expect"]))
' "$ROOT/tests/grammar-cases.yaml")

elapsed=$(( $(date +%s) - started ))
echo
printf '  %d/%d in %ds\n' "$pass" "$total" "$elapsed"
[ "$missed"  -gt 0 ] && printf '    %d not the minimal fix\n' "$missed"
[ "$rewrote" -gt 0 ] && printf '    %d rewrote something correct  ← the one that loses your voice\n' "$rewrote"
[ "$pass" = "$total" ]
