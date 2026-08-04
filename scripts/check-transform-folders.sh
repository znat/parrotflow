#!/usr/bin/env bash
# Checks that a transform's folder is where its files are found and where its
# command runs.
#
#   scripts/check-transform-folders.sh
#
# A transform named X owns `transforms/X/` beside the config that declared it.
# Three things have to be true of that, and each of them was a decision:
#
#   the folder is searched first        so `command: shout.py` finds it there
#   the config directory is searched    so a script written before folders
#   second                              existed keeps running, with one notice
#   the folder is the working           so a script can open a sibling data
#   directory                           file by a bare relative path, and the
#                                       whole transform is one directory you
#                                       can copy to another machine
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

# --- the old location ------------------------------------------------------
#
# The same script, beside the fixture rather than in a folder, which is where
# every `command:` written before this existed still sits.
mkdir -p "$WORK/transforms/legacy"
cat > "$WORK/legacy.py" <<'PY'
#!/usr/bin/env python3
import sys
print(sys.stdin.read().strip().upper())
PY
chmod +x "$WORK/legacy.py"

fixture() {  # fixture <file> <transform yaml>
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

fixture old.yaml '  - name: legacy
    description: everything in capitals
    command: legacy.py' legacy

fixture path.yaml '  - name: sed_transform
    description: a one-liner off PATH
    command: sed -e s/quick/slow/' sed_transform

# 1 — the folder is searched first, and is the working directory.
check "command: shout.py resolves in the folder" \
  "$("$BIN" --pipeline "$WORK/folder.yaml" "keep it down" --quiet 2>/dev/null | tail -1)" \
  "KEEP IT DOWN!"

# 2 — the spelled-out path names the same file, and is not reported as needing
# to move. Both spellings are things people write and both must work.
check "command: transforms/shout/shout.py resolves to the same file" \
  "$("$BIN" --pipeline "$WORK/spelled-out.yaml" "keep it down" --quiet 2>/dev/null | tail -1)" \
  "KEEP IT DOWN!"

check "the spelled-out path is not reported as needing to move" \
  "$("$BIN" --pipeline "$WORK/spelled-out.yaml" "keep it down" 2>/dev/null \
     | grep -c 'old location')" \
  "0"

# 3 — a bare name that is not a file anywhere is left for the shell to find.
check "command: sed still works" \
  "$("$BIN" --pipeline "$WORK/path.yaml" "the quick brown fox" --quiet 2>/dev/null | tail -1)" \
  "the slow brown fox"

# 4 — the old location runs, and says so exactly once.
check "a script at the old location still runs" \
  "$("$BIN" --pipeline "$WORK/old.yaml" "keep it down" --quiet 2>/dev/null | tail -1)" \
  "KEEP IT DOWN"

check "the old location gets exactly one notice" \
  "$("$BIN" --pipeline "$WORK/old.yaml" "keep it down" 2>/dev/null \
     | grep -c 'found at the old location')" \
  "1"

# 5 — a folder file wins over one of the same name at the old location. This is
# the case `--check-config` prints resolved paths for: with a copy in both
# places, nothing else can tell you which one ran.
cp "$WORK/legacy.py" "$WORK/transforms/legacy/legacy.py"
cat > "$WORK/transforms/legacy/legacy.py" <<'PY'
#!/usr/bin/env python3
import sys
print(sys.stdin.read().strip() + " (from the folder)")
PY
chmod +x "$WORK/transforms/legacy/legacy.py"
check "the folder wins over the old location" \
  "$("$BIN" --pipeline "$WORK/old.yaml" "keep it down" --quiet 2>/dev/null | tail -1)" \
  "keep it down (from the folder)"

# --- prompt: { path: } and replace: { path: } -------------------------------
mkdir -p "$WORK/transforms/tidy"
printf 'wrap dotted paths in backticks\n' > "$WORK/transforms/tidy/tidy.md"
cat > "$WORK/transforms/tidy/tidy.yaml" <<'YAML'
'`$1`': ['/\b([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)+)/']
YAML

cat > "$WORK/table.yaml" <<'YAML'
transforms:
  - name: tidy
    description: wrap dotted paths in backticks
    replace: { path: tidy.yaml }
pipeline:
  - transform: tidy
YAML

check "replace: { path: } reads the table out of the folder" \
  "$("$BIN" --pipeline "$WORK/table.yaml" "read config.port" --quiet 2>/dev/null | tail -1)" \
  'read `config.port`'

# An inline table with one entry called `path` is still a table. The mapping
# form is only ever `path: <a string>`, so this cannot be taken for one.
cat > "$WORK/inline-table.yaml" <<'YAML'
transforms:
  - name: tidy
    description: a table with a rule about the word path
    replace:
      chemin: [path]
pipeline:
  - transform: tidy
YAML

check 'an inline table whose key is `path` is still a table' \
  "$("$BIN" --pipeline "$WORK/inline-table.yaml" "the path is long" --quiet 2>/dev/null | tail -1)" \
  "the chemin is long"

# A `path:` naming nothing takes out that transform and nothing else. The
# pipeline still runs, and the transcript comes through.
cat > "$WORK/missing.yaml" <<'YAML'
transforms:
  - name: tidy
    description: points at a file that is not there
    prompt: { path: nowhere.md }
pipeline:
  - replacements
  - transform: tidy
YAML

check "a path: naming nothing leaves the rest of the config working" \
  "$("$BIN" --pipeline "$WORK/missing.yaml" "the rest still runs" --quiet 2>/dev/null | tail -1)" \
  "the rest still runs"

# --- what a first launch writes --------------------------------------------
#
# Against a config directory of its own, so this says nothing about — and does
# nothing to — the one on this machine.
FRESH="$WORK/fresh"
mkdir -p "$FRESH"
seeded="$(PARROTFLOW_CONFIG_DIR="$FRESH" "$BIN" --seed-config 2>/dev/null)"

check "a first launch writes the transform as a folder" \
  "$(cd "$FRESH" && find . -type f | sed 's|^\./||' | sort | tr '\n' ' ')" \
  "config.yaml transforms/code_identifiers/cases.yaml transforms/code_identifiers/code_identifiers.py "

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

# Nothing is ever overwritten, and an install that predates folders keeps the
# script it has: seeding a fresh one into the folder would put it in front of
# the edited copy — the folder is searched first — and the stop lists someone
# tuned would stop running with nothing said.
UPGRADED="$WORK/upgraded"
mkdir -p "$UPGRADED"
printf '#!/usr/bin/env python3\nimport sys\nprint(sys.stdin.read().strip())\n' \
  > "$UPGRADED/code_identifiers.py"
chmod +x "$UPGRADED/code_identifiers.py"
mine="$(cat "$UPGRADED/code_identifiers.py")"
PARROTFLOW_CONFIG_DIR="$UPGRADED" "$BIN" --seed-config > /dev/null 2>&1

check "an edited script at the old location is left alone" \
  "$(cat "$UPGRADED/code_identifiers.py")" \
  "$mine"

check "and no fresh copy is put in front of it" \
  "$([ -e "$UPGRADED/transforms/code_identifiers/code_identifiers.py" ] && echo yes || echo no)" \
  "no"

check "and it is reported as wanting to move, exactly once" \
  "$(PARROTFLOW_CONFIG_DIR="$UPGRADED" "$BIN" --check-config 2>/dev/null \
     | grep -c 'found at the old location')" \
  "1"

check "and --check-config still exits 0" \
  "$(PARROTFLOW_CONFIG_DIR="$UPGRADED" "$BIN" --check-config > /dev/null 2>&1; echo $?)" \
  "0"

echo
echo "  $pass/$total$failed"
[ "$pass" = "$total" ]
