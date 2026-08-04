#!/usr/bin/env bash
# Checks that the transform folder a new install is seeded with is the one in
# examples/transforms/code_identifiers/.
#
#   scripts/check-seeded-transform.sh
#
# There are two copies of every file in that folder: the ones under examples/,
# which are what you read, edit and score with
# scripts/validate-code-identifiers.py, and the strings in Config.swift, which
# are what a new install actually gets. They drift, and the drift is silent —
# the set would keep scoring 91% against a script nobody runs while every
# install got the old one.
#
# The same trap config.example.yaml is in, and the same fix.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FOLDER="$ROOT/examples/transforms/code_identifiers"
SOURCE="$ROOT/Sources/ParrotFlow/Config.swift"

ok=0

# check <file in the folder> <the Swift constant that ships it>
check() {
  local file="$1" constant="$2" embedded
  embedded="$(awk -v marker="static let $constant = #\"\"\"" '
    index($0, marker) { inside = 1; next }
    inside && /^"""#/ { exit }
    inside { print }
  ' "$SOURCE")"

  if [ -z "$embedded" ]; then
    printf '  ✗ could not find %s in Config.swift\n' "$constant"
    ok=1
    return
  fi

  if diff -u <(printf '%s\n' "$embedded") "$FOLDER/$file" > "/tmp/seeded-$file.diff"; then
    printf '  ✓ transforms/code_identifiers/%s is the one in examples/  (%s lines)\n' \
      "$file" "$(printf '%s\n' "$embedded" | wc -l | tr -d ' ')"
  else
    printf '  ✗ examples/transforms/code_identifiers/%s and Config.%s differ:\n' \
      "$file" "$constant"
    sed -n '1,40p' "/tmp/seeded-$file.diff"
    echo
    printf '  edit examples/transforms/code_identifiers/%s, then copy it into Config.%s.\n' \
      "$file" "$constant"
    ok=1
  fi
}

check code_identifiers.py defaultCodeIdentifiersScript
check cases.yaml defaultCodeIdentifiersCases

exit $ok
