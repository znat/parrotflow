---
name: calibrate
description: Measure a ParrotFlow vocabulary against the user's own voice — write sentences containing each vocabulary term and the words it can be confused with, have the user read them aloud into the app, and compute the safe band per term. Use after gathering a vocabulary, when a name keeps being mis-transcribed, or when a term is overwriting an ordinary word.
---

# Calibrating a vocabulary against one person's voice

A similarity band is a fact about two things: how far this speaker's rendering
of a name lands from its spelling, and how close the ordinary words that sound
like it land. Both are properties of a mouth. Neither can be read off a
dictionary, and the gap between them differs enormously between speakers.

This skill measures both, per term.

**What the bands decide now.** The app no longer takes a number per term. It
takes two numbers for the whole file — `offer_below`, how far a spelling may
sit from a term and still reach the judge's menu, and `decide_above`, how hard
the audio has to argue before a reading is dropped. So a band no longer sets a
term's threshold. It answers two questions:

- **Does any threshold work for this term at all?** A closed band means no.
  That term is `floor: off` and a `pronunciations:` list, and nothing else.
- **Where should `offer_below` sit for this speaker?** Below the lowest
  rendering of any term that still has a band. Being offered costs a line the
  model reads; being missed cannot be recovered downstream.

Do not tune `offer_below` from one term. It is one number for the file, and a
band that argues for moving it is a report, not an edit.

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

The band is the gap between the lowest of the first group and the highest of
the second. Here: 0.51 to 0.67.

## The band is the answer

    wide band     0.50 .. 0.67   the speaker separates them clearly.
                                 Pick the middle and stop thinking about it.
    narrow band   0.62 .. 0.67   works, but one bad day of diction breaks it.
    no band       0.71 .. 0.67   the confusables land CLOSER than the speaker's
                                 own renderings. No threshold exists.

**A closed band is a result, not a failure.** It says this term can never be
separated acoustically for this person. The answer is `floor: off` with a
`pronunciations:` list of the renderings actually seen, and the name judge
behind it. Those renderings are not only rules: each one's *sound* is
registered with the spotter under the term's name, so a closed band still gets
an acoustic path — it just gets it from the rendering instead of the term.
Report it that way — a user told "no threshold works, here is the rule
instead" has learned something; a user handed a number that quietly damages
their transcripts has not.

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
from the English "praise" and 0.67 from the French "vrais", so a band measured
with both languages describes a speaker who uses both. Wrong for someone who
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
  the band; more and nobody finishes.
- **Write them in the language they would be said in.** A French speaker's
  French sentences and English sentences fail differently, and mixing them
  into one list hides that.

Write a manifest at `voice/calibration.json`, beside the config — the same
directory `PARROTFLOW_CONFIG_DIR` moves:

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

    scripts/calibrate.py score            # reads voice/calibration.json

It pairs the last N recordings with the N sentences by order, re-decodes each
with the vocabulary off, and reports the band per term. It also writes the
bands to `voice/calibration.yaml`, so the next person to ask why a term is
`floor: off` does not have to make anybody read forty sentences again.

`voice/` is where everything measured from this person's voice lives —
`observations.jsonl`, `calibration.yaml`, `samples/`. None of it goes into a
git repository.

**Pairing by order breaks when someone re-reads a line**, so it checks that
half the sentence's words actually turned up before trusting a clip, and
refuses the ones that do not match:

    ✗ 2 recording(s) do not match their sentence
        expected: I deployed my app on Vercel this morning.
        heard:    And then for the code base, I think you can already uh

Have those read again rather than working around them. A mispaired clip does
not fail loudly — it produces a confident band from two unrelated sentences.

## Step 4 — check it against real speech

**Read speech is not dictated speech.** People enunciate when reading from a
screen, and an enunciated `Versailles` separates from `Vercel` in a way
ordinary muttered dictation does not. That biases every band wider than
reality.

So before reporting anything, run the terms against recordings the person made
without thinking about it:

    ParrotFlow --boost-eval --terms Vercel,Tasmeen,Praisy --limit 400

A term that causes damage there had its band measured from reading rather than
speaking. Say so — it is a candidate for `floor: off`, not for a number.

## What to hand back

The `terms:` block for `vocabulary.yaml`, which sits beside `config.yaml`:

```yaml
terms:
  Vercel:
    pronunciations:
      - heard: Versailles  # 0.40 — below any threshold
        from: calibration
  Tasmeen:                 # band 0.55 .. 0.71, nothing to say
  Praisy:
    floor: off             # no band: "praise" landed at 0.83, closer than
    pronunciations:        # this speaker's own renderings
      - heard: Prissy
        from: calibration
```

`heard: [a, b]` is the old spelling of that list. It still loads, and
`--check-config` says what to write instead.

No number per term. A measured floor written here still works and still
applies to that term, but `--check-config` calls it legacy: the setting is
`offer_below:` at the top of the file.

`floor: off` is the YAML boolean `false`, not the string. So are `on`, `yes`
and `no`. The decoder reads both, but write it the way the file already does.

That file carries a "do not edit unless you know what you are doing" header
because it is normally written by the app. This skill is one of the things
that writes it, so editing it here is the intended path — say so, rather than
letting the header look like it was ignored.

And a one-line summary per term saying what was measured, because a `heard:`
list on its own is unarguable-with in six months:

    Vercel     band 0.50 .. 0.67   wide
    Tasmeen    band 0.55 .. 0.71   wide
    Praisy     no band             "praise" at 0.83 — rule instead

Then one line for the file: the lowest rendering across every term that still
has a band, and whether `offer_below` currently sits below it.
