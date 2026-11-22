#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=.build/terminal-grid-tests
mkdir -p "$OUT"
swiftc -parse-as-library -module-cache-path "$OUT/cache" \
  Sources/ParrotFlow/TerminalGrid.swift tests/TerminalGridTests.swift -o "$OUT/grid"
swiftc -parse-as-library -module-cache-path "$OUT/cache" \
  Sources/ParrotFlow/TerminalGrid.swift Sources/ParrotFlow/InputRow.swift \
  tests/InputRowTests.swift -o "$OUT/row"
"$OUT/grid"
"$OUT/row"
