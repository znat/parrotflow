#!/usr/bin/env bash
# Scores ClaudeSpeakable against tests/claude-voice-cases.yaml. No model, no
# audio, and the flag exits before the config is read.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }
"$BIN" --claude-voice-test "$ROOT/tests/claude-voice-cases.yaml"
