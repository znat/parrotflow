#!/usr/bin/env bash
# Checks that the identifiers script the app writes is the one in examples/.
#
# There are two copies: examples/identifiers.py, which is what you read, edit
# and score with scripts/validate-identifiers.py, and the string in
# Config.defaultIdentifiersScript, which is what a new install actually gets.
# They drift, and the drift is silent — the set would keep scoring 100% on a
# file nobody runs while every install got the old one.
#
# The same trap config.example.yaml is in, and the same fix.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

embedded="$(awk '
  /static let defaultIdentifiersScript = #"""/ { inside = 1; next }
  inside && /^"""#/ { exit }
  inside { print }
' "$ROOT/Sources/ParrotFlow/Config.swift")"

if [ -z "$embedded" ]; then
  echo "  ✗ could not find defaultIdentifiersScript in Config.swift"
  exit 1
fi

if diff -u <(printf '%s\n' "$embedded") "$ROOT/examples/identifiers.py" > /tmp/identifiers.diff; then
  printf '  ✓ the shipped identifiers.py is examples/identifiers.py  (%s lines)\n' \
    "$(printf '%s\n' "$embedded" | wc -l | tr -d ' ')"
  exit 0
fi

echo "  ✗ examples/identifiers.py and Config.defaultIdentifiersScript differ:"
sed -n '1,40p' /tmp/identifiers.diff
echo
echo "  edit examples/identifiers.py, then copy it into Config.defaultIdentifiersScript."
exit 1
