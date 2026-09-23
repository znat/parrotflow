#!/usr/bin/env bash
# Runs built-in/recipes/runner.py against a fake app and a fake Jev.
#
#   scripts/check-recipe-runner.sh
#
# No screen, no network. See tests/recipe-runner.py.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/tests/recipe-runner.py"
