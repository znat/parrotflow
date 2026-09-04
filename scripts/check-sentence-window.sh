#!/usr/bin/env bash
# Checks the window a boundary is read over, against tests/sentence-window-cases.json.
#
#   scripts/check-sentence-window.sh
#
# `SentenceReadings.build` is the deterministic half of a reading: the mark
# taken off the left half, twelve words kept each side, the first word on the
# right with and without its capital, and one continuation per reading in the
# order the winner is picked from. scripts/check-sentence-probe.sh compares a
# build against the scores an earlier build produced, so a mistake in the window
# would be regenerated into that fixture and never seen. Every expectation here
# was written from the rules, not from a run.
#
# No model. `--sentence-probe --window` builds the window and stops, so this
# runs in CI. A case whose `want` is null expects no window and exit 1.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

WORK="$(mktemp -d -t parrotflow-sentence-window)"
trap 'rm -rf "$WORK"' EXIT
# The shipped marks, not whatever this machine is tuned to.
export PARROTFLOW_CONFIG_DIR="$WORK/config"

exec python3 - "$ROOT" "$BIN" <<'PY'
import json, subprocess, sys
from pathlib import Path

root, binary = Path(sys.argv[1]), sys.argv[2]
cases = json.load(open(root / "tests/sentence-window-cases.json"))

passed = 0
for case in cases:
    command = [binary, "--sentence-probe", "--window"]
    if case.get("bare"):
        command.append("--bare")
    command += [case["left"], case["right"]]
    run = subprocess.run(command, capture_output=True, text=True)
    want = case["want"]
    if want is None:
        got = run.stdout.strip()
        ok = run.returncode == 1
    else:
        try:
            got = json.loads(run.stdout)
        except ValueError:
            got = run.stdout.strip()
        ok = run.returncode == 0 and got == want
    if ok:
        passed += 1
        print("  ✓  " + case["why"])
    else:
        print("  ✗  " + case["why"])
        print("      want  " + json.dumps(want, ensure_ascii=False))
        print("      got   " + json.dumps(got, ensure_ascii=False)
              + "  (exit %d)" % run.returncode)

print()
if not cases:
    print("  ✗ no cases read from tests/sentence-window-cases.json")
    sys.exit(1)
print("  %d/%d  (tests/sentence-window-cases.json)" % (passed, len(cases)))
sys.exit(0 if passed == len(cases) else 1)
PY
