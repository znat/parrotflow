#!/usr/bin/env bash
# Replays the last spoken Claude lines with tone instructions you write, to
# compare tones by ear. Runs the installed dev app's binary, which already has
# the OpenRouter key; a freshly built .build binary would ask for keychain access.
#
#   scripts/tone-play.sh "<instructions>" [voice] [how many, default 4]
#   scripts/tone-play.sh --list [how many]      # print them, say nothing
#
# Lines come from ~/Library/Logs/ParrotFlow-Dev.log ("claude voice: said:").
set -uo pipefail
BIN="${PF_BIN:-/Applications/ParrotFlowDev.app/Contents/MacOS/ParrotFlow}"
LOG="${PF_LOG:-$HOME/Library/Logs/ParrotFlow-Dev.log}"
[ -x "$BIN" ] || { echo "no app at $BIN — make install first"; exit 1; }

lines() {
  grep -F "claude voice: said: " "$LOG" | sed 's/^.*claude voice: said: //' | tail -n "$1"
}

if [ "${1:-}" = "--list" ]; then
  n=0; while IFS= read -r line; do n=$((n + 1)); printf '%d. %s\n\n' "$n" "$line"; done < <(lines "${2:-4}")
  exit 0
fi

tone="${1:?usage: tone-play.sh \"<instructions>\" [voice] [how many]}"
voice="${2:-}"
count="${3:-4}"
n=0
while IFS= read -r line; do
  n=$((n + 1))
  printf '\n%d. %s\n' "$n" "$line"
  if [ -n "$voice" ]; then
    "$BIN" --claude-say "$line" --tone "$tone" --voice "$voice" 2>/dev/null | grep -vE "^tone:"
  else
    "$BIN" --claude-say "$line" --tone "$tone" 2>/dev/null | grep -vE "^tone:"
  fi
done < <(lines "$count")
