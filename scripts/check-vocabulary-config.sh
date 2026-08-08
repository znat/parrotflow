#!/usr/bin/env bash
# Checks what `vocabulary.yaml` adds up to, old spellings included.
#
#   scripts/check-vocabulary-config.sh
#
# The file is learnt, not written, so nobody rereads it and a key that quietly
# stops meaning what it meant is invisible. Two things are scored here.
#
#   the two numbers    `offer_below` is the spelling distance at which a
#                      reading still reaches the menu; `decide_above` is how
#                      hard the audio has to argue before it is dropped
#                      instead. They are separate because one threshold could
#                      not do both jobs (F1).
#   the old spellings  a file written before them still loads and still
#                      behaves: `min_similarity:` is read as `offer_below:`, a
#                      per-term `floor:` number still sets that term's, and
#                      `floor: off` still means never matched by sound.
#
# The last one has teeth. Yams answers `Bool.self` for `0.85` — anything that
# is not `true`/`yes`/`on` decodes as `false` — so a decoder that asks about
# `off` before asking about the number reads every measured floor as
# `floor: off` and drops the term from sound matching. That is silent: the file
# loads, the term is simply never found again. Cases 1 and 4 are that bug.
#
# Every case is a whole config directory in /tmp read through
# PARROTFLOW_CONFIG_DIR, so this says nothing about the config on the machine
# and scores the same anywhere.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

WORK="$(mktemp -d -t parrotflow-vocabulary)"
trap 'rm -rf "$WORK"' EXIT
printf 'transcription:\n  languages: [en]\n' > "$WORK/config.yaml"

pass=0; total=0; failed=""

# say <vocabulary.yaml body> — the `vocabulary:` notices of `--check-config`,
# one per line, with the leading marker stripped.
say() {
  printf '%s\n' "$1" > "$WORK/vocabulary.yaml"
  PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --check-config 2>/dev/null \
    | sed -n 's/^  · vocabulary: //p'
}

# complains <vocabulary.yaml body> — the same for the ✗ list, which is what
# `--check-config` exits 1 on.
complains() {
  printf '%s\n' "$1" > "$WORK/vocabulary.yaml"
  PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --check-config 2>/dev/null \
    | sed -n 's/^  ✗ vocabulary: //p'
}

# wants <name> <text> <substring> — the substring has to be in the text.
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

# rejects <name> <text> <substring> — and the substring has to be absent.
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

# --- 1. a per-term floor, the shape every learnt file has ------------------
got="$(say 'acoustic: true
terms:
  Mirza:
    floor: 0.85
  Tasmeen:')"
wants "a legacy floor still sets what that term offers" "$got" "Mirza 0.85"
wants "the other term is on the file default"          "$got" "similarity 0.5 and up"
wants "and the key is called legacy"                   "$got" "is legacy"
wants "with what to write instead"                     "$got" '`offer_below:` at the top of the file'

# --- 2. `floor: off` still means never matched by sound --------------------
got="$(say 'acoustic: true
terms:
  Claude:
    floor: off
    heard: [cloud]
  Tasmeen:')"
wants "off leaves one term matched by sound"  "$got" "2 terms in vocabulary.yaml, 1 matched by sound, 1 by rule"
rejects "and it is not the one turned off"    "$got" "Claude"
rejects "off is not reported as a legacy number" "$got" "is legacy"

# --- 3. `floor: no` is the same switch -------------------------------------
#
# `no` is a YAML 1.1 boolean like `off`, and a term with no `heard` and no
# sound matching can be reached by nothing at all — which is worth saying.
got="$(say 'acoustic: true
terms:
  Matthieu:
    floor: no
  Tasmeen:')"
wants "no means never matched by sound" "$got" "2 terms in vocabulary.yaml, 1 matched by sound, 0 by rule"
wants "and nothing can reach that term"  "$got" "Matthieu — \`floor: off\` and no \`heard\`, so nothing can match them"

# --- 4. no floor anywhere: the shipped defaults ----------------------------
got="$(say 'acoustic: true
terms:
  Tasmeen:')"
wants "the default offer floor"    "$got" "offered at similarity 0.5 and up"
wants "the default decide margin"  "$got" "by more than 3.0 nats"
rejects "and nothing is legacy"    "$got" "is legacy"

# --- 5. the old file-level key ---------------------------------------------
got="$(say 'acoustic: true
min_similarity: 0.75
terms:
  Tasmeen:')"
wants "min_similarity is read as offer_below" "$got" "offered at similarity 0.75 and up"
wants "and named as the old spelling"         "$got" '`min_similarity: 0.75` is the old name for `offer_below:`'

# --- 6. both file-level keys: the new one is the intent --------------------
got="$(say 'acoustic: true
min_similarity: 0.75
offer_below: 0.40
decide_above: 5.5
terms:
  Tasmeen:')"
wants "offer_below wins over min_similarity" "$got" "offered at similarity 0.4 and up"
wants "decide_above is read"                 "$got" "by more than 5.5 nats"

# --- 7. a number in the wrong units is refused, not just reported ----------
#
# Both look exactly like the vocabulary being broken: above 1 nothing ever
# reaches the menu, at or below 0 nats every reading the decoder does not
# already prefer is dropped before anyone sees it. Nothing downstream
# re-checks them, so the value has to be refused where it is read — reporting
# it and running it anyway means every dictation is quietly wrong until
# somebody happens to run this command.
body='acoustic: true
offer_below: 85
decide_above: 0
terms:
  Mirza:
    floor: 12
  Tasmeen:'
got="$(complains "$body")"
wants "a similarity outside 0 to 1 is refused" "$got" '`offer_below: 85.0` is outside 0 to 1'
wants "a margin at 0 nats is refused"          "$got" '`decide_above: 0.0` would drop every'
wants "a per-term floor outside 0 to 1 too"    "$got" '`floor:` on Mirza is outside 0 to 1'

got="$(say "$body")"
wants "and the defaults are what actually run" "$got" \
  "offered at similarity 0.5 and up, dropped when the audio argues against it by more than 3.0 nats"
rejects "the refused per-term number is gone" "$got" "Mirza 12"
rejects "and it is not called legacy either"  "$got" "is legacy"

printf '\n  %d/%d\n' "$pass" "$total"
if [ -n "$failed" ]; then
  printf '  failed:%s\n' "$failed"
  exit 1
fi
