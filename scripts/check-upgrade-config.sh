#!/usr/bin/env bash
# Upgrades each config in tests/upgrade-config/ with `--upgrade-config --write`.
#
#   scripts/check-upgrade-config.sh
#
# `<name>.yaml` is the file before. `<name>.want.yaml` is the file after, byte
# for byte; without one the file must not change. Each upgraded file must pass
# `--check-config`, keep the old file as a backup, and come out of a second run
# unchanged. `example-v0.yaml` is built-in/config.example.yaml before version 1:
# upgraded, it must run the pipeline the shipped example runs.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${PARROTFLOW_BIN:-$ROOT/.build/release/ParrotFlow}"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }
CASES="$ROOT/tests/upgrade-config"

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
  check "$name: the file" "$(cmp -s "$want" "$dir/config.yaml" && echo same || diff "$want" "$dir/config.yaml" | head -5)" "same"

  backups=("$dir"/config.yaml.bak-*)
  if [ "$want" = "$before" ]; then
    check "$name: no backup" "$([ -e "${backups[0]}" ] && echo "${backups[0]##*/}")" ""
    continue
  fi
  check "$name: the backup is the old file" \
    "$(cmp -s "$before" "${backups[0]}" && echo "${backups[0]##*/}" | sed 's/-[0-9-]*$//')" \
    "config.yaml.bak-v0"

  cp "$dir/config.yaml" "$WORK/$name.after"
  pf "$dir" --upgrade-config --write >/dev/null
  check "$name: a second run changes nothing" \
    "$(cmp -s "$WORK/$name.after" "$dir/config.yaml" && echo same)" "same"

  out="$(pf "$dir" --check-config)"
  check "$name: --check-config passes" "$?" "0"
  check "$name: version 1" "$(printf '%s\n' "$out" | grep -c '✓ version *1$')" "1"
  check "$name: sentence_repair runs" \
    "$(printf '%s\n' "$out" | grep -c '^  · pipeline .*transform sentence_repair')" "1"
done

# What an old config is told before it is upgraded.
dir="$WORK/told"
mkdir -p "$dir"
cp "$CASES/block-enabled.yaml" "$dir/config.yaml"
out="$(pf "$dir" --check-config)"
check "an old config fails --check-config" "$?" "1"
check "it says an upgrade is pending" "$(printf '%s\n' "$out" | grep -c 'version *0 — 1 upgrade(s) pending.*--upgrade-config --write')" "1"
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

mkdir -p "$WORK/example"
cp "$ROOT/built-in/config.example.yaml" "$WORK/example/config.yaml"
check "the upgraded old example runs the shipped example's pipeline" \
  "$(pipeline_line "$WORK/example-v0")" "$(pipeline_line "$WORK/example")"

echo
printf '  %d/%d\n' "$pass" "$total"
[ "$pass" = "$total" ]
