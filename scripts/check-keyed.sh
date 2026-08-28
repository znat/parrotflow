#!/usr/bin/env bash
# Scores the keyed path against tests/keyed-cases.yaml.
#
#   scripts/check-keyed.sh
#
# Tap-and-hold: a key said this was an instruction, so there is no router in
# the path. A name anywhere in the sentence wins; everything else is the
# catch-all. That is the whole decision, and it costs no model call — this runs
# in under a second, unlike check-routing.sh, which is a round trip per case.
#
# The catalogue is written here rather than read from your config. A set that
# inherits whichever transforms happen to be on the machine only means
# something on that machine, and what is being scored is a matcher against a
# list — the list is half the question. Same argument as
# tests/routing-cases.yaml makes for itself.
#
# What a failure costs is not symmetrical, so read the two groups at the end.
# A name that misses does not degrade to a slightly worse rewrite: the
# catch-all is a prompt, and most of these tools are not. "flag this" sent to
# ANY does not file your text, it rewords it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
CASES="$ROOT/tests/keyed-cases.yaml"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

WORK="$(mktemp -d -t parrotflow-keyed)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/config.yaml" <<'YAML'
transcription:
  languages: [en]
models:
  local:
    api: ollama
    model: gemma4:e4b
    default: true
transforms:
  - name: bullets
    description: turn the text into a bullet list
    prompt: "Rewrite as bullets."
  - name: terse
    description: make the text shorter
    prompt: "Shorten."
  - name: slack_handles
    description: turn names into slack handles
    say: [slack handles, handles]
    command: 'true'
  - name: flag
    description: save this dictation to look at later
    say: [flag this, save this for later]
    command: 'true'
  - name: punctuation
    description: fix spoken punctuation
    command: 'true'
  - name: repetitions
    description: drop repeated words
    command: 'true'
  - name: dotted
    description: spoken dotted paths as code
    replace:
      "$1.": ['/(\w+) dot (?=\w)/']
YAML

pass=0; total=0; missed=""; forced=""

route() { PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --route "$1" --keyed --quiet 2>/dev/null | tail -1; }

while IFS='|' read -r instruction want; do
  [ -z "$instruction" ] && continue
  total=$((total + 1))
  got="$(route "$instruction")"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    printf '  ✓ %-46s %s\n' "$instruction" "$got"
  else
    printf '  ✗ %-46s got %s, want %s\n' "$instruction" "$got" "$want"
    # A name that fell through to the catch-all is the expensive failure: the
    # tool it named is a script or a table, and a prompt cannot stand in for
    # one. The other direction only costs a rewrite that was not asked for.
    if [ "$got" = "ANY" ]; then
      missed="$missed
      $instruction → wanted $want"
    else
      forced="$forced
      $instruction → $got, wanted $want"
    fi
  fi
done < <(
  awk '
    /^  - instruction: / { sub(/^  - instruction: /, ""); ins = $0; next }
    /^    expect: /      { sub(/^    expect: /, ""); if (ins != "") print ins "|" $0; ins = "" }
  ' "$CASES"
)

printf '\n  %d/%d\n' "$pass" "$total"
[ -n "$missed" ] && printf '\n  named a tool and did not reach it (a script did not run):%s\n' "$missed"
[ -n "$forced" ] && printf '\n  reached the wrong tool:%s\n' "$forced"
[ "$pass" = "$total" ] || exit 1
