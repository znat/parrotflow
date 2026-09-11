#!/usr/bin/env bash
# Does the boundary read French? Same three readings, plus the colon.
#
#   scripts/check-french-boundary.sh
#
# The reason this stage was English alone went when ModernBERT left: the model
# is Qwen3 and it is multilingual. Measured over 234 French boundaries — 103
# real periods mined from real dictation and 131 cuts made by inserting one —
# AUC 0.968 against 0.984 in English and 91% of cuts repaired. These 28 are a
# subset with names filtered out.
#
# Not in `make test`: it needs the 320 MB sentence model.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN=""
for candidate in "$ROOT/.build/release/ParrotFlow" "$ROOT/.build/debug/ParrotFlow"; do
  [ -x "$candidate" ] || continue
  if [ -z "$BIN" ] || [ "$candidate" -nt "$BIN" ]; then BIN="$candidate"; fi
done
[ -n "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

CASES="$ROOT/tests/french-boundary-cases.json"
WORK="$(mktemp -d -t parrotflow-french-boundary)"
trap 'rm -rf "$WORK"' EXIT

# The bench reads left, right and mark and ignores the rest, so the labels
# travel in the same file as the cases they label.
"$BIN" --sentence-probe --bench "$CASES" --out "$WORK/out.json" >/dev/null 2>&1 \
  || { echo "  ✗ the bench did not run"; exit 1; }

python3 - "$CASES" "$WORK/out.json" <<'PY'
import json, sys
cases = json.load(open(sys.argv[1]))
out = json.load(open(sys.argv[2]))
rows = out if isinstance(out, list) else out.get("results", [])
if len(rows) != len(cases):
    print(f"  ✗ {len(rows)} results for {len(cases)} cases"); sys.exit(1)
ok = bad = cost = 0
for case, row in zip(cases, rows):
    joined = row["winner"] == "join"
    right = joined == (case["want"] == "lower")
    got = "lower" if joined else "keep"
    if case.get("cost"):
        # The measured price of dropping the comma, not a regression. Printed
        # so it stays visible, and it fails the run only if it stops being a
        # price — a case that starts passing is a better rule, not a broken one.
        cost += 1
        print(f"  ·  {case['right'].split()[0][:12]:12} want {case['want']:5} got {got:5} — {case['why']}")
        continue
    ok, bad = ok + right, bad + (not right)
    if not right:
        print(f"  ✗  {case['right'].split()[0][:12]:12} want {case['want']:5} got {got:5} — {case['why']}")
print()
print(f"  {ok}/{len(cases) - cost}  and {cost} known costs  (tests/french-boundary-cases.json)")
sys.exit(0 if bad == 0 else 1)
PY
bench=$?

# The bench above scores which reading wins. It never applies one, so it cannot
# see what is written. These three do.
echo
echo "  what a won join writes"
echo
fail=$bench
check () {   # $1 said, $2 wanted, $3 why
  got="$("$BIN" --sentence-join "$1" 2>/dev/null | sed -n 's/^  text       //p')"
  if [ "$got" = "$2" ]; then
    printf '  ✓  %s\n' "$3"
  else
    printf '  ✗  %s\n     got  %s\n     want %s\n' "$3" "$got" "$2"
    fail=1
  fi
}
check "Je me demande si on ne devrait pas ? Attendre la prochaine version." \
      "Je me demande si on ne devrait pas attendre la prochaine version." \
      "the space French sets before ? goes with the mark, and one is left"
check "On ne peut pas continuer comme ça. Parce que le budget est déjà dépassé." \
      "On ne peut pas continuer comme ça. Parce que le budget est déjà dépassé." \
      "a real French period is left alone"
check "You should see a parrot. At the top right of your screen." \
      "You should see a parrot at the top right of your screen." \
      "English is unchanged"
exit $fail

