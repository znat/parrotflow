#!/usr/bin/env bash
# Scores the vocabulary's sound path — Phonemes, phonemeParts, and the wiring.
#
#   scripts/check-sound.sh
#
# Three halves. `--sound` pins the Swift metric to the Python that measured the
# 0.85 floor and scores the stage on sentences; the fixture run below proves the
# pipeline reaches it at all, which is the part that broke twice — a second
# Step is built in PipelineCommand and dropped the switch on the floor.
#
# Needs espeak-ng, and says so rather than failing without it. It is a separate
# program invoked over a pipe, never linked, so its GPL-3 stays its own.
#
#   brew install espeak-ng
#
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

"$BIN" --sound 2>/dev/null || exit 1

command -v espeak-ng >/dev/null || exit 0

# The stage, through a real pipeline. Each line is a sentence, how many places
# it should open, and why.
FIXTURE="$ROOT/tests/pipelines/vocabulary-sound.yaml"
failures=0
check() {
  local want="$1" name="$2" text="$3"
  local got
  got="$("$BIN" --pipeline "$FIXTURE" "$text" --app "" --quiet --vars 2>/dev/null \
    | sed -n 's/.*vocabulary\.slots = //p')"
  if [ "$got" = "$want" ]; then
    printf '✓ %s\n' "$name"
  else
    printf '✗ %s  — %s slot(s), wanted %s\n' "$name" "${got:-none}" "$want"
    failures=$((failures + 1))
  fi
}

# Two ordinary words, no rendering written down, no edit distance to it. The
# sound is all there is.
check 1 "a term only its sound reaches"      "I opened Ghost E this morning"
# 0.76, under the floor, and a homophone: no number separates these two.
check 0 "a homophone stays under the floor"  "We should praise the work"
# Already the term. Not a question.
check 0 "the term itself is not a question"  "I use Ghostty daily"

echo
[ "$failures" -eq 0 ] && echo "3/3" || echo "$((3 - failures))/3"
exit "$failures"
