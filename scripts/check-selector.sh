#!/usr/bin/env bash
# Scores where an open place lands and what an answer writes there, against
# tests/selector-cases.json.
#
#   scripts/check-selector.sh
#
# The pill asks about a place the vocabulary gates could not settle, and the
# words wait for the answer. Two things have to be right for that to be safe.
# The span has to be found again in the text that actually landed — the stages
# after `vocabulary` may rewrite, and a span that is gone must be dropped
# rather than guessed at. And the answers have to go back into the text
# without touching anything between them: a newline, a double space and a
# comma glued to the next word all belong to the person who dictated them.
#
# `OpenPlaces.located` and `OpenPlaces.written` are the two halves, and
# `--selector` is the entry point, so the set runs against the shipped
# functions rather than a copy of them.
#
# No model and no audio. This runs in CI and on a machine that has never
# dictated.
#
# **This scores the write, not the surface.** What the pill draws is
# `--panels selector`, `selector-long` and `selector-two`; the lowercasing of a
# refused glued span is scripts/check-lowercase-refused.sh. Raising the pill
# from a real dictation needs a term the gates leave open, and that is a
# by-hand run — docs/transcription.md says which sentence does it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

WORK="$(mktemp -d -t parrotflow-selector)"
trap 'rm -rf "$WORK"' EXIT
export PARROTFLOW_CONFIG_DIR="$WORK"

# Base64, one line per field, and an empty last field for a case that wants the
# text rather than the ranges.
#
# A case cannot check a trailing newline, and does not need to: the comparison
# below goes through `$(...)`, which strips them, and `print` adds one of its
# own that could not be told apart from the text's. Nothing reaches the selector
# with a newline at either end anyway — `finishTranscription` trims those off
# before it asks. Newlines *inside* the text are what matter here, and those a
# case does check. A case holds newlines and double spaces on
# purpose — those are what it is checking survive — and neither goes through a
# line-per-field file as itself.
if ! python3 -c '
import base64, json, sys
def b(s): return base64.b64encode(s.encode()).decode()
for case in json.load(open(sys.argv[1])):
    print(b(case["text"]))
    print(b("\n".join(case["places"])))
    print(b(case["want"]))
    print(b(case["why"]))
    print(b("--ranges" if case.get("ranges") else ""))
' "$ROOT/tests/selector-cases.json" > "$WORK/cases"; then
  echo "  ✗ tests/selector-cases.json could not be read"
  exit 1
fi

pass=0; total=0
while IFS= read -r text64 && IFS= read -r places64 && IFS= read -r want64 \
   && IFS= read -r why64 && IFS= read -r mode64; do
  total=$((total + 1))
  text="$(printf '%s' "$text64" | base64 -d)"
  want="$(printf '%s' "$want64" | base64 -d)"
  why="$(printf '%s' "$why64" | base64 -d)"
  # The last line of a decoded field has no newline after it, and `read`
  # returns non-zero there — so the trailing newline is added back rather than
  # the loop losing its last place.
  places=()
  while IFS= read -r place; do places+=("$place"); done \
    < <(printf '%s' "$places64" | base64 -d; printf '\n')
  mode="$(printf '%s' "$mode64" | base64 -d)"
  if [ -n "$mode" ]; then
    got="$("$BIN" --selector "$text" "${places[@]}" "$mode" 2>/dev/null)"
  else
    got="$("$BIN" --selector "$text" "${places[@]}" 2>/dev/null)"
  fi
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    printf '  ✓  %s\n' "$why"
  else
    printf '  ✗  %s\n     got  %s\n     want %s\n' "$why" "${got:-<nothing>}" "$want"
  fi
done < "$WORK/cases"

printf '\n%d/%d\n' "$pass" "$total"
[ "$pass" -eq "$total" ]
