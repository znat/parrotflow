#!/usr/bin/env bash
# Checks what the clause decider path does with rule places and pill answers.
#
#   scripts/check-clause-places.sh
#
# Needs the parser, so it is not in `make test`. CFFIXED_USER_HOME is passed
# through, so a scratch home with the model in it works.
#
#   a pill answer that keeps the heard word adds no term
#   a slot refusal puts the heard word back over a rule's write
#   a heard word in neither word list is still written
#   a rule place the decider offers shows the heard word
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

picked() {
  mkdir -p "$WORK/$1"
  printf 'transcription:\n  languages: [en]\n  vocabulary:\n    clause_decider: %s\n' "$1" > "$WORK/$1/config.yaml"
  printf 'terms:\n  Vercel:\n    kind: organization\n' > "$WORK/$1/vocabulary.yaml"
  PARROTFLOW_CONFIG_DIR="$WORK/$1" "$BIN" --picked Versailles Vercel \
    --in "We visited the Versailles castle last summer." 2>/dev/null | tail -1
}

check "flag on: keeping the heard word refuses the offered term" "$(picked true)" "counter Vercel"
check "and adds no term" "$(grep -c Versailles "$WORK/true/vocabulary.yaml")" "0"
check "flag off: the same answer still creates the name" "$(picked false)" "create Versailles place"

cat > "$WORK/fixture.yaml" <<'EOF'
languages: [en]
clause_decider: true
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

printf '\n  %d/%d\n' "$pass" "$total"
[ "$pass" -eq "$total" ]
