#!/usr/bin/env bash
# The marker rule's gate, on the native `disfluency` stage with the parser
# loaded.
#
#   scripts/check-disfluency-markers.sh
#
# Not in `make test`: `--eval` loads parrot-syrinx, a 519 MB download the
# first time. The cases are built-in/transforms/disfluency/cases.yaml.
#
#   original cases  every keep comes back unchanged, and every miss differs
#                   from its `expect` only by a marker left in
#   blind probe     the total is at least spaCy's 25/30 and no more than
#                   spaCy's 3 keeps are lost
#   fresh probe     no more than 2 wrong cuts, the count before it was used
#                   to tune the rules
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

WORK="$(mktemp -d -t parrotflow-markers)"
trap 'rm -rf "$WORK"' EXIT
export PARROTFLOW_CONFIG_DIR="$WORK"

"$BIN" --eval disfluency --verbose > "$WORK/eval.txt" 2>/dev/null
python3 - "$WORK/eval.txt" "$ROOT/built-in/transforms/disfluency/cases.yaml" <<'PY'
import re, sys
import yaml

report, path = sys.argv[1:3]
text = open(report, encoding="utf-8").read()
if "parser   parrot-syrinx" not in text:
    sys.exit("  ✗ the parser did not load:\n" + text)
cases = yaml.safe_load(open(path, encoding="utf-8"))["cases"]
got = dict(re.findall(r"  ✗ (.*)  \[.*\]\n(?:      in .*\n)?      got   (.*)\n", text))
overall = re.search(r"overall  (\d+)/(\d+)", text)
if not overall or int(overall.group(2)) != len(cases) or len(got) != len(cases) - int(overall.group(1)):
    sys.exit("  ✗ the eval report does not account for every case:\n" + text)
MARKER = re.compile(r"\b(?:i\s+mean|you\s+know|like)\b", re.I)


def bare(s):
    return re.sub(r"\s+", " ", MARKER.sub(" ", s).replace(",", " ")).strip().lower()


failed = 0
blind = {"cut": [0, 0], "keep": [0, 0]}
fresh = [0, 0, 0]
for case in cases:
    want = case.get("expect", case["input"])
    out = got.get(case["input"], want)
    kind = "keep" if "expect" not in case else "cut"
    if case.get("probe") == "fresh":
        fresh[0] += out == want
        fresh[1] += 1
        fresh[2] += out != want and len(out.split()) < len(want.split())
        continue
    if case.get("probe") == "blind":
        blind[kind][0] += out == want
        blind[kind][1] += 1
        continue
    if out == want:
        continue
    filler_left = kind == "cut" and len(out) > len(want) and bare(out) == bare(want)
    print("  %s %s miss: %s\n      got   %s" % ("·" if filler_left else "✗", kind, case["input"], out))
    failed += not filler_left

total = blind["cut"][0] + blind["keep"][0]
lost = blind["keep"][1] - blind["keep"][0]
print("\n  blind  cut %d/%d  keep %d/%d  total %d/30, spaCy 25/30 with 3 keeps lost"
      % (*blind["cut"], *blind["keep"], total))
if total < 25 or lost > 3:
    print("  ✗ the blind probe is below spaCy")
    failed += 1
print("  fresh  %d/%d  wrong cuts %d, at most 2" % tuple(fresh))
if fresh[2] > 2:
    print("  ✗ the fresh probe cuts more than it did")
    failed += 1
print("  ✓ every original miss is a filler left in" if not failed else "  ✗ %d failure(s)" % failed)
sys.exit(1 if failed else 0)
PY
