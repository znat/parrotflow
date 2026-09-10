# Sound groups: several names, one sound

Decided 2026-09-09 after a real failure. Mik and Mick are two people. The
recogniser hears "Mick" for both. Today Mik owns the sound: `heard: Mick` is
a rule that rewrites every "Mick" to "Mik", and the only thing that can undo
it is Mik's portrait, where Mick lives as a counter-example. Mick has no
portrait of his own. On "Mick is adjusting the piano" the portrait scored
0.886 own against 0.874 counter, band 0.01, and wrote Mik.

The fix is not a better threshold. It is a model where every name is a term
with its own portrait, and the sound is shared.

## The model

**A group is a set of terms that share a sound.** It is derived, never
declared. Two terms are in one group when any of these holds:

- one term's spelling is a `heard:` rendering of the other (Mik has
  `heard: Mick`, and Mick is a term);
- the two share a `heard:` rendering (both have `heard: meek`);
- a counter row under one term has a span that is the other term's spelling.

Groups are transitive. A term with no such link is a group of one, and a
group of one must behave exactly as the app does today. That is the
regression gate.

**A group has one more member with no name: plain.** Plain is "an ordinary
word that sounds like this": Mick Jagger, the Versailles castle, "a better
stack than PHP". Its portrait is the counter rows of the group's members,
pooled. Today's counter centre is plain's centre for a group of one.

**A heard word opens the whole group.** When a heard word is any member's
spelling or any member's `heard:` rendering, the place carries every member
as a candidate, the heard spelling included. A `heard:` that equals another
term's spelling is no longer a substitution rule; it opens the group. A group
place never auto-applies through the word-list tier; it always reaches the
portrait.

**The decision is nearest centre, with floors.** Score the window around the
place against each member's own centre, divided by that member's own
tightness, as `TermPortrait` does now. Plain is scored the same way against
the pooled counter centre.

1. A member below its own floor is out. A member with fewer than
   `floorMinimum` uses has no floor and is never out on that ground.
2. Among the members standing, the best wins if it leads the second best by
   more than `band`.
3. A win by a named member writes that spelling. A win by plain keeps what
   was heard.
4. No member standing: keep what was heard, record nothing.
5. Two or more standing and no lead: the place is open and the pill asks.

The heard spelling gets no bonus. The recogniser's choice between homophones
is frequency, not evidence.

**Recording.** What a correction or a pill answer writes depends on what was
put in:

- put back, or chosen, a word that is a term: a **use** of that term, with
  `heard:` set to the spelling it replaced. No counter row under the term
  that lost. "Mick is playing guitar" is a use of Mick, and by that fact a
  place Mik does not live.
- put back an ordinary word, or "as heard" chosen on the pill: a **counter**
  under the term that was proposed, exactly as today.

The "one term corrected into another" branch that writes two rows for one
sentence goes away. That branch is what produced the poisoned rows.

**The rival clip.** The window is cut at any other member's spelling and at
any counter span, before it enters a portrait. Today it is cut at counter
spans only.

**The pill.** An open group place lists the standing members, the heard
spelling first, and "as heard" last. Reuse the stacked surface from #299 and
the mechanism from #300. Cap the list; four members plus as-heard is enough.
Do not design a new surface.

One more option after "as heard": **something else**. It writes the heard
spelling and records nothing — no use, no counter. The user then corrects the
word by hand, and the edit watch and the correction panel handle that edit as
they do today: a rule offer, a use for the term typed, or a counter. So the
list is the standing members with the heard spelling first, then "as heard",
then "something else", with the members still capped at four. The last two
differ in what they teach: "as heard" says the heard word is right and records
a counter under the group, which is plain; "something else" says none of the
options are right and leaves the file untouched.

## The files

No new field in either file. Every row that exists today keeps its meaning.

```yaml
# vocabulary.yaml
terms:
  Mik:
    pronunciations:
      - heard: Mick        # another term: Mik and Mick are one group
      - heard: meek
  Mick:
    pronunciations:
      - heard: meek        # shared: same group, no conflict
  Vercel:
    pronunciations:
      - heard: Versal      # no other term sounds like it: a group of one
```

```yaml
# vocabulary-uses.yaml
terms:
  "Mik":
    - said: "Mik is reviewing my PR."
      span: "Mik"
      from: correction
      heard: "Mick"
    - said: "But he's not Mick Jagger."
      span: "Mick"
      from: chosen
      counter: true               # "as heard" on the pill: plain
  "Mick":
    - said: "Mick is adjusting the piano."
      span: "Mick"
      from: correction
      heard: "Mik"                # a use of Mick, not a counter of Mik
  "Vercel":
    - said: "We visited the Versailles castle."
      span: "Versailles"
      from: correction
      counter: true               # an ordinary word: the only counter still written
```

## What the experiment needs

`--portrait <heard> "<sentence>"` with a heard word instead of a term must
print the group it opens and, per member and for plain, the score, the floor,
whether it stands, then the verdict. This is how the change will be judged by
hand. The existing `--portrait <term> "<sentence>" <span>` form keeps working.

## What the first live tests changed

Three rules were added after the prototype met real dictation on 2026-09-10.
They are part of the model, not fixes around it.

- **A member with no portrait is unknown, not out.** Nothing is known about it,
  so it cannot lose a comparison it was never in. One unknown member opens the
  place and the pill lists it. That is how a member gets its first sentence.
- **Nobody standing keeps what was heard only when plain has a centre.** With
  no counter row anywhere in the group there is no ordinary word to win, so
  the place is opened, best first.
- **A name picked on the pill becomes a term**, with no pronunciation and the
  kind the tagger read — person, place or organization — and the sentence is a
  use of it. A person the recogniser spells right is never corrected, so
  nothing else ever creates their term. Plain stays what it always was: an
  ordinary word.
- **A sentence naming two members of one group is recorded nowhere.** The
  rival clip cuts the window at the other name and the words between the two
  survive, which are the sentence. Corrections and pill answers both refuse it.

## What must not move

`scripts/check-counter-portrait.sh` on `tests/portrait-cases.tsv`, and
`scripts/check-slot-gate.sh` on `tests/judge-cases.yaml`. Run both before the
first change and after the last. A group of one has to give the same numbers.
Name against name has no bench and none should be invented from dictation;
the derivation, the decision rule on synthetic centres, and the recording
rules get unit tests.
