#!/usr/bin/env bash
# Compares the Swift parser with the PyTorch reference, item by item.
#
#   scripts/check-parser-parity.sh
#
# Needs the model, so it is not in `make test`. Until the model is published, serve the converter's output with a mirror and
# set PARROTFLOW_HUB_ENDPOINT.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

CASES="$ROOT/tests/parser-parity.json"
WORK="$(mktemp -d -t parrotflow-parser-parity)"
trap 'rm -rf "$WORK"' EXIT
export PARROTFLOW_CONFIG_DIR="$WORK/config"

python3 - "$CASES" "$WORK/items.json" <<'EOF' || { echo "  ✗ $CASES could not be read"; exit 1; }
import json, sys
items = []
for case in json.load(open(sys.argv[1])):
    item = dict(id=case["id"], language=case["language"])
    if "text" in case:
        item["text"] = case["text"]
    else:
        item["words"] = case["words"]
    items.append(item)
json.dump(items, open(sys.argv[2], "w"), ensure_ascii=False)
EOF

if ! "$BIN" --parse --batch "$WORK/items.json" > "$WORK/got.jsonl" 2> "$WORK/stderr"; then
  tail -3 "$WORK/got.jsonl" "$WORK/stderr"
  echo "  ✗ the parser did not run"
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
passed = 0
for case in want:
    row = got.get(case["id"], {})
    if case.get("abstain") == "split":
        ok = row.get("abstain") == "no word split"
    elif case.get("abstain") == "subwords":
        ok = "abstain" in row and "heads" not in row and row.get("words") == case["words"]
    else:
        ok = all(row.get(k) == case[k] for k in ("words", "ids", "heads", "labels", "upos"))
        ok = ok and ("utf16" not in case or row.get("utf16") == case["utf16"])
    passed += ok
    if not ok:
        print(f"  ✗ {case['id']}: {json.dumps(case.get('text') or case['words'], ensure_ascii=False)[:80]}")
        for key in ("words", "utf16", "ids", "heads", "labels", "upos", "abstain"):
            if row.get(key) != case.get(key):
                print(f"      {key:7} want {case.get(key)}\n      {'':7} got  {row.get(key)}")
print(f"\n  {passed}/{len(want)}  (tests/parser-parity.json)")
print(f"  load {summary.get('load_s', 0):.2f} s, first parse {summary.get('first_ms', 0):.0f} ms, "
      f"then median {summary.get('median_ms', 0):.1f} ms, slowest {summary.get('max_ms', 0):.1f} ms, {summary.get('units')}")
sys.exit(0 if passed == len(want) else 1)
EOF
status=$?

if grep -q 'static let revision: String? = nil' "$ROOT/Sources/ParrotFlow/SyrinxModel.swift"; then
  echo "  ✗ SyrinxModel.revision is a placeholder: publish the model and pin its commit"
  exit 1
fi
exit $status
