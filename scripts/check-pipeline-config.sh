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
  # `gate_sentence:` is the only key here that lives in vocabulary.yaml.
  if [ "$#" -ge 3 ]; then printf '%s\n' "$3" > "$dir/vocabulary.yaml"; fi
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
  "$(stages)" "interpret → numbers  (nothing configured, so every stage)"

# --- the interpret step -------------------------------------------------------
#
# The boundary readings were a pass that ran before the pipeline and answered
# to `transcription.sentences`. They are a step now, so the list is the switch
# and the options live on the line.

# What `--check-config` prints for the marks the step resolves to.
marks() {
  printf '%s\n' "$out" | sed -n 's/^  · sentence marks  *//p'
}

run_config interpret_bare 'transcription:
  languages: [en]
  pipeline:
    - interpret
    - vocabulary
    - numbers'

check "a bare - interpret line loads" "$code" "0"
check "and runs above vocabulary without being refused for it" \
  "$(stages)" "interpret → vocabulary → numbers"
check "and takes the built-in marks" "$(marks)" ". , ?"

run_config interpret_options 'transcription:
  languages: [en]
  pipeline:
    - stage: interpret
      marks: [".", "?"]
      capitals: false
      pause: 0
      app: /term/'

check "a map with every option loads" "$code" "0"
check "and the condition is printed with the step" \
  "$(stages)" "interpret in /term/"
check "and the step marks are what runs" "$(marks)" ". ?  (bare capitals off)"

run_config interpret_capitals 'transcription:
  languages: [en]
  pipeline:
    - {stage: interpret, capitals: false}'

check "capitals: false alone loads" "$code" "0"
check "and says so beside the marks" "$(marks)" ". , ?  (bare capitals off)"

run_config interpret_pause 'transcription:
  languages: [en]
  pipeline:
    - {stage: interpret, pause: 0}'

check "pause: 0 loads" "$code" "0"
check "and the step still resolves" "$(stages)" "interpret"

run_config interpret_bad_marks 'transcription:
  languages: [en]
  pipeline:
    - {stage: interpret, marks: ["hello"]}'

check "a mark that is a word is refused" "$code" "1"
check "and the message names the key that was written" \
  "$(printf '%s\n' "$out" | grep -c 'pipeline.interpret.marks')" "1"

run_config interpret_comma_only 'transcription:
  languages: [en]
  pipeline:
    - {stage: interpret, marks: [","]}'

check "marks with no sentence ender is refused" "$code" "1"
check "and says where a boundary is looked for" \
  "$(printf '%s\n' "$out" | grep -c 'at least one of')" "1"

# --- the legacy keys ----------------------------------------------------------

run_config legacy_off 'transcription:
  languages: [en]
  sentences: false
  pipeline:
    - numbers'

check "sentences: false with no step loads" "$code" "0"
check "and the notice says to remove the step instead" \
  "$(printf '%s\n' "$out" | grep -c 'is legacy; remove the `interpret` step')" "1"
check "and no migration line is printed as well" \
  "$(printf '%s\n' "$out" | grep -c 'the sentence readings no longer run')" "0"

run_config legacy_off_listed 'transcription:
  languages: [en]
  sentences: false
  pipeline:
    - interpret'

check "sentences: false beside the step loads" "$code" "0"
check "and says the key is what still turns it off" \
  "$(printf '%s\n' "$out" | grep -c 'this key is what still turns it off')" "1"
# The same predicate decides whether the 320 MB model is fetched, so a step
# reported as off is also a step nothing is downloaded for.
check "and the step is reported off, not merely configured" \
  "$(marks)" ". , ?  (off — \`transcription.sentences: false\`)"

run_config legacy_marks 'transcription:
  languages: [en]
  sentences:
    marks: [".", "?"]
  pipeline:
    - interpret'

check "the old marks: key loads" "$code" "0"
check "and feeds the step" "$(marks)" ". ?"
check "and the notice points at the step" \
  "$(printf '%s\n' "$out" | grep -c '`marks:` belongs on the `interpret` step now')" "1"

run_config legacy_marks_both 'transcription:
  languages: [en]
  per_language:
    en: {marks: [".", "?"]}
  pipeline:
    - {stage: interpret, marks: [".", ",", "?"]}'

check "both homes for marks: loads" "$code" "0"
check "and the step wins" "$(marks)" ". , ?"
check "and the notice says the step is what runs" \
  "$(printf '%s\n' "$out" | grep -c 'The step is what runs')" "1"

# --- a pipeline written before the step existed -------------------------------
#
# Nothing is inserted. The readings stop, and the line that says so is printed
# by `--check-config` and written to the log at launch, because nobody runs
# `--check-config` after an update.

run_config no_interpret 'transcription:
  languages: [en]
  pipeline:
    - vocabulary
    - numbers'

check "a pipeline with no interpret step loads" "$code" "0"
check "and nothing is inserted into it" "$(stages)" "vocabulary → numbers"
check "and the migration line says what to add" \
  "$(printf '%s\n' "$out" | grep -c 'add `- interpret` to the front')" "1"
check "and no marks line is printed for a step that is not there" \
  "$(marks)" ""

# --- the vocabulary step's gates ----------------------------------------------
#
# Two tests read the sentence and each has its own switch, both on by default.
# The line `--check-config` prints is the same predicate that decides whether
# the model behind each one is fetched, so a gate reported off is a gate
# nothing is downloaded for.

gates() {
  printf '%s\n' "$out" | sed -n 's/^  · vocabulary gates  *//p'
}
# One language's resolved slot floor, whichever of the two homes it came from.
floor() {
  printf '%s\n' "$out" | sed -n "s/^      $1  slot floor //p"
}

run_config gates_default 'transcription:
  languages: [en, fr]
  pipeline:
    - vocabulary'

check "a bare - vocabulary line has both gates on" "$(gates)" "slot on, portrait on"
check "and the built-in floors" "$(floor en)/$(floor fr)" "0.20/0.30"

run_config gates_slot_off 'transcription:
  languages: [en]
  pipeline:
    - {stage: vocabulary, slot_gate: false}'

check "slot_gate: false loads" "$code" "0"
check "and reports the slot gate off, the portrait still on" \
  "$(gates)" "slot off, portrait on"

run_config gates_portrait_off 'transcription:
  languages: [en]
  pipeline:
    - {stage: vocabulary, portrait: false}'

check "portrait: false loads" "$code" "0"
check "and reports the portrait off, the slot gate still on" \
  "$(gates)" "slot on, portrait off"

run_config gates_both_off 'transcription:
  languages: [en]
  pipeline:
    - {stage: vocabulary, slot_gate: false, portrait: false}'

check "both switches off loads" "$code" "0"
check "and neither model is read" "$(gates)" "slot off, portrait off"

run_config gates_legacy_switch 'transcription:
  languages: [en]
  pipeline:
    - vocabulary' 'gate_sentence: false'

check "the legacy gate_sentence: false loads" "$code" "0"
check "and turns both sentence tests off, naming the key" \
  "$(gates)" "slot on, portrait off  (the sentence tests are off — \`vocabulary.gate_sentence: false\`)"

# --- the slot floor, on the step ----------------------------------------------

run_config floor_scalar 'transcription:
  languages: [en, fr]
  pipeline:
    - {stage: vocabulary, slot_floor: 0.35}'

check "a bare number loads" "$code" "0"
check "and applies to every language" "$(floor en)/$(floor fr)" "0.35/0.35"

run_config floor_map 'transcription:
  languages: [en, fr]
  pipeline:
    - {stage: vocabulary, slot_floor: {en: 0.25, fr: 0.45}}'

check "a map loads" "$code" "0"
check "and each language gets its own" "$(floor en)/$(floor fr)" "0.25/0.45"

run_config floor_map_partial 'transcription:
  languages: [en, fr]
  pipeline:
    - {stage: vocabulary, slot_floor: {fr: 0.45}}'

check "a map naming one language loads" "$code" "0"
check "and the language it misses keeps its built-in floor" \
  "$(floor en)/$(floor fr)" "0.20/0.45"

run_config floor_bad 'transcription:
  languages: [en]
  pipeline:
    - {stage: vocabulary, slot_floor: 0}'

check "a floor of 0 on the step is refused" "$code" "1"
check "and the message names the key that was written" \
  "$(printf '%s\n' "$out" | grep -c 'pipeline.vocabulary.slot_floor')" "1"
check "and says what a floor may be, as it always has" \
  "$(printf '%s\n' "$out" | grep -c 'a number above 0 and at most 2')" "1"

run_config floor_bad_map 'transcription:
  languages: [en, fr]
  pipeline:
    - {stage: vocabulary, slot_floor: {en: 0.20, fr: 3}}'

check "an out-of-range language in a map is refused" "$code" "1"
check "and the message names that language" \
  "$(printf '%s\n' "$out" | grep -c 'pipeline.vocabulary.slot_floor.fr')" "1"

run_config floor_bad_shape 'transcription:
  languages: [en]
  pipeline:
    - {stage: vocabulary, slot_floor: "0.20"}'

check "a floor that is neither a number nor a map is refused" "$code" "1"
check "and the message shows both spellings" \
  "$(printf '%s\n' "$out" | grep -c 'slot_floor: {en: 0.20, fr: 0.30}')" "1"

# --- the legacy floor ---------------------------------------------------------
#
# `transcription.per_language` is legacy now that both of its keys live on a
# step. It is still read, and it still feeds a step that names no floor.

run_config floor_legacy 'transcription:
  languages: [en, fr]
  per_language:
    fr: {slot_floor: 0.45}
  pipeline:
    - vocabulary'

check "the old per_language floor loads" "$code" "0"
check "and feeds the step" "$(floor en)/$(floor fr)" "0.20/0.45"
check "and the notice says the block is legacy" \
  "$(printf '%s\n' "$out" | grep -c '`transcription.per_language` is legacy')" "1"

run_config floor_both 'transcription:
  languages: [en, fr]
  per_language:
    fr: {slot_floor: 0.45}
  pipeline:
    - {stage: vocabulary, slot_floor: {fr: 0.35}}'

check "both homes for the floor loads" "$code" "0"
check "and the step wins, the language it misses taking its built-in" \
  "$(floor en)/$(floor fr)" "0.20/0.35"
check "and the notice says the step is what runs" \
  "$(printf '%s\n' "$out" | grep -c 'the step is what runs')" "1"

run_config floor_legacy_bad 'transcription:
  languages: [en]
  per_language:
    en: {slot_floor: 0}'

check "an out-of-range legacy floor is refused as it always was" "$code" "1"
check "and still names its own key" \
  "$(printf '%s\n' "$out" | grep -c 'transcription.per_language.en.slot_floor')" "1"

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
  "$(stages)" "interpret → numbers  (nothing configured, so every stage)"

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
  "$(stages)" "interpret → numbers  (nothing configured, so every stage)"

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
  "$(stages)" "interpret → numbers  (nothing configured, so every stage)"

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
