#!/usr/bin/env bash
# Two centroids against one, on tests/portrait-cases.tsv.
#
#   scripts/check-counter-portrait.sh
#
# A term's portrait is built from the sentences it was confirmed in. A term
# with a counter-example gets a second centre built from those, and the verdict
# is which one the sentence is closer to. This scores both rules on the same
# cases:
#
#   floor        the counters are stripped from the fixture, so every term
#                falls back to the floor and the refusal band
#   comparison   the fixture as it stands
#
# The fixture is tests/fixtures/vocabulary-uses-portrait.yaml, a snapshot of
# one speaker's own uses file. Four terms, each with uses and counter-examples.
# A case with a fifth column names a stored row to remove before scoring it, so
# a sentence is never compared with itself.
#
# Not in `make test`: it needs the 400 MB word-vector model, which CI has no
# business downloading. Run it by hand after touching TermPortrait. Same note
# as check-portrait.sh.
#
# The portrait cache is keyed by term and lives in Application Support, not in
# PARROTFLOW_CONFIG_DIR, so a run here evicts the cached portrait of any term
# of the same name on this machine. Nothing is misread — the fingerprint covers
# every stored sentence — and the app rebuilds it once.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN=""
for candidate in "$ROOT/.build/release/ParrotFlow" "$ROOT/.build/debug/ParrotFlow"; do
  [ -x "$candidate" ] || continue
  if [ -z "$BIN" ] || [ "$candidate" -nt "$BIN" ]; then BIN="$candidate"; fi
done
[ -n "$BIN" ] || { echo "build first: swift build"; exit 1; }

FIXTURE="$ROOT/tests/fixtures/vocabulary-uses-portrait.yaml"
CASES="$ROOT/tests/portrait-cases.tsv"
WORK="$(mktemp -d -t parrotflow-counter-portrait)"
trap 'rm -rf "$WORK"' EXIT
export PARROTFLOW_CONFIG_DIR="$WORK"

# Written with yaml, never with sed. One stored row carries an escaped quote in
# its `span`, and a regex parser silently dropped it in an earlier bench.
uses () {
  python3 -c '
import sys, yaml
terms = yaml.safe_load(open(sys.argv[1]))["terms"]
strip, hold = sys.argv[2] == "yes", sys.argv[3]
out = {}
for term, rows in terms.items():
    kept = [r for r in rows
            if not (strip and r.get("counter"))
            and not (hold and r["said"] == hold)]
    if kept:
        out[term] = kept
yaml.safe_dump({"terms": out}, open(sys.argv[4], "w"), allow_unicode=True)
' "$FIXTURE" "$1" "$2" "$WORK/vocabulary-uses.yaml"
}

verdict () {
  case "$("$BIN" --portrait "$1" "$2" "$3" 2>/dev/null | tail -1)" in
    *authorises*) echo write ;;
    *refuses*)    echo refuse ;;
    *)            echo quiet ;;
  esac
}

# One arm over every case. $1 is "yes" to strip the counters first.
#
# Two scores. The 20 cases with no holdout are the held-out set the design was
# chosen on; the 4 with one come from issue #249 and duplicate a stored row, so
# they are reported beside it and not inside it. The wrong count of the second
# is written to $WORK/wrong for the exit status.
arm () {
  local strip="$1" ok=0 bad=0 quiet=0 held_ok=0 held_bad=0 held_quiet=0
  while IFS=$'\t' read -r want term span said hold; do
    case "$want" in ""|"#"*) continue ;; esac
    uses "$strip" "$hold" || { echo "  ✗ the fixture could not be read"; return 1; }
    got="$(verdict "$term" "$said" "$span")"
    mark=" "
    if [ "$got" = "$want" ]; then
      ok=$((ok + 1)); [ -z "$hold" ] && held_ok=$((held_ok + 1))
    elif [ "$got" = quiet ]; then
      quiet=$((quiet + 1)); mark="·"; [ -z "$hold" ] && held_quiet=$((held_quiet + 1))
    else
      bad=$((bad + 1)); mark="✗"; [ -z "$hold" ] && held_bad=$((held_bad + 1))
    fi
    printf '  %s %-6s %-11s %-13s %-7s %.44s\n' \
      "$mark" "$want" "$term" "$span" "$got" "$said"
  done < "$CASES"
  printf '\n  the 20 held-out cases   %d right   %d wrong   %d quiet\n' \
    "$held_ok" "$held_bad" "$held_quiet"
  printf '  all 24                  %d right   %d wrong   %d quiet\n' "$ok" "$bad" "$quiet"
  printf '%s' "$held_bad" > "$WORK/wrong"
}

echo "  the shipped floor rule — the counters stripped"
echo
arm yes || exit 1
echo
echo "  the comparison — the counters kept"
echo
arm no || exit 1

# Measured 2026-09-02: no error on the 20 held-out cases, where the floor rule
# makes two. That is the property, so an error here fails the run. Re-measured
# 2026-09-04 with the minimums at one: the same numbers in both arms. Qwen has
# two counters and is now read by the comparison rather than by the floor, with
# the same verdict on all four of its cases.
echo
if [ "$(cat "$WORK/wrong")" = 0 ]; then
  echo "Every check passed."
else
  echo "Failed: the comparison is wrong on $(cat "$WORK/wrong") held-out case(s)"
  exit 1
fi
