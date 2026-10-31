#!/usr/bin/env bash
# Several names, one sound: the group and what it records.
#
#   scripts/check-sound-group.sh
#
# None of it needs a model. Which terms end up in one group (`--sound-group`),
# what a correction that runs against a term writes (`--correction`), and what
# a pill answer records (`--picked`). The clause decider that reads a group
# place is scored by scripts/check-clause-places.sh, which needs the parser.
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

# Two spellings of one rendering under one term are two renderings of it, not
# two terms claiming it. Counted as two owners, the word opened no group — a
# group of one is not a group — and stopped being a rule as well.
cat > "$WORK/vocabulary-owners.yaml" <<'YAML'
terms:
  Vercel:
    pronunciations:
      - heard: Versal
      - heard: versal
YAML
cp "$WORK/vocabulary.yaml" "$WORK/vocabulary-kept.yaml"
cp "$WORK/vocabulary-owners.yaml" "$WORK/vocabulary.yaml"
check "one term with two spellings of a rendering keeps its rule" \
  "Vercel" "$(rule Versal)"
check "and the rendering opens no group" "Vercel" "$(members Versal)"
cp "$WORK/vocabulary-kept.yaml" "$WORK/vocabulary.yaml"

# What a correction against a term writes. The rows are printed and the file is
# read back, so this is the write and not a description of it.
rows () { "$BIN" --correction "$1" "$2" --in "$3" 2>/dev/null; }
USES="$WORK/vocabulary-uses.yaml"
counters () { [ -f "$USES" ] || { echo 0; return; }; grep -c '^      counter: true' "$USES"; }
said () { [ -f "$USES" ] || { echo 0; return; }; grep -c '^    - said:' "$USES"; }
# The nth stored sentence of the file, whichever term it is under.
stored () { python3 -c '
import sys, yaml
rows = [r for term in yaml.safe_load(open(sys.argv[1]))["terms"].values() for r in term]
print(rows[int(sys.argv[2])]["said"])
' "$USES" "$1" 2>/dev/null; }

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
# A row past "something else" was never offered. Taken as given, the answer
# kept what stands there and was recorded as teaching.
pick 3 >/dev/null 2>&1
check "a row the place never offered is a usage error" 2 "$?"

cat > "$WORK/vocabulary.yaml" <<'YAML'
terms:
  Erik:
    kind: person
    pronunciations:
      - heard: Eric
  Vercel:
    pronunciations:
      - heard: Versal
  Ghostty:
    pronunciations:
      - heard: Ghosty
YAML
# The occurrence that was corrected, not the first copy of the word. A terminal
# joins dictations with no space after the stop, so one field holds several
# sentences and the same name more than once. Measured on the live app,
# 2026-09-10: the second correction wrote nothing at all.
FIELD='❯ Eric is software engineer.Erik is a musician.Erik plays the piano.'
rm -f "$USES"
"$BIN" --for Erik "$FIELD" Erik >/dev/null 2>&1
check "with nothing to say which, the first occurrence is stored" \
  "Erik is a musician." "$(stored 0)"
# 6, the way `EditWatch` counts: the shell prompt in front of the line is not
# a word, and the periods glue the sentences into single words.
"$BIN" --for Erik "$FIELD" Erik --near 6 >/dev/null 2>&1
check "the position picks the sentence that was corrected" \
  "Erik plays the piano." "$(stored 1)"
check "and both rows are there" 2 "$(said)"
"$BIN" --for Erik "$FIELD" Erik --near 6 >/dev/null 2>&1
check "the same row again is still one row" 2 "$(said)"
"$BIN" --for Erik "$FIELD" Erik --near abc >/dev/null 2>&1
check "--near without a number is a usage error" 2 "$?"

# A sentence naming two members of one group belongs to neither: "Erik the
# musician and Eric the software engineer" was kept as a counter under Erik on
# 2026-09-10, and every later "Eric the musician" was refused.
cat > "$WORK/vocabulary.yaml" <<'YAML'
terms:
  Erik:
    kind: person
    pronunciations:
      - heard: Eric
  Eric:
    kind: person
  Vercel:
    pronunciations:
      - heard: Versal
YAML
rm -f "$USES"
BOTH='So I tried again with Erik the musician and Eric the software engineer.'
check "a sentence naming two members is recorded nowhere" \
  "blocked Eric Erik" "$("$BIN" --correction Erik Eric --in "$BOTH" 2>/dev/null)"
check "and no row is written" 0 "$(said)"
# The sentence the row is recorded in, not the whole field. A terminal joins
# every dictation since the last Return, so a field naming both members can
# still hold a sentence that names one.
FIELD_BOTH='Erik presented first. Eric plays cello.'
rm -f "$USES"
check "a field of two sentences is blocked only by the one recorded" \
  'use Eric "Eric" heard Erik' \
  "$("$BIN" --correction Erik Eric --in "$FIELD_BOTH" 2>/dev/null)"
check "and the row is the sentence naming one member" "Eric plays cello." "$(stored 0)"
rm -f "$USES"

check "one member standing is recorded as before" \
  'use Eric "Eric" heard Erik' \
  "$("$BIN" --correction Erik Eric --in "Eric is reviewing my pull request." 2>/dev/null)"
check "which does write a row" 1 "$(said)"

# Picking on the pill. A term picked is a use of it; any other word picked is a
# counter under the term that was offered, and adds nothing to the vocabulary:
# a picked "Versailles" made a term, and a heard "Versailles" was then never a
# place for Vercel again.
rm -f "$USES"
pick () { "$BIN" --picked "$1" "$2" --in "$3" 2>/dev/null; }
check "a word that is already a term is a use of it" \
  "use Eric" "$(pick Eric Erik "Eric is a software engineer.")"
check "an ordinary word is still a counter" \
  "counter Vercel" "$(pick versus Vercel "It is versus the other one.")"
check "a name with no term yet is a counter under the offered term" \
  "counter Erik" "$(pick Sarah Erik "Sarah is on the call.")"
check "and no term is written for it" "0" "$(grep -c Sarah "$WORK/vocabulary.yaml")"
check "the blocked sentence is not written from the pill either" \
  "blocked Eric Erik" "$(pick Eric Erik "$BOTH")"

# A correction onto a name the vocabulary has never seen. It is not an ordinary
# word, so it is not a counter: the rendering is written, the term is created
# with the kind the tagger read, and the sentence is a use of it. Measured on
# decoded audio, 2026-09-10 — five sentences about a third person had become
# five counters under the second.
rm -f "$USES"
cat > "$WORK/vocabulary.yaml" <<'YAML'
terms:
  Ana:
    kind: person
    pronunciations:
      - heard: Anna
  Anna:
    kind: person
  Vercel:
    pronunciations:
      - heard: Versal
YAML
check "a correction onto a new name learns it" "learn Annah person heard Anna" \
  "$("$BIN" --correction Anna Annah --in "Annah booked the dentist." 2>/dev/null)"
check "written with its kind and the rendering it replaced" "person Anna" "$(python3 -c '
import sys, yaml
term = yaml.safe_load(open(sys.argv[1]))["terms"]["Annah"] or {}
heard = [p["heard"] if isinstance(p, dict) else p
         for p in (term.get("pronunciations") or [])]
print(term.get("kind", "—"), " ".join(heard))
' "$WORK/vocabulary.yaml" 2>/dev/null)"
check "the sentence is a use of the new name" 1 "$(python3 -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))["terms"]
print(len([u for u in d.get("Annah", []) if not u.get("counter")]))
' "$USES" 2>/dev/null)"
check "with no counter anywhere" 0 "$(counters)"
check "and the new name joins the group" "Ana Anna Annah" "$(members Anna)"
check "the rendering it was learnt with is not a rule" "none" "$(rule Anna)"
check "an ordinary word put back is still a counter" \
  'counter Vercel "Versailles"' \
  "$("$BIN" --correction Vercel Versailles --in "The Versailles gardens." 2>/dev/null)"

# One sentence, one owner. Two members of a group both holding the same
# sentence at the same place are the same evidence for both: the pill
# records "Eric has a new piano." under Eric, the correction that follows
# records "Erik has a new piano." under Erik, and the first row stays.
cat > "$WORK/vocabulary.yaml" <<'YAML'
terms:
  Erik:
    kind: person
    pronunciations:
      - heard: Eric
  Eric:
    kind: person
  Vercel:
    pronunciations:
      - heard: Versal
YAML
# The terms that still hold a row, and how many rows there are in all.
owners () { python3 -c '
import sys, yaml
d = (yaml.safe_load(open(sys.argv[1])) or {}).get("terms") or {}
print(" ".join(sorted(t for t, rows in d.items() if rows)))
' "$USES" 2>/dev/null; }

rm -f "$USES"
"$BIN" --picked Eric Erik --in "Eric has a new piano." >/dev/null 2>&1
"$BIN" --correction Eric Erik --in "Erik has a new piano." >/dev/null 2>&1
check "the member you correct to takes the place from the other" "Erik" "$(owners)"
check "and one row is left" 1 "$(said)"

rm -f "$USES"
"$BIN" --correction Eric Erik --in "Erik has a new piano." >/dev/null 2>&1
"$BIN" --picked Eric Erik --in "Eric has a new piano." >/dev/null 2>&1
check "and it works the other way round" "Eric" "$(owners)"
check "with one row again" 1 "$(said)"

# Whatever polarity: a counter under one member is a claim on the place too.
rm -f "$USES"
cat > "$USES" <<'YAML'
terms:
  "Erik":
    - said: "Eric has a new piano."
      span: "Eric"
      from: correction
      counter: true
YAML
"$BIN" --picked Eric Erik --in "Eric has a new piano." >/dev/null 2>&1
check "a counter at the place goes when another member takes it" "Eric" "$(owners)"
check "leaving one row" 1 "$(said)"
check "and no counter" 0 "$(counters)"

rm -f "$USES"
"$BIN" --picked Eric Erik --in "Eric is a software engineer." >/dev/null 2>&1
"$BIN" --correction Eric Erik --in "Erik has a new piano." >/dev/null 2>&1
check "a different sentence under the other member is left alone" \
  "Eric Erik" "$(owners)"
check "and both rows are kept" 2 "$(said)"

echo
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
