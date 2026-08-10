#!/usr/bin/env bash
# Scores `VocabularyJudge.verdicts` against tests/verdict-cases.yaml.
#
#   scripts/check-verdicts.sh
#
# The question is what the judge reads out of a model's reply. A reply read
# wrongly is a name written into somebody's sentence, or a name taken out of
# one, with no menu behind it and nothing that says so.
#
# Failures are split, because they are not equally expensive. Reading REVERT
# where the model said KEEP takes a name the pass had right out of the
# transcript. Reading KEEP where it said REVERT leaves the transcript as the
# pass wrote it, which is where every other failure in this stage lands too.
# The first is the direction worth watching.
#
# The same cases run twice: once through the app, and once through the copy of
# the parser `scripts/judge-verdicts.py` carries. A harness that reads a reply
# differently scores a decision the app never made.
#
# Runs against a scratch PARROTFLOW_CONFIG_DIR, so it says nothing about the
# config on the machine and scores the same anywhere. `--verdicts` reads no
# config, but the binary creates one on any path that loads it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

CONFIG="$(mktemp -d -t parrotflow-verdicts)"
trap 'rm -rf "$CONFIG"' EXIT
export PARROTFLOW_CONFIG_DIR="$CONFIG"

pass=0; total=0; lost=0; kept=0

# Unit separator, not a tab. A tab is whitespace, so bash collapses two of
# them into one and the empty-reply case arrives with its fields shifted along.
while IFS=$'\x1f' read -r name count reply expect; do
  [ -z "$name" ] && continue
  total=$((total + 1))
  # The reply arrives with newlines escaped, because a case is one line here.
  got="$("$BIN" --verdicts "$count" "$(printf '%b' "$reply")" 2>/dev/null)"

  if [ "$got" = "$expect" ]; then
    pass=$((pass + 1))
    printf '  ✓ %-46s %s\n' "$name" "$got"
    continue
  fi

  # Which direction it went wrong in, counted from the words themselves: a
  # REVERT this read where the case wanted KEEP is a name lost.
  if [ "$(printf '%s' "$got" | grep -o REVERT | wc -l)" \
     -gt "$(printf '%s' "$expect" | grep -o REVERT | wc -l)" ]; then
    lost=$((lost + 1)); why="undid a substitution the reply did not"
  else
    kept=$((kept + 1)); why="kept a substitution the reply undid"
  fi
  printf '  ✗ %-46s got [%s], want [%s]  (%s)\n' "$name" "$got" "$expect" "$why"
done < <(python3 -c '
import sys, yaml
for case in yaml.safe_load(open(sys.argv[1]))["cases"]:
    reply = case["reply"].replace("\\", "\\\\").replace("\n", "\\n")
    print("\x1f".join([case["name"], str(case["count"]), reply, case["expect"]]))
' "$ROOT/tests/verdict-cases.yaml")

echo
# A set that read no cases is not a passing run. Nothing above fails when the
# case file is missing or will not parse: the loop simply never runs, and
# `0 = 0` reports green. That is the one failure this script must not have.
if [ "$total" -eq 0 ]; then
  echo "  ✗ no cases read from tests/verdict-cases.yaml"
  exit 1
fi

printf '  %d/%d  (tests/verdict-cases.yaml)\n' "$pass" "$total"
[ "$lost" -gt 0 ] && printf '    %d undid a substitution the reply did not  ← the expensive direction\n' "$lost"
[ "$kept" -gt 0 ] && printf '    %d kept a substitution the reply undid\n' "$kept"
[ "$pass" = "$total" ] || exit 1

# The same cases through the harness's own copy of the parser.
#
# `scripts/judge-verdicts.py` cannot link the app, so it ports this function.
# A port that reads a reply differently scores a decision the app would never
# make, and every number in the measurement would be about a judge nobody runs.
echo
python3 - "$ROOT" <<'PY'
import importlib.util, pathlib, sys, yaml
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("jv", root / "scripts/judge-verdicts.py")
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)

cases = yaml.safe_load((root / "tests/verdict-cases.yaml").read_text())["cases"]
wrong = [c for c in cases
         if " ".join(harness.parse(c["reply"], c["count"])) != c["expect"]]
for case in wrong:
    got = " ".join(harness.parse(case["reply"], case["count"]))
    print(f"  ✗ {case['name']}: the harness reads [{got}], the app reads [{case['expect']}]")
if not cases:
    print("  ✗ no cases read from tests/verdict-cases.yaml")
    sys.exit(1)
if wrong:
    sys.exit(1)
print(f"  ✓ scripts/judge-verdicts.py reads a reply the way the app does"
      f"  ({len(cases)} cases)")
PY
