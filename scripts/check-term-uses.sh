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

[ "$failed" -eq 0 ] && echo "Every check passed." || echo "Failed: term-uses"
exit "$failed"
