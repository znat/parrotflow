#!/usr/bin/env bash
# Scores the lowercasing rule, against tests/sentence-case-cases.json.
#
#   scripts/check-sentence-case.sh
#
# Joining two sentences means taking the period out and lowercasing the word
# after it. Not every capital after a period is there because of the period:
# "I will ask him. Nathan knows the answer" must not become "ask him nathan
# knows". This is the half of `SentenceJoin` that decides, and it is the half
# that writes nonsense when it is wrong.
#
# No model. `NLTagger` and the vocabulary answer this, so it runs in CI and on
# a machine that has never dictated.
#
# The scratch config carries one term, `Compass` — a name that is also an
# English word, which is the one case the lemma rule cannot see. Without the
# term in the file that case comes back lowercased.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

WORK="$(mktemp -d -t parrotflow-sentence-case)"
trap 'rm -rf "$WORK"' EXIT
export PARROTFLOW_CONFIG_DIR="$WORK"
printf 'terms:\n  Compass:\n' > "$WORK/vocabulary.yaml"

# Text, want and why on three lines per case, so a case holding a quote or an
# apostrophe arrives whole.
if ! python3 -c '
import json, sys
for case in json.load(open(sys.argv[1])):
    print(case["text"])
    print(case["want"])
    print(case["why"])
' "$ROOT/tests/sentence-case-cases.json" > "$WORK/cases"; then
  echo "  ✗ tests/sentence-case-cases.json could not be read"
  exit 1
fi

pass=0; total=0
while IFS= read -r text && IFS= read -r want && IFS= read -r why; do
  total=$((total + 1))
  # The line for this case's own boundary, not the first one printed. A text
  # can hold several — "what I meant. Which one" has a bare "I" before the
  # period — and only one of them is what the case is about.
  got="$("$BIN" --sentence-join --case "$text" 2>/dev/null | awk -v w="$want" '
    $1 == "next" {
      a = tolower(substr($2, 1, 1)) substr($2, 2)
      b = tolower(substr(w, 1, 1)) substr(w, 2)
      if (a == b) { print $4; exit }
    }')"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    printf '  ✓  %-12s %s\n' "$got" "$why"
  else
    printf '  ✗  %-12s want %s — %s\n' "${got:-<nothing>}" "$want" "$why"
  fi
done < "$WORK/cases"

echo
if [ "$total" -eq 0 ]; then
  echo "  ✗ no cases read from tests/sentence-case-cases.json"
  exit 1
fi
printf '  %d/%d  (tests/sentence-case-cases.json)\n' "$pass" "$total"
[ "$pass" = "$total" ]
