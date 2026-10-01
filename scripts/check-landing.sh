#!/usr/bin/env bash
# Checks the rules for words that had nowhere to type. At landing: paste only
# into a field of the app the press was in. After a ⌘V by hand: offer only when
# our words are on the clipboard and right before the caret of a field.
#
#   scripts/check-landing.sh
#
# The rules only. Reading focus needs a real app in front and stays manual.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

exec "$BIN" --landing-test 2>/dev/null
