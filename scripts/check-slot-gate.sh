#!/usr/bin/env bash
# Scores the route the vocabulary pass takes, against tests/judge-cases.yaml.
#
#   scripts/check-slot-gate.sh
#
# Four numbers, and the last two are the ones that decide: how many proposals
# were written without asking, how many were refused without asking, how many
# were left open, and how many of the first two were wrong.
#
# A place nobody settles keeps whatever is already in the text, so an open
# route is a decision by default and not a question asked of anything. `SlotGate` settles some of them with a
# masked language model — see that file for the rules and their order.
#
# Not in `make test` and not in CI: it needs the 269 MB slot model, which
# CI has no business downloading. Run it by hand after touching `SlotGate`,
# `Vocabulary.autoApplies` or the tag sets. Nothing is downloaded here either —
# with no cached model every case is left open and the run says so.
#
# Four of the 60 cases are not scored. They are spelling lessons:
# `VocabularyPass.teaching` reverts them with no model, so they are not a
# routing decision — scripts/check-spells-rule.sh is where that rule is scored.
#
# Six cases are French. The slot tags its fillers in the language
# `Pipeline.language` reads, as the pass does.
#
# Runs against a scratch PARROTFLOW_CONFIG_DIR, so it says nothing about the
# config on the machine. The language detector needs `languages: [en, fr]`,
# which is what built-in/config.example.yaml gives a fresh directory.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

WORK="$(mktemp -d -t parrotflow-slot-gate)"
trap 'rm -rf "$WORK"' EXIT
export PARROTFLOW_CONFIG_DIR="$WORK"

# Unit separator, not a tab: a case holding a tab would arrive with its fields
# shifted. Read into a file first, so a set that could not be parsed fails here
# rather than ending the loop early with a clean score over half of it.
if ! python3 -c '
import sys, yaml
for number, case in enumerate(yaml.safe_load(open(sys.argv[1]))["cases"], 1):
    print("\x1f".join([str(number)] + [case[k] for k in ("said", "heard", "term", "expect")]
                      + [case.get("route", "")]))
' "$ROOT/tests/judge-cases.yaml" > "$WORK/cases"; then
  echo "  ✗ tests/judge-cases.yaml could not be read"
  exit 1
fi

applied=0; declined=0; asked=0; skipped=0
wrong_apply=0; wrong_decline=0; wrong_route=0; total=0

field() { printf '%s\n' "$1" | awk -v k="$2" '$1 == k { print $2 }'; }

while IFS=$'\x1f' read -r number said heard term expect pinned; do
  [ -z "$number" ] && continue

  if [ "$("$BIN" --teaching "$said" "$heard" 2>/dev/null | tail -1)" = REVERT ]; then
    skipped=$((skipped + 1))
    printf '  ·  %-14s %-10s spelling lesson\n' "$heard" "$term"
    continue
  fi

  out="$("$BIN" --word-gate "$heard" "$term" --in "$said" 2>/dev/null)"

  total=$((total + 1))
  route="$(field "$out" route)"
  slot="$(field "$out" slot)"
  case "$route" in
    apply)   applied=$((applied + 1)) ;;
    decline) declined=$((declined + 1)) ;;
    open)    asked=$((asked + 1)) ;;
    *)       echo "  ✗ case $number: the binary printed no route"; exit 1 ;;
  esac

  # A route that decided is checked against the label. `open` is not an
  # answer, so it can be neither right nor wrong here.
  mark=" "
  if [ "$route" = apply ] && [ "$expect" = decline ]; then
    wrong_apply=$((wrong_apply + 1)); mark="✗"
  elif [ "$route" = decline ] && [ "$expect" = approve ]; then
    wrong_decline=$((wrong_decline + 1)); mark="✗"
  fi
  # A case with `route:` must take that route, open included. Not checked
  # without the model, where every route is open.
  if [ -n "$pinned" ] && [ "$slot" != unavailable ] && [ "$route" != "$pinned" ]; then
    wrong_route=$((wrong_route + 1)); mark="✗"
  fi
  printf '  %s  %-14s %-10s %-12s %-8s want %s\n' \
    "$mark" "$heard" "$term" "$slot" "$route" "$expect"
done < "$WORK/cases"

echo
if [ "$total" -eq 0 ]; then
  echo "  ✗ no cases read from tests/judge-cases.yaml"
  exit 1
fi

printf '  %d scored, %d not (tests/judge-cases.yaml)\n' "$total" "$skipped"
printf '  applied %d   declined %d   open %d\n' "$applied" "$declined" "$asked"
printf '  wrong applies %d   wrong declines %d   wrong pinned routes %d\n' \
  "$wrong_apply" "$wrong_decline" "$wrong_route"

# A wrong apply writes a word nobody said with no menu behind it. A wrong
# decline loses a name the speaker did say. Neither may be traded for fewer
# open places, so either one fails the run.
[ "$wrong_apply" -eq 0 ] && [ "$wrong_decline" -eq 0 ] && [ "$wrong_route" -eq 0 ]
