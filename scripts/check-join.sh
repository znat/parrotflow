#!/usr/bin/env bash
# Scores the `join` transform against examples/transforms/join/cases.yaml.
#
#   scripts/check-join.sh
#
# Runs the deployed script, on the envelope it really receives — `--eval` cannot,
# because this transform reads `ctx.vars.input.*` and the eval harness feeds a
# transcript and nothing else. Same reason `code_identifiers` has a runner of
# its own.
#
# Counts the two failures separately. Leaving a transcript unjoined is a miss.
# Reformatting one that was already right is a rewrite, and that is the one this
# stage exists not to do — it costs you your own wording, silently.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The tags come from the app, so the binary is a prerequisite and not an
# optional extra: without it every case is scored against no tags at all.
[ -x "$ROOT/.build/release/ParrotFlow" ] || {
  echo "build first: swift build -c release"; exit 1; }
exec python3 - "$ROOT" <<'PY'
import json, subprocess, sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("pip install pyyaml")

root = Path(sys.argv[1])
transform = root / "examples/transforms/join/join.py"
cases = yaml.safe_load((root / "examples/transforms/join/cases.yaml").read_text())["cases"]

passed = missed = rewrote = 0
for case in cases:
    # Tags come from the app, not from the case file: a fixture would score
    # itself rather than the tagger the transform actually receives.
    # `--lang` is passed rather than left to fall back to the first configured
    # language, so the score does not move with whoever's config is on the
    # machine. A case says `lang: fr` when it needs the French tagger.
    tagged = subprocess.run([str(root / ".build/release/ParrotFlow"),
                             "--tag", case["input"], "--lang", case.get("lang", "en")],
                            capture_output=True, text=True)
    try:
        tokens = json.loads(tagged.stdout.strip().splitlines()[-1])
    except Exception:
        tokens = []
    vars = {"input": {"before": case.get("before"), "after": case.get("after")}}
    # `protected:` is a mapping of stage -> terms, because that is the shape the
    # transform reads: `ctx.vars` nests by stage, so the stage that wrote a term
    # is the namespace it arrives under. A case says who protected what.
    for stage, terms in (case.get("protected") or {}).items():
        vars[stage] = {"protected": terms}
    envelope = {"text": case["input"], "tokens": tokens, "ctx": {"vars": vars}}
    done = subprocess.run([sys.executable, str(transform)],
                          input=json.dumps(envelope), capture_output=True, text=True)
    try:
        reply = json.loads(done.stdout)
        got = reply["text"]
        applied = (reply.get("vars") or {}).get("applied", "")
    except Exception:
        got, applied = f"<unparseable: {done.stdout[:60]!r} {done.stderr[:60]!r}>", ""
    want = case.get("expect", case["input"])
    # `rule:` is optional and asserts *why*. A case that passes for the wrong
    # reason is the failure an input/output set cannot see, and this evening
    # produced three of them.
    rule = case.get("rule")
    if rule and rule not in applied.split(", "):
        missed += 1
        print(f"  ✗ [{case.get('probe','')}] {case['input']!r} — right answer, wrong rule")
        print(f"      want rule {rule!r}")
        print(f"      applied   {applied!r}")
        continue

    if got == want:
        passed += 1
        print(f"  ✓ [{case.get('probe','')}] {case['input']!r}"
              + (f"  {applied}" if applied else ""))
    else:
        if want == case["input"]:
            rewrote += 1
            mark = "rewrote something correct"
        else:
            missed += 1
            mark = "not the join it wanted"
        print(f"  ✗ [{case.get('probe','')}] {case['input']!r} — {mark}")
        print(f"      before {case.get('before')!r}  after {case.get('after')!r}")
        print(f"      want   {want!r}")
        print(f"      got    {got!r}")

print()
print(f"{passed}/{len(cases)}   missed {missed}   rewrote {rewrote}")
sys.exit(0 if passed == len(cases) else 1)
PY
