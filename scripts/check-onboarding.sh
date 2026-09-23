#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/onboarding-tests
swiftc -module-cache-path .build/onboarding-tests/cache \
  Sources/ParrotFlow/OnboardingTour.swift tests/OnboardingTourTests.swift \
  -o .build/onboarding-tests/check
.build/onboarding-tests/check
