#!/usr/bin/env bash
# Does a capital mean anything where it stands?
#
#   scripts/check-sentence-open.sh
#
# `AppDelegate.teaches` offers a correction onto a capitalised word, on the
# grounds that a capital mid-sentence is how a name looks. That is only true
# away from a sentence opening, where every word is capitalised and the capital
# says nothing.
#
# The test used to ask whether the word opened the *line*. A line holds several
# sentences: correcting `Fais` to `Et` at the start of one, mid-line, read as a
# name and offered a French grammar fix as a vocabulary rule.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

pass=0; fail=0
check() {
  local what="$1" written="$2" now="$3" want="$4"
  local got
  got="$("$BIN" --edit-diff "$written" "$now" 2>/dev/null | awk '/^  opens: /{print $2; exit}')"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$what"
  else
    fail=$((fail + 1)); printf '  ✗ %s: got "%s", expected "%s"\n' "$what" "$got" "$want"
  fi
}

check "the first word of the line opens one" \
  "Fais on verra demain." "Et on verra demain." true

check "a word after a stop opens one" \
  "C'est fait. Fais on verra." "C'est fait. Et on verra." true

check "a word after a question mark opens one" \
  "Tu viens? Fais on verra." "Tu viens? Et on verra." true

check "a word in the middle does not" \
  "I use the versal dashboard daily." "I use the Vercel dashboard daily." false

check "a word after a stop inside a word does not" \
  "We run Node.js and gwen here." "We run Node.js and Qwen here." false

check "the second word does not" \
  "The versal deploy went out." "The Vercel deploy went out." false

echo
if [ "$fail" -gt 0 ]; then
  printf '  %d/%d\n' "$pass" "$((pass + fail))"
  exit 1
fi
echo "Every check passed."
