#!/usr/bin/env bash
# Scores the spelling correction the way the app actually runs it.
#
# scripts/validate-prompt.py is the tuning loop: it holds every prompt variant
# side by side and re-implements interpret()'s repair in Python so a variant can
# be scored in a minute. This is the check on that — the same cases through the
# shipped binary, the shipped prompt, and the real interpret(). When the two
# disagree, the Python one is testing code nobody runs.
#
#   scripts/check-spelling.sh                          # English
#   scripts/check-spelling.sh tests/french-cases.yaml  # French
#
# Failures are split, because they are not equally expensive. A miss costs one
# correction. A false positive writes a rule into transcription.replacements
# that rewrites every transcript from then on.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

CASES="${1:-tests/spelling-cases.yaml}"
PHRASE="$(python3 -c '
import yaml, pathlib
cfg = yaml.safe_load((pathlib.Path.home() / ".config/parrotflow/config.yaml").read_text())
t = cfg.get("transcription") or {}
print(t.get("activation_phrase") or t.get("correction_phrase") or "hey parrot")
')"

pass=0; total=0; missed=0; wrong=0; invented=0
started=$(date +%s)

while IFS='|' read -r source correction expect; do
  [ -z "$source" ] && continue
  total=$((total + 1))
  out="$("$BIN" --command "$PHRASE, $correction" "$source" 2>/dev/null)"
  if rule="$(printf '%s' "$out" | sed -n 's/.*action: add rule *//p')"; then :; fi
  if [ -n "$rule" ]; then
    got="$(printf '%s' "$rule" | sed 's/ → / => /')"
  else
    got="NO MATCH"
  fi

  if [ "$got" = "$expect" ]; then
    pass=$((pass + 1))
    printf '  ✓ %-46s %s\n' "$source" "$got"
  else
    if   [ "$expect" = "NO MATCH" ]; then invented=$((invented + 1)); mark="invented a rule  ← rewrites every future transcript"
    elif [ "$got"    = "NO MATCH" ]; then missed=$((missed + 1));     mark="missed it"
    else wrong=$((wrong + 1));                                        mark="wrong span or spelling"
    fi
    printf '  ✗ %-46s got %s, want %s  (%s)\n' "$source" "$got" "$expect" "$mark"
  fi
done < <(python3 -c '
import sys, yaml
for case in yaml.safe_load(open(sys.argv[1]))["cases"]:
    print("|".join([str(case["source"]), str(case["correction"]), str(case["expect"])]))
' "$ROOT/$CASES")

elapsed=$(( $(date +%s) - started ))
echo
printf '  %d/%d in %ds  (%s)\n' "$pass" "$total" "$elapsed" "$CASES"
[ "$invented" -gt 0 ] && printf '    %d invented a rule  ← the expensive direction\n' "$invented"
[ "$wrong"    -gt 0 ] && printf '    %d wrong span or spelling\n' "$wrong"
[ "$missed"   -gt 0 ] && printf '    %d missed\n' "$missed"
exit 0
