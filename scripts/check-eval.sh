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

# --- `tests:` on the transform ----------------------------------------------
#
# A transform whose default set is not cases.yaml says so once, in the config,
# rather than in every command anyone runs against it.
cp "$WORK/transforms/shout/cases.yaml" "$WORK/transforms/shout/heldout.yaml"
cat >> "$WORK/config.yaml" <<'YAML'
  - name: shout_heldout
    description: the same transform, scored against a set of its own
    command: shout.py
    tests: { path: heldout.yaml }
YAML
mkdir -p "$WORK/transforms/shout_heldout"
ln -s ../shout/heldout.yaml "$WORK/transforms/shout_heldout/heldout.yaml"
ln -s ../shout/shout.py "$WORK/transforms/shout_heldout/shout.py"
ln -s ../shout/roster.json "$WORK/transforms/shout_heldout/roster.json"

check "tests: names the set --eval scores by default" \
  "$("$BIN" --eval shout_heldout 2>/dev/null | grep -c 'heldout.yaml')" \
  "1"

# --- the set's own transform wins over the machine's -----------------------
#
# A case file carrying `transforms:` is stating what it assumes, and the whole
# point is that it scores the same wherever it runs. A config on this machine
# with an entry of the same name must not be the one that runs — silently, and
# only on the machines where the two differ, which is exactly the case the set
# carried its own definition to survive.
cat >> "$WORK/config.yaml" <<'YAML'
  - name: contested
    description: the machine's version, which must not be what runs
    replace:
      MACHINE: [contested]
YAML

cat > "$WORK/elsewhere/contested-cases.yaml" <<'YAML'
transform: contested
transforms:
  - name: contested
    description: the set's own version
    replace:
      SET: [contested]
cases:
  - input: a contested word
    expect: a SET word
YAML

check "a set that carries its own transform scores that one" \
  "$("$BIN" --eval "$WORK/elsewhere/contested-cases.yaml" 2>/dev/null \
     | grep -E '^  overall' | sed 's/  */ /g;s/^ //')" \
  "overall 1/1 = 100%"

# --- a --probe that matches nothing ----------------------------------------
#
# Scoring nothing and exiting 0 is how a typo reads as a clean run.
check "a --probe naming no case is refused" \
  "$("$BIN" --eval shout --probe nosuchprobe > /dev/null 2>&1; echo $?)" \
  "1"

check "and it says which probes the set does have" \
  "$("$BIN" --eval shout --probe nosuchprobe 2>/dev/null | grep -c 'have: bystander, roster')" \
  "1"

# --- a tests: that is neither form -----------------------------------------
#
# `tests: { file: … }` is a key that does not do what it says. It used to
# decode as nothing and leave the transform scoring cases.yaml while the config
# said otherwise.
cat >> "$WORK/config.yaml" <<'YAML'
  - name: mistyped
    description: names its set with the wrong key
    command: shout.py
    tests: { file: heldout.yaml }
YAML

check "a malformed tests: is refused rather than ignored" \
  "$(PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --check-config 2>/dev/null \
     | grep -c 'tests:` is neither a filename')" \
  "1"

# A malformed `tests:` must survive a body that reads perfectly well. The
# reason an entry cannot be used was being assigned into the same variable the
# body's own result went into, so a valid `prompt: { path: … }` erased it and
# the transform was kept — scoring cases.yaml while the config named something
# else.
mkdir -p "$WORK/transforms/mistyped_with_body"
printf 'Return only the text.\n' > "$WORK/transforms/mistyped_with_body/mistyped_with_body.md"
cat >> "$WORK/config.yaml" <<'YAML'
  - name: mistyped_with_body
    description: a body that reads, beside a mistyped test key
    prompt: { path: mistyped_with_body.md }
    tests: { file: heldout.yaml }
YAML

check "a malformed tests: is not erased by a body that reads" \
  "$(PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --check-config 2>/dev/null \
     | grep -c '"mistyped_with_body" `tests:` is neither a filename')" \
  "1"

# --- what --probe actually hands to the program ----------------------------
#
# A `command:` body is someone's program. This runner treats a transform as
# text in and text out, but nothing stops the script from writing a file or
# calling something, so an input the user asked to exclude must not reach it —
# including through the warm-up run, which used to take the first case in the
# file rather than the first case being scored — so the excluded case is
# deliberately the first one here.
mkdir -p "$WORK/transforms/recorded"
cat > "$WORK/transforms/recorded/recorded.py" <<'RECORDER'
#!/usr/bin/env python3
import pathlib, sys
text = sys.stdin.read().strip()
with pathlib.Path("seen.txt").open("a") as log:
    log.write(text + "\n")
print(text)
RECORDER
chmod +x "$WORK/transforms/recorded/recorded.py"
cat >> "$WORK/config.yaml" <<'YAML'
  - name: recorded
    description: writes down every input it is given
    command: recorded.py
YAML
cat > "$WORK/transforms/recorded/cases.yaml" <<'YAML'
cases:
  - probe: excluded
    input: this one is not
  - probe: wanted
    input: this one is asked for
YAML
: > "$WORK/transforms/recorded/seen.txt"
"$BIN" --eval recorded --probe wanted > /dev/null 2>&1

check "--probe never hands an excluded input to the program" \
  "$(grep -c 'this one is not' "$WORK/transforms/recorded/seen.txt")" \
  "0"

check "and the warm-up runs a case that was going to be scored anyway" \
  "$(grep -c 'this one is asked for' "$WORK/transforms/recorded/seen.txt")" \
  "2"

# The same question for the gold check. `resolve:` is a `command:` like any
# other, and the check that the gold agrees with itself used to send every
# case's gold to it before --probe had filtered anything — so an excluded case
# reached the program through a side door rather than through the scoring loop.
mkdir -p "$WORK/transforms/goldrecorded"
cat > "$WORK/transforms/goldrecorded/goldrecorded.py" <<'RECORDER'
#!/usr/bin/env python3
import pathlib, sys
text = sys.stdin.read().strip()
with pathlib.Path("seen.txt").open("a") as log:
    log.write(text + "\n")
print(text.replace("[[", "").replace("]]", ""))
RECORDER
chmod +x "$WORK/transforms/goldrecorded/goldrecorded.py"
cat >> "$WORK/config.yaml" <<'YAML'
  - name: goldrecorded
    description: writes down every gold it is asked to resolve
    command: goldrecorded.py
YAML
cat > "$WORK/transforms/goldrecorded/cases.yaml" <<'YAML'
intermediate:
  field: marks
  resolve: goldrecorded.py
cases:
  - probe: excluded
    input: this gold is not asked for
    marks: this gold is not asked for
  - probe: wanted
    input: this gold is asked for
    marks: this gold is asked for
YAML
: > "$WORK/transforms/goldrecorded/seen.txt"
"$BIN" --eval goldrecorded --probe wanted > /dev/null 2>&1

check "the gold check never resolves an excluded case" \
  "$(grep -c 'this gold is not asked for' "$WORK/transforms/goldrecorded/seen.txt")" \
  "0"

check "and it still checks the gold of the cases it will score" \
  "$(grep -c 'this gold is asked for' "$WORK/transforms/goldrecorded/seen.txt")" \
  "3"

# --- a set that names a file that is not there ------------------------------
check "a missing set names where it looked" \
  "$("$BIN" --eval shout --cases nowhere.yaml 2>&1 | grep -c 'no nowhere.yaml')" \
  "1"

echo
echo "  $pass/$total$failed"
[ "$pass" = "$total" ]
