#!/usr/bin/env bash
# Checks that a correction keeps the audio, and says what it threw away.
#
#   scripts/check-corrections.sh
#
# A correction used to write one line of YAML. It now also cuts the corrected
# span out of the dictation and files it under `voice/samples/<Term>/`, with a
# row in `voice/observations.jsonl` naming the clip it came from. Four things
# are scored here.
#
#   the three files   a correction on a vocabulary term writes the rendering
#                     into `vocabulary.yaml` with `seen:` and `from:
#                     correction`, a row into `observations.jsonl` carrying
#                     `lang` and the build stamp, and a wav under
#                     `samples/<Term>/`.
#   the guard         a word time that swallowed a pause produces a span no
#                     word can be. It is refused, out loud, with the number —
#                     and the observation still gets written, carrying why
#                     there is no audio. A clip nobody knows is missing is the
#                     failure this whole change is trying to avoid.
#   the cap           a term keeps 25 samples. The oldest *unconfirmed* one
#                     goes first, and what went is printed.
#   `--forget`        takes all three back out and leaves `--check-config`
#                     clean.
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

WORK="$(mktemp -d -t parrotflow-corrections)"
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
        did not want: $3"
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

# seconds <wav> — how long a wav is, to two decimals.
seconds() {
  python3 - "$1" <<'PY'
import sys, wave
with wave.open(sys.argv[1], "rb") as f:
    print("%.2f" % (f.getnframes() / f.getframerate()))
PY
}

fresh() {
  rm -rf "$WORK/voice" "$CLIPS" "$WORK/vocabulary.yaml"
  mkdir -p "$CLIPS"
  printf 'transcription:\n  languages: [en, fr]\naudio:\n  output_dir: %s\n' "$CLIPS" \
    > "$WORK/config.yaml"
  printf 'acoustic: true\nterms:\n  Praisy:\n    heard: [Prissy]\n  Supabase:\n' \
    > "$WORK/vocabulary.yaml"
}

# ── a correction on a term writes all three ─────────────────────────────────
printf '\n  a correction on a vocabulary term\n'
fresh
clip one.wav
traced one.wav fr "I said praise again" "i:0.10:0.30" "said:0.40:0.90" \
  "praise:1.00:1.50" "again:1.60:2.20"
got="$(PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --learn praise Praisy 2>/dev/null)"
wants "it says the rule was learnt"      "$got" "praise → Praisy"
wants "and how many times it is seen"    "$got" "Praisy: seen 1 time(s), from correction"
wants "and where the audio went"         "$got" "kept the audio as voice/samples/Praisy/00-praise.wav"

vocab="$(cat "$WORK/vocabulary.yaml")"
wants "vocabulary.yaml carries the rendering" "$vocab" "- heard: praise"
wants "with a count"                          "$vocab" "seen: 1"
wants "and where it came from"                "$vocab" "from: correction"
wants "and the term's old list is untouched"  "$vocab" "heard: [Prissy]"

row="$(cat "$WORK/voice/observations.jsonl")"
wants "an observation names the term"    "$row" '"term":"Praisy"'
wants "and the rendering"                "$row" '"heard":"praise"'
wants "and that a person confirmed it"   "$row" '"from":"correction"'
wants "and the language it was said in"  "$row" '"lang":"fr"'
wants "and the build that cut it"        "$row" "\"build\":\"$("$BIN" --version)\""
wants "and the clip it came out of"      "$row" '"wav":"one.wav"'
wants "and the span inside that clip"    "$row" '"span":[1,1.5]'
wants "and the sample it wrote"          "$row" '"sample":"samples/Praisy/00-praise.wav"'
lacks "and nothing was skipped"          "$row" '"skipped"'

holds "the audio is on disk" "$WORK/voice/samples/Praisy/00-praise.wav"
total=$((total + 1))
cut="$(seconds "$WORK/voice/samples/Praisy/00-praise.wav" 2>/dev/null)"
if [ "$cut" = "0.60" ]; then
  pass=$((pass + 1)); printf '  ✓ and it is the span plus the padding, 0.60s\n'
else
  failed="$failed
      the cut is 0.60s (got ${cut:-nothing})"
  printf '  ✗ and it is the span plus the padding, 0.60s (got %s)\n' "${cut:-nothing}"
fi

# ── the same rendering again is counted, not duplicated ─────────────────────
printf '\n  the same rendering a second time\n'
clip two.wav
traced two.wav en "praise again" "praise:1.00:1.50" "again:1.60:2.20"
got="$(PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --learn praise Praisy 2>/dev/null)"
wants "the count goes up"          "$got" "seen 2 time(s)"
wants "and a second sample lands"  "$got" "voice/samples/Praisy/01-praise.wav"
total=$((total + 1))
if [ "$(grep -c 'heard: praise' "$WORK/vocabulary.yaml")" = "1" ]; then
  pass=$((pass + 1)); printf '  ✓ and the rendering is written once, not twice\n'
else
  failed="$failed
      the rendering is written once, not twice"
  printf '  ✗ and the rendering is written once, not twice\n'
fi

# ── a correction that is not a term keeps its old home ──────────────────────
printf '\n  a correction that is not a vocabulary term\n'
fresh
clip three.wav
traced three.wav en "teh thing" "teh:1.00:1.50" "thing:1.60:2.20"
got="$(PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --learn teh the 2>/dev/null)"
wants "it still learns the rule"  "$got" "teh → the"
wants "into config.yaml"          "$(cat "$WORK/config.yaml")" "the: [teh]"
lacks "and vocabulary.yaml is left alone" "$(cat "$WORK/vocabulary.yaml")" "teh"
total=$((total + 1))
if [ ! -e "$WORK/voice/samples" ]; then
  pass=$((pass + 1)); printf '  ✓ and no audio is kept for an ordinary word\n'
else
  failed="$failed
      no audio is kept for an ordinary word"
  printf '  ✗ and no audio is kept for an ordinary word\n'
fi

# ── the duration guard, out loud ────────────────────────────────────────────
printf '\n  a span no word can be\n'
fresh
clip four.wav
traced four.wav en "praise" "praise:0.10:6.50"
got="$(PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --learn praise Praisy 2>/dev/null)"
wants "the cut is refused"            "$got" "no audio kept"
wants "and it names the span"         "$got" "6.40s"
wants "and what was allowed"          "$got" "over the 2.00s allowed for 1 word(s)"
wants "the rule is learnt anyway"     "$(cat "$WORK/vocabulary.yaml")" "- heard: praise"
row="$(cat "$WORK/voice/observations.jsonl")"
wants "and the row says why there is no audio" "$row" '"skipped":"the span is 6.40s'
wants "and still names the clip"               "$row" '"wav":"four.wav"'
total=$((total + 1))
if [ ! -e "$WORK/voice/samples/Praisy" ]; then
  pass=$((pass + 1)); printf '  ✓ and nothing was written under samples/\n'
else
  failed="$failed
      nothing was written under samples/"
  printf '  ✗ and nothing was written under samples/\n'
fi

# A two-word rendering gets a second of rope, because it is two words.
fresh
clip five.wav
traced five.wav en "super base" "super:0.50:1.60" "base:1.65:2.60"
got="$(PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --learn "super base" Supabase 2>/dev/null)"
wants "a two-word rendering is allowed more" "$got" "kept the audio as voice/samples/Supabase/"

# ── the two ways the audio cannot be found ──────────────────────────────────
printf '\n  a rendering that is not in the decoder'"'"'s own words\n'
fresh
clip six.wav
# The line is found by its text, and its word times do not contain the
# rendering. That is the shape of a clip whose words were logged by an older
# build, or one the decoder split differently from the person correcting it.
traced six.wav en "I said praise there" "something:1.00:1.50" "else:1.60:2.20"
got="$(PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --learn praise Praisy 2>/dev/null)"
wants "it says so"                   "$got" "is not in the decoder's own words"
wants "and the rule is still learnt" "$(cat "$WORK/vocabulary.yaml")" "- heard: praise"

printf '\n  a correction with no dictation behind it at all\n'
fresh
got="$(PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --learn praise Praisy 2>/dev/null)"
wants "it says there is no trace line" "$got" "no trace line for this dictation"
wants "and the rule is still learnt"   "$(cat "$WORK/vocabulary.yaml")" "- heard: praise"
wants "and the row records that too"   "$(cat "$WORK/voice/observations.jsonl")" \
  '"skipped":"no trace line for this dictation"'

# ── the cap, and what it drops ──────────────────────────────────────────────
printf '\n  the per-term cap\n'
fresh
mkdir -p "$WORK/voice/samples/Praisy"
# 25 already there: one of them confirmed by a correction, and it is the oldest.
for n in $(seq -w 0 24); do : > "$WORK/voice/samples/Praisy/$n-old.wav"; done
mkdir -p "$WORK/voice"
printf '%s\n' \
  '{"at":"2026-08-01T10:00:00Z","term":"Praisy","heard":"old","from":"correction","sample":"samples/Praisy/00-old.wav"}' \
  > "$WORK/voice/observations.jsonl"
clip seven.wav
traced seven.wav en "praise" "praise:1.00:1.50"
got="$(PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --learn praise Praisy 2>/dev/null)"
wants "going over says what went"     "$got" "capped voice/samples/Praisy/01-old.wav"
wants "and why it was the one to go"  "$got" "oldest unconfirmed"
total=$((total + 1))
if [ -f "$WORK/voice/samples/Praisy/00-old.wav" ]; then
  pass=$((pass + 1)); printf '  ✓ and the confirmed sample stayed\n'
else
  failed="$failed
      the confirmed sample stayed"
  printf '  ✗ and the confirmed sample stayed\n'
fi
total=$((total + 1))
left="$(ls "$WORK/voice/samples/Praisy" | wc -l | tr -d ' ')"
if [ "$left" = "25" ]; then
  pass=$((pass + 1)); printf '  ✓ and the term is back at the cap, 25\n'
else
  failed="$failed
      the term is back at the cap, 25 (got $left)"
  printf '  ✗ and the term is back at the cap, 25 (got %s)\n' "$left"
fi

# A sample name is only unique inside its term's folder, so `Praisy` and
# `Supabase` can both hold a `00-praise.wav`. Matching on the bare name across
# terms let one term's confirmed sample protect another term's unconfirmed one,
# and the cap then deleted the confirmed sample and kept the audio nobody
# vouched for.
printf '\n  the cap does not confuse two terms'"'"' samples\n'
fresh
mkdir -p "$WORK/voice/samples/Praisy" "$WORK/voice/samples/Supabase"
for n in $(seq -w 0 24); do : > "$WORK/voice/samples/Praisy/$n-old.wav"; done
# Only Supabase's copy of `00-old.wav` was ever confirmed. Praisy's is not, and
# it is the oldest, so it is the one that has to go.
: > "$WORK/voice/samples/Supabase/00-old.wav"
printf '%s\n' \
  '{"at":"2026-08-01T10:00:00Z","term":"Supabase","heard":"old","from":"correction","sample":"samples/Supabase/00-old.wav"}' \
  > "$WORK/voice/observations.jsonl"
clip twelve.wav
traced twelve.wav en "praise" "praise:1.00:1.50"
got="$(PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --learn praise Praisy 2>/dev/null)"
wants "the other term's confirmation does not protect this one" \
  "$got" "capped voice/samples/Praisy/00-old.wav"
total=$((total + 1))
if [ -f "$WORK/voice/samples/Supabase/00-old.wav" ]; then
  pass=$((pass + 1)); printf '  ✓ and the other term is untouched\n'
else
  failed="$failed
      the other term is untouched"
  printf '  ✗ and the other term is untouched\n'
fi

# ── naming the clip, which is what the panel does ───────────────────────────
printf '\n  the clip named outright\n'
fresh
clip ten.wav
clip eleven.wav
# The same rendering in two dictations. Without `--clip` the newest wins; with
# it, the one asked for wins. This is the panel's path — it always knows which
# dictation is on screen — and it is only reachable from a terminal through
# `--clip`.
traced ten.wav fr "praise here" "praise:1.00:1.50"
traced eleven.wav en "praise there" "praise:1.00:1.50"
got="$(PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --learn praise Praisy --clip ten.wav 2>/dev/null)"
wants "the audio is kept" "$got" "kept the audio as voice/samples/Praisy/00-praise.wav"
row="$(cat "$WORK/voice/observations.jsonl")"
wants "from the clip that was named" "$row" '"wav":"ten.wav"'
wants "and its language, not the other one's" "$row" '"lang":"fr"'
rm -rf "$WORK/voice"
got="$(PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --learn praise Praisy 2>/dev/null)"
wants "and without a clip the newest wins" "$(cat "$WORK/voice/observations.jsonl")" \
  '"wav":"eleven.wav"'

# ── a rendering seen once and never again ───────────────────────────────────
printf '\n  a rendering seen once, long ago\n'
fresh
mkdir -p "$WORK/voice"
printf 'acoustic: true\nterms:\n  Praisy:\n    pronunciations:\n      - heard: Prezi\n        seen: 1\n        from: correction\n      - heard: Prissy\n        seen: 4\n        from: correction\n      - heard: Pracy\n        seen: 1\n        from: mined\n' \
  > "$WORK/vocabulary.yaml"
printf '%s\n%s\n%s\n' \
  '{"at":"2020-01-01T10:00:00Z","term":"Praisy","heard":"Prezi","from":"correction"}' \
  '{"at":"2020-01-01T10:00:00Z","term":"Praisy","heard":"Prissy","from":"correction"}' \
  '{"at":"2020-01-01T10:00:00Z","term":"Praisy","heard":"Pracy","from":"mined"}' \
  > "$WORK/voice/observations.jsonl"
clip nine.wav
traced nine.wav en "praise" "praise:1.00:1.50"
got="$(PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --learn praise Praisy 2>/dev/null)"
wants "the one seen once is dropped" "$got" 'dropped "Prezi" — seen once and not again since'
vocab="$(cat "$WORK/vocabulary.yaml")"
lacks "and it leaves vocabulary.yaml" "$vocab" "Prezi"
wants "the one seen four times stays" "$vocab" "heard: Prissy"
# A mined entry has no honest first-seen date, so nothing here is allowed to
# delete it on one.
wants "and a mined entry is left alone" "$vocab" "heard: Pracy"

# ── --forget takes all three back ───────────────────────────────────────────
printf '\n  --forget after a correction\n'
fresh
clip eight.wav
traced eight.wav en "praise" "praise:1.00:1.50"
PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --learn praise Praisy >/dev/null 2>&1
got="$(PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --forget Praisy 2>/dev/null)"
wants "it forgets the term"        "$got" "✓ forgot Praisy"
wants "the pronunciations go"      "$got" "pronunciation(s) from vocabulary.yaml"
wants "the observations go"        "$got" "1 observation(s) from voice/observations.jsonl"
wants "and the samples go"         "$got" "1 sample(s) from voice/samples/Praisy/"
lacks "vocabulary.yaml has nothing left of it" "$(cat "$WORK/vocabulary.yaml")" "praise"
total=$((total + 1))
if [ ! -e "$WORK/voice/samples/Praisy" ]; then
  pass=$((pass + 1)); printf '  ✓ and the folder is gone\n'
else
  failed="$failed
      the folder is gone"
  printf '  ✗ and the folder is gone\n'
fi
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
