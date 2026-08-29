#!/usr/bin/env bash
# Scores the auto-apply gate's two word lists against tests/word-gate-cases.yaml.
#
#   scripts/check-word-gate.sh
#
# The question is which words a vocabulary term may overwrite with nothing
# reading the sentence. `Vocabulary.autoApplies` asks two lists and needs both
# to say "unknown": NSSpellChecker, which has no first names in it, and the
# whole-word half of a tokenizer vocabulary, which has no rare compounds in it.
# Either one alone overwrites a whole class of ordinary word.
#
# Both verdicts are checked, not only the decision. A word reaches `judge` from
# either side, so a set that read the decision alone would pass with one half
# broken — `Chloé` in particular, where the accent is the thing under test.
#
# The last block is the fail-open case, and it is the reason the lookup answers
# three things rather than two. With the list missing, `Versal` must stop
# auto-applying. A missing resource that read as "unknown" would put the gate
# back where it was, silently, on every machine where the file did not ship.
#
# NSSpellChecker is a service and it intermittently times out. A timeout is
# indistinguishable from "known word" (see Replacements.isRealWord), so a case
# is asked a second time before it is called failed — see the note at the loop.
# Same hazard as check-replacements.sh, which has no such retry and has twice
# gone red on it.
#
# Runs against a scratch PARROTFLOW_CONFIG_DIR, so it says nothing about the
# config on the machine and scores the same anywhere.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

CONFIG="$(mktemp -d -t parrotflow-word-gate)"
trap 'rm -rf "$CONFIG"' EXIT
export PARROTFLOW_CONFIG_DIR="$CONFIG"

# `<key> <value>` lines, everything the binary logs dropped.
verdicts() {
  "$BIN" --word-gate "$1" 2>/dev/null | awk '$1 ~ /^(spell|wordpiece|gate)$/ { print $1, $2 }'
}

field() { printf '%s\n' "$1" | awk -v k="$2" '$1 == k { print $2 }'; }

pass=0; total=0; overwrote=0

while IFS=$'\t' read -r word spell wordpiece gate; do
  [ -z "$word" ] && continue
  total=$((total + 1))
  # Asked twice when the first answer is wrong, and only then. NSSpellChecker
  # is a service that times out, a timeout is indistinguishable from "known
  # word", and `isRealWord` caches per process — so a second process is a
  # second sample. Seen once while writing this: `Versal` came back `known`
  # under load, then `unknown` ten times in a row. A real regression fails
  # both times; nothing here is retried until it passes.
  out="$(verdicts "$word")"
  got_spell="$(field "$out" spell)"
  got_piece="$(field "$out" wordpiece)"
  got_gate="$(field "$out" gate)"
  if [ "$got_spell" != "$spell" ] || [ "$got_piece" != "$wordpiece" ] \
     || [ "$got_gate" != "$gate" ]; then
    out="$(verdicts "$word")"
    got_spell="$(field "$out" spell)"
    got_piece="$(field "$out" wordpiece)"
    got_gate="$(field "$out" gate)"
  fi

  if [ "$got_spell" = "$spell" ] && [ "$got_piece" = "$wordpiece" ] && [ "$got_gate" = "$gate" ]
  then
    pass=$((pass + 1))
    printf '  ✓ %-12s spell %-11s wordpiece %-11s %s\n' \
      "$word" "$got_spell" "$got_piece" "$got_gate"
    continue
  fi

  # An expected `judge` that came back `auto-apply` is the expensive direction:
  # a word nobody said, written into the transcript, with no menu behind it.
  if [ "$gate" = "judge" ] && [ "$got_gate" = "auto-apply" ]; then
    overwrote=$((overwrote + 1))
  fi
  printf '  ✗ %-12s got   spell %-11s wordpiece %-11s %s\n' \
    "$word" "$got_spell" "$got_piece" "$got_gate"
  printf '    %-12s want  spell %-11s wordpiece %-11s %s\n' \
    "" "$spell" "$wordpiece" "$gate"
done < <(python3 -c '
import sys, yaml
for case in yaml.safe_load(open(sys.argv[1]))["cases"]:
    print("\t".join([case["word"], case["spell"], case["wordpiece"], case["gate"]]))
' "$ROOT/tests/word-gate-cases.yaml")

echo
# A set that read no cases is not a passing run.
if [ "$total" -eq 0 ]; then
  echo "  ✗ no cases read from tests/word-gate-cases.yaml"
  exit 1
fi

printf '  %d/%d  (tests/word-gate-cases.yaml)\n' "$pass" "$total"
[ "$overwrote" -gt 0 ] && printf '    %d would be overwritten unasked  ← the expensive direction\n' "$overwrote"

echo
echo '  fail open — the list is missing'
open_ok=1
out="$(PARROTFLOW_WORDPIECE=/nonexistent/wordpiece.txt verdicts Versal)"
got_piece="$(field "$out" wordpiece)"
got_gate="$(field "$out" gate)"
if [ "$got_piece" = "unavailable" ] && [ "$got_gate" = "judge" ]; then
  printf '  ✓ %-12s wordpiece %-11s %s\n' "Versal" "$got_piece" "$got_gate"
else
  open_ok=0
  printf '  ✗ %-12s got wordpiece %s, gate %s; want unavailable, judge\n' \
    "Versal" "$got_piece" "$got_gate"
  echo '    a missing list must send the word to the judge, never auto-apply it'
fi

[ "$pass" = "$total" ] && [ "$open_ok" = 1 ]
