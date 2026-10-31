#!/usr/bin/env bash
# Checks `--serve`: one process, one JSON request per line, one answer per line.
#
#   scripts/check-serve.sh
#
# One server is driven through a pipe, request by request, so the files can be
# read between two answers. Every write is replayed through the separate flags
# on a second scratch directory, and the two must print the same lines and
# leave the same bytes. No model: the word lists settle every place here.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

WORK="$(mktemp -d -t parrotflow-serve)"
SERVER=""
cleanup() {
  exec 3>&- 4<&- 2>/dev/null
  [ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
# Its own home, so the log and the caches are this run's and a machine with
# the models behaves like one without.
export CFFIXED_USER_HOME="$WORK/home"
mkdir -p "$WORK/home" "$WORK/serve" "$WORK/cli"
for dir in serve cli; do
  printf 'transcription:\n  languages: [en]\n' > "$WORK/$dir/config.yaml"
done
cat > "$WORK/fixture.yaml" <<'EOF'
languages: [en]
vocabulary:
  terms:
    Zorblix:
      pronunciations:
        - heard: Zorbly
pipeline:
  - vocabulary
EOF

pass=0; total=0
check() {
  total=$((total + 1))
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
  else
    printf '  ✗ %s\n      want  %s\n      got   %s\n' "$1" "$3" "$2"
  fi
}

mkfifo "$WORK/in" "$WORK/out"
PARROTFLOW_CONFIG_DIR="$WORK/serve" "$BIN" --serve < "$WORK/in" > "$WORK/out" 2>/dev/null &
SERVER=$!
exec 3>"$WORK/in" 4<"$WORK/out"

ask() {
  printf '%s\n' "$1" >&3
  IFS= read -r -t 60 reply <&4 || reply=""
  printf '%s' "$reply"
}
# One field of an answer: a string as is, a list one item per line.
field() {
  python3 -c '
import json, sys
value = json.loads(sys.argv[1])
for key in sys.argv[2].split("/"):
    value = value.get(key) if isinstance(value, dict) else None
if isinstance(value, list):
    print("\n".join(str(v) for v in value))
elif value is not None:
    print(value if not isinstance(value, bool) else str(value).lower())
' "$1" "$2" 2>/dev/null
}
has() { field "$1" "$2" | grep -c -- "$3"; }
cli() { PARROTFLOW_CONFIG_DIR="$WORK/cli" "$BIN" "$@" 2>/dev/null; }
VOCAB="$WORK/serve/vocabulary.yaml"
USES="$WORK/serve/vocabulary-uses.yaml"
SENTENCE="We ship Zorblix on Friday."

r=$(ask '{"id": 1, "cmd": "reset"}')
check "reset answers code 0" "$(field "$r" code)" "0"
check "and echoes the id" "$(field "$r" id)" "1"
check "reset empties vocabulary.yaml" "$(cat "$VOCAB")" "terms: {}"
check "and vocabulary-uses.yaml" "$(cat "$USES")" "terms: {}"
printf 'terms: {}\n' > "$WORK/cli/vocabulary.yaml"
printf 'terms: {}\n' > "$WORK/cli/vocabulary-uses.yaml"

r=$(ask "{\"id\": 2, \"cmd\": \"learn\", \"heard\": \"Zorbly\", \"corrected\": \"Zorblix\", \"in\": \"$SENTENCE\"}")
check "learn says what --learn says" "$(field "$r" said)" "✓ Zorbly → Zorblix"
check "and the same line as --learn" "$(field "$r" said)" \
  "$(cli --learn Zorbly Zorblix --in "$SENTENCE")"
check "vocabulary.yaml holds the term" "$(python3 -c '
import sys, yaml
term = yaml.safe_load(open(sys.argv[1]))["terms"]["Zorblix"]
print(" ".join(p["heard"] for p in term["pronunciations"]))
' "$VOCAB" 2>/dev/null)" "Zorbly"
check "vocabulary-uses.yaml holds the sentence" "$(python3 -c '
import sys, yaml
print(yaml.safe_load(open(sys.argv[1]))["terms"]["Zorblix"][0]["said"])
' "$USES" 2>/dev/null)" "$SENTENCE"

cp "$VOCAB" "$WORK/vocab-before"; cp "$USES" "$WORK/uses-before"
r=$(ask "{\"id\": \"three\", \"cmd\": \"dictate\", \"fixture\": \"$WORK/fixture.yaml\", \"text\": \"We ship Zorbly on Friday.\"}")
check "dictate echoes a string id" "$(field "$r" id)" "three"
check "dictate answers the rewritten sentence" "$(field "$r" out)" "$SENTENCE"
check "and the same one as --pipeline --quiet" "$(field "$r" out)" \
  "$(cli --pipeline "$WORK/fixture.yaml" "We ship Zorbly on Friday." --quiet)"
check "vars carries the slot count" "$(field "$r" vars/vocabulary.slots)" "1"
check "and the language as --vars prints it" "$(field "$r" vars/language)" '"en"'
check "log carries the stage's census line" "$(has "$r" log '^vocabulary: 1 slot(s) from ')" "1"
check "and the gate's decision" \
  "$(has "$r" log 'vocabulary gate: "Zorbly" -> "Zorblix" is in neither word list')" "1"
check "dictate writes no vocabulary" "$(cmp -s "$VOCAB" "$WORK/vocab-before" && cmp -s "$USES" "$WORK/uses-before" && echo same)" "same"

r=$(ask '{"id": 4, "cmd": "correction", "wrote": "Zorblix", "put": "zorbly", "in": "The zorbly cat sat down."}')
check "correction says a counter" "$(field "$r" said)" 'counter Zorblix "zorbly"'
check "and the same line as --correction" "$(field "$r" said)" \
  "$(cli --correction Zorblix zorbly --in "The zorbly cat sat down.")"
check "no line from the last dictation leaks into its log" "$(has "$r" log '^sentence gate:')" "0"

r=$(ask '{"id": 5, "cmd": "picked", "word": "Zorbly", "term": "Zorblix", "in": "Zorbly is on the call."}')
check "picked says a counter" "$(field "$r" said)" "counter Zorblix"
check "and the same line as --picked" "$(field "$r" said)" \
  "$(cli --picked Zorbly Zorblix --in "Zorbly is on the call.")"
check "vocabulary.yaml matches the separate commands' byte for byte" \
  "$(cmp -s "$VOCAB" "$WORK/cli/vocabulary.yaml" && echo same)" "same"
check "and vocabulary-uses.yaml too" \
  "$(cmp -s "$USES" "$WORK/cli/vocabulary-uses.yaml" && echo same)" "same"

r=$(ask 'not json')
check "a line that is not JSON answers an error" "$(field "$r" error)" "not a JSON object"
r=$(ask '{"id": 6, "cmd": "nope"}')
check "an unknown command answers an error with its id" "$(field "$r" id) $(field "$r" error)" \
  '6 "nope" is not a command'
r=$(ask '{"id": 7, "cmd": "learn", "heard": "Zorbly"}')
check "a missing field answers an error" "$(field "$r" error)" \
  '"corrected" is missing or not a string'

r=$(ask '{"id": 8, "cmd": "reset"}')
check "the server still answers after bad lines" "$(field "$r" code)" "0"
check "reset empties vocabulary.yaml again" "$(cat "$VOCAB")" "terms: {}"
check "and vocabulary-uses.yaml" "$(cat "$USES")" "terms: {}"

exec 3>&-
wait "$SERVER"
check "end of input exits 0" "$?" "0"
SERVER=""

# Without a scratch config dir, reset would empty the vocabulary someone
# dictates with. HOME is this run's, so the config it would have hit is too.
mkdir -p "$WORK/home/.config/parrotflow"
printf 'terms:\n  Zorblix:\n' > "$WORK/home/.config/parrotflow/vocabulary.yaml"
r=$(printf '{"id": 9, "cmd": "reset"}\n' \
  | env -u PARROTFLOW_CONFIG_DIR HOME="$WORK/home" "$BIN" --serve 2>/dev/null)
check "reset refuses without PARROTFLOW_CONFIG_DIR" "$(field "$r" code)" "1"
check "and leaves the vocabulary alone" "$(head -1 "$WORK/home/.config/parrotflow/vocabulary.yaml")" "terms:"

printf '\n  %d/%d\n' "$pass" "$total"
[ "$pass" -eq "$total" ]
