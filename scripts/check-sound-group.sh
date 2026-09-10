#!/usr/bin/env bash
# Several names, one sound: the group, the decision and what it records.
#
#   scripts/check-sound-group.sh
#
# The model-backed half — that a member has a centre from its first use — is
# `--portrait <heard> "<sentence>"`, which needs the 400 MB word vectors. What
# is scored here is the rule that reads those numbers.
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
# Nobody standing is the ordinary word winning, so it needs an ordinary word to
# win: with a plain centre, keeping is a decision; without one it is a guess,
# and the place is a question. Measured on decoded audio, 2026-09-10 — see
# SoundGroup.decide.
check "nobody standing lets plain keep what was heard" \
  "keep" "$(verdict Mik:0.70:0.80 Mick:0.65:0.90 --plain 0.50)"
check "nobody standing and no plain opens the place, best first" \
  "open Mik Mick" "$(verdict Mik:0.70:0.80 Mick:0.65:0.90)"
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

# One name against another. The slot test cannot read such a place — the heard
# word is in the tokenizer and the term never is — so it must not be asked.
# Measured on the live app: `Eric` against `Erik` refused at -0.254, -0.253 and
# -0.257 in three different sentences.
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
place () { "$BIN" --name-place "$1" "$2" 2>/dev/null; }
check "a rendering of a term is a name against a name" "names" "$(place Eric Erik)"
check "kind: person on the term says so on its own" "names" "$(place zzarq Erik)"
check "a name the tagger knows counts on its own" "names" "$(place Sarah Ghostty)"
check "an ordinary word against a term is not" "ordinary" "$(place versus Vercel)"
check "nor is a rare word the lists have never seen" "ordinary" "$(place superbase Ghostty)"
# A sentence opens with a capital, and the frame the tagger reads must not turn
# every capitalised word into a name. `Price` and `Match` are surnames as well.
check "a capital at the start of a sentence is not a name" "ordinary" "$(place Cancel Vercel)"
check "nor is a word that is also a surname" "ordinary" "$(place Price Ghostty)"
check "a possessive is read as its name" "names" "$(place "Eric's" Erik)"

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

# A member nobody has ever confirmed — zero uses, and nothing else — is
# unknown, not out. It cannot lose a comparison it was never in, so the place
# is open and the pill lists it, which is the only way that member gets a first
# sentence.
check "a member with no uses opens the place" \
  "open Erik Eric" "$(verdict Erik:0.898:0.80 Eric:-:-:0 --plain 0.600)"
check "and it is listed after the ones that stand" \
  "open Erik Eric" "$(verdict Eric:-:-:0 Erik:0.898:0.80 --plain 0.600)"
check "once every member has a use, the rule runs as before" \
  "write Erik" "$(verdict Erik:0.898:0.80 Eric:0.600:-:1 --plain 0.600)"
# One sentence is enough to take part. A group member is scored against the
# other members, not against a fixed floor, so it has a centre from its first
# use and can lose the comparison — and a floor, which needs three uses to read
# off, is the only thing it cannot be out on before then.
#
# Measured on the live app, 2026-09-10: `Eric` at two uses had no centre at
# all, so the pill asked nine times in a row and would have gone on asking
# until both names reached three.
check "one use is enough to lose the comparison" \
  "write Erik" "$(verdict Erik:0.936:0.724 Eric:0.708:-:1)"
check "and enough to win it" \
  "write Eric" "$(verdict Erik:0.816:0.724 Eric:0.945:-:2)"
check "a member with uses but no centre is out, not unknown" \
  "write Erik" "$(verdict Erik:0.898:0.80 Eric:-:-:1 --plain 0.600)"
check "and a place where nothing can be scored at all is open, not kept" \
  "open Erik Eric" "$(verdict Erik:-:-:2 Eric:-:-:1)"

# A sentence naming two members of one group belongs to neither. The rival clip
# cuts the window at the other name and what is left is still the sentence:
# "Erik the musician and Eric the software engineer" was kept as a counter
# under Erik on 2026-09-10, and every later "Eric the musician" was refused.
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

# Picking a name on the pill. Every person is a term; plain is for ordinary
# words. A person the recogniser spells right is never corrected, so the pill
# is the only place their term can be created.
rm -f "$USES"
pick () { "$BIN" --picked "$1" "$2" --in "$3" 2>/dev/null; }
# What a created term says about itself: its kind, and that it has no
# pronunciation — nothing was misheard, so there is nothing to record.
kindOf () { python3 -c '
import sys, yaml
term = yaml.safe_load(open(sys.argv[1]))["terms"].get(sys.argv[2]) or {}
print(term.get("kind", "—"), len(term.get("pronunciations") or []) or "none")
' "$WORK/vocabulary.yaml" "$1" 2>/dev/null; }
check "a word that is already a term is a use of it" \
  "use Eric" "$(pick Eric Erik "Eric is a software engineer.")"
check "an ordinary word is still a counter" \
  "counter Vercel" "$(pick versus Vercel "It is versus the other one.")"
check "a name with no term yet is written as a person" \
  "create Sarah person" "$(pick Sarah Erik "Sarah is on the call.")"
check "with kind: person and no pronunciation" "person none" "$(kindOf Sarah)"
# The kind the tagger read, not the kind the branch was reached by. A place or
# an organization is a term too, and labelling it `person` would put a guess in
# the file where a fact belongs.
check "a place is written as a place" \
  "create Versailles place" "$(pick Versailles Erik "Versailles was closed.")"
check "with kind: place and no pronunciation" "place none" "$(kindOf Versailles)"
check "an organization is written as one" \
  "create Microsoft organization" "$(pick Microsoft Erik "Microsoft shipped it.")"
check "with kind: organization and no pronunciation" "organization none" \
  "$(kindOf Microsoft)"
# The fallback, and only where the tagger says nothing: a term that names a
# person was proposed over the word, so a person is the only kind on offer.
check "a word the tagger cannot read is a person under a person's term" \
  "create Zorbek person" "$(pick Zorbek Erik "Zorbek is on the call.")"
check "and an ordinary word under an ordinary term is still a counter" \
  "counter Vercel" "$(pick Kliffax Vercel "Kliffax is on the call.")"
check "and the sentence is a use of the new term" 1 "$(python3 -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))["terms"]
print(len([u for u in d.get("Sarah", []) if not u.get("counter")]))
' "$USES" 2>/dev/null)"
check "the blocked sentence is not written from the pill either" \
  "blocked Eric Erik" "$(pick Eric Erik "$BOTH")"

# A correction onto a name the vocabulary has never seen. It is not an ordinary
# word, so it is not a counter: the rendering is written, the term is created
# with the kind the tagger read, and the sentence is a use of it. Measured on
# decoded audio, 2026-09-10 — five sentences about a third person had become
# five counters under the second, and the pooled plain centre then scored 0.945
# on a sentence that was hers.
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
# sentence at the same place pull their centres toward each other: the pill
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

# Whatever polarity: a counter under one member is a claim on the place too,
# and the pooled plain centre is built from it.
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
