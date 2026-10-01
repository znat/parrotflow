#!/usr/bin/env bash
# Checks the second look at focus when the words of a press with nowhere to
# type are ready: paste only into a field of the app the press was in.
#
#   scripts/check-landing.sh
#
# The rule only. Reading focus needs a real app in front and stays manual.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

exec "$BIN" --landing-test 2>/dev/null
