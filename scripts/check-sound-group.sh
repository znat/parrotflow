#!/usr/bin/env bash
# Several names, one sound: the group, the decision and what it records.
#
#   scripts/check-sound-group.sh
#
# Three things, none of them needing a model. Which terms end up in one group
# (`--sound-group`), what the decision rule does with scores somebody wrote
# down (`--group-decide`), and what a correction that runs against a term
# writes (`--correction`). The whole thing with the portraits behind it is
# `--portrait <heard> "<sentence>"`, which needs the 400 MB word vectors.
#
# Runs against a scratch PARROTFLOW_CONFIG_DIR, so it says nothing about the
# vocabulary on this machine and writes nothing to it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN=""
for candidate in "$ROOT/.build/release/ParrotFlow" "$ROOT/.build/debug/ParrotFlow"; do
  [ -x "$candidate" ] || continue
  if [ -z "$BIN" ] || [ "$candidate" -nt "$BIN" ]; then BIN="$candidate"; fi
done
[ -n "$BIN" ] || { echo "build first: swift build"; exit 1; }

WORK="$(mktemp -d -t parrotflow-sound-group)"
trap 'rm -rf "$WORK"' EXIT
export PARROTFLOW_CONFIG_DIR="$WORK"
pass=0; fail=0

check () {
  local what="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$what"
  else
    fail=$((fail + 1)); printf '  ✗ %s: got "%s", expected "%s"\n' "$what" "$got" "$want"
  fi
}

# Mik and Mick link through a rendering that is the other's spelling. Mic joins
# through a rendering both claim, which is what makes the links transitive.
# Vercel shares its sound with nothing and is a group of one.
cat > "$WORK/vocabulary.yaml" <<'YAML'
terms:
  Mik:
    pronunciations:
      - heard: Mick
  Mick:
    pronunciations:
      - heard: meek
  Mic:
    pronunciations:
      - heard: meek
  Vercel:
    pronunciations:
      - heard: Versal
  Praisy:
    pronunciations:
      - heard: Prezi
YAML

members () { "$BIN" --sound-group "$1" 2>/dev/null | awk '$1 == "members" { $1 = ""; print substr($0, 2) }'; }

check "a rendering that is another term's spelling links the two" \
  "Mic Mick Mik" "$(members Mik)"
check "a shared rendering links them too, and the links are transitive" \
  "Mic Mick Mik" "$(members meek)"
check "the heard word opens the group whichever member wrote it down" \
  "Mic Mick Mik" "$(members Mick)"
check "a term nothing sounds like is a group of one" "Vercel" "$(members Versal)"
check "and so is a term whose rendering nobody shares" "Praisy" "$(members Prezi)"
check "a word in no vocabulary opens nothing" "" "$(members zebra)"

# A counter row whose span is another term's spelling is the third link. It is
# written here through the shipped command rather than by hand.
cat > "$WORK/vocabulary-uses.yaml" <<'YAML'
terms:
  "Praisy":
    - said: "The Prezi deck is done."
      span: "Prezi"
      from: correction
      counter: true
YAML
check "a counter span that is not a term links nothing" "Praisy" "$(members Praisy)"
cat > "$WORK/vocabulary-uses.yaml" <<'YAML'
terms:
  "Vercel":
    - said: "Praisy reviewed the deploy."
      span: "Praisy"
      from: correction
      counter: true
YAML
check "a counter span that is a term links the two" "Praisy Vercel" "$(members Vercel)"
rm -f "$WORK/vocabulary-uses.yaml"

# The rules. A rendering that opens a group is not a substitution any more.
rule () { "$BIN" --sound-group "$1" 2>/dev/null | awk '$1 == "rule" { print $2 }'; }
check "a rendering that is another term's spelling is no longer a rule" \
  "none" "$(rule Mick)"
check "a rendering two terms share is no longer a rule" "none" "$(rule meek)"
check "a rendering nobody else claims is still a rule" "Vercel" "$(rule Versal)"
check "and so is one whose term is a group of one" "Praisy" "$(rule Prezi)"

# The decision rule, on scores nobody measured. A floor of - is a member with
# too few uses to have one.
verdict () { "$BIN" --group-decide "$@" 2>/dev/null | tail -1; }
check "the best member wins when it leads by more than the band" \
  "write Mik" "$(verdict Mik:0.90:0.80 Mick:0.86:- --plain 0.70)"
check "a member below its own floor is out, and the next one wins" \
  "write Mick" "$(verdict Mik:0.79:0.80 Mick:0.86:- --plain 0.70)"
check "a member with no floor is never out on that ground" \
  "write Mick" "$(verdict Mik:0.10:0.80 Mick:0.20:-)"
check "plain winning keeps what was heard" \
  "keep" "$(verdict Mik:0.70:0.60 Mick:0.65:- --plain 0.90)"
check "nobody standing keeps what was heard" \
  "keep" "$(verdict Mik:0.70:0.80 Mick:0.65:0.90)"
check "two standing and no lead opens the place" \
  "open Mik Mick" "$(verdict Mik:0.900:0.80 Mick:0.895:- --plain 0.70)"
check "a member tying with plain opens it as well" \
  "open Mik" "$(verdict Mik:0.900:0.80 --plain 0.895)"
check "a lead under the band decides nothing" \
  "open Mik Mick" "$(verdict Mik:0.900:0.80 Mick:0.892:0.80)"

# What a correction against a term writes. The rows are printed and the file is
# read back, so this is the write and not a description of it.
rows () { "$BIN" --correction "$1" "$2" --in "$3" 2>/dev/null; }
USES="$WORK/vocabulary-uses.yaml"
counters () { [ -f "$USES" ] || { echo 0; return; }; grep -c '^      counter: true' "$USES"; }
said () { [ -f "$USES" ] || { echo 0; return; }; grep -c '^    - said:' "$USES"; }

check "a term put back over another is a use of the one you typed" \
  'use Mick "Mick" heard Mik' "$(rows Mik Mick "Mick is adjusting the piano.")"
check "and one row is written" 1 "$(said)"
check "with no counter under the term that lost" 0 "$(counters)"
check "under the term you typed" 1 "$(python3 -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))["terms"]
print(len(d.get("Mick", [])))
' "$USES" 2>/dev/null)"
check "carrying the spelling it replaced" 1 \
  "$(grep -c '^      heard: "\?Mik"\?$' "$USES")"

rm -f "$USES"
check "an ordinary word put back is a counter, as it always was" \
  'counter Vercel "Versailles"' "$(rows Vercel Versailles "I love visiting the Versailles Castle.")"
check "and it is the only row" 1 "$(said)"
check "marked as a counter" 1 "$(counters)"

rm -f "$USES"
check "a word that was never a term writes nothing" \
  "nothing: praise is not a term, or the two are the same term" \
  "$(rows praise Praisy "Praisy reviewed the parser.")"
check "and the file is not created" 0 "$(said)"

check "the same term on both sides writes nothing" \
  "nothing: Mick is not a term, or the two are the same term" \
  "$(rows Mick "Mick's" "Mick's piano is out of tune.")"

# "Something else" is the row past the last reading. It writes what was heard
# and teaches nothing, so the correction that follows is an ordinary one.
#
# Nothing here wrote a term over the span — `--selector` builds every place
# that way — so what was heard is also what stands, and this answer and 0 type
# the same characters. What separates them is the row nobody writes.
pick () { "$BIN" --selector "can you ask Mick to review it." "Mick|mixed bend|3|$1" "${@:2}" 2>/dev/null; }
check "something else writes what was heard" \
  "can you ask Mick to review it." "$(pick 2)"
check "and it records nothing" "Mick nothing" "$(pick 2 --taught)"
check "where taking the other reading records" "mixed bend teaches" "$(pick 1 --taught)"
check "and keeping what stands there records too" "Mick teaches" "$(pick 0 --taught)"

echo
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
