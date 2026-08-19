#!/usr/bin/env bash
# What the correction panel proposes, scored on the archive.
#
# Two numbers, and neither is a pass mark on its own. Recall is how many of the
# words that genuinely needed fixing get a row. Rows per sentence is what it
# costs to read the panel. A suggester that proposed every word would score
# 100% recall and be useless.
#
# The ground truth is `tests/judge-cases.yaml`: an `approve` case is one where
# the decoder really did write the wrong word.
set -euo pipefail
cd "$(dirname "$0")/.."

PF=.build/release/ParrotFlow
[ -x "$PF" ] || swift build -c release >/dev/null

python3 - "$PF" <<'PY'
import re, subprocess, sys, collections

pf = sys.argv[1]
cases, cur = [], {}
for line in open("tests/judge-cases.yaml"):
    m = re.match(r'\s*-?\s*(said|heard|term|expect):\s*"?(.*?)"?\s*$', line)
    if not m:
        continue
    key, value = m.group(1), m.group(2)
    if key == "said":
        if cur:
            cases.append(cur)
        cur = {}
    cur[key] = value
if cur:
    cases.append(cur)

sentences, truth = [], collections.defaultdict(set)
for case in cases:
    if case["said"] not in sentences:
        sentences.append(case["said"])
    if case.get("expect") == "approve":
        truth[case["said"]].add(case["heard"].strip(".,?!;:"))

wanted = sum(len(truth[s]) for s in sentences)
found, rows, misses = 0, 0, []
for sentence in sentences:
    out = subprocess.run([pf, "--suggest", sentence], capture_output=True, text=True)
    proposed = {line.split("\t")[0] for line in out.stdout.strip().split("\n") if line}
    rows += len(proposed)
    for word in sorted(truth[sentence]):
        if word in proposed:
            found += 1
        else:
            misses.append(word)

per = rows / len(sentences)
print(f"  {len(sentences)} sentences, {wanted} words that needed fixing")
print(f"  found      {found}/{wanted}")
print(f"  rows       {rows} in total, {per:.1f} per sentence")
print(f"  missed     {', '.join(misses)}")

# Both directions have a floor. Below 10 the proposal has stopped being worth
# reading; above 1.5 rows a sentence the panel is a list to wade through.
# Measured at 12 and 0.4 when this was written.
ok = found >= 10 and per <= 1.5
print(f"\n  {'PASS' if ok else 'FAIL'}  (need 10 or more found, 1.5 or fewer rows per sentence)")
sys.exit(0 if ok else 1)
PY
