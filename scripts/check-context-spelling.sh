#!/usr/bin/env bash
# Scores context spelling on invented screens, against
# tests/context-spelling-cases.json.
#
#   scripts/check-context-spelling.sh [cases.json]
#
# Each case is a dictation, the screen it was said over, and the text the
# app should write. Needs the sentence model already cached, and fails
# without it; nothing here downloads it. Runs under a scratch config, so the
# live one is not touched.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
CASES="${1:-$ROOT/tests/context-spelling-cases.json}"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

WORK="$(mktemp -d -t parrotflow-context-spelling)"
trap 'rm -rf "$WORK"' EXIT

PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" --context-spelling-test "$CASES" \
  > "$WORK/rows.json" 2> "$WORK/err.txt" < /dev/null
code=$?
[ "$code" -eq 0 ] || { echo "Failed: context-spelling — exit $code"; cat "$WORK/rows.json"; exit 1; }

python3 - "$CASES" "$WORK/rows.json" <<'EOF'
import json, sys
cases = json.load(open(sys.argv[1]))
rows = json.load(open(sys.argv[2]))
failed = 0
for case, row in zip(cases, rows):
    if row["output"] == case["want"]:
        print(f"  ✓ {case['note']}")
    else:
        failed += 1
        print(f"  ✗ {case['note']}\n      want  {case['want']}\n      got   {row['output']}")
if len(rows) != len(cases):
    failed += 1
    print(f"  ✗ {len(rows)} rows for {len(cases)} cases")
print(f"{len(cases) - failed} of {len(cases)}")
print("Every check passed." if failed == 0 else "Failed: context-spelling")
sys.exit(1 if failed else 0)
EOF
