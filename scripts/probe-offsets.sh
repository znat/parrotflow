#!/usr/bin/env bash
# Measures whether an app's text offsets address its own accessibility value.
#
#   scripts/probe-offsets.sh
#
# A probe, not a check: it prints what the app says and scores nothing. There is
# no right answer to assert yet, and #175 is why.
#
# The two are not the same thing. `kAXValue` is a string; `kAXSelectedTextRange`
# is a number; nothing guarantees the number indexes the string. In a Chromium
# contenteditable it does not — the value renders every block boundary as "\n"
# and counts it, and the offsets skip it. A caret at the end of a
# three-paragraph message is reported two characters early.
#
# What stopped this becoming a correction is the last two rows. Two carets that
# the page places one character apart, either side of a line break, come back as
# the same number: the position is not recoverable from the range, because the
# information is not in it.
#
# The page is the oracle, not accessibility — it publishes the selection it set
# in its own title, in value offsets, so every row can be checked against
# something that owes nothing to the API under test. Carets included, which is
# the part that matters: a caret selects no text, so without this two positions
# either side of a break look identical in the title as well.
#
# Needs Chrome and the dev app built (`make app`). Chrome rather than Slack
# because it is the same engine, it runs unattended, and it sends nothing to
# anyone. macOS may ask once for permission to control Chrome.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/ParrotFlowDev.app/Contents/MacOS/ParrotFlow"
[ -x "$BIN" ] || { echo "build the app first: make app"; exit 1; }
command -v osascript >/dev/null || { echo "needs macOS"; exit 1; }

# name | seed ("|" separates paragraphs) | "from,length" in value offsets, or "end"
probe() {
  local name="$1" seed="$2" at="${3:-}"
  local enc url
  enc="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$seed")"
  url="file://$ROOT/tests/fixtures/paragraphs.html#$enc"
  [ -n "$at" ] && url="$url&at=$at"

  osascript >/dev/null 2>&1 <<'OSA'
tell application "Google Chrome"
  repeat with w in windows
    set i to (count of tabs of w)
    repeat while i > 0
      if (URL of tab i of w as string) contains "/tests/fixtures/" then close tab i of w
      set i to i - 1
    end repeat
  end repeat
end tell
OSA
  osascript >/dev/null 2>&1 <<OSA
tell application "Google Chrome"
  activate
  if (count of windows) = 0 then make new window
  make new tab at end of tabs of front window with properties {URL:"$url"}
  set active tab index of front window to (count of tabs of front window)
end tell
OSA

  local title=""
  for _ in $(seq 1 24); do
    title="$(osascript -e 'tell application "Google Chrome" to get title of active tab of front window' 2>/dev/null)"
    case "$title" in *"|AT|"*) break ;; esac
    sleep 0.25
  done
  case "$title" in
    *"|AT|"*) ;;
    *) printf "  %-34s the page never published its selection\n" "$name"; return ;;
  esac

  local page peek value said
  page="${title#*|AT|}"; page="${page%%|SAID|*}"
  peek="$("$BIN" --peek 2 2>/dev/null)"
  value="$(echo "$peek" | sed -n 's/^value *\([0-9]*\) chars, \([0-9]*\).*/\1 chars, \2 line(s)/p' | head -1)"
  said="$(echo "$peek" | sed -n 's/^range *location \([0-9]*\), length \([0-9]*\)/\1+\2/p' | head -1)"
  printf "  %-34s page %-8s app %-8s (%s)\n" "$name" "$page" "$said" "$value"
}

echo "what the page set, and what the app reports for it:"
echo

probe "one paragraph, caret at the end"    "One line only, no breaks at all."
probe "two paragraphs, caret at the end"   "First line here.|Second line here."
probe "three paragraphs, caret at the end" \
  "Hey Mik, good to hear from you!|I'm taking off until Tuesday.|Does Tuesday morning work for you?"
probe "a blank last line, caret on it"     "First line here.|Second line here.|"
probe "a word on the third line"           \
  "Hey Mik, good to hear from you!|I'm taking off until Tuesday.|Does Tuesday morning work for you?" "62,12"

echo
echo "the two that stopped a correction being written:"
echo
probe "caret at the end of line two"       \
  "Hey Mik, good to hear from you!|I'm taking off until Tuesday.|Does Tuesday morning work for you?" "61,0"
probe "caret at the start of line three"   \
  "Hey Mik, good to hear from you!|I'm taking off until Tuesday.|Does Tuesday morning work for you?" "62,0"
echo
echo "  one number for two positions — see #175"
