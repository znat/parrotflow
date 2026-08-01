#!/usr/bin/env bash
# Scores the spoken-number pass against tests/numbers-cases.yaml.
#
#   scripts/check-numbers.sh          # both languages
#   scripts/check-numbers.sh fr       # one of them
#
# No model and no network: this is `Numbers` and a `NumberGrammar`, so the whole
# set runs in well under a second. That is the argument for the deterministic
# path as much as the score is.
#
# The two failures are counted apart. Leaving a number as words is a miss you
# can see and fix by saying it again. Writing digits into a sentence that was
# already right is the one that costs you text, because it runs on every
# transcript and nothing shows you it happened.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

ONLY="${1:-}"
pass=0; total=0; missed=0; wrong=0; touched=0
# Plain counters, not an associative array: macOS ships bash 3.2, which has none.
frpass=0; frtotal=0; enpass=0; entotal=0; autopass=0; autototal=0

while IFS='|' read -r lang input expect; do
  [ -z "$lang" ] && continue
  [ -n "$ONLY" ] && [ "$lang" != "$ONLY" ] && continue
  total=$((total + 1))
  case "$lang" in fr) frtotal=$((frtotal + 1)) ;; en) entotal=$((entotal + 1)) ;; *) autototal=$((autototal + 1)) ;; esac
  [ "$expect" = "unchanged" ] && want="$input" || want="$expect"

  # `auto` exercises what the app actually does: detect, then fall through the
  # rest of the configured languages. Anything else pins one grammar, which is
  # how a two-word case gets scored at all.
  if [ "$lang" = auto ]; then
    got="$("$BIN" --numbers "$input" --quiet 2>/dev/null | tail -1)"
  else
    got="$("$BIN" --numbers "$input" --quiet --lang "$lang" 2>/dev/null | tail -1)"
  fi

  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    case "$lang" in fr) frpass=$((frpass + 1)) ;; en) enpass=$((enpass + 1)) ;; *) autopass=$((autopass + 1)) ;; esac
    printf '  ✓ [%s] %s\n' "$lang" "$input"
  else
    if [ "$expect" = "unchanged" ]; then
      touched=$((touched + 1)); mark="wrote digits into a sentence that was right"
    elif [ "$got" = "$input" ]; then
      missed=$((missed + 1)); mark="left as words"
    else
      wrong=$((wrong + 1)); mark="wrong number"
    fi
    printf '  ✗ [%s] %s\n      got   %s\n      want  %s\n      (%s)\n' \
      "$lang" "$input" "$got" "$want" "$mark"
  fi
done < <(python3 -c '
import sys, yaml
for c in yaml.safe_load(open(sys.argv[1]))["cases"]:
    print("|".join(str(c[k]) for k in ("lang", "input", "expect")))
' "$ROOT/tests/numbers-cases.yaml")

echo
printf '  %d/%d   fr %d/%d   en %d/%d   auto %d/%d\n' \
  "$pass" "$total" "$frpass" "$frtotal" "$enpass" "$entotal" "$autopass" "$autototal"
[ "$missed"  -gt 0 ] && printf '    %d left as words\n' "$missed"
[ "$wrong"   -gt 0 ] && printf '    %d wrong number\n' "$wrong"
[ "$touched" -gt 0 ] && printf '    %d wrote digits into a sentence that was right  ← the costly one\n' "$touched"
[ "$pass" = "$total" ]
