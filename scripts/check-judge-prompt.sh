#!/usr/bin/env bash
# Refuses a harness that scores a prompt the app does not ship.
#
#   scripts/check-judge-prompt.sh
#
# The judge's prompt is compiled into the app (`VocabularyJudge.prompt`).
# `scripts/judge-verdicts.py` carries a copy, because the app is a bundle and a
# Python harness cannot link it. A copy that drifts is worse than no
# measurement: every number in the PR would describe a wording nobody runs.
#
# Compared with the `{terms}` placeholder left in, so this checks the text and
# not one dictation's substitution of it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import pathlib, sys, re
root = pathlib.Path(sys.argv[1])

swift = (root / "Sources/ParrotFlow/VocabularyJudge.swift").read_text()
body = swift.split('static let prompt = """', 1)[1].split('"""', 1)[0]
lines = body.split("\n")[1:-1]
# A Swift multi-line literal is indented to its closing delimiter, and the
# delimiter is on the line this split just dropped. The smallest indent over
# the non-blank lines is the same number, and does not depend on the split.
indent = min((len(l) - len(l.lstrip()) for l in lines if l.strip()), default=0)
compiled = "\n".join(line[indent:] if line.strip() else "" for line in lines).strip()

harness = (root / "scripts/judge-verdicts.py").read_text()
scored = harness.split('PROMPT = """', 1)[1].split('"""', 1)[0].strip()

if compiled == scored:
    print("  ✓ scripts/judge-verdicts.py scores the prompt the app compiles in")
    sys.exit(0)

print("  ✗ the harness and the app disagree about the judge's prompt")
import difflib
for line in difflib.unified_diff(
    compiled.split("\n"), scored.split("\n"),
    fromfile="VocabularyJudge.prompt", tofile="judge-verdicts.py PROMPT", lineterm=""
):
    print("    " + line)
sys.exit(1)
PY
