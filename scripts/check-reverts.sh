#!/usr/bin/env bash
# Checks what happens when somebody takes a vocabulary term back.
#
#   scripts/check-reverts.sh
#
# A revert is a correction in the other direction: the app wrote `Praisy`, the
# speaker meant "praise". It used to write `"praise": ["Praisy"]` into
# `config.yaml`, which rewrote *every* `Praisy` into "praise" from then on —
# one revert disabling the term, in a file `--forget` could not reach.
#
# Six things are scored here.
#
#   no rule           nothing is written to `config.yaml`, and nothing to
#                     `vocabulary.yaml` that could fire on text later.
#   the blame         if a rendering fired, its `seen:` count goes down. If
#                     nothing in the files fired, the command says so instead
#                     of inventing a culprit.
#   the negative      the clip lands in `voice/negatives/<Term>/`, never in
#                     `samples/`, and its row says `"polarity":"negative"`.
#   `collides_with:`  the pair is recorded under the term, and is never applied
#                     as a substitution.
#   `--forget`        takes pronunciations, samples, negatives and the
#                     `collides_with` entry back out.
#   old rows          an observation written before `polarity` existed still
#                     reads as a positive.
#
# The forward direction is scored by `scripts/check-corrections.sh`, which this
# leaves alone.
#
# The audio is generated here, not committed: a tone burst in a silent file.
# The cut is frame arithmetic, so a sine wave scores it exactly as a voice
# would, and `scripts/check-no-voice.sh` refuses a repository carrying the real
# thing.
#
# Every case is a whole config directory in /tmp read through
# PARROTFLOW_CONFIG_DIR, so this says nothing about the config on the machine
# and scores the same anywhere.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }
command -v python3 >/dev/null || { echo "python3 is needed to write the test audio"; exit 1; }

WORK="$(mktemp -d -t parrotflow-reverts)"
trap 'rm -rf "$WORK"' EXIT
CLIPS="$WORK/recordings"
mkdir -p "$CLIPS"

pass=0; total=0; failed=""

# wants <name> <text> <substring>
wants() {
  total=$((total + 1))
  if printf '%s' "$2" | grep -qF -- "$3"; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
  else
    failed="$failed
      $1
        wanted: $3
        got:    $(printf '%s' "$2" | tr '\n' '|')"
    printf '  ✗ %s\n' "$1"
  fi
}

# lacks <name> <text> <substring>
lacks() {
  total=$((total + 1))
  if printf '%s' "$2" | grep -qF -- "$3"; then
    failed="$failed
      $1
        did not want: $3
        got:          $(printf '%s' "$2" | tr '\n' '|')"
    printf '  ✗ %s\n' "$1"
  else
    pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
  fi
}

# holds <name> <path> — the file has to exist and not be empty.
holds() {
  total=$((total + 1))
  if [ -s "$2" ]; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
  else
    failed="$failed
      $1 ($2 is missing or empty)"
    printf '  ✗ %s\n' "$1"
  fi
}

# absent <name> <path> — nothing may be there at all.
absent() {
  total=$((total + 1))
  if [ ! -e "$2" ]; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
  else
    failed="$failed
      $1 ($2 exists)"
    printf '  ✗ %s\n' "$1"
  fi
}

# same <name> <got> <wanted> — an exact match, for a count.
same() {
  total=$((total + 1))
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
  else
    failed="$failed
      $1
        wanted: $3
        got:    $2"
    printf '  ✗ %s (got %s)\n' "$1" "$2"
  fi
}

# clip <name> — three seconds at 16 kHz, with a burst from 1.00s to 1.50s.
clip() {
  python3 - "$CLIPS/$1" <<'PY'
import math, struct, sys, wave
rate, seconds = 16000, 3.0
with wave.open(sys.argv[1], "wb") as f:
    f.setnchannels(1); f.setsampwidth(2); f.setframerate(rate)
    frames = bytearray()
    for n in range(int(rate * seconds)):
        t = n / rate
        loud = 1.0 <= t < 1.5
        frames += struct.pack("<h", int(12000 * math.sin(2 * math.pi * 440 * t)) if loud else 0)
    f.writeframes(bytes(frames))
PY
}

# traced <wav> <lang> <final> <word:start:end>... — one dictation line.
#
# `final` is what was *delivered*, so for a revert it holds the term. The word
# times are the decoder's own, from before any vocabulary stage ran, so they
# hold the ordinary word. That difference is the whole point of the case.
traced() {
  local wav="$1" lang="$2" final="$3"; shift 3
  python3 - "$CLIPS/trace.jsonl" "$wav" "$lang" "$final" "$@" <<'PY'
import json, sys
path, wav, lang, final, *words = sys.argv[1:]
row = {"v": 2, "kind": "dictation", "at": "2026-08-09T10:00:00Z", "wav": wav,
       "source": "live", "lang": lang, "final": final,
       "asr": {"model": "test", "text": final, "confidence": 0.9, "duration": 3.0,
               "processing": 0.1,
               "words": [{"word": w.split(":")[0], "start": float(w.split(":")[1]),
                          "end": float(w.split(":")[2]), "confidence": 0.9} for w in words]},
       "stages": []}
with open(path, "a") as f:
    f.write(json.dumps(row) + "\n")
PY
}

# fresh [<vocabulary body>] — a config directory with nothing learnt in it.
fresh() {
  rm -rf "$WORK/voice" "$CLIPS" "$WORK/vocabulary.yaml"
  mkdir -p "$CLIPS"
  printf 'transcription:\n  languages: [en, fr]\n  replacements:\n    "CLAUDE.md": ["claude dot MD"]\naudio:\n  output_dir: %s\n' \
    "$CLIPS" > "$WORK/config.yaml"
  if [ $# -gt 0 ]; then
    printf '%b' "$1" > "$WORK/vocabulary.yaml"
  else
    printf 'acoustic: true\nterms:\n  Praisy:\n    pronunciations:\n      - heard: praise\n        seen: 2\n        from: correction\n  Supabase:\n' \
      > "$WORK/vocabulary.yaml"
  fi
}

# said <term> <word> [args...] — a revert, with the clip already traced.
said() {
  PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --learn "$1" "$2" "${@:3}" 2>/dev/null
}

# ── a revert writes no rule, and counts the rendering down ──────────────────
printf '\n  a revert of a term the speaker did not say\n'
fresh
clip one.wav
traced one.wav fr "I said Praisy again" "i:0.10:0.30" "said:0.40:0.90" \
  "praise:1.00:1.50" "again:1.60:2.20"
got="$(said Praisy praise)"
wants "it says the term was taken back" "$got" "took the term back, no rule written"
wants "and why no rule was written"     "$got" \
  'no rule written — a rule here would rewrite every Praisy into "praise"'

config="$(cat "$WORK/config.yaml")"
lacks "config.yaml gets no rule"        "$config" "praise"
wants "and the rule already there stays" "$config" '"CLAUDE.md": ["claude dot MD"]'

vocab="$(cat "$WORK/vocabulary.yaml")"
lacks "vocabulary.yaml gets no rendering for the term" "$vocab" "heard: Praisy"
wants "the rendering that fired is counted down"       "$got" \
  'Praisy: "praise" fired and is now seen 1 time(s)'
wants "and the file says so"                           "$vocab" "seen: 1"

# ── the negative clip, and where it is not ─────────────────────────────────
printf '\n  the audio kept as a negative\n'
wants "it says where the audio went" "$got" \
  "kept the audio as voice/negatives/Praisy/00-praise.wav"
holds  "the clip is under negatives/" "$WORK/voice/negatives/Praisy/00-praise.wav"
absent "and nothing at all under samples/" "$WORK/voice/samples"

row="$(cat "$WORK/voice/observations.jsonl")"
wants "the row names the term"          "$row" '"term":"Praisy"'
wants "and the ordinary word that was said" "$row" '"heard":"praise"'
wants "and says which way it points"    "$row" '"polarity":"negative"'
wants "and where the clip went"         "$row" '"sample":"negatives/Praisy/00-praise.wav"'
wants "and the span inside the clip"    "$row" '"span":[1,1.5]'
wants "and the clip it came out of"     "$row" '"wav":"one.wav"'
wants "and the language it was said in" "$row" '"lang":"fr"'
wants "and the build that cut it"       "$row" "\"build\":\"$("$BIN" --version)\""

# ── collides_with, written and never applied ───────────────────────────────
printf '\n  collides_with\n'
wants "the pair is recorded"     "$vocab" "collides_with:"
wants "with the ordinary word"   "$vocab" "- word: praise"
wants "how often it was reverted" "$vocab" "reverted: 1"
wants "and how many clips back it" "$vocab" "clips: 1"
wants "and the command says the same" "$got" \
  'collides_with "praise": reverted 1 time(s), 1 clip(s)'

# A rendering seen twice and reverted once still stands at one, and still
# fires. That is the point of counting down by one instead of deleting: one
# revert must not disable a rendering the speaker produces regularly, which is
# the same bug this change fixes, pointing the other way.
replaced="$(PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --replace "I said praise again" 2>/dev/null)"
wants "a rendering that survives the count-down still fires" "$replaced" "Praisy"

# A second revert of the same pair counts up rather than writing a second entry.
clip two.wav
traced two.wav en "Praisy again" "praise:1.00:1.50" "again:1.60:2.20"
got="$(said Praisy praise)"
wants "a second revert counts up" "$got" 'collides_with "praise": reverted 2 time(s), 2 clip(s)'
same "and there is still one entry" \
  "$(grep -c -- '- word: praise' "$WORK/vocabulary.yaml")" "1"
same "and two clips under negatives/" \
  "$(ls "$WORK/voice/negatives/Praisy" | wc -l | tr -d ' ')" "2"

# ── the rendering that stood on one sighting ───────────────────────────────
printf '\n  a rendering seen once, and now contradicted\n'
fresh 'acoustic: true\nterms:\n  Praisy:\n    pronunciations:\n      - heard: praise\n        seen: 1\n        from: correction\n'
clip three.wav
traced three.wav en "Praisy" "praise:1.00:1.50"
got="$(said Praisy praise)"
wants "it goes, and says why" "$got" \
  'Praisy: dropped "praise" — one sighting, one revert, nothing left'
lacks "and it leaves vocabulary.yaml" "$(cat "$WORK/vocabulary.yaml")" "heard: praise"
wants "the collision is still recorded" "$(cat "$WORK/vocabulary.yaml")" "- word: praise"

# ── a rendering with no count behind it ────────────────────────────────────
printf '\n  a legacy rendering, which was never counted\n'
fresh 'acoustic: true\nterms:\n  Praisy: [praise]\n'
clip four.wav
traced four.wav en "Praisy" "praise:1.00:1.50"
got="$(said Praisy praise)"
wants "it says there is nothing to count down" "$got" \
  'Praisy: "praise" fired and was never counted'
wants "and leaves the entry where it is" "$(cat "$WORK/vocabulary.yaml")" "heard: [praise]"

# ── nothing in the files fired ─────────────────────────────────────────────
printf '\n  a term the acoustic pass proposed on its own\n'
fresh 'acoustic: true\nterms:\n  Praisy:\n  Supabase:\n'
clip five.wav
traced five.wav en "Praisy" "praise:1.00:1.50"
got="$(said Praisy praise)"
wants "it says nothing can be blamed" "$got" \
  "Praisy: nothing in the files fired, so the acoustic pass proposed it"
wants "and the clip is still kept" "$got" "kept the audio as voice/negatives/Praisy/"
wants "and the pair is still recorded" "$(cat "$WORK/vocabulary.yaml")" "- word: praise"

# `collides_with:` on its own, with no rendering anywhere near it. This is the
# case that proves it is a record and not a rule: `--replace` runs every
# deterministic substitution pass over a line, including the one
# `vocabulary.yaml` feeds.
replaced="$(PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --replace "I said praise again" 2>/dev/null)"
wants "a collision is never substituted" "$replaced" "I said praise again"
lacks "and the term is not written over the word" "$replaced" "Praisy"

# ── a rule somebody wrote by hand ──────────────────────────────────────────
printf '\n  a rule written into config.yaml by hand\n'
fresh 'acoustic: true\nterms:\n  Praisy:\n'
printf 'transcription:\n  languages: [en]\n  replacements:\n    Praisy: [praise]\naudio:\n  output_dir: %s\n' \
  "$CLIPS" > "$WORK/config.yaml"
clip six.wav
traced six.wav en "Praisy" "praise:1.00:1.50"
got="$(said Praisy praise)"
wants "it is named" "$got" 'a rule you wrote in config.yaml maps "praise" to it'
wants "and left alone" "$(cat "$WORK/config.yaml")" "Praisy: [praise]"

# ── a revert with no audio behind it ───────────────────────────────────────
printf '\n  a revert with no dictation behind it\n'
fresh
got="$(said Praisy praise)"
wants "it says there is no trace line" "$got" "no trace line for this dictation"
wants "the pair is recorded anyway"    "$(cat "$WORK/vocabulary.yaml")" "- word: praise"
wants "with no clip behind it"         "$(cat "$WORK/vocabulary.yaml")" "clips: 0"
wants "and the row records why"        "$(cat "$WORK/voice/observations.jsonl")" \
  '"skipped":"no trace line for this dictation"'
wants "and still says which way it points" "$(cat "$WORK/voice/observations.jsonl")" \
  '"polarity":"negative"'

# ── the forward direction is untouched ─────────────────────────────────────
printf '\n  a correction the other way round still behaves\n'
fresh
clip seven.wav
traced seven.wav en "I said praise" "i:0.10:0.30" "said:0.40:0.90" "praise:1.00:1.50"
got="$(said praise Praisy)"
wants "it still learns the rule"   "$got" "✓ praise → Praisy"
wants "and counts the rendering up" "$got" "Praisy: seen 3 time(s), from correction"
wants "and keeps a positive sample" "$got" "kept the audio as voice/samples/Praisy/00-praise.wav"
wants "and its row says so"         "$(cat "$WORK/voice/observations.jsonl")" '"polarity":"positive"'
absent "and writes no negative"     "$WORK/voice/negatives"
lacks  "and no collision"           "$(cat "$WORK/vocabulary.yaml")" "collides_with"

# One term corrected into another is a rendering, not a revert. Both sides name
# a term, so there is a term to keep either way.
printf '\n  one term written where another was said\n'
fresh
clip eight.wav
traced eight.wav en "Supabase" "praisy:1.00:1.50"
got="$(said Praisy Supabase)"
wants "it is learnt as a rendering" "$got" "✓ Praisy → Supabase"
wants "under the term that was meant" "$(cat "$WORK/vocabulary.yaml")" "- heard: Praisy"
lacks "and is not a revert"          "$got" "took the term back"

# ── an observation written before polarity existed ─────────────────────────
printf '\n  a row with no polarity on it\n'
fresh
mkdir -p "$WORK/voice/negatives/Praisy"
for n in $(seq -w 0 24); do : > "$WORK/voice/negatives/Praisy/$n-old.wav"; done
# The row claims a *negative* clip and has no `polarity`, so it reads as a
# positive — which means it confirms nothing about the negative bank, and the
# cap is free to take the oldest file. A row read the other way would protect
# it and the cap would delete a later file instead.
printf '%s\n' \
  '{"at":"2026-08-01T10:00:00Z","term":"Praisy","heard":"old","from":"correction","sample":"negatives/Praisy/00-old.wav"}' \
  > "$WORK/voice/observations.jsonl"
clip nine.wav
traced nine.wav en "Praisy" "praise:1.00:1.50"
got="$(said Praisy praise)"
wants "it is not read as a negative"  "$got" "capped voice/negatives/Praisy/00-old.wav"
wants "so the cap treats it as unvouched" "$got" "oldest unconfirmed"
same "and the bank is back at the cap, 25" \
  "$(ls "$WORK/voice/negatives/Praisy" | wc -l | tr -d ' ')" "25"

# ── --check-config counts the two banks apart ──────────────────────────────
printf '\n  what --check-config says\n'
fresh
clip ten.wav
traced ten.wav en "I said Praisy" "i:0.10:0.30" "said:0.40:0.90" "praise:1.00:1.50"
said Praisy praise >/dev/null
clip eleven.wav
traced eleven.wav en "I said praise" "i:0.10:0.30" "said:0.40:0.90" "praise:1.00:1.50"
said praise Praisy >/dev/null
got="$(PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --check-config 2>/dev/null)"
wants "samples and negatives are counted apart" "$got" "1 sample(s), 1 negative(s)"

# ── --forget takes all four back ───────────────────────────────────────────
printf '\n  --forget after a revert\n'
got="$(PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --forget Praisy 2>/dev/null)"
wants "it forgets the term"  "$got" "✓ forgot Praisy"
wants "the pronunciations go" "$got" "pronunciation(s) from vocabulary.yaml"
wants "the observations go"   "$got" "2 observation(s) from voice/observations.jsonl"
wants "the samples and the negatives go" "$got" "1 sample(s) and 1 negative(s) from"
wants "and the collides_with entry"      "$got" "1 collides_with entr(ies) from vocabulary.yaml"
vocab="$(cat "$WORK/vocabulary.yaml")"
lacks  "vocabulary.yaml has no collision left" "$vocab" "collides_with"
lacks  "and no rendering left"                 "$vocab" "heard:"
absent "the negatives folder is gone"          "$WORK/voice/negatives/Praisy"
absent "and the samples folder too"            "$WORK/voice/samples/Praisy"
got="$(PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --check-config 2>/dev/null)"
status=$?
total=$((total + 1))
if [ $status -eq 0 ] && ! printf '%s' "$got" | grep -q '  ✗ vocabulary'; then
  pass=$((pass + 1)); printf '  ✓ and --check-config is clean afterwards\n'
else
  failed="$failed
      --check-config is clean afterwards"
  printf '  ✗ and --check-config is clean afterwards\n'
fi

printf '\n  %d/%d\n' "$pass" "$total"
if [ -n "$failed" ]; then
  printf '  failed:%s\n' "$failed"
  exit 1
fi
