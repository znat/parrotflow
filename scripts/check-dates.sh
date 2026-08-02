#!/usr/bin/env bash
# Scores the deterministic date rewriter against tests/dates-cases.yaml.
#
#   scripts/check-dates.sh            # DateRewriter — no model, no network
#   scripts/check-dates.sh --model    # the same cases through the free-form
#                                     # prompt, for the comparison that decides
#                                     # whether the code path earns its place
#
# Counts the two failures apart, as the other scripts here do. Leaving a date
# alone costs a second attempt. Rewriting one that was not asked about, or
# printing a field the speaker never said, costs you text — and for a date that
# is the expensive kind of wrong, because a plausible wrong date does not look
# wrong when you read it back.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

MODEL=0
[ "${1:-}" = "--model" ] && MODEL=1

pass=0; total=0; missed=0; wrong=0; touched=0; known=0; fixed=""
started=$(date +%s)

while IFS='|' read -r name instruction input expect limit; do
  [ -z "$name" ] && continue
  total=$((total + 1))
  [ "$expect" = "unchanged" ] && want="$input" || want="$expect"

  if [ "$MODEL" = 1 ]; then
    got="$("$BIN" --prompt anything "$instruction" "$input" --quiet 2>/dev/null | tail -1)"
  else
    # Same reason as check-numbers.sh: the month a date is spelled out in
    # follows the languages this set says it assumes, not the machine's.
    got="$("$BIN" --dates "$instruction" "$input" --quiet --lang en,fr 2>/dev/null | tail -1)"
  fi

  # A case marked `known:` documents a limit rather than asserting a fix. It
  # does not fail the run — a set that is red on purpose teaches nobody to read
  # it — but it does fail if it starts passing, because a limit that has gone
  # away should be noticed rather than quietly kept as an excuse.
  if [ -n "$limit" ]; then
    if [ "$got" = "$want" ]; then
      printf '  ✗ %s\n      this now works — drop the `known:` line\n' "$name"
      fixed="$fixed $name"
    else
      known=$((known + 1))
      printf '  ⚠ %s\n      known limit: %s\n' "$name" "$limit"
    fi
    continue
  fi

  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    printf '  ✓ %s\n' "$name"
  else
    if [ "$expect" = "unchanged" ]; then
      touched=$((touched + 1)); mark="edited text that was not its business"
    elif [ "$got" = "$input" ]; then
      missed=$((missed + 1)); mark="left it alone"
    else
      wrong=$((wrong + 1)); mark="wrong date"
    fi
    printf '  ✗ %s\n      say   %s\n      in    %s\n      got   %s\n      want  %s\n      (%s)\n' \
      "$name" "$instruction" "$input" "$got" "$want" "$mark"
  fi
done < <(python3 -c '
import sys, yaml
for c in yaml.safe_load(open(sys.argv[1]))["cases"]:
    print("|".join(str(c[k]) for k in ("name", "instruction", "input", "expect"))
          + "|" + str(c.get("known", "")))
' "$ROOT/tests/dates-cases.yaml")

elapsed=$(( $(date +%s) - started ))
echo
[ "$known" -gt 0 ] && total=$((total - known))
printf '  %d/%d in %ds  (%s)\n' "$pass" "$total" "$elapsed" \
  "$([ "$MODEL" = 1 ] && echo "the model, via --prompt anything" || echo "DateRewriter, no model")"
[ "$missed"  -gt 0 ] && printf '    %d left alone\n' "$missed"
[ "$wrong"   -gt 0 ] && printf '    %d wrong date\n' "$wrong"
[ "$touched" -gt 0 ] && printf '    %d edited text that was not its business  ← the one that costs you text\n' "$touched"
[ "$known" -gt 0 ] && printf '    %d known limit(s), not counted\n' "$known"
[ -n "$fixed" ] && printf '    a known limit now passes:%s\n' "$fixed"
[ "$pass" = "$total" ] && [ -z "$fixed" ]
