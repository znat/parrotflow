#!/usr/bin/env bash
# Scores what the `context` stage would publish for a given screen, against
# tests/context-cases.txt.
#
#   scripts/check-context.sh
#
# Deterministic and offline. The stage has two string steps — cut the input box
# off, keep the tail — and they are the only part of it that has an exact
# answer. The capture itself depends on TCC and on whatever is genuinely in
# front, so it is scored by `--peek` on a real screen and not faked here.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
CASES="$ROOT/tests/context-cases.txt"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

pass=0; total=0; failed=""
while IFS='~' read -r screen limit flag expected; do
  case "$screen" in \#*) continue;; esac
  [ -z "${screen// }" ] && continue
  total=$((total + 1))

  # Trailing spaces are the separator's. A screen that ends in a real space
  # writes it before the tilde and keeps it, which the bare-shell case needs.
  limit="$(printf '%s' "$limit" | tr -d ' ')"
  flag="$(printf '%s' "$flag" | tr -d ' ')"
  screen="$(printf '%s' "$screen" | sed 's/ *$//')"
  expected="$(printf '%s' "$expected" | sed 's/^ *//; s/ *$//')"

  out="$("$BIN" --context-test "$screen" "$limit" 2>/dev/null)"
  gotFlag="$(printf '%s' "$out" | head -1)"
  gotText="$(printf '%s' "$out" | tail -n +2)"
  wantText="$(printf '%b' "${expected//\\n/\\n}")"

  if [ "$gotFlag" = "$flag" ] && [ "$gotText" = "$wantText" ]; then
    pass=$((pass + 1))
  else
    failed="$failed\n  screen: $screen\n  want:   $flag | $(printf '%s' "$wantText" | tr '\n' '|')\n  got:    $gotFlag | $(printf '%s' "$gotText" | tr '\n' '|')\n"
  fi
done < "$CASES"

if [ -n "$failed" ]; then printf '%b' "$failed"; fi
echo
echo "  $pass/$total"
[ "$pass" = "$total" ]
