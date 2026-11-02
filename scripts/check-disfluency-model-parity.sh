#!/usr/bin/env bash
# Compares the Swift tree cutter and cut filter with the PyTorch reference,
# case by case: the same candidates, the same kept cuts, P(real) within 1e-3,
# the same cut and the same output.
#
#   scripts/check-disfluency-model-parity.sh
#
# Needs the model, so it is not in `make test`. It fetches the model on first
# use. PARROTFLOW_SYRINX_ENDPOINT points the fetch at a mirror and
# CFFIXED_USER_HOME at a scratch home; both are passed through.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

CASES="$ROOT/tests/disfluency-model-parity.json"
WORK="$(mktemp -d -t parrotflow-tree-cut-parity)"
trap 'rm -rf "$WORK"' EXIT
export PARROTFLOW_CONFIG_DIR="$WORK/config"

python3 - "$CASES" "$WORK/items.json" <<'EOF' || { echo "  ✗ $CASES could not be read"; exit 1; }
import json, sys
json.dump([dict(id=c["id"], text=c["text"]) for c in json.load(open(sys.argv[1]))], open(sys.argv[2], "w"),
          ensure_ascii=False)
EOF

if ! "$BIN" --tree-cut --batch "$WORK/items.json" > "$WORK/got.jsonl" 2> "$WORK/stderr"; then
  tail -3 "$WORK/got.jsonl" "$WORK/stderr"
  echo "  ✗ the tree cutter did not run"
  exit 1
fi

python3 - "$CASES" "$WORK/got.jsonl" <<'EOF'
import json, sys
want = json.load(open(sys.argv[1]))
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
    if case.get("abstain") != row.get("declined"):
        problems.append(f"declined: want {case.get('abstain')} got {row.get('declined')}")
    mine = {tuple(c["words"]): c for c in row.get("candidates", [])}
    theirs = {tuple(c["words"]): c for c in case["candidates"]}
    if set(mine) != set(theirs):
        problems.append(f"candidates: want {sorted(theirs)} got {sorted(mine)}")
    for words in set(mine) & set(theirs):
        diff = abs(mine[words]["p_real"] - theirs[words]["p_real"])
        worst = max(worst, diff)
        if diff > 1e-3 or mine[words]["kept"] != theirs[words]["kept"]:
            problems.append(f"{list(words)}: want {theirs[words]['p_real']:.6f} {theirs[words]['kept']}"
                            f" got {mine[words]['p_real']:.6f} {mine[words]['kept']}")
    for key in ("view", "cut", "output"):
        if row.get(key) != case[key]:
            problems.append(f"{key}: want {case[key]!r}\n          got  {row.get(key)!r}")
    passed += not problems
    if problems:
        print(f"  ✗ {case['id']}: {case['text'][:80]!r}")
        for p in problems:
            print(f"      {p}")
print(f"\n  {passed}/{len(want)}  (tests/disfluency-model-parity.json), largest P(real) difference {worst:.2e}")
print(f"  load {summary.get('load_s', 0):.2f} s, first {summary.get('first_ms', 0):.0f} ms, "
      f"then median {summary.get('median_ms', 0):.1f} ms, slowest {summary.get('max_ms', 0):.1f} ms")
sys.exit(0 if passed == len(want) else 1)
EOF
