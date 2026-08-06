---
name: calibrate
description: Derive per-term similarity floors for ParrotFlow from the user's own voice — write sentences containing each vocabulary term and the words it can be confused with, have the user read them aloud into the app, and compute the safe band per term. Use after gathering a vocabulary, when a name keeps being mis-transcribed, or when a term is overwriting an ordinary word.
---

# Calibrating a vocabulary against one person's voice

A similarity floor is a bet about two things: how far this speaker's rendering
of a name lands from its spelling, and how close the ordinary words that sound
like it land. Both are properties of a mouth. Neither can be read off a
dictionary, and the gap between them differs enormously between speakers.

This skill measures both, per term, and derives the floor from the gap.

**Everything stays on the machine.** The recordings are already on disk, the
decoding runs locally, and nothing leaves. Say so before asking anyone to read
their colleagues' names aloud.

## What the measurement is

For each term, two sets of sentences:

    Vercel        "I deployed my app on Vercel this morning."
                  "We should move staging to Vercel before Friday."

    confusables   "We visited the gardens at Versailles last summer."
                  "Please verify the build before you merge."

The user reads all of them. Every clip is re-decoded with the vocabulary
**off**, which is what `--transcribe --no-vocab` does, and each rendering is
scored against the term:

    said "Vercel"        heard "Versal"       0.67
    said "Vercel"        heard "Vercel"       1.00
    said "Versailles"    heard "Versailles"   0.40
    said "verify"        heard "verify"       0.50

The floor goes in the gap between the lowest of the first group and the
highest of the second. Here: anywhere from 0.51 to 0.67, so 0.58.

## The band is the answer, not just the floor

    wide band     0.50 .. 0.67   the speaker separates them clearly.
                                 Pick the middle and stop thinking about it.
    narrow band   0.62 .. 0.67   works, but one bad day of diction breaks it.
    no band       0.71 .. 0.67   the confusables land CLOSER than the speaker's
                                 own renderings. No floor exists.

**A closed band is a result, not a failure.** It says this term can never be
safe acoustically for this person. The answer is `floor: off` with a `heard:`
list of the renderings actually seen, and the `verify_names` judge behind it.
Report it that way — a user told "no floor works,
here is the rule instead" has learned something; a user handed a floor that
quietly damages their transcripts has not.

Band widths across a whole vocabulary are also the honest way to talk about
accent. A speaker whose bands are all wide needs almost no tuning. A speaker
with three closed bands has three terms that need rules, and that is a fact
about their speech rather than a judgement about it.

## Step 1 — find the confusables

    scripts/calibrate.py confusables Vercel Praisy Tasmeen --lang en

Dictionary neighbours within 0.55, plus the glued two-word phrases — `turn
down`, `back end`, `set up`. That second list matters: `Turndown` has no
single-word collision at all and still eats "turn down the volume", because
the compound matcher glues the pair.

**Pass only the languages this person dictates in.** The default is `en,fr`,
and each language adds neighbours the other does not have. "Praisy" is 0.83
from the English "praise" and 0.67 from the French "vrais", so a floor derived
with both languages is set for a speaker who uses both. Wrong for someone who
only dictates in English, and it costs them a term.

Take the top three or four per term. Below about 0.55 nothing will ever be
proposed anyway, so testing them wastes the user's breath.

## Step 2 — write the sentences

This is the part that is a judgement rather than a lookup, which is why it is
yours and not the script's.

- **Bury the term mid-clause.** A word read on its own decodes differently
  from one surrounded by speech, and the surrounded case is the real one.
- **Vary what surrounds it.** Different neighbours, different sentence
  positions, never twice at the end.
- **Make them sound like this person.** Use their domain — deploys, crawls,
  tickets, whatever the codebase and Slack gathering turned up. A sentence
  someone would never say is read in a voice they never use.
- **Three per term, three per confusable.** Fewer and one odd reading moves
  the floor; more and nobody finishes.
- **Write them in the language they would be said in.** A French speaker's
  French sentences and English sentences fail differently, and mixing them
  into one list hides that.

Write a manifest beside them:

```json
{"sentences": [
  {"n": 1, "text": "I deployed my app on Vercel this morning.",
   "contains": "Vercel", "kind": "term", "against": "Vercel"},
  {"n": 2, "text": "We visited the gardens at Versailles last summer.",
   "contains": "Versailles", "kind": "confusable", "against": "Vercel"}
]}
```

Then print the numbered sentences for the user to read **in order**, one
dictation each.

## Step 3 — score

    scripts/calibrate.py score calibration.json

It pairs the last N recordings with the N sentences by order, re-decodes each
with the vocabulary off, and reports the band and floor per term.

**Pairing by order breaks when someone re-reads a line**, so it checks that
half the sentence's words actually turned up before trusting a clip, and
refuses the ones that do not match:

    ✗ 2 recording(s) do not match their sentence
        expected: I deployed my app on Vercel this morning.
        heard:    And then for the code base, I think you can already uh

Have those read again rather than working around them. A mispaired clip does
not fail loudly — it produces a confident floor from two unrelated sentences.

## Step 4 — check it against real speech

**Read speech is not dictated speech.** People enunciate when reading from a
screen, and an enunciated `Versailles` separates from `Vercel` in a way
ordinary muttered dictation does not. That biases every band wider than
reality and sets floors slightly too low.

So before shipping the floors, run them against recordings the person made
without thinking about it:

    ParrotFlow --boost-eval --terms Vercel,Tasmeen,Praisy --limit 400

Any term whose new floor causes damage there had its band measured from
reading rather than speaking. Raise it, and say why.

## What to hand back

The `terms:` block for `vocabulary.yaml`, which sits beside `config.yaml`:

```yaml
terms:
  Vercel:
    floor: 0.58            # band 0.50 .. 0.67, measured
    heard: [Versailles]    # 0.40 — below any floor
  Tasmeen: 0.62            # band 0.55 .. 0.71
  Praisy:
    floor: off             # no band: "praise" landed at 0.83, closer than
    heard: [Prissy]        # this speaker's own renderings
```

`floor: off` is the YAML boolean `false`, not the string. So are `on`, `yes`
and `no`. The decoder reads both, but write it the way the file already does.

That file carries a "do not edit unless you know what you are doing" header
because it is normally written by the app. This skill is one of the things
that writes it, so editing it here is the intended path — say so, rather than
letting the header look like it was ignored.

And a one-line summary per term saying what was measured, because the number
on its own is unarguable-with in six months:

    Vercel     band 0.50 .. 0.67   wide, floor uncritical
    Tasmeen    band 0.55 .. 0.71   wide
    Praisy     no band             "praise" at 0.83 — rule instead
