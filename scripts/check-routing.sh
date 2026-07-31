#!/usr/bin/env bash
# Scores the router against tests/routing-cases.yaml.
#
# Every case is a real round trip through Ollama, so this takes a minute or so.
# Failures are grouped by kind at the end: sending a request to the wrong tool
# and sending an idle sentence to a tool are different problems, and only the
# second one loses you text.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

pass=0; total=0; wrong=0; spurious=0; missed=0
started=$(date +%s)

while IFS='|' read -r instruction want; do
  [ -z "$instruction" ] && continue
  total=$((total + 1))
  got="$("$BIN" --route "$instruction" --quiet 2>/dev/null | tail -1)"

  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    printf '  ✓ %-52s %s\n' "$instruction" "$got"
  else
    if   [ "$want" = "NONE" ]; then spurious=$((spurious + 1)); mark="routed something idle"
    elif [ "$got"  = "NONE" ]; then missed=$((missed + 1));     mark="refused a real request"
    else wrong=$((wrong + 1));                                  mark="wrong tool"
    fi
    printf '  ✗ %-52s got %s, want %s  (%s)\n' "$instruction" "$got" "$want" "$mark"
  fi
done < <(python3 -c '
import sys, yaml
for case in yaml.safe_load(open(sys.argv[1]))["cases"]:
    print(str(case["instruction"]) + "|" + str(case["expect"]))
' "$ROOT/tests/routing-cases.yaml")

elapsed=$(( $(date +%s) - started ))
echo
printf '  %d/%d in %ds\n' "$pass" "$total" "$elapsed"
[ "$wrong"    -gt 0 ] && printf '    %d wrong tool\n' "$wrong"
[ "$missed"   -gt 0 ] && printf '    %d refused a real request\n' "$missed"
[ "$spurious" -gt 0 ] && printf '    %d routed something idle  ← the one that costs text\n' "$spurious"
[ "$pass" = "$total" ]
