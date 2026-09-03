#!/usr/bin/env bash
# Scores the whole route in front of the judge, against tests/judge-cases.yaml.
#
#   scripts/check-slot-gate.sh
#
# Four numbers, and the last two are the ones that decide: how many proposals
# were written without asking, how many were refused without asking, how many
# still cost a judge call, and how many of the first two were wrong.
#
# The judge is a model call of about 900 ms. Every proposal the free lexical
# gate does not settle goes to it today. `SlotGate` settles some of them with a
# masked language model — see that file for the rules and their order.
#
# Not in `make test` and not in CI: it needs the 269 MB slot model, which
# CI has no business downloading. Run it by hand after touching `SlotGate`,
# `Vocabulary.autoApplies` or the tag sets. Nothing is downloaded here either —
# with no cached model every case routes to `judge` and the run says so.
#
# Nine of the 59 cases are not scored, and both exclusions are made by shipped
# code rather than by a list here:
#
#   five are French. `Pipeline.language` says so, and the model is English.
#   four are spelling lessons. `VocabularyJudge.teaching` reverts them with no
#   model, so they are not a routing decision — scripts/check-spells-rule.sh
#   is where that rule is scored.
#
# That leaves the 50 English cases the routing was measured on.
#
# Runs against a scratch PARROTFLOW_CONFIG_DIR, so it says nothing about the
# config on the machine. The language detector needs `languages: [en, fr]`,
# which is what config.example.yaml gives a fresh directory.
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
    print("\x1f".join([str(number)] + [case[k] for k in ("said", "heard", "term", "expect")]))
' "$ROOT/tests/judge-cases.yaml" > "$WORK/cases"; then
  echo "  ✗ tests/judge-cases.yaml could not be read"
  exit 1
fi

applied=0; declined=0; asked=0; skipped=0
wrong_apply=0; wrong_decline=0; total=0

field() { printf '%s\n' "$1" | awk -v k="$2" '$1 == k { print $2 }'; }

while IFS=$'\x1f' read -r number said heard term expect; do
  [ -z "$number" ] && continue

  if [ "$("$BIN" --teaching "$said" "$heard" 2>/dev/null | tail -1)" = REVERT ]; then
    skipped=$((skipped + 1))
    printf '  ·  %-14s %-10s spelling lesson\n' "$heard" "$term"
    continue
  fi

  out="$("$BIN" --word-gate "$heard" "$term" --in "$said" 2>/dev/null)"
  if [ "$(field "$out" language)" != en ]; then
    skipped=$((skipped + 1))
    printf '  ·  %-14s %-10s not english\n' "$heard" "$term"
    continue
  fi

  total=$((total + 1))
  route="$(field "$out" route)"
  slot="$(field "$out" slot)"
  case "$route" in
    apply)   applied=$((applied + 1)) ;;
    decline) declined=$((declined + 1)) ;;
    judge)   asked=$((asked + 1)) ;;
    *)       echo "  ✗ case $number: the binary printed no route"; exit 1 ;;
  esac

  # A route that decided is checked against the label. `judge` is not an
  # answer, so it can be neither right nor wrong here.
  mark=" "
  if [ "$route" = apply ] && [ "$expect" = decline ]; then
    wrong_apply=$((wrong_apply + 1)); mark="✗"
  elif [ "$route" = decline ] && [ "$expect" = approve ]; then
    wrong_decline=$((wrong_decline + 1)); mark="✗"
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
printf '  applied %d   declined %d   judge %d\n' "$applied" "$declined" "$asked"
printf '  wrong applies %d   wrong declines %d\n' "$wrong_apply" "$wrong_decline"

# A wrong apply writes a word nobody said with no menu behind it. A wrong
# decline loses a name the speaker did say. Neither may be traded for fewer
# judge calls, so either one fails the run.
[ "$wrong_apply" -eq 0 ] && [ "$wrong_decline" -eq 0 ]
