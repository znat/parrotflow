#!/usr/bin/env bash
# What `--schema` prints, and which keys `--check-config` warns about.
#
#   scripts/check-schema.sh
#
# The schema is a table beside the parser. `--schema` refuses when the two
# disagree, so running it here is the drift guard. The warnings are checked
# both ways: none for a config that uses only real keys, one for each typo.
#
# tests/pipelines/ holds `--pipeline` fixtures, not configs. Each is rewritten
# into the config it stands for: `languages`, `pipeline` and `replacements` go
# under `transcription:`, and `vocabulary` becomes vocabulary.yaml. Only the
# `⚠` lines are read; those configs fail for other reasons on purpose.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

WORK="$(mktemp -d -t parrotflow-schema)"
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

# Runs --check-config on $WORK/<name>/config.yaml.
run_config() {
  out="$(PARROTFLOW_CONFIG_DIR="$WORK/$1" "$BIN" --check-config 2>/dev/null)"
  code=$?
}

warnings() {
  printf '%s\n' "$out" | grep -c '^  ⚠ '
}

# --- the schema -----------------------------------------------------------------

PARROTFLOW_CONFIG_DIR="$WORK/empty" "$BIN" --schema > "$WORK/schema.json" 2> "$WORK/schema.err"
code=$?
check "--schema finds the table and the parser in step" "$code" "0"
[ "$code" = "0" ] || sed 's/^/      /' "$WORK/schema.err"
check "and prints valid JSON Schema" "$(python3 -c '
import json, sys
schema = json.load(open(sys.argv[1]))
print(schema.get("$schema"))' "$WORK/schema.json" 2>&1)" \
  "https://json-schema.org/draft/2020-12/schema"

# --- configs that use only real keys --------------------------------------------

mkdir -p "$WORK/example"
cp "$ROOT/built-in/config.example.yaml" "$WORK/example/config.yaml"
run_config example
check "built-in/config.example.yaml has no unknown key" "$(warnings)" "0"
example_code=$code

converted=0
for fixture in "$ROOT"/tests/pipelines/*.yaml "$ROOT"/tests/pipelines/refused/*.yaml; do
  name="${fixture#"$ROOT"/tests/pipelines/}"
  dir="$WORK/fixtures/${name%.yaml}"
  mkdir -p "$dir"
  python3 - "$fixture" "$dir" <<'PY' || continue
import pathlib, sys, yaml

fixture, out = sys.argv[1], pathlib.Path(sys.argv[2])
try:
    data = yaml.safe_load(open(fixture)) or {}
except yaml.YAMLError:
    sys.exit(1)
config, transcription = {}, {}
for key in ("languages", "pipeline", "replacements"):
    if key in data:
        transcription[key] = data.pop(key)
if transcription:
    config["transcription"] = transcription
vocabulary = data.pop("vocabulary", None)
config.update(data)
yaml.safe_dump(config, open(out / "config.yaml", "w"), allow_unicode=True, sort_keys=False)
if vocabulary is not None:
    yaml.safe_dump(vocabulary, open(out / "vocabulary.yaml", "w"), allow_unicode=True)
PY
  converted=$((converted + 1))
  run_config "fixtures/${name%.yaml}"
  # Warnings come after a successful decode, so a config that fails to load
  # would pass with none.
  loaded="$(printf '%s\n' "$out" | grep -q '^  · pipeline' && echo loads || echo "does not load")"
  check "tests/pipelines/$name loads, with no unknown key" "$loaded, $(warnings)" "loads, 0"
  [ "$(warnings)" = "0" ] || printf '%s\n' "$out" | grep '^  ⚠ ' | sed 's/^/    /'
done
check "the fixtures were read at all" "$([ "$converted" -gt 30 ] && echo yes)" "yes"

# --- two typos ------------------------------------------------------------------

mkdir -p "$WORK/typos"
python3 - "$ROOT/built-in/config.example.yaml" "$WORK/typos/config.yaml" <<'PY'
import sys
text = open(sys.argv[1]).read()
assert "\nfeedback:\n" in text
text = text.replace("\nfeedback:\n", "\nfeedback:\n  sounds: false\n", 1)
open(sys.argv[2], "w").write("hotkey_typo: f5\n" + text)
PY
run_config typos
check "a top-level typo is named" \
  "$(printf '%s\n' "$out" | grep -cx '  ⚠ hotkey_typo: not a setting.')" "1"
check "a nested typo is named, with the key meant" \
  "$(printf '%s\n' "$out" | grep -cxF '  ⚠ feedback.sounds: not a setting. Did you mean "sound"?')" "1"
check "and nothing else is" "$(warnings)" "2"
check "a warning does not change the exit code" "$code" "$example_code"

# --- typos in lists and either-of keys, beside sections that take any key ---------

mkdir -p "$WORK/nested"
cat > "$WORK/nested/config.yaml" <<'YAML'
transcription:
  languages: [en]
  interpret:
    enabld: true
  pipeline:
    - transform: fillers
      wen: language == "fr"
models:
  my-own-name:
    api: ollama
    model: gemma4:e4b-mlx
    params: {anything_goes: 1}
commands:
  catch_all: {use: my-own-name, temprature: 0.2}
lists:
  whatever_i_want: ["a", "b"]
transforms:
  - name: fillers
    description: delete hesitation sounds
    promt: unused
    replace:
      "": ['/\buh\b/']
  - name: table
    description: a table read from a file
    replace: {path: table.yaml, typo: true}
YAML
run_config nested
check "a typo on a pipeline step is named by its position" \
  "$(printf '%s\n' "$out" | grep -cxF '  ⚠ transcription.pipeline[0].wen: not a setting. Did you mean "when"?')" "1"
check "a typo in a transform is named by the transform" \
  "$(printf '%s\n' "$out" | grep -cxF '  ⚠ transforms[fillers].promt: not a setting. Did you mean "prompt"?')" "1"
check "a typo in catch_all's mapping is named" \
  "$(printf '%s\n' "$out" | grep -cxF '  ⚠ commands.catch_all.temprature: not a setting. Did you mean "temperature"?')" "1"
check "a typo under a deprecated block that is still read is named" \
  "$(printf '%s\n' "$out" | grep -cxF '  ⚠ transcription.interpret.enabld: not a setting. Did you mean "enabled"?')" "1"
check "a key beside a replace: file reference is named" \
  "$(printf '%s\n' "$out" | grep -cx '  ⚠ transforms\[table\]\.replace\.typo: not a setting\.')" "1"
check "model names, lists, params and a replace table take any key" "$(warnings)" "5"

# --- a config that does not load still names its typos -------------------------

mkdir -p "$WORK/broken"
printf 'hotkey:\n  mode: sideways\n  moed: toggle\n' > "$WORK/broken/config.yaml"
run_config broken
check "a value the parser refuses fails the check" "$code" "1"
check "and a typo beside it is still named" \
  "$(printf '%s\n' "$out" | grep -cxF '  ⚠ hotkey.moed: not a setting. Did you mean "mode"?')" "1"

echo
echo "  $pass/$total$failed"
[ "$pass" = "$total" ]
