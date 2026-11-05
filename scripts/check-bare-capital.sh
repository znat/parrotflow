#!/usr/bin/env bash
# A capital with no mark in front of it: is it a name, or a pause?
#
#   scripts/check-bare-capital.sh
#
# Scores the `sentence_repair` transform's capitals rule against
# tests/bare-capital-cases.json, mined from real dictation and labelled by hand.
# Each case goes through the transform with the parse the binary hands it.
# `cost: true` marks a case the rule is known to get wrong; it is printed and
# does not fail the run. Three are the transform's: it reads no pause, so two
# real sentence starts the decoder wrote with no mark are lowercased, and the
# parse keeps one capital that a pause put there.
#
# Not in `make test` and not in CI: it needs the syrinx parser on disk.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

exec python3 - "$ROOT" "$BIN" <<'PY'
import importlib.util, json, sys
from pathlib import Path

root, binary = Path(sys.argv[1]), sys.argv[2]
spec = importlib.util.spec_from_file_location(
    "score", root / "built-in/transforms/sentence_repair/score.py")
score = importlib.util.module_from_spec(spec)
spec.loader.exec_module(score)

cases = json.load(open(root / "tests/bare-capital-cases.json"))
def text_of(case):
    return case["left"].rstrip() + " " + case["right"]

ran = score.through(binary, [(text_of(c), "en") for c in cases])
print()
ok = bad = cost = 0
for case in cases:
    text = text_of(case)
    if text not in ran:
        cost += 1
        print(f"  ·  {case['word']:12} reads as a spoken command, so no transform runs")
        continue
    at = len(case["left"].rstrip()) + 1
    _, edits, _ = ran[text]
    lowered = any(e.start == at and e.rule == "capital" for e in edits)
    got = "lower" if lowered else "keep"
    right = got == case["want"]
    if case.get("cost"):
        cost += 1
        print(f"  ·  {case['word']:12} want {case['want']:5} got {got:5} — {case['why']}")
        continue
    ok, bad = ok + right, bad + (not right)
    if not right:
        print(f"  ✗  {case['word']:12} want {case['want']:5} got {got:5} — {case['why']}")
print()
print(f"  {ok}/{len(cases) - cost}  and {cost} known costs  (tests/bare-capital-cases.json)")
sys.exit(0 if bad == 0 else 1)
PY
