#!/usr/bin/env bash
# Compares the Swift syrinx parse with the Python reference on the same Core ML
# package, row by row.
#
#   scripts/check-parser-parity.sh
#
# tests/parser-parity.json is written from the Python side, never from this
# binary. Words, offsets, UPOS, features, heads, labels, NER types and token
# ids must be exact; the tag probabilities within 1e-4; a word's `vector`,
# where the fixture has one, within one float16 step. A row that abstains
# must abstain here too, for any reason.
#
# Needs the parrotflow-syrinx-fp16 model cache, so it is not in `make test`.
# It uses the app's own cache under $HOME and fetches the package there when
# it is missing. A load also removes the retired parrotflow-syrinx and
# parrot-syrinx caches from that folder.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

CASES="$ROOT/tests/parser-parity.json"
WORK="$(mktemp -d -t parrotflow-parser-parity)"
trap 'rm -rf "$WORK"' EXIT
export PARROTFLOW_CONFIG_DIR="$WORK/config"

python3 -c '
import json, sys
json.dump([row["input"] for row in json.load(open(sys.argv[1]))], open(sys.argv[2], "w"), ensure_ascii=False)
' "$CASES" "$WORK/items.json" || { echo "  ✗ $CASES could not be read"; exit 1; }

if ! "$BIN" --parse --batch "$WORK/items.json" --vectors > "$WORK/got.jsonl" 2> "$WORK/stderr"; then
  tail -3 "$WORK/got.jsonl" "$WORK/stderr"
  echo "  ✗ the parser did not run"
  exit 1
fi
python3 -c 'import json, sys; json.dump(json.load(open(sys.argv[1]))[:5], open(sys.argv[2], "w"))' \
  "$WORK/items.json" "$WORK/few.json"
"$BIN" --parse --batch "$WORK/few.json" > "$WORK/plain.jsonl" 2>> "$WORK/stderr"
if ! grep -q '"words"' "$WORK/plain.jsonl" || grep -q '"vector"' "$WORK/plain.jsonl"; then
  echo "  ✗ a word has a vector without --vectors"
  exit 1
fi

python3 - "$CASES" "$WORK/got.jsonl" <<'PY'
import base64, json, struct, sys

def halves(packed):
    raw = base64.b64decode(packed)
    return struct.unpack(f"<{len(raw) // 2}h", raw)

def steps(a, b):
    """The largest gap in float16 steps; sign-magnitude bits made monotonic."""
    order = lambda h: h if h >= 0 else -32768 - h
    x, y = halves(a), halves(b or "")
    return max((abs(order(p) - order(q)) for p, q in zip(x, y)), default=9) if len(x) == len(y) == 384 else 9

vectors = 0
want = json.load(open(sys.argv[1]))
got, summary = {}, {}
for line in open(sys.argv[2]):
    if line.startswith("{"):
        row = json.loads(line)
        if "summary" in row:
            summary = row["summary"]
        else:
            got[row["id"]] = row
EXACT = ("text", "at", "len", "upos", "feats", "head", "deprel", "ner")
passed = 0
for case in want:
    row = got.get(case["id"], {})
    problems = []
    if "abstain" in case or "abstain" in row:
        if ("abstain" in case) != ("abstain" in row):
            problems.append(f"abstain want {case.get('abstain')} got {row.get('abstain')}")
    else:
        if row.get("language") != case["language"]:
            problems.append(f"language want {case['language']} got {row.get('language')}")
        if row.get("tag_names") != case["tag_names"]:
            problems.append(f"tag_names want {case['tag_names']} got {row.get('tag_names')}")
        for key in ("ids", "ner_ids"):
            if [w[key] for w in row.get("windows", [])] != [w[key] for w in case["windows"]]:
                problems.append(f"{key} differ")
        words = row.get("words", [])
        if len(words) != len(case["words"]):
            problems.append(f"{len(words)} words, want {len(case['words'])}")
        for k, (a, b) in enumerate(zip(case["words"], words)):
            for key in EXACT:
                if a[key] != b.get(key):
                    problems.append(f"word {k + 1} {key} want {a[key]!r} got {b.get(key)!r}")
            mine = b.get("tags", [])
            gap = max((abs(x - y) for x, y in zip(a["tags"], mine)), default=9) if len(mine) == len(a["tags"]) else 9
            if gap > 1e-4:
                problems.append(f"word {k + 1} tags differ by {gap:.2g}")
            if "vector" in a:
                vectors += 1
                gap = steps(a["vector"], b.get("vector"))
                if gap > 1:
                    problems.append(f"word {k + 1} vector differs by {gap} float16 steps")
    passed += not problems
    if problems:
        print(f"  ✗ {case['id']}")
        for problem in problems[:6]:
            print(f"      {problem}")
print(f"\n  {passed}/{len(want)}  (tests/parser-parity.json, {vectors} word vectors)")
print(f"  load {summary.get('load_s', 0):.2f} s, first parse {summary.get('first_ms', 0):.0f} ms, "
      f"then median {summary.get('median_ms', 0):.1f} ms, slowest {summary.get('max_ms', 0):.1f} ms, "
      f"peak {summary.get('peak_mb', 0):.0f} MB")
if not vectors:
    print("  ✗ the fixture has no word vectors to compare")
sys.exit(0 if passed == len(want) and vectors else 1)
PY
