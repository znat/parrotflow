#!/usr/bin/env bash
# Scores `Vocabulary.inflected` against tests/possessive-cases.yaml.
#
#   scripts/check-possessive.sh
#
# The question is whether a possessive survives a substitution. The pass
# replaces a whole decoded token, so "Mathieu's" becomes "Matthieu" and the
# grammar is lost — silently, because that substitution auto-applies and never
# reaches a menu.
#
# Failures are split, because they are not equally expensive. A dropped `'s`
# costs one word in one sentence. An invented `'s` is a word nobody said, on a
# path with no menu behind it, so it is the direction worth watching.
#
# Runs against a scratch PARROTFLOW_CONFIG_DIR, so it says nothing about the
# config on the machine and scores the same anywhere. `--inflected` reads no
# config, but the binary creates one on any path that loads it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

CONFIG="$(mktemp -d -t parrotflow-possessive)"
trap 'rm -rf "$CONFIG"' EXIT
export PARROTFLOW_CONFIG_DIR="$CONFIG"

pass=0; total=0; dropped=0; invented=0; wrong=0

while IFS=$'\t' read -r name term heard expect miss; do
  [ -z "$name" ] && continue
  total=$((total + 1))
  got="$("$BIN" --inflected "$term" "$heard" 2>/dev/null)"

  if [ "$got" = "$expect" ]; then
    pass=$((pass + 1))
    printf '  ✓ %-40s %s\n' "$name" "$got"
    continue
  fi

  # A known miss that now carries is good news and still a failure: the case
  # file is the record of what this function does, and it has stopped being it.
  if [ -n "$miss" ] && [ "$got" = "$miss" ]; then
    printf '  ! %-40s now carries: %s — move it out of known-miss\n' "$name" "$got"
    wrong=$((wrong + 1))
    continue
  fi

  case "$got" in
    "$expect"*) invented=$((invented + 1)); why="invented a suffix  ← nobody said this";;
    *)          if [ "${#got}" -lt "${#expect}" ]
                then dropped=$((dropped + 1)); why="dropped the suffix"
                else wrong=$((wrong + 1)); why="neither"
                fi;;
  esac
  printf '  ✗ %-40s got %s, want %s  (%s)\n' "$name" "$got" "$expect" "$why"
done < <(python3 -c '
import sys, yaml
for case in yaml.safe_load(open(sys.argv[1]))["cases"]:
    print("\t".join([case["name"], case["term"], case["heard"],
                     case["expect"], case.get("known-miss", "")]))
' "$ROOT/tests/possessive-cases.yaml")

echo
# A set that read no cases is not a passing run. Nothing above fails when the
# case file is missing or will not parse: the loop simply never runs, and
# `0 = 0` reports green. That is the one failure this script must not have.
if [ "$total" -eq 0 ]; then
  echo "  ✗ no cases read from tests/possessive-cases.yaml"
  exit 1
fi

printf '  %d/%d  (tests/possessive-cases.yaml)\n' "$pass" "$total"
[ "$invented" -gt 0 ] && printf '    %d invented a suffix  ← the expensive direction\n' "$invented"
[ "$dropped"  -gt 0 ] && printf '    %d dropped a suffix\n' "$dropped"
[ "$wrong"    -gt 0 ] && printf '    %d neither\n' "$wrong"
[ "$pass" = "$total" ]
