#!/usr/bin/env bash
# Scores how a refused glued span is written back, against
# tests/lowercase-refused-cases.json.
#
#   scripts/check-lowercase-refused.sh
#
# `Better Stack` glues to the term `BetterStack`, so the rule writes the term
# everywhere. When the sentence refuses that place, putting back what the
# decoder wrote puts back its capitals too — and the decoder wrote them because
# it thought it was writing a name. `VocabularyJudge.lowercased` is the half
# that decides, and `AS HEARD` is the half that keeps a real name safe.
#
# No model. `NLTagger` and the vocabulary answer this, so it runs in CI and on
# a machine that has never dictated.
#
# A case may name `terms`, which is the vocabulary the span is asked against.
# A word the vocabulary already knows refuses the whole span.
#
# **This scores the rewrite, not the stage.** The rule only fires where a
# sentence test refused a place, and both of those read a model, so no
# deterministic run can reach it — `make test` must not need a download. The
# stage end to end is two fixtures and a by-hand run, the way
# scripts/check-portrait.sh is:
#
#   W=$(mktemp -d) && cp tests/fixtures/vocabulary-uses-portrait.yaml \
#     "$W/vocabulary-uses.yaml"
#   PARROTFLOW_CONFIG_DIR=$W .build/release/ParrotFlow --warm --quiet \
#     --pipeline tests/pipelines/vocabulary-lowercase.yaml \
#     "We have now we now have a much Better Stack than before we migrated
#      to the Better Stack platform."
#
# writes `a much better stack`, and vocabulary-lowercase-off.yaml, which is the
# same fixture with `lowercase_refused: false`, writes `a much Better Stack`.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

WORK="$(mktemp -d -t parrotflow-lowercase-refused)"
trap 'rm -rf "$WORK"' EXIT
export PARROTFLOW_CONFIG_DIR="$WORK"

# Five lines per case, so a case holding a quote or an apostrophe arrives whole.
if ! python3 -c '
import json, sys
for case in json.load(open(sys.argv[1])):
    print(case["span"])
    print(case["text"])
    print(case["want"])
    print(case.get("terms", ""))
    print(case["why"])
' "$ROOT/tests/lowercase-refused-cases.json" > "$WORK/cases"; then
  echo "  ✗ tests/lowercase-refused-cases.json could not be read"
  exit 1
fi

pass=0; total=0
while IFS= read -r span && IFS= read -r text && IFS= read -r want \
   && IFS= read -r terms && IFS= read -r why; do
  total=$((total + 1))
  if [ -n "$terms" ]; then
    got="$("$BIN" --lowercase-refused "$span" "$text" --terms "$terms" 2>/dev/null)"
  else
    got="$("$BIN" --lowercase-refused "$span" "$text" 2>/dev/null)"
  fi
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    printf '  ✓  %-16s %s\n' "$got" "$why"
  else
    printf '  ✗  %-16s want %s — %s\n' "${got:-<nothing>}" "$want" "$why"
  fi
done < "$WORK/cases"

printf '\n%d/%d\n' "$pass" "$total"
[ "$pass" -eq "$total" ]
