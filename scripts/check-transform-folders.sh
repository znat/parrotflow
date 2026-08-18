#!/usr/bin/env bash
# Checks that a transform's folder is where its files are found and where its
# command runs.
#
#   scripts/check-transform-folders.sh
#
# A transform named X owns `transforms/X/` beside the config that declared it,
# and that is the only place its files are looked for. Three things follow, and
# each of them was a decision:
#
#   one place to look          `command: shout.py` is in the folder or it is
#                              nowhere — there is no second directory that
#                              could disagree about which file runs
#   either spelling            `transforms/X/shout.py` names the same file,
#                              because people write both. It is accepted only
#                              when it lands inside the folder
#   the folder is the          so a script opens a sibling data file by a bare
#   working directory          relative path, and the whole transform is one
#                              directory you can copy to another machine
#
# Everything is built in a temporary directory and run through `--pipeline`,
# which carries its own `transforms:` and resolves relative paths against the
# fixture's own directory — so this scores the same on any machine and touches
# no config.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

WORK="$(mktemp -d -t parrotflow-folders)"
trap 'rm -rf "$WORK"' EXIT

pass=0; total=0; failed=""

check() {  # check <name> <got> <want>
  total=$((total + 1))
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
    printf '  ✓ %s\n' "$1"
  else
    failed="$failed
      $1"
    printf '  ✗ %s\n      got   %s\n      want  %s\n' "$1" "$2" "$3"
  fi
}

# --- the folder ------------------------------------------------------------
#
# `shout.py` uppercases, and it reads the suffix it appends out of a sibling
# file by a bare relative path. That second half is the working directory being
# tested: without it the open fails, the script exits non-zero, and the
# transcript comes back unchanged — which is exactly what a wrong answer here
# looks like.
mkdir -p "$WORK/transforms/shout"
cat > "$WORK/transforms/shout/shout.py" <<'PY'
#!/usr/bin/env python3
import pathlib, sys
suffix = pathlib.Path("suffix.txt").read_text().strip()
print(sys.stdin.read().strip().upper() + suffix)
PY
chmod +x "$WORK/transforms/shout/shout.py"
printf '!\n' > "$WORK/transforms/shout/suffix.txt"

fixture() {  # fixture <file> <transform yaml> <name>
  cat > "$WORK/$1" <<YAML
transforms:
$2
pipeline:
  - transform: $3
YAML
}

fixture folder.yaml '  - name: shout
    description: everything in capitals
    command: shout.py' shout

fixture spelled-out.yaml '  - name: shout
    description: everything in capitals
    command: transforms/shout/shout.py' shout

fixture path.yaml '  - name: sed_transform
    description: a one-liner off PATH
    command: sed -e s/quick/slow/g' sed_transform

# 1 — the folder is searched, and is the working directory.
check "command: shout.py resolves in the folder" \
  "$("$BIN" --pipeline "$WORK/folder.yaml" "keep it down" --quiet 2>/dev/null | tail -1)" \
  "KEEP IT DOWN!"

# 2 — and the spelled-out path names the same file. Both are things people
# write; neither may be the only one that works.
check "command: transforms/shout/shout.py resolves to the same file" \
  "$("$BIN" --pipeline "$WORK/spelled-out.yaml" "keep it down" --quiet 2>/dev/null | tail -1)" \
  "KEEP IT DOWN!"

# 3 — a bare name that is not a file anywhere is left for the shell to find.
check "command: sed still works" \
  "$("$BIN" --pipeline "$WORK/path.yaml" "the quick brown fox" --quiet 2>/dev/null | tail -1)" \
  "the slow brown fox"

# 4 — a path that reaches outside the folder resolves to nothing. This is the
# fallback that used to exist, and its absence is the point: one place to look.
mkdir -p "$WORK/outside/transforms/stray"
cat > "$WORK/outside/config.yaml" <<'YAML'
transforms:
  - name: stray
    description: a script left beside config.yaml
    command: stray.py
YAML
printf '#!/usr/bin/env python3\nprint("nope")\n' > "$WORK/outside/stray.py"
chmod +x "$WORK/outside/stray.py"
stray="$(PARROTFLOW_CONFIG_DIR="$WORK/outside" "$BIN" --check-config 2>/dev/null)"

check "a command outside its folder is reported, not silently left to the shell" \
  "$(printf '%s\n' "$stray" | grep -c 'stray.py is not in transforms/stray/')" \
  "1"

check "and that is a fault, so --check-config exits 1" \
  "$(PARROTFLOW_CONFIG_DIR="$WORK/outside" "$BIN" --check-config > /dev/null 2>&1; echo $?)" \
  "1"

# --- a transform named after something the runner already publishes ---------
#
# Asked where the name is declared, not where a pipeline step spells it.
# `transform(named:)` resolves case-insensitively, so a step written `Lists`
# reaches a transform declared `lists` and files under `lists.*` regardless of
# how the step was spelled.
RESERVED="$WORK/reserved"
mkdir -p "$RESERVED"
cat > "$RESERVED/config.yaml" <<'YAML'
lists:
  determiners: ["the", "a", "an"]
transforms:
  - name: lists
    description: collides with the named word lists
    replace:
      hush: [shout]
transcription:
  pipelines:
    default:
      - transform: Lists
YAML
reserved="$(PARROTFLOW_CONFIG_DIR="$RESERVED" "$BIN" --check-config 2>/dev/null)"

check "a transform declared with a reserved name is dropped, and said so" \
  "$(printf '%s\n' "$reserved" | grep -c 'transforms: "lists" would file its variables')" \
  "1"

check "and that is a fault, whatever spelling the pipeline step used" \
  "$(PARROTFLOW_CONFIG_DIR="$RESERVED" "$BIN" --check-config > /dev/null 2>&1; echo $?)" \
  "1"

# Dropped, so the step naming it names nothing — which is the second half of
# the same message. Reported and kept, it would have run.
check "so the pipeline step that named it reaches nothing" \
  "$(printf '%s\n' "$reserved" | grep -c 'no transform named "Lists"')" \
  "1"

# And the same the other way round. `transform(named:)` resolves
# case-insensitively and `Pipeline.namespace` files a stage under the spelling
# the *step* wrote, so a transform declared `Lists` reached by a step spelled
# `lists` lands in `lists.*` all the same. Either casing is a way into the same
# namespace, so neither may be declared.
CASED="$WORK/cased"
mkdir -p "$CASED"
cat > "$CASED/config.yaml" <<'YAML'
lists:
  determiners: ["the", "a", "an"]
transforms:
  - name: Lists
    description: the same collision, spelled differently
    replace:
      hush: [shout]
transcription:
  pipelines:
    default:
      - transform: lists
YAML
cased="$(PARROTFLOW_CONFIG_DIR="$CASED" "$BIN" --check-config 2>/dev/null)"

check "a reserved name is taken whatever its casing" \
  "$(printf '%s\n' "$cased" | grep -c 'transforms: "Lists" would file its variables where lists')" \
  "1"

check "and the step spelled the other way reaches nothing" \
  "$(printf '%s\n' "$cased" | grep -c 'no transform named "lists"')" \
  "1"

# --- prompt: { path: }, through a whole config ------------------------------
#
# A prompt body cannot be scored without a model, so what is checked here is
# everything up to the call: that the file is read, that --check-config prints
# the resolved path, and that a sibling naming a file which is not there is
# reported as itself and takes nothing else with it.
BODIES="$WORK/bodies"
mkdir -p "$BODIES/transforms/shouty"
printf 'Return the text in capital letters. Return only the text.\n' \
  > "$BODIES/transforms/shouty/shouty.md"
cat > "$BODIES/config.yaml" <<'YAML'
transforms:
  - name: shouty
    description: everything in capitals
    prompt: { path: shouty.md }
  - name: broken
    description: points at a file that is not there
    prompt: { path: nowhere.md }
YAML
bodies="$(PARROTFLOW_CONFIG_DIR="$BODIES" "$BIN" --check-config 2>/dev/null)"

check "prompt: { path: } resolves, and its path is printed" \
  "$(printf '%s\n' "$bodies" | grep -c 'shouty *prompt.*transforms/shouty/shouty.md')" \
  "1"

check "a prompt file that is not there is reported as itself" \
  "$(printf '%s\n' "$bodies" | grep -c '✗ transforms: "broken" prompt: no file at nowhere.md')" \
  "1"

check "and takes only its own transform with it" \
  "$(printf '%s\n' "$bodies" | grep -E '^  · transforms ' | grep -c '1 defined')" \
  "1"

# --- what a first launch writes --------------------------------------------
#
# Against a config directory of its own, so this says nothing about — and does
# nothing to — the one on this machine.
FRESH="$WORK/fresh"
mkdir -p "$FRESH"
seeded="$(PARROTFLOW_CONFIG_DIR="$FRESH" "$BIN" --seed-config 2>/dev/null)"

check "a first launch writes the transform as a folder" \
  "$(cd "$FRESH" && find . -type f | sed 's|^\./||' | sort | tr '\n' ' ')" \
  "config.yaml transforms/code_identifiers/cases.yaml transforms/code_identifiers/code_identifiers.py transforms/punctuation/cases.yaml transforms/punctuation/punctuation.py transforms/repetitions/cases.yaml transforms/repetitions/repetitions.py vocabulary.yaml "

check "the seeded script is executable" \
  "$([ -x "$FRESH/transforms/code_identifiers/code_identifiers.py" ] && echo yes || echo no)" \
  "yes"

check "the seeded config resolves its command into the folder" \
  "$(PARROTFLOW_CONFIG_DIR="$FRESH" "$BIN" --check-config 2>/dev/null \
     | grep -c 'transforms/code_identifiers/code_identifiers.py')" \
  "1"

check "a seeded config is clean" \
  "$(PARROTFLOW_CONFIG_DIR="$FRESH" "$BIN" --check-config > /dev/null 2>&1; echo $?)" \
  "0"

echo
echo "  $pass/$total$failed"
[ "$pass" = "$total" ]
