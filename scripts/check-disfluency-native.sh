#!/usr/bin/env bash
# The native `disfluency` stage against Python's string rules, case by case.
#
#   scripts/check-disfluency-native.sh [cases.json]
#
# tests/disfluency-native-cases.json holds what `collapse()` in
# built-in/transforms/disfluency/disfluency.py returns for each input, written
# by scripts/generate-disfluency-native-cases.py. Each case runs through the
# binary with tests/pipelines/disfluency-native.yaml. The text, `applied`,
# `edits` and `declined` must all match. One difference fails the check.
#
# One run takes about 160 ms but almost no CPU, so the cases run eight at a time.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }
CASES="${1:-$ROOT/tests/disfluency-native-cases.json}"

WORK="$(mktemp -d -t parrotflow-disfluency)"
trap 'rm -rf "$WORK"' EXIT
export PARROTFLOW_CONFIG_DIR="$WORK"

python3 -c '
import concurrent.futures, json, subprocess, sys

binary, fixture, path = sys.argv[1:4]
cases = json.load(open(path, encoding="utf-8"))["cases"]


def run(case):
    try:
        out = subprocess.run(
            [binary, "--pipeline", fixture, case["input"], "--quiet", "--vars"],
            capture_output=True, text=True, encoding="utf-8", timeout=30,
        ).stdout
    except subprocess.TimeoutExpired:
        return "<timed out after 30 s>", set()
    lines = out.split("\n")
    names = [line for line in lines if line.startswith("var   ")]
    text = "\n".join(lines[len(names):])
    if text.endswith("\n"):
        text = text[:-1]
    return text, set(names)


def want(case):
    return case.get("text", case["input"]), {
        "var   disfluency.ran = true",
        "var   disfluency.ok = true",
        "var   disfluency.applied = \"%s\"" % case.get("applied", ""),
        "var   disfluency.edits = %d" % case.get("edits", 0),
        "var   disfluency.declined = \"%s\"" % case.get("declined", ""),
    }


with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    results = list(pool.map(run, cases))

failed = 0
for case, (text, names) in zip(cases, results):
    wanted_text, wanted_vars = want(case)
    missing = sorted(wanted_vars - names)
    if text == wanted_text and not missing:
        continue
    failed += 1
    if failed <= 20:
        print("  ✗ %r" % case["input"])
        if text != wanted_text:
            print("      got   %r\n      want  %r" % (text, wanted_text))
        for line in missing:
            print("      missing  %s" % line)
if failed > 20:
    print("  … and %d more" % (failed - 20))
print("\n  %d/%d  (%s)" % (len(cases) - failed, len(cases), path))
sys.exit(1 if failed or not cases else 0)
' "$BIN" "$ROOT/tests/pipelines/disfluency-native.yaml" "$CASES"
