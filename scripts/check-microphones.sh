#!/usr/bin/env bash
# Checks that the microphone priority list survives a round trip through
# config.yaml.
#
#   scripts/check-microphones.sh
#
# The menu bar writes this list, and it writes it into a file that is mostly
# comments — so the write is a text splice, not a YAML round trip, and every
# shape the file can be in has to come out valid and keep its comments. The
# shapes: an `audio:` block with no list yet, a list already there, a list
# written by hand as a flow sequence, and no `audio:` block at all.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

WORK="$(mktemp -d -t parrotflow-mics)"
trap 'rm -rf "$WORK"' EXIT

pass=0; total=0; failed=""

wants() {
  total=$((total + 1))
  if printf '%s' "$2" | grep -qF -- "$3"; then
    pass=$((pass + 1))
    printf '  ✓ %s\n' "$1"
  else
    failed="$failed
      $1"
    printf '  ✗ %s\n      want  %s\n      got   %s\n' "$1" "$3" "$2"
  fi
}

counts() {
  total=$((total + 1))
  got="$(printf '%s' "$2" | grep -cF -- "$3")"
  if [ "$got" = "$4" ]; then
    pass=$((pass + 1))
    printf '  ✓ %s\n' "$1"
  else
    failed="$failed
      $1"
    printf '  ✗ %s\n      want  %s × %s\n      got   × %s\n' "$1" "$3" "$4" "$got"
  fi
}

rejects() {
  total=$((total + 1))
  if printf '%s' "$2" | grep -qF -- "$3"; then
    failed="$failed
      $1"
    printf '  ✗ %s\n      unwanted  %s\n      got       %s\n' "$1" "$3" "$2"
  else
    pass=$((pass + 1))
    printf '  ✓ %s\n' "$1"
  fi
}

set_mics() { PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --microphones --set "$1" >/dev/null 2>&1; }
config() { cat "$WORK/config.yaml"; }
check() { PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --check-config 2>&1; }

fresh() {
  cat > "$WORK/config.yaml" <<'YAML'
hotkey:
  key: right_option

audio:
  # Where recordings go.
  output_dir: ~/Recordings/ParrotFlow
  speech_gate: true

transcription:
  languages: [en]
YAML
}

# --- an audio block with no list yet ----------------------------------------
fresh
set_mics "Studio Display Microphone, MacBook Pro Microphone"
wants "the key lands in the audio block" "$(config)" "  microphones:"
wants "first entry, in order"           "$(config)" "    - Studio Display Microphone"
wants "second entry, in order"          "$(config)" "    - MacBook Pro Microphone"
wants "the comment above output_dir survives" "$(config)" "# Where recordings go."
wants "the block below is untouched"    "$(config)" "transcription:"
wants "it parses, best first"           "$(check)"  "2 listed, best first"

# --- replacing a list that is already there ---------------------------------
set_mics "MacBook Pro Microphone"
wants "the new list is written"    "$(config)" "    - MacBook Pro Microphone"
rejects "the old entry is gone"    "$(config)" "Studio Display Microphone"
counts "the key is written once"   "$(config)" "microphones:" 1
counts "and holds one entry"       "$(config)" "    - " 1

# --- clearing it ------------------------------------------------------------
set_mics ""
rejects "the key is removed, not emptied" "$(config)" "microphones"
wants "the rest of the audio block stays" "$(config)" "  speech_gate: true"
wants "an empty list follows the system"  "$(check)"  "none listed"

# --- a list a person wrote as a flow sequence -------------------------------
cat > "$WORK/config.yaml" <<'YAML'
audio:
  output_dir: ~/Recordings/ParrotFlow
  microphones: [Old One, Other One]
  speech_gate: true

transcription:
  languages: [en]
YAML
set_mics "MacBook Pro Microphone"
rejects "the flow list is replaced whole" "$(config)" "Old One"
wants "by a block list"                   "$(config)" "    - MacBook Pro Microphone"
wants "in the place the old one had"      "$(config)" "  speech_gate: true"
counts "and written once"                 "$(config)" "microphones:" 1

# --- no audio block at all --------------------------------------------------
printf 'transcription:\n  languages: [en]\n' > "$WORK/config.yaml"
set_mics "MacBook Pro Microphone"
wants "an audio block is added" "$(config)" "audio:"
wants "with the list under it"  "$(config)" "    - MacBook Pro Microphone"
wants "and it still parses"     "$(check)"  "1 listed, best first"

# --- a name that is not a plain word ----------------------------------------
fresh
set_mics "Nathan's AirPods: Pro"
wants "punctuation is quoted" "$(config)" '- "Nathan'"'"'s AirPods: Pro"'
wants "and it still parses"   "$(check)"  "1 listed, best first"

printf '\n%d/%d\n' "$pass" "$total"
[ -n "$failed" ] && printf 'failed:%s\n' "$failed"
[ "$pass" -eq "$total" ]
