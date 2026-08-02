#!/usr/bin/env bash
# Checks that the code_identifiers script the app writes is the one in examples/.
#
# There are two copies: examples/code_identifiers.py, which is what you read, edit
# and score with scripts/validate-code-identifiers.py, and the string in
# Config.defaultCodeIdentifiersScript, which is what a new install actually gets.
# They drift, and the drift is silent — the set would keep scoring 100% on a
# file nobody runs while every install got the old one.
#
# The same trap config.example.yaml is in, and the same fix.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

embedded="$(awk '
  /static let defaultCodeIdentifiersScript = #"""/ { inside = 1; next }
  inside && /^"""#/ { exit }
  inside { print }
' "$ROOT/Sources/ParrotFlow/Config.swift")"

if [ -z "$embedded" ]; then
  echo "  ✗ could not find defaultCodeIdentifiersScript in Config.swift"
  exit 1
fi

if diff -u <(printf '%s\n' "$embedded") "$ROOT/examples/code_identifiers.py" > /tmp/code-identifiers.diff; then
  printf '  ✓ the shipped code_identifiers.py is examples/code_identifiers.py  (%s lines)\n' \
    "$(printf '%s\n' "$embedded" | wc -l | tr -d ' ')"
  exit 0
fi

echo "  ✗ examples/code_identifiers.py and Config.defaultCodeIdentifiersScript differ:"
sed -n '1,40p' /tmp/code-identifiers.diff
echo
echo "  edit examples/code_identifiers.py, then copy it into Config.defaultCodeIdentifiersScript."
exit 1
