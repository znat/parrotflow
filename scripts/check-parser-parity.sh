#!/usr/bin/env bash
# Compares the Swift parser with the PyTorch reference, item by item.
#
#   scripts/check-parser-parity.sh
#
# Needs the model, so it is not in `make test`. It fetches the model on first
# use. PARROTFLOW_SYRINX_ENDPOINT points the fetch at a mirror; the files it
# serves must match the hashes pinned in SyrinxModel.swift.
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

# A cache built for other pinned hashes must be fetched again, never loaded.
# The fetch goes to a closed port, so it fails fast and the parse abstains.
STALE="$WORK/home/Library/Application Support/ParrotFlow/models/parrotflow-syrinx"
mkdir -p "$STALE"
zeros=0000000000000000000000000000000000000000000000000000000000000000
printf '{"pinned":{"syrinx.safetensors":"%s"},"files":{"syrinx.safetensors":"%s"}}' "$zeros" "$zeros" > "$STALE/digests.json"
out="$(CFFIXED_USER_HOME="$WORK/home" PARROTFLOW_SYRINX_ENDPOINT=http://127.0.0.1:9 "$BIN" --parse "we can try" 2>&1)"
if grep -q "from another release; fetching it again" <<< "$out" && grep -q "✗ parser unavailable" <<< "$out"; then
  echo "  ✓ a cache from another release is fetched again, not loaded"
else
  echo "  ✗ a cache from another release was not refetched:"
  grep -v "ParrotFlow\[" <<< "$out" | sed 's/^/      /'
  status=1
fi
exit $status
