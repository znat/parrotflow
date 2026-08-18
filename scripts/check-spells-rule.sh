#!/usr/bin/env bash
# Scores `VocabularyJudge.teaching` against tests/spells-cases.yaml.
#
#   scripts/check-spells-rule.sh
#
# The rule reverts a substitution sitting immediately before "spells", because
# that word is the source of a spelling lesson and writing the term over it
# destroys the correction the user is making.
#
# Two halves, and the second is the one that matters. Firing on the four real
# lessons is easy. Not firing anywhere else is the whole risk: this rule runs
# before the model and its answer cannot be argued with, so a false positive is
# a name silently left as the decoder wrote it.
#
# So the sweep. Every case in tests/judge-cases.yaml is put to the rule, and it
# has to fire on exactly the four lessons and nothing else. That set is 59
# sentences of real dictation this rule was never tuned on, which is the only
# evidence available that the pattern is as narrow as it looks.
#
# Nothing here calls a model. The rule is a pure function over text, and that
# is the point of it — the four cases are the ones every model tried answered
# the wrong way.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

CONFIG="$(mktemp -d -t parrotflow-spells)"
trap 'rm -rf "$CONFIG"' EXIT
export PARROTFLOW_CONFIG_DIR="$CONFIG"

pass=0; total=0; missed=0; overfired=0

echo "  tests/spells-cases.yaml"
while IFS=$'\x1f' read -r name said heard expect; do
  [ -z "$name" ] && continue
  total=$((total + 1))
  got="$("$BIN" --teaching "$said" "$heard" 2>/dev/null | tail -1)"

  if [ "$got" = "$expect" ]; then
    pass=$((pass + 1))
    printf '    ✓ %-34s %s\n' "$name" "$got"
    continue
  fi
  # Which direction, because they are not equally expensive. Failing to fire
  # leaves the model to answer, which is the behaviour before this rule. Firing
  # wrongly overrides a decision nothing can appeal.
  if [ "$expect" = "REVERT" ]; then
    missed=$((missed + 1)); why="did not fire; the model answers, as before"
  else
    overfired=$((overfired + 1)); why="fired on an ordinary sentence"
  fi
  printf '    ✗ %-34s got %s, want %s  (%s)\n' "$name" "$got" "$expect" "$why"
done < <(python3 -c '
import sys, yaml
for case in yaml.safe_load(open(sys.argv[1]))["cases"]:
    print("\x1f".join([case["name"], case["said"], case["heard"], case["expect"]]))
' "$ROOT/tests/spells-cases.yaml")

if [ "$total" -eq 0 ]; then
  echo "    ✗ no cases read from tests/spells-cases.yaml"
  exit 1
fi

# The sweep. `heard` is the decoder's word, so this asks the rule the same
# question the stage asks it, on every substitution the archive proposed.
echo
echo "  sweep over tests/judge-cases.yaml"
fired=0; swept=0; wrong=""
while IFS=$'\x1f' read -r said heard; do
  [ -z "$heard" ] && continue
  swept=$((swept + 1))
  got="$("$BIN" --teaching "$said" "$heard" 2>/dev/null | tail -1)"
  [ "$got" != "REVERT" ] && continue
  fired=$((fired + 1))
  # A lesson has "spells" in it. Anything else the rule reverted is a case this
  # script did not predict, and it is named rather than counted.
  case "$(printf '%s' "$said" | tr '[:upper:]' '[:lower:]')" in
    *" spells "*) ;;
    *) wrong="$wrong\n      $heard — $said" ;;
  esac
done < <(python3 -c '
import re, sys
text = open(sys.argv[1]).read()
for said, heard, _, _ in re.findall(
        r"  - said: \"(.*?)\"\n    heard: \"(.*?)\"\n    term: \"(.*?)\"\n"
        r"    expect: (\w+)", text, re.S):
    print("\x1f".join([said, heard]))
' "$ROOT/tests/judge-cases.yaml")

printf '    fired on %d of %d substitutions\n' "$fired" "$swept"
if [ "$swept" -eq 0 ]; then
  echo "    ✗ no cases read from tests/judge-cases.yaml"
  exit 1
fi
if [ -n "$wrong" ]; then
  printf '    ✗ fired on a sentence with no spelling lesson in it:'
  printf "$wrong\n"
  overfired=$((overfired + 1))
fi
if [ "$fired" -ne 4 ]; then
  printf '    ✗ expected 4, the lessons labelled in that file\n'
  overfired=$((overfired + 1))
fi

echo
printf '  %d/%d  (tests/spells-cases.yaml)\n' "$pass" "$total"
[ "$overfired" -gt 0 ] && printf '    %d fired on an ordinary sentence  ← the expensive direction\n' "$overfired"
[ "$missed" -gt 0 ] && printf '    %d did not fire\n' "$missed"
[ "$pass" = "$total" ] && [ "$overfired" -eq 0 ]
