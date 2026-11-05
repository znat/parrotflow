#!/usr/bin/env bash
# mypy --strict over the built-in Python: each folder of built-in/transforms on
# its own, then built-in/runner. One folder per run, because dates, money and
# numbers each have an engine.py, en.py and fr.py, and one mypy run refuses two
# modules with one name.
#
#   scripts/check-python-types.sh
#
# Needs mypy and types-PyYAML (the score.py files read YAML). A dev tool only:
# the app never runs it. Settings are in mypy.ini.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
MYPY="${MYPY:-python3 -m mypy}"
$MYPY --version >/dev/null 2>&1 || { echo "  ✗ no mypy: python3 -m pip install mypy types-PyYAML"; exit 1; }

CACHE="$(mktemp -d -t parrotflow-mypy)"
trap 'rm -rf "$CACHE"' EXIT

failed=0
for folder in built-in/transforms/*/ built-in/runner/; do
  files=("$folder"*.py)
  [ -e "${files[0]}" ] || continue
  if out=$($MYPY --config-file mypy.ini --cache-dir "$CACHE" "${files[@]}" 2>&1); then
    printf '  ✓ %s\n' "$folder"
  else
    printf '  ✗ %s\n%s\n' "$folder" "$out"
    failed=1
  fi
done
exit $failed
