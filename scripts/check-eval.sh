#!/usr/bin/env bash
# Checks the --eval harness against sets built for the purpose.
#
#   scripts/check-eval.sh
#
# Six things --eval has to do, each of which came from building
# scripts/validate-slack-mentions.py and each of which caught something real:
#
#   1  split the must-not-change half out and report it separately
#   2  break out by probe, never only an aggregate
#   3  report latency per case, warm
#   4  a no-model control, when the transform can run without one
#   5  score an intermediate gold separately, for two-stage transforms
#   6  check the gold against itself before scoring anything
#
# Everything runs against a config directory built in /tmp, so this scores the
# real binary and says nothing about — and does nothing to — the config on this
# machine. Nothing here calls a model: the numbers have to be the same on a
# laptop with Ollama running and one without.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

WORK="$(mktemp -d -t parrotflow-eval)"
trap 'rm -rf "$WORK"' EXIT
export PARROTFLOW_CONFIG_DIR="$WORK"

pass=0; total=0; failed=""

check() {  # check <name> <got> <want>
  total=$((total + 1))
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
  else
    failed="$failed
      $1"
    printf '  ✗ %s\n      got   %s\n      want  %s\n' "$1" "$2" "$3"
  fi
}

# --- a transform with two stages, and no model anywhere ---------------------
#
# `shout.py` marks the words to change and resolves the marks, in one pass or
# either half on demand — which is what lets one set exercise the control, the
# intermediate gold and the gold's own self-check without asking Ollama for
# anything. The rule it applies is deliberately trivial: a word in the roster
# comes back in capitals.
mkdir -p "$WORK/transforms/shout"
cat > "$WORK/transforms/shout/shout.py" <<'PY'
#!/usr/bin/env python3
"""Roster words in capitals. --mark stops after marking, --resolve starts there."""
import json, pathlib, re, sys

roster = set(json.loads(pathlib.Path("roster.json").read_text()))
text = sys.stdin.read().rstrip("\n")

if "--resolve" not in sys.argv:
    text = re.sub(r"\b\w+\b", lambda m: "[[%s]]" % m.group(0)
                  if m.group(0).lower() in roster else m.group(0), text)
if "--mark" not in sys.argv:
    text = re.sub(r"\[\[(\w+)\]\]", lambda m: m.group(1).upper(), text)
print(text)
PY
chmod +x "$WORK/transforms/shout/shout.py"
printf '["mark", "tess"]\n' > "$WORK/transforms/shout/roster.json"

cat > "$WORK/config.yaml" <<'YAML'
transforms:
  - name: shout
    description: roster words in capitals
    command: shout.py
  - name: quiet
    description: a table, so a replace body is scored too
    replace:
      hush: [shout]
YAML

cat > "$WORK/transforms/shout/cases.yaml" <<'YAML'
# Half the set must come back byte for byte. That is not padding: the expensive
# failure is shouting a word that was never on the roster.
control: shout.py
intermediate:
  field: marks
  produce: shout.py --mark
  resolve: shout.py --resolve
cases:
  - probe: roster
    input: ask mark about it
    marks: ask [[mark]] about it
    expect: ask MARK about it
  - probe: roster
    input: tess knows
    marks: '[[tess]] knows'
    expect: TESS knows
  - probe: bystander
    input: leave it alone
    marks: leave it alone
    expect: leave it alone
  - probe: bystander
    input: nothing to see
    marks: nothing to see
    expect: nothing to see
YAML

out="$("$BIN" --eval shout 2>/dev/null)"
line() { printf '%s\n' "$out" | grep -E "^  $1" | sed 's/  */ /g;s/^ //;s/ $//'; }

# 1 — the two halves, separately and always.
check "the must-not-change half is reported on its own" \
  "$(line change)$(line keep | sed 's/ <-.*//')" \
  "change 2/2 = 100%keep 2/2 = 100%"

# 2 — the per-probe grid.
check "the per-probe grid is printed" \
  "$(printf '%s\n' "$out" | grep -cE '^    (roster|bystander) +2/2')" \
  "2"

# 3 — latency, warm.
check "latency is reported" \
  "$(printf '%s\n' "$out" | grep -c 'latency.*warm')" \
  "1"

# 4 — the control.
check "the no-model control is scored" \
  "$(printf '%s\n' "$out" | grep -c 'without a model')" \
  "1"

# 5 — the first stage on its own.
check "the intermediate gold is scored separately" \
  "$(printf '%s\n' "$out" | grep -E 'first stage alone' | grep -c '4/4')" \
  "1"

check "a passing set exits 0" "$("$BIN" --eval shout > /dev/null 2>&1; echo $?)" "0"

# 6 — a gold that does not agree with itself stops everything.
#
# A typo here otherwise scores every candidate against the typo, silently and
# for as long as the set exists. So it is a refusal before any case is run,
# and the proof that nothing was run is that no score is printed.
cp "$WORK/transforms/shout/cases.yaml" "$WORK/transforms/shout/typo.yaml"
sed -i '' 's/marks: ask \[\[mark\]\] about it/marks: ask [[tess]] about it/' \
  "$WORK/transforms/shout/typo.yaml"
bad="$("$BIN" --eval shout --cases typo.yaml 2>/dev/null)"

check "a bad gold is refused" \
  "$(printf '%s\n' "$bad" | grep -c 'does not agree with itself')" \
  "1"

check "and nothing is scored before it is" \
  "$(printf '%s\n' "$bad" | grep -cE '^  overall')" \
  "0"

check "and it exits 1" \
  "$("$BIN" --eval shout --cases typo.yaml > /dev/null 2>&1; echo $?)" \
  "1"

# --- a set that carries its own transform ----------------------------------
#
# So a case file can state what it assumes rather than inherit this machine's
# config — the same reason `--pipeline` takes a fixture.
mkdir -p "$WORK/elsewhere"
cat > "$WORK/elsewhere/table-cases.yaml" <<'YAML'
transform: quiet
transforms:
  - name: quiet
    description: a table carried by the set itself
    replace:
      hush: [shout]
cases:
  - input: please shout about it
    expect: please hush about it
  - input: nothing to change here
YAML

check "a replace: body scores, from a set that carries its own transform" \
  "$("$BIN" --eval "$WORK/elsewhere/table-cases.yaml" 2>/dev/null \
     | grep -E '^  overall' | sed 's/  */ /g;s/^ //')" \
  "overall 2/2 = 100%"

# `expect` absent means "comes back exactly as it went in", and that case
# belongs to the keep half without anyone having to say so.
check "a case with no expect: is detected as must-not-change" \
  "$("$BIN" --eval "$WORK/elsewhere/table-cases.yaml" 2>/dev/null \
     | grep -E '^  keep' | sed 's/ <-.*//;s/  */ /g;s/^ //;s/ $//')" \
  "keep 1/1 = 100%"

# --- a set that names a file that is not there ------------------------------
check "a missing set names where it looked" \
  "$("$BIN" --eval shout --cases nowhere.yaml 2>&1 | grep -c 'no nowhere.yaml')" \
  "1"

echo
echo "  $pass/$total$failed"
[ "$pass" = "$total" ]
