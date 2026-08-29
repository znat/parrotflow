#!/usr/bin/env bash
# Compares the Swift probe's scores against the reference, case by case.
#
#   scripts/check-sentence-probe.sh [tolerance]
#
# The tokenizer check answers "are the ids right". This answers "is the whole
# thing right": the window, the lowercased next word, the padding, the row read
# out of the logits, and the log-softmax over it.
#
# tests/sentence-boundary-cases.json holds 40 boundaries from a scored set of
# the user's own dictation, half real periods and half synthetic cuts, with the
# scores coremltools gets from the same .mlpackage. Same weights, same runtime,
# so a disagreement is Swift's packing and nothing else. Regenerate it with
# scripts/sentence-probe-reference.py.
#
# Not in `make test`: it needs the 300 MB model, which CI has no business
# downloading. Run it by hand after touching the tokenizer or the probe.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

TOLERANCE="${1:-0.05}"
CASES="$ROOT/tests/sentence-boundary-cases.json"
WORK="$(mktemp -d -t parrotflow-sentence-probe)"
trap 'rm -rf "$WORK"' EXIT

# left, right and the three reference numbers, one field per line, so a case
# holding a quote arrives whole.
python3 -c '
import json, sys
for case in json.load(open(sys.argv[1])):
    print(json.dumps(case["left"]))
    print(json.dumps(case["right"]))
    print("%s %s %s" % (case["score"], case["period"], case["next"]))
' "$CASES" > "$WORK/cases" || { echo "  ✗ $CASES could not be read"; exit 1; }

unquote() { python3 -c 'import json,sys; sys.stdout.write(json.loads(sys.argv[1]))' "$1"; }

pass=0; total=0; worst=0; worst_case=""
while IFS= read -r left && IFS= read -r right && IFS= read -r want; do
  total=$((total + 1))
  out="$("$BIN" --sentence-probe "$(unquote "$left")" "$(unquote "$right")" 2>/dev/null)"
  got="$(printf '%s\n' "$out" | awk '$1 == "score" || $1 == "period" || $1 == "next" { print $1, $2 }')"
  read -r verdict <<< "$(python3 -c '
import sys
want = dict(zip(("score", "period", "next"), (float(x) for x in sys.argv[1].split())))
got = dict(line.split() for line in sys.argv[2].splitlines() if line)
if len(got) != 3:
    print("gone 0.0 the probe printed nothing")
    raise SystemExit
gap = max(abs(float(got[k]) - want[k]) for k in want)
print("%s %.4f score %s want %s" % ("ok" if gap <= float(sys.argv[3]) else "off",
                                     gap, got["score"], want["score"]))
' "$want" "$got" "$TOLERANCE")"
  state="${verdict%% *}"
  rest="${verdict#* }"
  gap="${rest%% *}"
  note="${rest#* }"
  if [ "$state" = ok ]; then
    pass=$((pass + 1))
  else
    printf '  ✗ %s\n      %s  gap %s\n' "$left" "$note" "$gap"
  fi
  if python3 -c "import sys; sys.exit(0 if float('$gap') > float('$worst') else 1)"; then
    worst="$gap"; worst_case="$left"
  fi
done < "$WORK/cases"

echo
[ "$total" -eq 0 ] && { echo "  ✗ no cases read from $CASES"; exit 1; }
printf '  %d/%d within %s  (tests/sentence-boundary-cases.json)\n' "$pass" "$total" "$TOLERANCE"
printf '  worst gap %s  %s\n' "$worst" "$worst_case"
[ "$pass" = "$total" ]
