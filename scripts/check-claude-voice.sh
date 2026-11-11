#!/usr/bin/env bash
# Scores ClaudeSpeakable against tests/claude-voice-cases.yaml. No model, no
# audio, and the flag exits before the config is read. Then checks the voice
# prompt files through --check-config under a scratch config.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }
"$BIN" --claude-voice-test "$ROOT/tests/claude-voice-cases.yaml"
cases=$?

WORK="$(mktemp -d -t parrotflow-voice-prompts)"
trap 'rm -rf "$WORK"' EXIT
VOICE="$WORK/voice"
mkdir -p "$VOICE"
pass=0; total=0

# check <name> <got> <want glob>
check() {
  total=$((total + 1))
  # shellcheck disable=SC2053
  if [[ "$2" == $3 ]]; then
    pass=$((pass + 1))
    printf '  ✓ %s\n' "$1"
  else
    printf '  ✗ %s\n      got   %s\n      want  %s\n' "$1" "$2" "$3"
  fi
}

prompt_line() {
  PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --check-config </dev/null 2>/dev/null \
    | grep "voice $1 " | sed 's/^ *//; s/  */ /g'
}

copies() {
  for file in "$ROOT"/built-in/voice/*; do
    cmp -s "$file" "$VOICE/built-in/$(basename "$file")" || { echo "differs: $(basename "$file")"; return; }
  done
  echo same
}

echo
echo "voice prompt files"
check "with no override, the rewrite prompt is the built-in" "$(prompt_line rewrite)" "· voice rewrite built-in"
check "launch writes the reference copies to voice/built-in/" "$(copies)" "same"

echo "Say it in one sentence." > "$VOICE/reminder.md"
check "a file in voice/ replaces the built-in" "$(prompt_line reminder)" "· voice reminder *voice/reminder.md"

printf '\n  \n' > "$VOICE/explain.md"
check "an empty override is a problem, and the built-in is used" "$(prompt_line explain)" \
  "✗ voice explain *voice/explain.md is empty; the built-in prompt is used"
printf '<!--\nonly the note\n-->\n' > "$VOICE/rewrite.md"
check "an override with only the note is empty" "$(prompt_line rewrite)" "✗ voice rewrite *voice/rewrite.md is empty;*"
printf '\xff\xfe broken\n' > "$VOICE/rewrite.md"
check "an override that is not UTF-8 is a problem" "$(prompt_line rewrite)" \
  "✗ voice rewrite *voice/rewrite.md cannot be read as UTF-8 text; the built-in prompt is used"
rm "$VOICE/explain.md" "$VOICE/rewrite.md"
check "deleting the override brings the built-in back" "$(prompt_line explain)" "· voice explain built-in"

echo "edited" > "$VOICE/built-in/rewrite.md"
echo "stale" > "$VOICE/built-in/retired.md"
echo '{"term": "Mira"}' > "$VOICE/observations.jsonl"
prompt_line rewrite > /dev/null
check "an edited reference copy is put back" "$(copies)" "same"
check "a reference copy no longer shipped is removed" "$([ -e "$VOICE/built-in/retired.md" ] && echo kept || echo removed)" "removed"
check "the refresh leaves the rest of voice/ alone" "$(cat "$VOICE/observations.jsonl" "$VOICE/reminder.md")" \
  '{"term": "Mira"}'$'\n'"Say it in one sentence."

# voice_key <pause|skip> <value>: the check-config lines about that key. No value: the key left out.
voice_key() {
  local name=$1; shift
  printf 'voice:\n  enabled: false\n' > "$WORK/config.yaml"
  [ $# -gt 0 ] && printf '  %s_key: %s\n' "$name" "$1" >> "$WORK/config.yaml"
  PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --check-config </dev/null 2>/dev/null \
    | grep -E "$name key|voice.${name}_key" | sed 's/^ *//; s/  */ /g'
}
pause_key() { voice_key pause "$@"; }
skip_key() { voice_key skip "$@"; }

echo
echo "voice.pause_key"
check "the default is ⌃⌥P" "$(pause_key)" "· pause key ⌃⌥P"
check "a key and modifiers" "$(pause_key '{ key: f13, modifiers: [cmd, shift] }')" "· pause key ⇧⌘F13"
check "none turns it off" "$(pause_key none)" "· pause key none"
check "an empty value turns it off" "$(pause_key '')" "· pause key none"
check "off turns it off" "$(pause_key off)" "· pause key none"
check "an unknown key is a problem" "$(pause_key '{ key: pp, modifiers: [control] }')" \
  "✗ voice.pause_key: \"pp\" is not a known key name; the shortcut is off"$'\n'"· pause key none"
check "a key with no modifier is a problem" "$(pause_key '{ key: p }')" \
  "✗ voice.pause_key: it needs one or more of command, control, option, shift; the shortcut is off"$'\n'"· pause key none"
check "an unknown modifier is named" "$(pause_key '{ key: p, modifiers: [control, hyper] }')" \
  "✗ voice.pause_key: hyper is not a modifier — it needs one or more of command, control, option, shift; the shortcut is off"$'\n'"· pause key none"
check "a bare modifier is a problem" "$(pause_key '{ key: right_option }')" \
  "✗ voice.pause_key: \"right_option\" is a modifier alone — it needs a key; the shortcut is off"$'\n'"· pause key none"
check "a word that is not none is a problem" "$(pause_key ctrl-p)" \
  "✗ voice.pause_key: \"ctrl-p\" is not a shortcut — expected { key: p, modifiers: \[control, option\] } or none; the shortcut is off"$'\n'"· pause key none"

echo
echo "voice.skip_key"
check "the default is ⌃⌥S" "$(skip_key)" "· skip key ⌃⌥S"
check "a key and modifiers" "$(skip_key '{ key: f14, modifiers: [cmd] }')" "· skip key ⌘F14"
check "none turns it off" "$(skip_key none)" "· skip key none"
check "a word that is not none names the skip example" "$(skip_key ctrl-s)" \
  "✗ voice.skip_key: \"ctrl-s\" is not a shortcut — expected { key: s, modifiers: \[control, option\] } or none; the shortcut is off"$'\n'"· skip key none"
check "a key with no modifier is a problem" "$(skip_key '{ key: s }')" \
  "✗ voice.skip_key: it needs one or more of command, control, option, shift; the shortcut is off"$'\n'"· skip key none"

# during_calls [value]: the check-config line for voice.pause_during_calls.
during_calls() {
  printf 'voice:\n  enabled: false\n' > "$WORK/config.yaml"
  [ $# -gt 0 ] && printf '  pause_during_calls: %s\n' "$1" >> "$WORK/config.yaml"
  PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --check-config </dev/null 2>/dev/null \
    | grep "during calls" | sed 's/^ *//; s/  */ /g'
}

echo
echo "voice.pause_during_calls"
check "on by default" "$(during_calls)" "· during calls paused"
check "false keeps the voice speaking" "$(during_calls false)" "· during calls keeps speaking"

printf '\n%d/%d\n' "$pass" "$total"
[ "$cases" -eq 0 ] && [ "$pass" -eq "$total" ]
