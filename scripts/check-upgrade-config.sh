#!/usr/bin/env bash
# Upgrades each config in tests/upgrade-config/ with `--upgrade-config --write`.
#
#   scripts/check-upgrade-config.sh
#
# `<name>.yaml` is the file before. `<name>.want.yaml` is the file after, byte
# for byte; without one the file must not change. Each upgraded file must pass
# `--check-config`, keep the old file as a backup, and come out of a second run
# unchanged. `example-v0.yaml` and `example-v1.yaml` are
# built-in/config.example.yaml at those versions: upgraded, each must run the
# pipeline the shipped example runs.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${PARROTFLOW_BIN:-$ROOT/.build/release/ParrotFlow}"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }
CASES="$ROOT/tests/upgrade-config"
CURRENT="$(sed -n 's/^version: *\([0-9]*\).*/\1/p' "$ROOT/built-in/config.example.yaml")"

WORK="$(mktemp -d -t parrotflow-upgrade)"
trap 'rm -rf "$WORK"' EXIT

pass=0; total=0

check() {
  total=$((total + 1))
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
    printf '  ✓ %s\n' "$1"
  else
    printf '  ✗ %s\n      got   %s\n      want  %s\n' "$1" "$2" "$3"
  fi
}

pf() {
  local dir="$1"; shift
  PARROTFLOW_CONFIG_DIR="$dir" "$BIN" "$@" </dev/null 2>/dev/null
}

same_or_diff() {
  if cmp -s "$1" "$2"; then echo same; else diff "$1" "$2" | head -5; fi
}

pipeline_line() {
  pf "$1" --check-config | sed -n 's/^  · pipeline *//p'
}

for before in "$CASES"/*.yaml; do
  case "$before" in *.want.yaml) continue ;; esac
  name="$(basename "$before" .yaml)"
  dir="$WORK/$name"
  mkdir -p "$dir"
  cp "$before" "$dir/config.yaml"
  want="$CASES/$name.want.yaml"
  [ -f "$want" ] || want="$before"

  pf "$dir" --upgrade-config >/dev/null
  check "$name: a dry run writes nothing" "$(cmp -s "$before" "$dir/config.yaml" && echo same)" "same"

  pf "$dir" --upgrade-config --write >/dev/null
  code=$?
  if [ "$name" = "unreadable" ]; then
    check "$name: refused" "$code" "1"
  else
    check "$name: exit" "$code" "0"
  fi
  check "$name: the file" "$(same_or_diff "$want" "$dir/config.yaml")" "same"

  backups=("$dir"/config.yaml.bak-*)
  if [ "$want" = "$before" ]; then
    check "$name: no backup" "$([ -e "${backups[0]}" ] && echo "${backups[0]##*/}")" ""
    continue
  fi
  backup="${backups[0]##*/}"
  from="$(sed -n 's/^version: *\([0-9]*\).*/\1/p' "$before" | head -1)"
  check "$name: the backup is the old file" \
    "$(cmp -s "$before" "${backups[0]}" && echo "${backup%-????-??-??}")" "config.yaml.bak-v${from:-0}"

  cp "$dir/config.yaml" "$WORK/$name.after"
  pf "$dir" --upgrade-config --write >/dev/null
  check "$name: a second run changes nothing" \
    "$(cmp -s "$WORK/$name.after" "$dir/config.yaml" && echo same)" "same"

  out="$(pf "$dir" --check-config)"
  # A `file:` key the fixture names is not on this Mac.
  check "$name: --check-config passes" \
    "$(printf '%s\n' "$out" | grep '^  ✗' | grep -vc '^  ✗ models\.[^:]*: no key at ~/.config/example/')" "0"
  check "$name: version $CURRENT" "$(printf '%s\n' "$out" | grep -c "✓ version *$CURRENT\$")" "1"
  [ "${from:-0}" -lt 2 ] && check "$name: sentence_repair runs" \
    "$(printf '%s\n' "$out" | grep -c '^  · pipeline .*transform sentence_repair')" "1"
done

# Which agents each upgraded `claude:` section hooks, and where.
agents_line() {
  CODEX_HOME='' pf "$WORK/$1" --check-config | sed -n 's/^  · agents *//p'
}
check "the dev config: voice off" "$(agents_line voice-dev)" "off — voice.enabled is false"
check "folders and codex: both agents" "$(agents_line voice-full)" "claude ~/.claude, ~/.claude-personal; codex ~/.codex"
check "codex: false: claude alone" "$(agents_line voice-flow)" "claude ~/.claude, ~/work/.claude"
check "codex alone: claude in its default folder" "$(agents_line voice-codex)" "claude ~/.claude; codex ~/codex-home"
check "no voice: section: off" "$(agents_line current)" "off — voice.enabled is false"
check "a voice: without enabled: stays on" "$(agents_line voice-unindented)" "claude ~/.claude, ~/.claude-work"
check "the old example upgrades to the shipped one" \
  "$(cmp -s "$WORK/example-v3/config.yaml" "$ROOT/built-in/config.example.yaml" && echo same)" "same"

dir="$WORK/told-voice"
mkdir -p "$dir"
cp "$CASES/voice-full.yaml" "$dir/config.yaml"
out="$(pf "$dir" --check-config)"
check "a claude: section fails --check-config" "$?" "1"
check "and names voice: and the command" \
  "$(printf '%s\n' "$out" | grep -c '✗ claude: now `voice:`, with `folders` and `codex` under `voice.agents`.*--upgrade-config --write')" "1"

# What an old config is told before it is upgraded.
dir="$WORK/told"
mkdir -p "$dir"
cp "$CASES/block-enabled.yaml" "$dir/config.yaml"
out="$(pf "$dir" --check-config)"
check "an old config fails --check-config" "$?" "1"
check "it says an upgrade is pending" "$(printf '%s\n' "$out" | grep -c 'version *0 — 4 upgrade(s) pending.*--upgrade-config --write')" "1"
check "the retired block names the command" \
  "$(printf '%s\n' "$out" | grep -c '✗ transcription.sentence_repair no longer does anything — it is the `sentence_repair` transform now.*--upgrade-config --write')" "1"

# A config kept elsewhere and linked in stays linked, and its backup holds
# the old text rather than another link.
mkdir -p "$WORK/linked" "$WORK/elsewhere"
cp "$CASES/block-enabled.yaml" "$WORK/elsewhere/config.yaml"
ln -s "$WORK/elsewhere/config.yaml" "$WORK/linked/config.yaml"
pf "$WORK/linked" --upgrade-config --write >/dev/null
check "a linked config is still a link" "$([ -L "$WORK/linked/config.yaml" ] && echo link)" "link"
check "and the file it points at is upgraded" \
  "$(cmp -s "$CASES/block-enabled.want.yaml" "$WORK/elsewhere/config.yaml" && echo same)" "same"
backups=("$WORK/linked"/config.yaml.bak-*)
check "and its backup is the old text, not a link" \
  "$([ ! -L "${backups[0]}" ] && cmp -s "$CASES/block-enabled.yaml" "${backups[0]}" && echo old)" "old"

# A config can hold keys: the upgraded file and its backup keep its mode.
mkdir -p "$WORK/private"
cp "$CASES/block-enabled.yaml" "$WORK/private/config.yaml"
chmod 600 "$WORK/private/config.yaml"
pf "$WORK/private" --upgrade-config --write >/dev/null
backups=("$WORK/private"/config.yaml.bak-*)
check "a 0600 config stays 0600, and so is its backup" \
  "$(stat -f '%Lp' "$WORK/private/config.yaml") $(stat -f '%Lp' "${backups[0]}")" "600 600"
left=("$WORK/private"/.*upgrade*)
check "and no temporary file is left" "$([ -e "${left[0]}" ] && echo "${left[0]##*/}")" ""

mkdir -p "$WORK/example"
cp "$ROOT/built-in/config.example.yaml" "$WORK/example/config.yaml"
for old in example-v0 example-v1; do
  check "the upgraded $old runs the shipped example's pipeline" \
    "$(pipeline_line "$WORK/$old")" "$(pipeline_line "$WORK/example")"
done

# What each upgraded built-in definition is handed, and from where.
needs() {
  pf "$1" --check-config | grep -A1 "^      $2 " | sed -n '2s/^ *//p'
}
for old in example example-v0 example-v1; do
  check "$old: disfluency gets the vectors its script declares" \
    "$(needs "$WORK/$old" disfluency)" "returns json (script), parse vectors (script), runner python (script)"
  check "$old: sentence_repair gets what its script declares" \
    "$(needs "$WORK/$old" sentence_repair)" \
    "returns json (script), parse true (script), readings true (script), runner python (script)"
done
check "a written parse: vectors stays" \
  "$(needs "$WORK/vectors-v1" disfluency)" "returns json (script), parse vectors (config), runner python (script)"
check "a value the example never shipped stays" \
  "$(needs "$WORK/vectors-v1" sentence_repair)" \
  "returns json (script), parse true (script), readings false (config), runner python (script)"
check "a built-in script under another name loses the shipped values" \
  "$(needs "$WORK/user-v1" tidy)" "returns json (script), parse vectors (script), runner python (script)"
check "a one-line flow mapping loses the shipped values" \
  "$(needs "$WORK/flow-v1" disfluency)" "returns json (script), parse vectors (script), runner python (script)"
check "and so does a prompts: entry" \
  "$(needs "$WORK/flow-v1" dates)" "returns json (script), runner python (script)"
check "a program of the user's keeps its keys" \
  "$(needs "$WORK/user-v1" mine)" "returns json (config), parse true (config)"

echo
printf '  %d/%d\n' "$pass" "$total"
[ "$pass" = "$total" ]
