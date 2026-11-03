#!/usr/bin/env bash
# Scores the replacement passes against tests/replacement-cases.txt.
#
# Through a fixture rather than your config. The set used to read whichever
# names happened to be configured — its own header said so — and scored 8/20 on
# an empty table, which is a number about the machine and not about the passes.
# tests/pipelines/replacements.yaml carries the four names the cases assume.
#
# The fuzzy half is not deterministic and cannot be made so here. It asks
# NSSpellChecker whether a word is real, and that service intermittently times
# out — a timeout is indistinguishable from "known word", so fuzzy declines and
# a correction is missed. Seen twice as 19/20, each time unreproducible, and
# confirmed by `NSSpellServer findMisspelledWordInString timed out` appearing
# four calls in a row. Re-run before believing a single low score.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

pass=0; total=0; failed=""
while IFS='|' read -r input want; do
  case "$input" in \#*|"") continue;; esac
  total=$((total + 1))
  got="$("$BIN" --pipeline "$ROOT/tests/pipelines/replacements.yaml" "$input" --quiet 2>/dev/null | tail -1)"
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
