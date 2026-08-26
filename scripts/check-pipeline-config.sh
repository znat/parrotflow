#!/usr/bin/env bash
# Scores which pipeline a whole config resolves to, and what `pipelines:` gets.
#
#   scripts/check-pipeline-config.sh
#
# Every case asserts the resolved pipeline, not only the message. A config that
# is refused and also loses its steps fails twice, and only the message is
# visible — asserting the message alone is how that got shipped once already.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

WORK="$(mktemp -d -t parrotflow-pipeline-config)"
trap 'rm -rf "$WORK"' EXIT

pass=0; total=0; failed=""

check() {
  local name="$1" got="$2" want="$3"
  total=$((total + 1))
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    printf '  ✓ %s\n' "$name"
  else
    failed="$failed
      $name"
    printf '  ✗ %s\n      got   %s\n      want  %s\n' "$name" "$got" "$want"
  fi
}

run_config() {
  local dir="$WORK/$1"
  mkdir -p "$dir"
  printf '%s\n' "$2" > "$dir/config.yaml"
  out="$(PARROTFLOW_CONFIG_DIR="$dir" "$BIN" --check-config 2>/dev/null)"
  code=$?
}

# The line `--check-config` prints for the resolved pipeline, stages only.
stages() {
  printf '%s\n' "$out" | sed -n 's/^  · pipeline  *//p'
}

# --- the shape that ships -----------------------------------------------------

run_config new 'transcription:
  languages: [en, fr]
  pipeline:
    - vocabulary
    - numbers'

check "a bare pipeline: list loads" "$code" "0"
check "and it is the pipeline that runs" "$(stages)" "vocabulary → numbers"

# --- an empty list is a choice ------------------------------------------------

run_config empty 'transcription:
  languages: [en]
  pipeline: []'

check "an empty pipeline loads" "$code" "0"
check "and runs nothing, which is what it says" \
  "$(stages)" "nothing — the list is empty"

# --- no pipeline at all -------------------------------------------------------

run_config absent 'transcription:
  languages: [en]'

check "a config naming no pipeline loads" "$code" "0"
check "and gets the built-in default, said out loud" \
  "$(stages)" "numbers  (nothing configured, so every stage)"

# --- the retired key ----------------------------------------------------------
#
# Refused outright. Nothing under it is read, whatever shape it is in, so the
# built-in default runs — and the message has to say that, because a pipeline
# that is not being read must not look like one that is.

run_config retired 'transcription:
  languages: [en, fr]
  pipelines:
    default: [vocabulary, numbers]
    fr: [numbers]'

check "pipelines: is refused" "$code" "1"
check "and the message says nothing under it is read" \
  "$(printf '%s\n' "$out" | grep -c 'transcription.pipelines: is retired')" "1"
check "and says what to write instead" \
  "$(printf '%s\n' "$out" | grep -c 'when: language == "fr"')" "1"
check "and says the built-in default is what runs" \
  "$(printf '%s\n' "$out" | grep -c 'no pipeline of yours is running')" "1"
check "and that is what resolves" \
  "$(stages)" "numbers  (nothing configured, so every stage)"

# --- any shape under the retired key ------------------------------------------
#
# A bare list is what half a migration produces. It is never decoded, so it
# cannot be mis-read as an empty map — one refusal covers every shape.

run_config retired_list 'transcription:
  languages: [en]
  pipelines:
    - vocabulary
    - numbers'

check "a bare list under pipelines: is refused the same way" "$code" "1"
check "with the same one message" \
  "$(printf '%s\n' "$out" | grep -c 'transcription.pipelines: is retired')" "1"
check "and the built-in default resolves" \
  "$(stages)" "numbers  (nothing configured, so every stage)"

# --- the rest of the config still loads ---------------------------------------
#
# The regression this guards: refusing a key must not cost the file. A throw
# from the decoder leaves ConfigStore.load() entirely, and at launch that is
# swallowed — every other setting would silently revert to stock.

run_config survives 'transcription:
  insert_mode: clipboard
  activation_phrases: [salut perroquet]
  languages: [en]
  pipelines:
    default: [vocabulary]'

check "a refused pipelines: does not cost the rest of the config" \
  "$(printf '%s\n' "$out" | sed -n 's/^  · wake phrase  *//p')" '"salut perroquet"'
check "including a setting read after it" \
  "$(printf '%s\n' "$out" | grep -c 'copy to clipboard')" "1"
check "and the built-in default is still what resolves" \
  "$(stages)" "numbers  (nothing configured, so every stage)"

# --- both keys ----------------------------------------------------------------

run_config both 'transcription:
  languages: [en]
  pipeline:
    - vocabulary
  pipelines:
    default: [numbers]'

check "pipelines: beside pipeline: is still refused" "$code" "1"
check "and pipeline: is what runs" "$(stages)" "vocabulary"
check "and the message says so" \
  "$(printf '%s\n' "$out" | grep -c 'the `pipeline:` list is what runs')" "1"

echo
echo "  $pass/$total$failed"
[ "$pass" = "$total" ]
