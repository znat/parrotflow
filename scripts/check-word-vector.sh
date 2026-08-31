#!/usr/bin/env bash
# Compares the Swift word vectors against the reference, case by case.
#
#   scripts/check-word-vector.sh [tolerance]
#
# Every threshold in the vocabulary plan was measured in Python, against these
# weights through mlx-lm. This answers whether the Swift path computes the same
# function: the token ids, the span the word covers, which tokens each side
# takes, and the mean before it is normalised.
#
# tests/word-vector-cases.json holds six sentences and the first eight
# components of each vector. Same weights, same runtime, so a disagreement is
# Swift's packing and nothing else. Regenerate it with
# scripts/word-vector-reference.py.
#
# Not in `make test`: it needs the 400 MB model, which CI has no business
# downloading. Run it by hand after touching WordVectors.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || BIN="$ROOT/.build/debug/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build"; exit 1; }

TOLERANCE="${1:-0.01}"
seen=0
CASES="$ROOT/tests/word-vector-cases.json"
failed=0

# One field per line, so a sentence holding a quote arrives whole.
while IFS= read -r line; do
  IFS=$'\t' read -r sentence word side tokens taken head <<< "$line"
  seen=$((seen + 1))

  if [ "$side" = "around" ]; then
    got="$("$BIN" --word-vector "$sentence" "$word" --around 2>/dev/null)"
  else
    got="$("$BIN" --word-vector "$sentence" "$word" 2>/dev/null)"
  fi

  got_tokens="$(printf '%s\n' "$got" | sed -n 's/^tokens \([0-9]*\).*/\1/p')"
  got_taken="$(printf '%s\n' "$got" | sed -n 's/^tokens [0-9]*   taken \(.*\)/\1/p' | tr -d ' []')"
  got_head="$(printf '%s\n' "$got" | tail -1)"

  if [ "$got_tokens" != "$tokens" ] || [ "$got_taken" != "$taken" ]; then
    printf '  ✗ %s [%s] %s: tokens %s taken [%s], expected %s [%s]\n' \
      "$word" "$side" "${sentence:0:30}" "${got_tokens:-none}" "${got_taken:-none}" \
      "$tokens" "$taken"
    failed=1
    continue
  fi

  drift="$(python3 -c '
import sys
want = [float(x) for x in sys.argv[1].split(",")]
got = [float(x) for x in sys.argv[2].split()]
print("%.4f" % max(abs(a - b) for a, b in zip(want, got)) if len(got) == len(want) else "nan")
' "$head" "$got_head")"

  if [ "$drift" = "nan" ] || awk "BEGIN{exit !($drift > $TOLERANCE)}"; then
    printf '  ✗ %s [%s]: largest component differs by %s\n' "$word" "$side" "$drift"
    failed=1
  else
    printf '  ✓ %s [%s]  %s tokens, off by %s\n' "$word" "$side" "$tokens" "$drift"
  fi
done < <(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for c in d["cases"]:
    for side in ("inside", "around"):
        s = c[side]
        print("\t".join([
            c["sentence"], c["word"], side, str(c["tokens"]),
            ",".join(str(i) for i in s["taken"]),
            ",".join(str(x) for x in s["head"]),
        ]))
' "$CASES")

if [ "$seen" -eq 0 ]; then
  echo "Failed: word-vector — no case was read from $CASES"
  exit 1
fi
[ "$failed" -eq 0 ] && echo "Every check passed." || echo "Failed: word-vector"
exit "$failed"
