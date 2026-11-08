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

printf '\n%d/%d\n' "$pass" "$total"
[ "$cases" -eq 0 ] && [ "$pass" -eq "$total" ]
