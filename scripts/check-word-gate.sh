#!/usr/bin/env bash
# Scores the auto-apply gate against tests/word-gate-cases.yaml.
#
#   scripts/check-word-gate.sh
#
# The question is what a vocabulary term may overwrite with nothing reading the
# sentence. `Vocabulary.autoApplies` asks two word lists and needs both to say
# "unknown": NSSpellChecker, which has no first names in it, and the whole-word
# half of a tokenizer vocabulary, which has no rare compounds in it. Either one
# alone overwrites a whole class of ordinary word.
#
# Both verdicts are checked, not only the decision. A word reaches `judge` from
# either side, so a set that read the decision alone would pass with one half
# broken — `Chloé` in particular, where the accent is the thing under test.
#
# A case with a `term` asks the whole gate about that pair instead, and checks
# the `possessive` verdict beside the decision. Same reason: `Matthew at`
# reaches `judge` from the glued-compound branch whatever the possessive rule
# says, so the decision alone would not show the rule firing on the wrong side.
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

# `<key> <value>` lines, everything the binary logs dropped. The term is
# passed only when the case names one — an empty second argument would be one
# argument too many for a set that is asking about a word.
verdicts() {
  if [ -n "${2:-}" ]; then
    "$BIN" --word-gate "$1" "$2" 2>/dev/null
  else
    "$BIN" --word-gate "$1" 2>/dev/null
  fi | awk '$1 ~ /^(spell|wordpiece|possessive|gate)$/ { print $1, $2 }'
}

field() { printf '%s\n' "$1" | awk -v k="$2" '$1 == k { print $2 }'; }

# A verdict the case does not name is not asked for. A word case names no
# `possessive`, a pair case names neither list. Which verdicts a case has to
# name is checked separately, at the top of the loop — read as "not asked",
# an empty expectation would also let a case that names nothing pass.
same() { [ -z "$1" ] || [ "$1" = "$2" ]; }

pass=0; total=0; overwrote=0

# Unit separator, not a tab. A tab is whitespace, so bash collapses two of
# them into one and a case with no `term` arrives with its fields shifted.
while IFS=$'\x1f' read -r word term spell wordpiece possessive gate; do
  total=$((total + 1))

  # The shape of the case, before its answer. A case that leaves out something
  # its shape needs is a broken case and not a passing one — `same` would read
  # the gap as "not asked" and the binary printing nothing there would agree.
  # A case with no word used to be skipped, which kept it out of the count as
  # well as out of the run: a malformed one could be added and the set still
  # said 25/25.
  missing=""
  [ -z "$word" ] && missing="$missing word"
  [ -z "$gate" ] && missing="$missing gate"
  if [ -n "$term" ]; then
    [ -z "$possessive" ] && missing="$missing possessive"
  else
    [ -z "$spell" ] && missing="$missing spell"
    [ -z "$wordpiece" ] && missing="$missing wordpiece"
  fi
  if [ -n "$missing" ]; then
    printf '  ✗ %-12s the case names no%s\n' "${word:-(no word)}" "$missing"
    continue
  fi

  # Asked twice when the first answer is wrong, and only then. NSSpellChecker
  # is a service that times out, a timeout is indistinguishable from "known
  # word", and `isRealWord` caches per process — so a second process is a
  # second sample. Seen once while writing this: `Versal` came back `known`
  # under load, then `unknown` ten times in a row. A real regression fails
  # both times; nothing here is retried until it passes.
  for _ in 1 2; do
    out="$(verdicts "$word" "$term")"
    got_spell="$(field "$out" spell)"
    got_piece="$(field "$out" wordpiece)"
    got_poss="$(field "$out" possessive)"
    got_gate="$(field "$out" gate)"
    ok=0
    same "$spell" "$got_spell" && same "$wordpiece" "$got_piece" \
      && same "$possessive" "$got_poss" && same "$gate" "$got_gate" && ok=1
    [ "$ok" = 1 ] && break
  done

  # What this case was about, for the report: the two lists, or the pair. The
  # verdict above is what decides — a case may name a field this does not
  # print, and it is still checked.
  if [ -n "$term" ]; then
    got_line="$(printf 'term %-12s possessive %-9s %s' "$term" "$got_poss" "$got_gate")"
    want_line="$(printf 'term %-12s possessive %-9s %s' "$term" "$possessive" "$gate")"
  else
    got_line="$(printf 'spell %-11s wordpiece %-11s %s' "$got_spell" "$got_piece" "$got_gate")"
    want_line="$(printf 'spell %-11s wordpiece %-11s %s' "$spell" "$wordpiece" "$gate")"
  fi

  if [ "$ok" = 1 ]; then
    pass=$((pass + 1))
    printf '  ✓ %-12s %s\n' "$word" "$got_line"
    continue
  fi

  # An expected `judge` that came back `auto-apply` is the expensive direction:
  # a word nobody said, written into the transcript, with no menu behind it.
  if [ "$gate" = "judge" ] && [ "$got_gate" = "auto-apply" ]; then
    overwrote=$((overwrote + 1))
  fi
  printf '  ✗ %-12s got   %s\n' "$word" "$got_line"
  printf '    %-12s want  %s\n' "" "$want_line"
done < <(python3 -c '
import sys, yaml
for case in yaml.safe_load(open(sys.argv[1]))["cases"]:
    print("\x1f".join(str(case.get(key, "")) for key in
                    ("word", "term", "spell", "wordpiece", "possessive", "gate")))
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
