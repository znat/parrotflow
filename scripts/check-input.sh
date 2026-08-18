#!/usr/bin/env bash
# Scores where the `input` stage cuts a field, against tests/input-cases.txt.
#
#   scripts/check-input.sh
#
# Deterministic and offline. The stage has one string step — the field cut in
# three at the selection, each side capped on its own — and it is the only part
# with an exact answer. The capture itself depends on TCC and on whatever is
# focused, so it is checked with `--peek` on a real surface and not faked here.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
CASES="$ROOT/tests/input-cases.txt"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

pass=0; total=0; failed=""
while IFS='~' read -r field caret selected limit shape where before selection after; do
  case "$field" in \#*) continue;; esac
  caret="$(printf '%s' "$caret" | tr -d ' ')"
  [ -z "$caret" ] && continue
  total=$((total + 1))

  # Trailing spaces belong to the separator; the blocks carry their own inside
  # ⟪⟫, so trimming around the tildes is safe for them and necessary for a
  # field that ends in a real space.
  field="$(printf '%s' "$field" | sed 's/ *$//')"
  selected="$(printf '%s' "$selected" | tr -d ' ')"
  limit="$(printf '%s' "$limit" | tr -d ' ')"
  trim() { printf '%s' "$1" | sed 's/^ *//; s/ *$//'; }
  want="$(trim "$shape")
$(trim "$where")
before $(trim "$before")
selection $(trim "$selection")
after $(trim "$after")"

  got="$("$BIN" --input-test "$field" "$caret" "$selected" "$limit" 2>/dev/null)"

  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    printf '  ✓ %s\n' "${field:-(empty)} @$caret+$selected/$limit"
  else
    failed="$failed
  ✗ ${field:-(empty)} @$caret+$selected/$limit
      want  $(printf '%s' "$want" | tr '\n' '|')
      got   $(printf '%s' "$got" | tr '\n' '|')"
  fi
done < "$CASES"

[ -n "$failed" ] && printf '%s\n' "$failed"
echo
echo "$pass/$total"
[ "$pass" = "$total" ]
