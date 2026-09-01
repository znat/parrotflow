#!/usr/bin/env bash
# The sentences a term was confirmed in, written and read back.
#
#   scripts/check-term-uses.sh
#
# A term's portrait is built from these sentences, so what is stored has to be
# exactly what was said and nothing else. No model is loaded: this is the file,
# the deduplication and the guards.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN=""
for candidate in "$ROOT/.build/release/ParrotFlow" "$ROOT/.build/debug/ParrotFlow"; do
  [ -x "$candidate" ] || continue
  if [ -z "$BIN" ] || [ "$candidate" -nt "$BIN" ]; then BIN="$candidate"; fi
done
[ -n "$BIN" ] || { echo "build first: swift build"; exit 1; }

WORK="$(mktemp -d -t parrotflow-term-uses)"
trap 'rm -rf "$WORK"' EXIT
USES="$WORK/vocabulary-uses.yaml"
failed=0

learn() { PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --learn "$@" >/dev/null 2>&1; }
count() { grep -c '^    - said:' "$USES" 2>/dev/null | head -1; }

check() {
  local what="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then printf '  ✓ %s\n' "$what"
  else printf '  ✗ %s: %s, expected %s\n' "$what" "$got" "$want"; failed=1; fi
}

learn Prezi Praisy person --in "Praisy joined the team in March."
check "the first use is written" 1 "$(count)"

learn Precy Praisy --in "Praisy has done great work on the crawler."
check "a second use is added" 2 "$(count)"

learn Prazi Praisy --in "Praisy joined the team in March."
check "the same sentence is not stored twice" 2 "$(count)"

# The term has to be in the sentence, or the portrait cannot leave it out.
learn Vercell Vercel --in "This sentence does not hold the term."
check "a sentence without the term is refused" 2 "$(count)"

learn Versal Vercel --in "We deploy the dashboard on Vercel every Friday."
check "a second term keeps its own list" 3 "$(count)"

# A quote in the sentence has to survive the round trip.
learn Ghosty Ghostty --in "He said \"open it in Ghostty\" and left."
check "a sentence holding a quote is stored" 4 "$(count)"
back="$(PARROTFLOW_CONFIG_DIR="$WORK" python3 -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))["terms"]
print(d["Ghostty"][0]["said"])
' "$USES" 2>/dev/null)"
check "and reads back unchanged" 'He said "open it in Ghostty" and left.' "$back"

# The two files are written by the same call and have to agree.
learn Prezzy Praisy --in "Praisy reviewed the migration."
check "the mapping still lands in vocabulary.yaml" 1 \
  "$(grep -c 'heard: Prezzy' "$WORK/vocabulary.yaml" 2>/dev/null | head -1)"
check "and the sentence beside it" 5 "$(count)"

# A file the app cannot parse is not a file to write over. One unbalanced
# quote read as "no uses" would drop every sentence the term had.
BROKE="$WORK/broken"
mkdir -p "$BROKE"
printf 'terms:\n  "Praisy":\n    - said: "Praisy joined the team.\n      span: "Praisy"\n' \
  > "$BROKE/vocabulary-uses.yaml"
sum_before="$(shasum "$BROKE/vocabulary-uses.yaml" | cut -d' ' -f1)"
out="$(PARROTFLOW_CONFIG_DIR="$BROKE" "$BIN" --learn Prezi Praisy \
  --in "Praisy wrote the guide." 2>/dev/null)"
code=$?
sum_after="$(shasum "$BROKE/vocabulary-uses.yaml" | cut -d' ' -f1)"
check "a file that does not parse is left alone" "$sum_before" "$sum_after"
check "and the correction still succeeds" 0 "$code"
check "and says the sentence was not recorded" 1 \
  "$(printf '%s' "$out" | grep -c 'was not recorded')"
check "and the mapping went in anyway" 1 \
  "$(grep -c 'heard: Prezi' "$BROKE/vocabulary.yaml" 2>/dev/null | head -1)"

# The mapping is written first, so a sentence that cannot be stored is a
# warning. Reporting it as a failure would say the correction was lost.
BLOCKED="$WORK/blocked"
mkdir -p "$BLOCKED/vocabulary-uses.yaml"
out="$(PARROTFLOW_CONFIG_DIR="$BLOCKED" "$BIN" --learn Precy Praisy \
  --in "Praisy fixed the crawler." 2>/dev/null)"
check "an unwritable uses file does not fail the correction" 0 "$?"
check "and the mapping is still there" 1 \
  "$(grep -c 'heard: Precy' "$BLOCKED/vocabulary.yaml" 2>/dev/null | head -1)"

# --forget takes the sentences too, or a forgotten term keeps describing itself.
check "three terms hold five sentences between them" 5 "$(count)"
PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --forget praisy >/dev/null 2>&1
check "--forget takes one term's three, whatever the case" 2 "$(count)"

# Bytes that are not UTF-8 are the same problem as a syntax error: the file is
# there, it cannot be read, and it is not a file to write over.
BYTES="$WORK/bytes"
mkdir -p "$BYTES"
printf 'terms:\n  "Praisy":\n    - said: "Praisy joined the team."\n      span: "Praisy"\n' \
  > "$BYTES/vocabulary-uses.yaml"
printf '\xff\xfe\xc3\x28\n' >> "$BYTES/vocabulary-uses.yaml"
sum_before="$(shasum "$BYTES/vocabulary-uses.yaml" | cut -d' ' -f1)"
PARROTFLOW_CONFIG_DIR="$BYTES" "$BIN" --learn Prezi Praisy \
  --in "Praisy wrote the guide." >/dev/null 2>&1
check "a file that is not UTF-8 is left alone" "$sum_before" \
  "$(shasum "$BYTES/vocabulary-uses.yaml" | cut -d' ' -f1)"

# A forget that could not reach the sentences has to say so. The renderings are
# already gone by then, so silence would leave a term half forgotten.
HALF="$WORK/half"
mkdir -p "$HALF"
PARROTFLOW_CONFIG_DIR="$HALF" "$BIN" --learn Precy Praisy \
  --in "Praisy fixed the crawler." >/dev/null 2>&1
sed -i '' 's|    - said: "Praisy fixed the crawler."|    - said: "Praisy fixed the crawler.|' \
  "$HALF/vocabulary-uses.yaml"
out="$(PARROTFLOW_CONFIG_DIR="$HALF" "$BIN" --forget Praisy 2>/dev/null)"
check "a forget that cannot reach the sentences fails" 1 "$?"
check "and says the term was only partly forgotten" 1 \
  "$(printf '%s' "$out" | grep -c 'only partly forgotten')"

# A newline written as itself is folded back into a space, and a raw control
# character makes the whole file unparseable. Both change or lose what a
# portrait is built from, so both are escaped.
ODD="$WORK/odd"
mkdir -p "$ODD"
two="$(printf 'Praisy wrote\nthe guide.')"
PARROTFLOW_CONFIG_DIR="$ODD" "$BIN" --learn Precy Praisy --in "$two" >/dev/null 2>&1
back="$(python3 -c '
import sys, yaml
print(yaml.safe_load(open(sys.argv[1]))["terms"]["Praisy"][0]["said"])
' "$ODD/vocabulary-uses.yaml" 2>/dev/null)"
check "a sentence holding a newline reads back unchanged" "$two" "$back"

PARROTFLOW_CONFIG_DIR="$ODD" "$BIN" --learn Prezi Praisy --in "$two" >/dev/null 2>&1
check "and is still recognised as the same sentence" 1 \
  "$(grep -c '^    - said:' "$ODD/vocabulary-uses.yaml")"

bell="$(printf 'Praisy fixed \athe crawler.')"
PARROTFLOW_CONFIG_DIR="$ODD" "$BIN" --learn Praise Praisy --in "$bell" >/dev/null 2>&1
PARROTFLOW_CONFIG_DIR="$ODD" "$BIN" --learn Prizy Praisy \
  --in "Praisy joined in March." >/dev/null 2>&1
check "a control character does not make the file unreadable" 3 \
  "$(grep -c '^    - said:' "$ODD/vocabulary-uses.yaml")"

# Which occurrence the sentence is cut around. `range(of:)` matches inside a
# longer word, so `Vercel` found itself in `Vercelli` and an Italian town was
# stored as a use of the hosting platform.
said_of() { PARROTFLOW_CONFIG_DIR="$1" python3 -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))["terms"]
print(next(iter(d.values()))[0]["said"])
' "$1/vocabulary-uses.yaml" 2>/dev/null; }

INSIDE="$WORK/inside"; mkdir -p "$INSIDE"
PARROTFLOW_CONFIG_DIR="$INSIDE" "$BIN" --for Vercel \
  "I visited Vercelli last year. We deploy on Vercel." >/dev/null 2>&1
check "the term is found as a word, not inside a longer one" \
  "We deploy on Vercel." "$(said_of "$INSIDE")"

TWICE="$WORK/twice"; mkdir -p "$TWICE"
PARROTFLOW_CONFIG_DIR="$TWICE" "$BIN" --for Vercel \
  "Vercel is where we deploy. Vercel also hosts the docs." >/dev/null 2>&1
# Twice as a word takes the first. Both are genuine uses, and nothing that
# records one carries the position of the occurrence that was corrected.
check "a term twice as a word takes the first" \
  "Vercel is where we deploy." "$(said_of "$TWICE")"

# `--tidy-uses` rewrites the whole file, so it has to read it the strict way.
# Reading a broken file as "no uses" and writing that back is how every stored
# sentence goes at once.
sum_before="$(shasum "$BROKE/vocabulary-uses.yaml" | cut -d' ' -f1)"
PARROTFLOW_CONFIG_DIR="$BROKE" "$BIN" --tidy-uses >/dev/null 2>&1
check "--tidy-uses fails on a file it cannot parse" 1 "$?"
check "and leaves it exactly as it was" "$sum_before" \
  "$(shasum "$BROKE/vocabulary-uses.yaml" | cut -d' ' -f1)"

PARROTFLOW_CONFIG_DIR="$ODD" "$BIN" --tidy-uses >/dev/null 2>&1
check "--tidy-uses keeps the sentences of a file it can parse" 3 \
  "$(grep -c '^    - said:' "$ODD/vocabulary-uses.yaml")"

[ "$failed" -eq 0 ] && echo "Every check passed." || echo "Failed: term-uses"
exit "$failed"
