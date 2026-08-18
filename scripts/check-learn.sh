#!/usr/bin/env bash
# Checks that `--learn` writes into vocabulary.yaml, not config.yaml.
#
#   scripts/check-learn.sh
#
# The correction panel and the "hey parrot, <name> spells ..." voice command
# call the same code this does. A name is a pronunciation, not a pattern, so
# it belongs beside the pronunciations the acoustic pass finds on its own —
# `config.yaml`'s `transcription.replacements` stays for patterns and
# deletions, which `--learn` never touches.
#
# `vocabulary.yaml` has been written by hand five different ways over time —
# a bare term, a legacy `floor:` number, a shorthand list, and a block with or
# without `pronunciations:` already in it — and every one of those has to
# still be valid YAML with the new rendering spliced in, not just the shape a
# fresh install starts with.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

WORK="$(mktemp -d -t parrotflow-learn)"
trap 'rm -rf "$WORK"' EXIT
printf 'transcription:\n  languages: [en]\n' > "$WORK/config.yaml"

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

learn() {
  PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --learn "$1" "$2" ${3+"$3"} >/dev/null 2>&1
}
vocab() { cat "$WORK/vocabulary.yaml"; }
config() { cat "$WORK/config.yaml"; }

# --- a fresh install: `terms: {}` becomes a block ---------------------------
printf 'terms: {}\n' > "$WORK/vocabulary.yaml"
learn "super base" Supabase
wants "a new term is added"          "$(vocab)" "Supabase:"
wants "with its rendering"           "$(vocab)" "heard: super base"
wants "and its provenance"           "$(vocab)" "from: correction"
rejects "config.yaml is untouched"   "$(config)" "replacements"

# --- a second rendering of the same term appends, does not duplicate -------
learn superbees Supabase
wants "a second rendering is added"  "$(vocab)" "heard: superbees"
n="$(grep -c 'heard: super base' "$WORK/vocabulary.yaml")"
total=$((total + 1))
if [ "$n" = "1" ]; then
  pass=$((pass + 1)); printf '  ✓ the first rendering is still there once\n'
else
  failed="$failed
      the first rendering is still there once"
  printf '  ✗ the first rendering is still there once\n      got %s\n' "$n"
fi

# --- learning the same rendering again is a no-op ---------------------------
before="$(vocab)"
learn superbees Supabase
total=$((total + 1))
if [ "$(vocab)" = "$before" ]; then
  pass=$((pass + 1)); printf '  ✓ a repeated rendering changes nothing\n'
else
  failed="$failed
      a repeated rendering changes nothing"
  printf '  ✗ a repeated rendering changes nothing\n'
fi

# --- an existing shorthand list gets appended to, not replaced --------------
printf 'terms:\n  Redcrawl: [Redcroll, red crawl]\n' > "$WORK/vocabulary.yaml"
learn "Red Croll" Redcrawl
wants "the old renderings survive"   "$(vocab)" "Redcroll, red crawl, Red Croll"

# --- a rendering that is a substring of an existing one is not a duplicate --
# Greptile found this one: "Press" is not "Pressy", and a bare `contains`
# over the joined list text said it was, so the write was silently skipped.
printf 'terms:\n  Praisy: [Prissy, Pressy]\n' > "$WORK/vocabulary.yaml"
learn Press Praisy
wants "the shorter rendering is still added" "$(vocab)" "Prissy, Pressy, Press"
before="$(vocab)"
learn Pressy Praisy
total=$((total + 1))
if [ "$(vocab)" = "$before" ]; then
  pass=$((pass + 1)); printf '  ✓ the exact rendering it is a substring of still no-ops\n'
else
  failed="$failed
      the exact rendering it is a substring of still no-ops"
  printf '  ✗ the exact rendering it is a substring of still no-ops\n'
fi

# --- a single-line flow mapping keeps its `heard:` list -------------------
# Greptile found this one too: the writer did not recognise `{...}` on the
# term's own line, fell through to the legacy-floor branch, and shoved the
# whole mapping under a `floor:` key — which the decoder cannot read back as
# pronunciations, so the old renderings were reachable only by their raw
# text, not as terms the sound search or the exact pass would ever find.
printf 'terms:\n  Claude: {floor: off, heard: [cloud]}\n' > "$WORK/vocabulary.yaml"
learn cloude Claude
wants "floor: off survives the rewrite"   "$(vocab)" "floor: off"
wants "the old heard: list survives"      "$(vocab)" "heard: [cloud]"
wants "the new rendering is added beside it" "$(vocab)" "heard: cloude"
got="$(PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --check-config 2>&1)"
wants "and both renderings are read back" "$got" "1 terms in vocabulary.yaml, 0 matched by sound, 2 by rule"
before="$(vocab)"
learn cloud Claude
total=$((total + 1))
if [ "$(vocab)" = "$before" ]; then
  pass=$((pass + 1)); printf '  ✓ a duplicate inside the old heard: list still no-ops\n'
else
  failed="$failed
      a duplicate inside the old heard: list still no-ops"
  printf '  ✗ a duplicate inside the old heard: list still no-ops\n'
fi

# --- a block-style (not flow-mapping) `heard:` list is also recognised -----
printf 'terms:\n  Praisy:\n    heard: [Prissy, Pressy]\n' > "$WORK/vocabulary.yaml"
before="$(vocab)"
learn Pressy Praisy
total=$((total + 1))
if [ "$(vocab)" = "$before" ]; then
  pass=$((pass + 1)); printf '  ✓ a duplicate inside a block heard: list no-ops\n'
else
  failed="$failed
      a duplicate inside a block heard: list no-ops"
  printf '  ✗ a duplicate inside a block heard: list no-ops\n'
fi
learn Prezi Praisy
wants "a new rendering still gets a pronunciations block" "$(vocab)" "heard: Prezi"
wants "beside the old heard: list, not instead of it"     "$(vocab)" "heard: [Prissy, Pressy]"

# --- a bare term (nothing known yet) grows a pronunciations block ----------
printf 'terms:\n  Tasmeen:\n' > "$WORK/vocabulary.yaml"
learn Tasmid Tasmeen
wants "a bare term gets pronunciations" "$(vocab)" "pronunciations:"
wants "with the new rendering"          "$(vocab)" "heard: Tasmid"

# --- a legacy floor number moves under its own key, not overwritten --------
printf 'terms:\n  Mirza: 0.85\n' > "$WORK/vocabulary.yaml"
learn Mirsa Mirza
wants "the floor number is kept"        "$(vocab)" "floor: 0.85"
wants "with a pronunciations block added" "$(vocab)" "heard: Mirsa"

# --- a block with `floor:` but no `pronunciations:` yet ---------------------
printf 'terms:\n  Vercel:\n    floor: off\n' > "$WORK/vocabulary.yaml"
learn Versailles Vercel
wants "floor: off is kept"              "$(vocab)" "floor: off"
wants "pronunciations are added beside it" "$(vocab)" "heard: Versailles"

# --- a term found case-insensitively, and one with punctuation -------------
printf 'terms:\n  gpt-4o: [gpt four o]\n' > "$WORK/vocabulary.yaml"
learn "gpt 4 oh" "GPT-4o"
n="$(grep -c '^  gpt-4o' "$WORK/vocabulary.yaml")"
total=$((total + 1))
if [ "$n" = "1" ]; then
  pass=$((pass + 1)); printf '  ✓ a case-insensitive match reuses the existing term\n'
else
  failed="$failed
      a case-insensitive match reuses the existing term"
  printf '  ✗ a case-insensitive match reuses the existing term\n      got %s\n' "$n"
fi

# --- the word kind, which only the correction panel fills in ----------------
printf 'terms:\n  Tasmeen:\n' > "$WORK/vocabulary.yaml"
learn Tasmin Tasmeen person
wants "a bare term takes a kind"           "$(vocab)" "kind: person"
wants "and keeps its pronunciations"       "$(vocab)" "heard: Tasmin"

learn Tasmeene Tasmeen organization
wants "a second correction replaces it"    "$(vocab)" "kind: organization"
rejects "and does not leave the old one"   "$(vocab)" "kind: person"
n="$(grep -c 'kind:' "$WORK/vocabulary.yaml")"
total=$((total + 1))
if [ "$n" = "1" ]; then
  pass=$((pass + 1)); printf '  ✓ one kind line, not two\n'
else
  failed="$failed
      one kind line, not two"
  printf '  ✗ one kind line, not two\n      got %s\n' "$n"
fi

learn Tasmeena Tasmeen
rejects "no kind given leaves it alone"    "$(vocab)" "kind: person"
wants "the existing kind survives"         "$(vocab)" "kind: organization"

# A shorthand list is left as it is. Expanding it would duplicate what
# insertVocabulary does, and `kind` is a label nothing reads yet.
printf 'terms:\n  Praisy: [Prissy]\n' > "$WORK/vocabulary.yaml"
learn Pressy Praisy person
wants "a shorthand list still takes the rendering" "$(vocab)" "Pressy"
rejects "and is not rewritten for a kind"          "$(vocab)" "kind:"

# --- the result always parses -----------------------------------------------
got="$(PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --check-config 2>&1)"
rejects "the last file written still parses" "$got" "could not be read"

printf '\n  %d/%d\n' "$pass" "$total"
if [ -n "$failed" ]; then
  printf '  failed:%s\n' "$failed"
  exit 1
fi
