#!/usr/bin/env bash
# The correction rule of the native `disfluency` stage, with the parser loaded.
#
#   scripts/check-disfluency-corrections.sh [cases.yaml]
#
# Not in `make test`: the rule reads parrot-syrinx, a 519 MB download the
# first time. Each case runs through tests/pipelines/disfluency-native.yaml
# with --warm. Fails on any wrong cut: a keep that changed, or a correction
# cut to a text other than its `expect`. A correction left unchanged is a miss
# and is only counted.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }
CASES="${1:-$ROOT/tests/disfluency-corrections-cases.yaml}"

WORK="$(mktemp -d -t parrotflow-corrections)"
trap 'rm -rf "$WORK"' EXIT
export PARROTFLOW_CONFIG_DIR="$WORK"

# One load first, so the parallel runs below find the cache instead of each fetching it.
"$BIN" --pipeline "$ROOT/tests/pipelines/disfluency-native.yaml" "no, I mean it" --quiet --warm >/dev/null 2>&1 \
  || { echo "  ✗ the parser did not load"; exit 1; }

python3 - "$BIN" "$ROOT/tests/pipelines/disfluency-native.yaml" "$CASES" "$WORK" <<'PY'
import collections, concurrent.futures, os, re, subprocess, sys
import yaml

binary, fixture, path, work = sys.argv[1:5]
cases = yaml.safe_load(open(path, encoding="utf-8"))["cases"]
VAR = re.compile(r"var   (\S+) = (.*)")
base = open(fixture, encoding="utf-8").read()


def fixture_for(languages):
    if not languages:
        return fixture
    name = os.path.join(work, "fixture-%s.yaml" % "-".join(languages))
    if not os.path.exists(name):
        text = base.replace("languages: [en]", "languages: [%s]" % ", ".join(languages))
        if text == base:
            sys.exit("  ✗ %s has no `languages: [en]` line to override" % fixture)
        with open(name, "w", encoding="utf-8") as out:
            out.write(text)
    return name


def run(case):
    out = subprocess.run(
        [binary, "--pipeline", fixture_for(case.get("languages")), case["input"], "--quiet", "--warm", "--vars"],
        capture_output=True, text=True, encoding="utf-8", timeout=120,
    ).stdout
    lines = out.split("\n")
    found = dict(m.groups() for m in map(VAR.fullmatch, lines) if m)
    text = "\n".join(line for line in lines if not line.startswith("var   "))
    return (text[:-1] if text.endswith("\n") else text), found


with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    results = list(pool.map(run, cases))

tally = collections.defaultdict(collections.Counter)
wrong = 0
slowest = (0.0, "")
for case, (got, found) in zip(cases, results):
    counts = tally[case.get("set", "")]
    slowest = max(slowest, (float(found.get("disfluency.ms", "0")), case["input"]))
    declined = found.get("disfluency.declined", "<absent>")
    if declined != '""' and not case.get("languages"):
        print("  ✗ %r declined %s" % (case["input"], declined))
        wrong += 1
    if case.get("probe") == "unscored":
        counts["unscored"] += 1
        continue
    if "expect" not in case:
        verdict = "kept" if got == case["input"] else "changed"
    elif got == case["expect"]:
        verdict = "fixed"
    elif got == case["input"]:
        verdict = "missed"
    else:
        verdict = "wrong"
    counts[verdict] += 1
    if verdict in ("changed", "wrong"):
        wrong += 1
        print("  ✗ %s %s: %s\n      got   %s" % (case.get("set", ""), verdict, case["input"], got))
    elif verdict == "missed":
        print("  · %s missed: %s" % (case.get("set", ""), case["input"]))

print()
for name, counts in tally.items():
    print("  %-8s corrections fixed %d, missed %d, wrong %d   keeps kept %d, changed %d"
          % (name, counts["fixed"], counts["missed"], counts["wrong"], counts["kept"], counts["changed"]))
print("  slowest stage %.0f ms: %s" % (slowest[0], slowest[1][:80]))
print("\n  ✓ no wrong cut" if not wrong else "\n  ✗ %d wrong" % wrong)
sys.exit(1 if wrong else 0)
PY
