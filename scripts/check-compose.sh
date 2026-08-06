#!/usr/bin/env bash
# Scores what a prompt says once the scope is folded into it, against
# tests/compose-cases.txt.
#
#   scripts/check-compose.sh
#
# Deterministic and offline. No model is consulted, because what is being
# checked happens before any model sees anything: which placeholders were
# filled, and which paragraphs disappeared because there was nothing to fill
# them with. What the model then does with the prompt is scored by the
# validate-*.py sets, which need Ollama running and cannot give an exact answer.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
CASES="$ROOT/tests/compose-cases.txt"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

pass=0; total=0; failed=""
while IFS='~' read -r template assignments expected; do
  case "$template" in \#*) continue;; esac
  [ -z "${template// }" ] && continue
  total=$((total + 1))

  # Leading and trailing spaces are the separator's, not the field's. A value
  # with a real trailing space would need quoting, and no case needs one.
  template="$(printf '%s' "$template" | sed 's/^ *//; s/ *$//')"
  assignments="$(printf '%s' "$assignments" | sed 's/^ *//; s/ *$//')"
  expected="$(printf '%s' "$expected" | sed 's/^ *//; s/ *$//')"

  # `|` separates assignments so a value may contain spaces. The empty case is
  # a real one — a template with no placeholders takes no variables at all.
  args=()
  if [ -n "$assignments" ]; then
    IFS='|' read -r -a vars <<< "$assignments"
    for v in "${vars[@]}"; do [ -n "$v" ] && args+=("$v"); done
  fi

  got="$("$BIN" --compose "$template" ${args[@]+"${args[@]}"} 2>/dev/null)"
  want="$(printf '%b' "${expected//\\n/\\n}")"

  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    failed="$failed\n  template: $template\n  vars:     $assignments\n  want:     $(printf '%s' "$want" | tr '\n' '|')\n  got:      $(printf '%s' "$got" | tr '\n' '|')\n"
  fi
done < "$CASES"

if [ -n "$failed" ]; then printf '%b' "$failed"; fi
echo
echo "  $pass/$total"
[ "$pass" = "$total" ]
