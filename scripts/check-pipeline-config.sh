#!/usr/bin/env bash
# Scores how `--check-config` reads the pipeline key, including the retired
# `pipelines:` map.
#
#   scripts/check-pipeline-config.sh
#
# Every case is a whole config in a directory of its own, read by the real
# binary through PARROTFLOW_CONFIG_DIR. What is measured is both halves of a
# refusal: the message, and what the app is left running. A config that is
# refused and also loses its stages fails twice, and only the message is
# visible — so the resolved pipeline is asserted on every case.
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

# Writes $2 as a config and leaves the run in $out / $code.
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

# --- the retired map, with only default: --------------------------------------
#
# Read for one more release. A notice, not a fault: the steps do run and the
# dictation is unchanged, so failing the command would be a lie about the cost.

run_config default_only 'transcription:
  languages: [en, fr]
  pipelines:
    default:
      - vocabulary
      - numbers'

check "pipelines: with only default: still loads" "$code" "0"
check "and its steps are the ones that run" "$(stages)" "vocabulary → numbers"
check "and it is named as the old spelling" \
  "$(printf '%s\n' "$out" | grep -c 'transcription.pipelines: is the old spelling')" "1"

# --- the retired map, with a language key -------------------------------------
#
# Refused, because a `fr:` list cannot become the one pipeline without changing
# what runs in English. Refused is not the same as dropped: the `default:` list
# keeps running, and the message says so. A config naming five stages that
# quietly runs one is the failure this half exists to prevent.

run_config language_key 'transcription:
  languages: [en, fr]
  pipelines:
    default:
      - vocabulary
      - numbers
    fr:
      - numbers'

check "a language key is refused" "$code" "1"
check "and the key is named, with what to write instead" \
  "$(printf '%s\n' "$out" | grep -c 'pipelines: "fr" is a language key')" "1"
check "and the condition is spelled out" \
  "$(printf '%s\n' "$out" | grep -c 'when: language == "fr"')" "1"
check "the default: steps keep running while it is migrated" \
  "$(stages)" "vocabulary → numbers"
check "and the config says which list that is" \
  "$(printf '%s\n' "$out" | grep -c 'the "default" list is what runs')" "1"

# --- a language key and no default: -------------------------------------------
#
# There is no `default:` to fall back to, so the first of `languages:` that has
# a key runs. Still refused, and still named — what must not happen is the
# pipeline silently collapsing to the automatic stages.

run_config no_default 'transcription:
  languages: [fr, en]
  pipelines:
    fr:
      - vocabulary
      - numbers'

check "a language key with no default: is refused" "$code" "1"
check "and the language list runs rather than nothing" "$(stages)" "vocabulary → numbers"
check "and the config says which list that is" \
  "$(printf '%s\n' "$out" | grep -c 'the "fr" list is what runs')" "1"

# --- both keys ----------------------------------------------------------------

run_config both 'transcription:
  languages: [en]
  pipeline:
    - vocabulary
  pipelines:
    default:
      - numbers'

check "both keys is refused" "$code" "1"
check "and the message says which one runs" \
  "$(printf '%s\n' "$out" | grep -c '`pipeline:` is the one that runs')" "1"
check "and pipeline: is what runs" "$(stages)" "vocabulary"

# --- a bare list under the retired key ----------------------------------------
#
# Half a migration: the steps were dedented and the key was not renamed. It
# decodes as neither shape. Refused rather than read as an empty map — that
# silently cost every step the config named, which is exactly the outcome the
# refusals above exist to prevent.

run_config malformed 'transcription:
  languages: [en]
  pipelines:
    - vocabulary
    - numbers'

check "a bare list under pipelines: is refused" "$code" "1"
check "and it is not accepted as the old spelling" \
  "$(printf '%s\n' "$out" | grep -c 'is the old spelling')" "0"
check "and the message names the key and what to write" \
  "$(printf '%s\n' "$out" | grep -c 'transcription.pipelines')" "1"

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
check "and gets the default, said out loud" \
  "$(printf '%s\n' "$out" | grep -c 'nothing configured, so every stage')" "1"

echo
echo "  $pass/$total$failed"
[ "$pass" = "$total" ]
