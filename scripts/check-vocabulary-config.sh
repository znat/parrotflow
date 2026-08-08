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
# The offered list, not the whole block: `Claude` also appears in the notice
# naming its legacy `heard:` key, which is a different sentence.
rejects "and it is not the one turned off"    "$got" "— Claude"
rejects "off is not reported as a legacy floor" "$got" "per-term \`floor:\` number"
# A rendering on a term that is never searched for by sound cannot be searched
# for either: it is registered under its term's name, and that name has no
# entry for the spotter to report.
wants "its rendering is a rule and nothing else" "$got" "1 matched exactly only"

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
wants "and nothing can reach that term"  "$got" "Matthieu — \`floor: off\` and no pronunciations, so nothing can match them"

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


# --- 8. `pronunciations:` is the schema, `heard:` is the old spelling --------
#
# Both load, both still work as exact rules, and both are now searched for by
# sound under their term's name — which is the only path to a rendering no
# threshold reaches ("Versailles" is 0.40 from "Vercel"). The difference is
# what the file can say about an entry: a bare string says nothing, so nothing
# can decide later whether it is worth keeping.
got="$(say 'acoustic: true
terms:
  Vercel:
    pronunciations:
      - heard: Versailles
        seen: 3
        from: mined
      - heard: Versal
        seen: 3
        from: mined')"
wants "pronunciations count as rules"      "$got" "1 terms in vocabulary.yaml, 1 matched by sound, 2 by rule"
wants "and they are searched for by sound" "$got" "2 pronunciation(s) searched for by sound"
rejects "the new key is not legacy"        "$got" "is legacy"

got="$(say 'acoustic: true
terms:
  Vercel:
    heard: [Versailles, Versal]')"
wants "the old key loads the same list"    "$got" "1 terms in vocabulary.yaml, 1 matched by sound, 2 by rule"
wants "and is searched for the same way"   "$got" "2 pronunciation(s) searched for by sound"
wants "the old key is named"               "$got" 'renderings on Vercel are written the old way'
wants "with what to write instead"         "$got" 'The setting is `pronunciations:`'

# The shorthand, and both keys at once. A file mid-migration must not lose the
# half that is written the old way.
got="$(say 'acoustic: true
terms:
  Vercel: [Versailles]
  Praisy:
    heard: [Prissy]
    pronunciations:
      - heard: Pressy
        seen: 4
        from: correction')"
wants "the bare-list shorthand still loads" "$got" "2 terms in vocabulary.yaml, 2 matched by sound, 3 by rule"
wants "both keys on one term are kept"      "$got" "3 pronunciation(s) searched for by sound"

# --- 9. a `from:` nobody can read is a note, not a refusal ------------------
#
# It labels a rendering rather than doing anything. Dropping the rendering over
# its label would cost the part that works to protect the part that does not do
# anything yet.
body='acoustic: true
terms:
  Vercel:
    pronunciations:
      - heard: Versailles
        from: guesswork'
got="$(say "$body")"
wants "the rendering still loads"   "$got" "1 pronunciation(s) searched for by sound"
wants "and the label is named"      "$got" 'Vercel/Versailles: `from: guesswork`'
wants "with what it was read as"    "$got" "so it is read as legacy"
got="$(complains "$body")"
rejects "nothing is refused over it" "$got" "from:"

# --- 10. --forget takes a term out of all three places ----------------------
#
# The three files only grow. A rendering learnt from one bad clip goes on
# shaping the audio search forever, and until this the only remedy was to
# hand-edit a file whose own header says not to.
forget_case() {
  printf '%s\n' "$1" > "$WORK/vocabulary.yaml"
  mkdir -p "$WORK/voice/samples/Praisy" "$WORK/voice/samples/Vercel"
  printf '%s\n' \
    '{"at":"2026-08-07T15:21:19","term":"Praisy","heard":"Prissy","from":"mined"}' \
    '{"at":"2026-08-07T15:21:23","term":"Vercel","heard":"Versal","from":"mined"}' \
    '{"at":"2026-08-07T15:21:29","term":"Praisy","heard":"Pressy","from":"mined"}' \
    > "$WORK/voice/observations.jsonl"
  : > "$WORK/voice/samples/Praisy/00-prissy.wav"
  : > "$WORK/voice/samples/Vercel/00-versal.wav"
  PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --forget Praisy 2>/dev/null
}

body='acoustic: true
terms:
  Praisy:
    heard: [Prissy, Pressy,
            Prezi]
  Vercel:
    pronunciations:
      - heard: Versal
        seen: 3
        from: mined'
got="$(forget_case "$body")"
wants "it says how many renderings went"   "$got" "3 pronunciation(s)"
wants "and how many observations"          "$got" "2 observation(s)"
wants "and how many samples"               "$got" "1 sample(s)"

# The file it left behind. A flow sequence wrapped over two lines has to go
# whole — cutting the first line strands the tail as invalid YAML.
got="$(cat "$WORK/vocabulary.yaml")"
rejects "the wrapped list is gone entirely" "$got" "Prezi"
wants "the term itself stays"               "$got" "Praisy:"
wants "and the other term is untouched"     "$got" "heard: Versal"
got="$(cat "$WORK/voice/observations.jsonl")"
rejects "its observations are gone"   "$got" '"term":"Praisy"'
wants "the other term's are not"      "$got" '"term":"Vercel"'
total=$((total + 1))
if [ -d "$WORK/voice/samples/Praisy" ]; then
  failed="$failed
      its samples are gone"
  printf '  ✗ its samples are gone\n'
else
  pass=$((pass + 1)); printf '  ✓ its samples are gone\n'
fi
total=$((total + 1))
if [ -f "$WORK/voice/samples/Vercel/00-versal.wav" ]; then
  pass=$((pass + 1)); printf "  ✓ the other term's samples are not\n"
else
  failed="$failed
      the other term's samples are not"
  printf "  ✗ the other term's samples are not\n"
fi

# And the file it left behind still loads.
got="$(say "$(cat "$WORK/vocabulary.yaml")")"
wants "what is left still parses" "$got" "2 terms in vocabulary.yaml, 2 matched by sound, 1 by rule"

# A quoted key. `'Praisy':` and `"Praisy":` are both legal YAML, and a reader
# that only knows one of them finds no term — which is the dangerous failure:
# the audio and the observations go and the pronunciations stay, so the term
# goes on firing while its evidence is gone.
for quote in "'" '"'; do
  body="acoustic: true
terms:
  ${quote}Praisy${quote}:
    heard: [Prissy, Pressy]
  Vercel:
    heard: [Versal]"
  got="$(forget_case "$body")"
  wants "a ${quote}-quoted key is found"  "$got" "2 pronunciation(s)"
  got="$(cat "$WORK/vocabulary.yaml")"
  rejects "and its renderings are gone"   "$got" "Prissy"
  wants "the key itself is left alone"    "$got" "${quote}Praisy${quote}:"
done

# And when the edit cannot reach the term, nothing else is touched either. A
# `--forget` that deletes the audio and leaves the pronunciations running is
# worse than one that refuses.
printf 'acoustic: true
terms:
  Praisy:
    heard: [Prissy]
' > "$WORK/vocabulary.yaml"
mkdir -p "$WORK/voice/samples/Praisy"
printf '%s
' '{"at":"2026-08-07T15:21:19","term":"Praisy","heard":"Prissy","from":"mined"}'   > "$WORK/voice/observations.jsonl"
: > "$WORK/voice/samples/Praisy/00-prissy.wav"
# The term is there and reachable, so this must succeed — the refusal path is
# exercised by the guard itself, which reads the file back through the decoder.
got="$(PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --forget Praisy 2>/dev/null)"
wants "a reachable term is forgotten"        "$got" "1 pronunciation(s)"
rejects "and nothing is left to complain about" "$got" "still has"

# A shape the text-level edit cannot reach — the whole term body as a flow
# mapping. The refusal is the point: deleting the audio and leaving the
# pronunciations running is worse than doing nothing, because the term goes on
# firing while the evidence for it is gone.
printf 'acoustic: true\nterms:\n  Praisy: {heard: [Prissy, Pressy]}\n' > "$WORK/vocabulary.yaml"
mkdir -p "$WORK/voice/samples/Praisy"
printf '%s\n' '{"at":"2026-08-07T15:21:19","term":"Praisy","heard":"Prissy","from":"mined"}' \
  > "$WORK/voice/observations.jsonl"
: > "$WORK/voice/samples/Praisy/00-prissy.wav"
got="$(PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --forget Praisy 2>/dev/null)"
wants "an unreachable shape is refused" "$got" "still has 2 pronunciation(s)"
wants "and it says nothing else moved"  "$got" "voice/ was left alone"
wants "and that none came out"          "$got" "and none came out"
got="$(cat "$WORK/voice/observations.jsonl")"
wants "the observations are still there" "$got" '"term":"Praisy"'
total=$((total + 1))
if [ -f "$WORK/voice/samples/Praisy/00-prissy.wav" ]; then
  pass=$((pass + 1)); printf '  ✓ and so are the samples\n'
else
  failed="$failed
      and so are the samples"
  printf '  ✗ and so are the samples\n'
fi

# Nothing recorded is not an error. `--forget` is what somebody reaches for
# when they are not sure what is in there.
printf 'acoustic: true\nterms:\n  Praisy:\n' > "$WORK/vocabulary.yaml"
rm -rf "$WORK/voice"
got="$(PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --forget Nothing 2>/dev/null)"
wants "a term with nothing recorded says so" "$got" "nothing recorded for Nothing"

printf '\n  %d/%d\n' "$pass" "$total"
if [ -n "$failed" ]; then
  printf '  failed:%s\n' "$failed"
  exit 1
fi
