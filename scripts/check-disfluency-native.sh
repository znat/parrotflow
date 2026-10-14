#!/usr/bin/env bash
# The native `disfluency` stage against Python's string rules, case by case.
#
#   scripts/check-disfluency-native.sh [cases.json]
#
# tests/disfluency-native-cases.json holds what `collapse()` in
# built-in/transforms/disfluency/disfluency.py returns for each input, written
# by scripts/generate-disfluency-native-cases.py. Each case runs through the
# binary with tests/pipelines/disfluency-native.yaml, with no parser cached
# and its download pointed at a closed port, so the correction rule never runs.
# The text, `applied` and `edits` must match, and `declined` must say the parser
# did not load exactly when a correction is said. The run must publish these
# variables and no others, so a stray `disfluency.needs` fails it too.
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
mkdir -p "$WORK/home"
export CFFIXED_USER_HOME="$WORK/home"
export PARROTFLOW_SYRINX_ENDPOINT="http://127.0.0.1:9"

python3 -c '
import concurrent.futures, json, re, subprocess, sys

binary, fixture, path = sys.argv[1:4]
cases = json.load(open(path, encoding="utf-8"))["cases"]

NAMES = {
    "disfluency.applied", "disfluency.changed", "disfluency.declined", "disfluency.edits",
    "disfluency.ms", "disfluency.ok", "disfluency.ran",
    "language", "vocabulary.changes", "vocabulary.count",
}
VAR = re.compile(r"var   (\S+) = (.*)")


def run(case):
    try:
        out = subprocess.run(
            [binary, "--pipeline", fixture, case["input"], "--quiet", "--vars"],
            capture_output=True, text=True, encoding="utf-8", timeout=30,
        ).stdout
    except subprocess.TimeoutExpired:
        return "<timed out after 30 s>", {}
    lines = out.split("\n")
    found = {}
    for line in lines[:len(NAMES)]:
        match = VAR.fullmatch(line)
        if match:
            found[match.group(1)] = match.group(2)
    text = "\n".join(lines[len(NAMES):])
    if text.endswith("\n"):
        text = text[:-1]
    return text, found


def want(case):
    text = case.get("text", case["input"])
    return text, {
        "disfluency.ran": "true",
        "disfluency.ok": "true",
        "disfluency.changed": "true" if text != case["input"] else "false",
        "disfluency.applied": "\"%s\"" % case.get("applied", ""),
        "disfluency.edits": str(case.get("edits", 0)),
    }


def declined_as_wanted(case, found):
    value = found.get("disfluency.declined", "<absent>")
    if "declined" in case:
        return value.startswith("\"%s (" % case["declined"])
    return value == "\"\""


with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    results = list(pool.map(run, cases))

failed = 0
for case, (text, found) in zip(cases, results):
    wanted_text, wanted_vars = want(case)
    wrong = sorted("%s = %s, want %s" % (name, found.get(name, "<absent>"), value)
                   for name, value in wanted_vars.items() if found.get(name) != value)
    if not declined_as_wanted(case, found):
        wrong.append("disfluency.declined = %s, want %s" % (
            found.get("disfluency.declined", "<absent>"), case.get("declined", "empty")))
    unexpected = sorted(set(found) ^ NAMES)
    if text == wanted_text and not wrong and not unexpected:
        continue
    failed += 1
    if failed <= 20:
        print("  ✗ %r" % case["input"])
        if text != wanted_text:
            print("      got   %r\n      want  %r" % (text, wanted_text))
        for line in wrong:
            print("      %s" % line)
        if unexpected:
            print("      variables not as expected: %s" % ", ".join(unexpected))
if failed > 20:
    print("  … and %d more" % (failed - 20))
print("\n  %d/%d  (%s)" % (len(cases) - failed, len(cases), path))
sys.exit(1 if failed or not cases else 0)
' "$BIN" "$ROOT/tests/pipelines/disfluency-native.yaml" "$CASES" || exit 1

status=0
expect() {  # expect <name> <got> <want>
  if [ "$2" = "$3" ]; then printf '  ✓ %s\n' "$1"; else printf '  ✗ %s\n      got   %s\n      want  %s\n' "$1" "$2" "$3"; status=1; fi
}
sed 's/^languages: \[en\]$/languages: [fr]/' "$ROOT/tests/pipelines/disfluency-native.yaml" > "$WORK/french.yaml"
expect "French is not read for corrections, so the parser is not asked" \
  "$("$BIN" --pipeline "$WORK/french.yaml" "avec Pierre, no, avec Jacques" --vars --quiet 2>/dev/null | grep -E 'declined|^avec' | tr '\n' '|')" \
  'var   disfluency.declined = ""|avec Pierre, no, avec Jacques|'
exit $status
