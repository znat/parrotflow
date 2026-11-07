#!/usr/bin/env bash
# The mini-swe-agent plugin's events, through whole runs. Without mini
# installed it runs on a stub of mini 2.4.6; PYTHON=<mini's python> runs it on
# the real one.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"${PYTHON:-python3}" -I "$ROOT/integrations/mini-swe-agent/tests/test_parrotflow_mini.py"
