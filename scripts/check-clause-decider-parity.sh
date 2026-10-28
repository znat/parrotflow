#!/usr/bin/env bash
# Compares the Swift clause decider with the PyTorch reference, case by case:
# the same decision, p and z within 1e-4, every feature within 1e-4 (absent
# where the reference has it absent), the same clause offsets.
#
#   scripts/check-clause-decider-parity.sh [cases.json]
#
# Needs the parser, so it is not in `make test`. It fetches the model on first
# use. PARROTFLOW_SYRINX_ENDPOINT points the fetch at a mirror and
# CFFIXED_USER_HOME at a scratch home; both are passed through. For text that
# is not committed: CLAUSE_ITEMS=<items.json> with the cases file
# `scripts/clause-decider-reference.py --batch <items.json>` wrote from it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

CASES="${1:-$ROOT/tests/clause-decider-parity.json}"
WORK="$(mktemp -d -t parrotflow-clause-parity)"
trap 'rm -rf "$WORK"' EXIT
export PARROTFLOW_CONFIG_DIR="$WORK/config"

python3 - "$CASES" "$WORK/items.json" <<'EOF' || { echo "  ✗ $CASES could not be read"; exit 1; }
import json, sys
cases = json.load(open(sys.argv[1]))
json.dump([{k: c[k] for k in ("id", "text", "a", "b", "heard", "term", "uses")} for c in cases if "text" in c],
          open(sys.argv[2], "w"), ensure_ascii=False)
EOF

ITEMS="$WORK/items.json"
if [ -n "${CLAUSE_ITEMS:-}" ]; then ITEMS="$CLAUSE_ITEMS"; fi
if ! "$BIN" --clause-decide --batch "$ITEMS" > "$WORK/got.jsonl" 2> "$WORK/stderr"; then
  tail -3 "$WORK/got.jsonl" "$WORK/stderr"
  echo "  ✗ the clause decider did not run"
  exit 1
fi

python3 - "$CASES" "$WORK/got.jsonl" <<'EOF'
import json, sys
want = [c for c in json.load(open(sys.argv[1])) if "decision" in c]
got, summary = {}, {}
for line in open(sys.argv[2]):
    if line.startswith("{"):
        row = json.loads(line)
        if "summary" in row:
            summary = row["summary"]
        else:
            got[row["id"]] = row
passed, worst = 0, 0.0
for case in want:
    row = got.get(case["id"], {})
    problems = []
    if row.get("decision") != case["decision"]:
        problems.append(f"decision: want {case['decision']} got {row.get('decision')}")
    for key in ("p", "z"):
        if key not in row:
            problems.append(f"{key}: missing")
            continue
        diff = abs(row[key] - case[key])
        worst = max(worst, diff)
        if diff > 1e-4:
            problems.append(f"{key}: want {case[key]:.6f} got {row[key]:.6f}")
    mine = row.get("features", {})
    for name, value in case["features"].items():
        if name not in mine:
            problems.append(f"{name}: missing")
            continue
        other = mine.get(name)
        if value is None or other is None:
            if value != other:
                problems.append(f"{name}: want {value} got {other}")
            continue
        diff = abs(value - other)
        worst = max(worst, diff)
        if diff > 1e-4:
            problems.append(f"{name}: want {value:.6f} got {other:.6f}")
    if row.get("clause") != case["clause"]:
        problems.append(f"clause: want {case['clause']} got {row.get('clause')}")
    passed += not problems
    if problems:
        print(f"  ✗ {case['id']}")
        for p in problems:
            print(f"      {p}")
print(f"\n  {passed}/{len(want)}  ({sys.argv[1].split('/')[-1]}), largest difference {worst:.2e}")
print(f"  first {summary.get('first_ms', 0):.0f} ms, then median {summary.get('median_ms', 0):.1f} ms,"
      f" slowest {summary.get('max_ms', 0):.1f} ms per place (rows parsed uncached)")
sys.exit(0 if passed == len(want) else 1)
EOF
