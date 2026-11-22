#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/terminal-grid-tests
swiftc -parse-as-library -module-cache-path .build/terminal-grid-tests/cache \
  Sources/ParrotFlow/TerminalGrid.swift tests/TerminalGridTests.swift \
  -o .build/terminal-grid-tests/check
.build/terminal-grid-tests/check
