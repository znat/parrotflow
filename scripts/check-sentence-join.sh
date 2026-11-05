#!/usr/bin/env bash
# Scores the `sentence_repair` transform's joins against
# tests/sentence-boundary-cases.json.
#
#   scripts/check-sentence-join.sh
#
# Half the cases are real sentence endings and half are pauses that cut one
# sentence in two, in both the period and the question-mark shape. Two more
# shapes carry their readings and are checked on drift alone, because neither
# has a real/cut pair: a capital with no mark in front of it, and a full stop
# in front of a lowercase word. Two numbers decide per paired shape: how many
# cuts were repaired, and how many real endings were joined by mistake. A
# joined real ending is a sentence nobody wrote, with nothing on screen to say
# so, so one of those fails the run.
#
# Each case goes through the transform with the parse and the readings the
# binary hands it. Each case also carries the readings measured when the set was
# built, and this compares the binary's against them. That is what says the app
# reads a boundary the same way the measurement did; without it the counts
# describe some other pipeline.
#
# Not in `make test` and not in CI: it needs the 320 MB model, which CI has no
# business downloading. Run it by hand after touching `ReadingsField` or the
# transform. Nothing is downloaded here either.
#
# Runs against a scratch PARROTFLOW_CONFIG_DIR, so the marks are the shipped
# defaults rather than whatever this machine is tuned to.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -x "$ROOT/.build/release/ParrotFlow" ] || {
  echo "build first: swift build -c release"; exit 1; }

WORK="$(mktemp -d -t parrotflow-sentence-join)"
trap 'rm -rf "$WORK"' EXIT
export PARROTFLOW_CONFIG_DIR="$WORK"

exec python3 - "$ROOT" <<'PY'
import importlib.util, json, sys
from pathlib import Path

root = Path(sys.argv[1])
binary = str(root / ".build/release/ParrotFlow")
cases = json.load(open(root / "tests/sentence-boundary-cases.json"))
spec = importlib.util.spec_from_file_location(
    "score", root / "built-in/transforms/sentence_repair/score.py")
score = importlib.util.module_from_spec(spec)
spec.loader.exec_module(score)

# The set stores the two halves already windowed to twelve words each, which is
# the window the app builds. Glued back into one text with the case's own mark,
# the boundary the app finds is the one the set is about.
def mark_of(case):
    return case.get("mark", ".")


def text_of(case):
    return case["left"].rstrip(".?!") + mark_of(case) + " " + case["right"]


def language_of(case):
    return "fr" if case["set"].startswith("fr_") else "en"


ran = score.through(binary, [(text_of(c), language_of(c)) for c in cases])

DRIFT = 0.05
tally = {name: {} for name in
         ("en_real.json", "en_cuts.json", "enq_real.json", "enq_cuts_hard.json",
          "bare-capitals", "en_lowercase.json", "fr_lowercase.json")}
drifted = []

for case in cases:
    text = text_of(case)
    if text not in ran:
        print("  ✗ the app ran no transform on: " + text)
        sys.exit(1)
    _, edits, recorded = ran[text]
    at = len(case["left"].rstrip(".?!"))
    removed = any(e.start <= at < e.end and e.rule in ("join", "period") for e in edits)
    lowered = any(e.start == at + len(mark_of(case)) + 1 and e.rule == "capital" for e in edits)
    decision = "join" if removed or lowered else "leave"
    counts = tally.setdefault(case["set"], {})
    counts[decision] = counts.get(decision, 0) + 1
    read = next((b for b in (recorded["readings"] or {}).get("boundaries", []) if b["at"] == at), None)
    gap, mark = 0.0, " "
    if read:
        gap = max(abs(read["means"].get(k, 0) - v) for k, v in case["mean"].items())
        if gap > DRIFT:
            drifted.append((text, case["winner"], read["winner"], gap))
            mark = "✗"
    print("  %s  %-10s %-5s stored %-5s  %s  %s" % (
        mark, case["set"].removeprefix("en").removeprefix("_").removesuffix(".json"),
        decision, case["winner"], "gap %.4f" % gap if read else "no reading", case["left"][:44]))

def row(name, key):
    counts = tally[key]
    total = sum(counts.values())
    listed = ", ".join("%d %s" % (n, k) for k, n in sorted(counts.items()))
    print("  %-16s %s  (of %d)" % (name, listed, total))
    return counts, total

print()
shapes = (
    ("period", "en_cuts.json", "en_real.json"),
    ("question", "enq_cuts_hard.json", "enq_real.json"),
)
false_joins = 0
for shape, cut_key, real_key in shapes:
    cuts, cut_total = row(shape + " cuts", cut_key)
    real, real_total = row(shape + " real", real_key)
    if not cut_total or not real_total:
        print("  ✗ no %s cases read from tests/sentence-boundary-cases.json" % shape)
        sys.exit(1)
    wrong = real.get("join", 0)
    false_joins += wrong
    print("  %d%% of %s cuts repaired, %.1f false joins per 100 real endings" % (
        round(100 * cuts.get("join", 0) / cut_total), shape,
        100 * wrong / real_total))
    print()

# A capital with no mark has no reading: the transform's capitals rule decides,
# and tests/bare-capital-cases.json scores it. A full stop in front of a
# lowercase word has no reading either: the period goes by rule, unless the
# word before it is an abbreviation.
for name, key in (("bare capitals", "bare-capitals"),
                  ("lowercase en", "en_lowercase.json"),
                  ("lowercase fr", "fr_lowercase.json")):
    counts, total = row(name, key)
    if total:
        print("  %d joined, %d left" % (counts.get("join", 0), total - counts.get("join", 0)))
        print()

if drifted:
    print()
    print("  ✗ %d case(s) read differently from the stored measurement:" % len(drifted))
    for text, want, got, gap in drifted:
        print("      stored %-5s got %-5s gap %.4f   %s" % (want, got, gap, text))

sys.exit(1 if drifted or false_joins else 0)
PY
