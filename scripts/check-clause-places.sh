#!/usr/bin/env bash
# Checks what the clause decider does with rule places and pill answers.
#
#   scripts/check-clause-places.sh
#
# Needs the parser, so it is not in `make test`. CFFIXED_USER_HOME is passed
# through, so a scratch home with the model in it works.
#
#   a pill answer that keeps the heard word adds no term
#   the pill still asks when a later stage only changed the letter case
#   a slot refusal puts the heard word back over a rule's write
#   a heard word in neither word list is still written
#   a rule place the decider offers shows the heard word
#   a span that glues to the term is asked, and a correction back counts
#   a case-only rendering of an ordinary word is settled, of a non-word written
#   a case-only place yields to a longer term and to a sound place
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

WORK="$(mktemp -d -t parrotflow-clause-places)"
trap 'rm -rf "$WORK"' EXIT
pass=0; total=0

check() {
  total=$((total + 1))
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
  else
    printf '  ✗ %s\n      want  %s\n      got   %s\n' "$1" "$3" "$2"
  fi
}

mkdir -p "$WORK/pill"
printf 'transcription:\n  languages: [en]\n' > "$WORK/pill/config.yaml"
printf 'terms:\n  Vercel:\n    kind: organization\n' > "$WORK/pill/vocabulary.yaml"
check "keeping the heard word refuses the offered term" "$(PARROTFLOW_CONFIG_DIR="$WORK/pill" "$BIN" \
  --picked Versailles Vercel --in "We visited the Versailles castle last summer." 2>/dev/null | tail -1)" \
  "counter Vercel"
check "and adds no term" "$(grep -c Versailles "$WORK/pill/vocabulary.yaml")" "0"
check "a keep is asked after a case-only rewrite" "$(PARROTFLOW_CONFIG_DIR="$WORK/pill" "$BIN" \
  --selector "We visited the versailles castle." "Versailles|Vercel|3|0" --taught 2>/dev/null | tail -1)" \
  "versailles teaches"
check "and it refuses the offered term" "$(PARROTFLOW_CONFIG_DIR="$WORK/pill" "$BIN" --picked versailles Vercel \
  --in "We visited the versailles castle." 2>/dev/null | tail -1)" "counter Vercel"

cat > "$WORK/fixture.yaml" <<'EOF'
languages: [en]
vocabulary:
  terms:
    Praisy:
      pronunciations:
        - heard: praise
    Vercel:
      pronunciations:
        - heard: Versal
        - heard: Versailles
pipeline:
  - vocabulary
EOF
mkdir -p "$WORK/run"
run() {
  PARROTFLOW_CONFIG_DIR="$WORK/run" "$BIN" --pipeline "$WORK/fixture.yaml" "$1" --quiet --warm 2>/dev/null | tail -1
}

check "a slot refusal puts the heard word back" \
  "$(run "We should praise his work.")" "We should praise his work."
check "a word in neither list is still written" \
  "$(run "We deploy on Versal every Friday.")" "We deploy on Vercel every Friday."
check "an offered rule place shows the heard word" \
  "$(run "We deploy our apps on Versailles every week.")" "We deploy our apps on Versailles every week."

# Needs espeak-ng: these places come from the sound pass.
cat > "$WORK/glued.yaml" <<'EOF'
languages: [en]
vocabulary:
  terms:
    BetterStack:
    Zorblix:
pipeline:
  - vocabulary
EOF
mkdir -p "$WORK/glued"
printf 'transcription:\n  languages: [en]\n' > "$WORK/glued/config.yaml"
printf 'terms:\n  BetterStack:\n  Zorblix:\n' > "$WORK/glued/vocabulary.yaml"
glued() {
  PARROTFLOW_CONFIG_DIR="$WORK/glued" "$BIN" --pipeline "$WORK/glued.yaml" "$1" --vars --warm 2>/dev/null \
    | sed -nE -e 's/^out:  //p' -e 's/^var   vocabulary\.clause_(offered|left) = /\1 /p' | paste -sd'|' -
}
phrase="Honestly, Rust with Postgres is a better stack for the billing service."
check "a span that glues to the term is asked, not written" \
  "$(glued "$phrase")" "left 0|offered 1|$phrase"
PARROTFLOW_CONFIG_DIR="$WORK/glued" "$BIN" --correction BetterStack "better stack" --in "$phrase" >/dev/null 2>&1
check "a correction back counts against it the next time" \
  "$(glued "$phrase")" "left 1|offered 0|$phrase"
check "a glued span with a word in neither list is still written" \
  "$(glued "We ship Zorb lix on Fridays." | sed 's/.*|//')" "We ship Zorblix on Fridays."

cat > "$WORK/cased.yaml" <<'EOF'
languages: [en]
vocabulary:
  terms:
    Resend:
      pronunciations:
        - heard: resend
        - heard: Resend
    Upstash:
      pronunciations:
        - heard: upstash
pipeline:
  - vocabulary
EOF
mkdir -p "$WORK/cased"
printf 'transcription:\n  languages: [en]\n' > "$WORK/cased/config.yaml"
printf 'terms:\n  Resend:\n  Upstash:\n  Bill:\n    kind: person\n' > "$WORK/cased/vocabulary.yaml"
cased() {
  PARROTFLOW_CONFIG_DIR="$WORK/cased" "$BIN" --pipeline "$WORK/cased.yaml" "$1" --quiet --warm 2>/dev/null | tail -1
}
check "a case-only rendering of an ordinary word is not a rule" \
  "$(cased "Can you resend me the invite?")" "Can you resend me the invite?"
check "a case-only rendering of a non-word still writes" \
  "$(cased "The rate limiter keeps its counters in upstash.")" "The rate limiter keeps its counters in Upstash."
casedvars() {
  PARROTFLOW_CONFIG_DIR="$WORK/cased" "$BIN" --pipeline "$WORK/cased.yaml" "$1" --vars --warm 2>/dev/null \
    | sed -nE -e 's/^out:  //p' -e 's/^var   vocabulary\.clause_(offered|left|written) = /\1 /p' | paste -sd'|' -
}
check "a case-only place before any sentence is offered, not written" \
  "$(casedvars "We send the receipts with resend.")" "left 0|offered 1|written 0|We send the receipts with resend."
check "keeping the ordinary word on the pill is a counter" "$(PARROTFLOW_CONFIG_DIR="$WORK/cased" "$BIN" \
  --picked resend Resend --in "We send the receipts with resend." 2>/dev/null | tail -1)" "counter Resend"
check "and the next one is left" \
  "$(casedvars "We send the receipts with resend.")" "left 1|offered 0|written 0|We send the receipts with resend."
check "a person's name corrected to the ordinary word is a counter" "$(PARROTFLOW_CONFIG_DIR="$WORK/cased" "$BIN" \
  --correction Bill "bill's" --in "Pay the bill's total." 2>/dev/null | tail -1)" "counter Bill \"bill's\""

cat > "$WORK/stacked.yaml" <<'EOF'
languages: [en]
vocabulary:
  terms:
    Stack:
    Stack Overflow:
    BetterStack:
pipeline:
  - vocabulary
EOF
mkdir -p "$WORK/stacked"
printf 'transcription:\n  languages: [en]\n' > "$WORK/stacked/config.yaml"
printf 'terms:\n  Stack:\n  Stack Overflow:\n  BetterStack:\n' > "$WORK/stacked/vocabulary.yaml"
placed() {
  PARROTFLOW_CONFIG_DIR="$WORK/stacked" "$BIN" --pipeline "$WORK/stacked.yaml" "$1" --vars --warm 2>/dev/null \
    | sed -n 's/^var   vocabulary\.clause = //p' | grep -o '"[^"]*" -> [^:]*' | paste -sd'|' -
}
check "a longer case-only term takes the span first" \
  "$(placed "I asked on stack overflow yesterday.")" '"stack overflow" -> Stack Overflow'
check "a case-only term does not take a span the sound pass wants" \
  "$(placed "We send the logs to better stack now.")" '"better stack" -> BetterStack'

printf '\n  %d/%d\n' "$pass" "$total"
[ "$pass" -eq "$total" ]
