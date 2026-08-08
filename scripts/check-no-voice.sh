#!/usr/bin/env bash
# Refuses a tree that carries one person's voice.
#
#   scripts/check-no-voice.sh
#
# Recordings of a speaker saying their colleagues' names, and the pronunciation
# table mined from them, are not source. They belong in `voice/` beside the
# config, which `PARROTFLOW_CONFIG_DIR` moves and `.gitignore` keeps out of
# `git add .` — see Sources/ParrotFlow/VoiceStore.swift.
#
# `.gitignore` alone is not enough. It stops `git add .`, not `git add -f`, not
# a file that was tracked before the rule existed, and not a rebase from a
# branch where the audio was committed. This checks what git actually tracks.
#
# The audio does exist, on one branch: `feat/vocabulary-skills-only` froze the
# prototype with `tests/acoustic/` and `tests/pronunciations.yaml` in it. That
# branch is read-only and never merges. This is what stops it arriving anyway.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

pass=0; total=0; failed=""

# refuses <name> <pathspec> — nothing git tracks may match.
refuses() {
  total=$((total + 1))
  local found
  found="$(git ls-files -- "$2" 2>/dev/null)"
  if [ -z "$found" ]; then
    pass=$((pass + 1))
    printf '  ✓ %s\n' "$1"
  else
    failed="$failed
      $1"
    printf '  ✗ %s\n      tracked:\n%s\n' "$1" "$(printf '%s\n' "$found" | sed 's/^/        /')"
  fi
}

refuses "no recordings under tests/acoustic/"   "tests/acoustic"
refuses "no mined pronunciation table in tests/" "tests/pronunciations.yaml"
refuses "no voice/ directory in the repository"  "voice"
# Anywhere at all. A wav that arrives under another name is the same file.
refuses "no .wav anywhere in the repository"     "*.wav"
refuses "no observations.jsonl anywhere"         "*observations.jsonl"

printf '\n  %d/%d\n' "$pass" "$total"
if [ -n "$failed" ]; then
  printf '  failed:%s\n' "$failed"
  printf '\n  Speaker audio and mined pronunciations live in voice/ beside the\n'
  printf '  config, never in git. Move them there and remove them from the index.\n'
  exit 1
fi
