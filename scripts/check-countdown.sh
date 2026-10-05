#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/countdown-tests
swiftc -module-cache-path .build/countdown-tests/cache \
  Sources/ParrotFlow/Countdown.swift tests/CountdownTests.swift \
  -o .build/countdown-tests/check
.build/countdown-tests/check
