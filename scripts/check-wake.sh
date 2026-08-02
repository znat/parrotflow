#!/usr/bin/env bash
# Scores wake-phrase splitting against tests/wake-cases.txt.
#
#   scripts/check-wake.sh
#
# What is measured is only where the phrase ends and the instruction begins —
# not what the instruction then resolves to, which needs a model and has
# tests/routing-cases.yaml. This half is deterministic and runs anywhere.
#
# Each case states its own phrases, passed with --phrases, so the set reads the
# same on any machine.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

pass=0; total=0; known=0; failed=""
while IFS='|' read -r phrases input want; do
  case "$phrases" in \#*) continue;; esac
  [ -z "$input" ] && continue

  out="$("$BIN" --command "$input" --phrases "$phrases" 2>/dev/null)"
  if printf '%s' "$out" | grep -q "not a command"; then
    got="NONE"
  else
    got="$(printf '%s' "$out" | sed -n 's/^command:     "\(.*\)"$/\1/p')"
    [ -z "$got" ] && got="EMPTY"
  fi

  # KNOWN: the right answer, not yet given. Counted apart so the number means
  # "what works", and so a fix announces itself instead of sitting unnoticed.
  case "$want" in
    KNOWN:*)
      known=$((known + 1))
      [ "$got" = "${want#KNOWN:}" ] \
        && printf '  ! %s\n      now passes — drop the KNOWN: marker\n' "$input"
      continue;;
  esac

  total=$((total + 1))
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    printf '  ✓ %-52s [%s]\n' "$input" "${phrases:-no phrases}"
  else
    failed="$failed
      $input"
    printf '  ✗ %s  [%s]\n      got   %s\n      want  %s\n' \
      "$input" "${phrases:-no phrases}" "$got" "$want"
  fi
done < "$ROOT/tests/wake-cases.txt"

echo
echo "  $pass/$total   plus $known known-unfixed$failed"
[ "$pass" = "$total" ]
