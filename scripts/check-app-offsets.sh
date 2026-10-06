#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/app-offsets-tests
swiftc -module-cache-path .build/app-offsets-tests/cache \
  Sources/ParrotFlow/AppOffsets.swift tests/AppOffsetsTests.swift \
  -o .build/app-offsets-tests/check
.build/app-offsets-tests/check
