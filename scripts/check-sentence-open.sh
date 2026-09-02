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
# A line can hold more than one correction, so the case names the word it is
# asking about rather than taking the first answer.
check() {
  local what="$1" written="$2" now="$3" word="$4" want="$5"
  local got
  got="$("$BIN" --edit-diff "$written" "$now" 2>/dev/null \
    | awk -v w=" -> $word" '$0 ~ w {found=1; next} found && /^  opens: /{print $2; exit}')"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$what"
  else
    fail=$((fail + 1)); printf '  ✗ %s: got "%s", expected "%s"\n' "$what" "$got" "$want"
  fi
}

check "the first word of the line opens one" \
  "Fais on verra demain." "Et on verra demain." Et true

check "a word after a stop opens one" \
  "C'est fait. Fais on verra." "C'est fait. Et on verra." Et true

check "a word after a question mark opens one" \
  "Tu viens? Fais on verra." "Tu viens? Et on verra." Et true

check "a word in the middle does not" \
  "I use the versal dashboard daily." "I use the Vercel dashboard daily." Vercel false

check "a word after a stop inside a word does not" \
  "We run Node.js and gwen here." "We run Node.js and Qwen here." Qwen false

check "the second word does not" \
  "The versal deploy went out." "The Vercel deploy went out." Vercel false

check "a stop inside a closing quote still opens one" \
  'He said "it is done." Fais on verra.' 'He said "it is done." Et on verra.' Et true

check "a stop inside a closing bracket still opens one" \
  "(that was it.) Fais on verra." "(that was it.) Et on verra." Et true

check "an earlier merge does not shift the answer" \
  "I use Ghost D daily. versal is fine." "I use Ghostty daily. Vercel is fine." Vercel true

check "an earlier merge does not invent an opening" \
  "I use Ghost D and the versal dashboard." "I use Ghostty and the Vercel dashboard." Vercel false

echo
if [ "$fail" -gt 0 ]; then
  printf '  %d/%d\n' "$pass" "$((pass + fail))"
  exit 1
fi
echo "Every check passed."
