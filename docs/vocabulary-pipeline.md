# One sentence through the vocabulary pass

What happens to a dictated sentence between the decoder and the text that lands
in your editor, when a vocabulary term is involved.

This follows one real sentence, end to end. It was dictated on 2026-08-09 and
every log line here is what the app wrote at the time. The sentence is:

> deployed on Vercel against the Versailles Castle

It is a hard case on purpose. `Vercel` is a vocabulary term. `Versailles` is an
ordinary word that sounds like it. The sentence contains both.

**Read [pipelines.md](pipelines.md) first if you have not.** It says what a
stage is and how a pipeline is configured. This page says what the vocabulary
stages actually do to a sentence.

## The vocabulary, in one paragraph

A vocabulary is a list of names you want written correctly — libraries, tools,
colleagues. It lives in `vocabulary.yaml`. Each term can carry a list of
**renderings**: spellings the decoder produces when you say that name. `Vercel`
carries `Versal`, `Versailles` and `Russell`. A rendering is a text rule. It
rewrites its spelling wherever it appears.

## The six steps

### 1. The decoder writes what it heard

The speech model turns audio into text. It knows nothing about your vocabulary.
This time it wrote:

    deployed on Versal against the Versailles Castle

Two mistakes are visible and one is not. `Versal` is wrong — the speaker said
`Vercel`. `Versailles` is right — the speaker said Versailles. Nothing in the
text says which is which.

### 2. The `replacements` stage fires the text rules

This stage applies every rendering in `vocabulary.yaml` as an exact,
whole-word, case-insensitive substitution. `Vercel`'s list holds `Versal` **and**
`Versailles`, so both are rewritten:

    deployed on Vercel against the Vercel Castle

**No audio has been consulted.** A rendering is a string. It fires wherever its
string appears, in every sentence from now on, whatever the sound was.

**The damage is already done at this point.** The second `Vercel` is wrong and
nothing later in the pipeline can un-know that the word used to be `Versailles`
— nothing later reads the audio either.

### 3. The `vocabulary:` stage works out what the rules did

This stage exists to offer the rules back for review. It reads
`replacements.changes`, a variable the previous stage publishes:

    Versailles -> Vercel; Versal -> Vercel

That says which rules fired. It does not say **where**. So the stage searches
the current text for `Vercel`, finds it standing twice, and compares against the
transcript as it stood before the rules ran. The rules rewrite in place, so
order is preserved: the first `Vercel` now is the first of those two words
before, and so on. That is how each occurrence is attributed to the rule that
made it.

Each attributed occurrence becomes a **slot** — a place in the sentence where
more than one reading is possible.

Two rules, two occurrences, two slots.

### 4. The menu

The stage builds every whole sentence the slots allow. Two slots with two
readings each gives four sentences:

| | reading |
|---|---|
| **A** | deployed on **Vercel** against the **Versailles** Castle |
| B | deployed on **Vercel** against the **Vercel** Castle |
| C | deployed on **Versal** against the **Versailles** Castle |
| D | deployed on **Versal** against the **Vercel** Castle |

**A is correct.** It is one of four. The letters here are for this page; the
app's own ordering is not recorded in the log.

### 5. Where the clip bank would come in — and does not today

The **clip bank** is a folder of your own recordings of each term, under
`voice/samples/<Term>/`. It exists, it is measured, and it is a prototype. **It
is not wired into this path at all.**

If it were, it would sit here, between the menu and the judge, and it would only
ever **remove** readings:

- Span 1 is the audio under the first `Vercel`. It is near the `Vercel`
  recordings, because the speaker did say `Vercel`. No veto. Both of its
  readings stay.
- Span 2 is the audio under the second `Vercel`. It is far from every `Vercel`
  recording, because the speaker said Versailles. Veto. Every reading holding
  `Vercel` there goes, so B and D go.

Four readings become two, A and C. **Not one.** A veto subtracts; it never
confirms. Removing `Versal` from slot 1 needs the opposite decision — "this
audio is as close as a genuine `Vercel`" — and that version does not exist and
carries its own risk: a wrong confirm writes a name nobody said.

**Two things stop this from being real today.** The bank runs inside the
acoustic pass, so the config line that switches that pass off switches the bank
off with it. And the bank has never been asked about a rule, in any measured
arm — it only ever sees proposals the audio search made. This sentence's
failure comes entirely from rules.

### 6. The judge picks a letter

The `vocabulary:` stage sends the menu to a local language model and asks for a
letter. The app looks the letter up and uses that sentence.

**The model never writes the transcript.** It chooses among sentences the app
built. That is deliberate: a model asked to write the sentence will also fix
grammar, drop a filler and re-punctuate on the way past, and none of that was
asked for. The cost is that a menu with no correct reading on it cannot produce
one.

## What actually happened, in both arms

The sentence was dictated twice, four minutes apart, on the same build. The two
runs differ in one config line: `acoustic: false` turns off the audio search for
names, leaving the text rules in place.

| arm | setting | result |
|---|---|---|
| A | today's config | `Deployed on Vercel against the Vercel Castle.` |
| B | `acoustic: false` | `deployed on Vercel against the Vercel Gastle.` |

Both wrong, for two unrelated reasons. (`Gastle` is the decoder mishearing an
ordinary word. It has nothing to do with the vocabulary.)

**Arm A — the judge had the menu and picked wrong.** One log line:

```
vocabulary judge: 2 slot(s) from 2 proposal(s)
```

Two slots, four readings, and it chose the one with `Vercel` in both places.
That is the same answer at both slots, which is what "always keep the term"
produces.

**Arm B — the menu was never built.** Three log lines:

```
vocabulary judge: "Vercel" stands 2 time(s) and no acoustic pass ran, so which one "Versailles" became cannot be told; that reading is not offered
vocabulary judge: "Vercel" stands 2 time(s) and no acoustic pass ran, so which one "Versal" became cannot be told; that reading is not offered
vocabulary judge: 0 slot(s) from 0 proposal(s)
```

Step 3 needs the transcript as it stood before the rules ran. The app carries
that text out of the audio search, and in this arm the audio search did not run.
So the stage could not tell which `Vercel` each rule had made, refused to guess,
and offered nothing. **The rules still fired** — the sentence is proof, and the
stage ran at all only because it counted two of them.

Same output, two causes. Only the log separates them.

## What each mechanism actually compares

Three different things measure "does this audio match this name". They are
easy to confuse and they are not comparable.

### The CTC comparison — your audio against a *spelling*

**CTC** stands for connectionist temporal classification. Read it as: a model
that scores every token it knows, for every short slice of audio. Take a
spelling, turn it into the tokens it would be made of, add up those tokens'
scores over those slices, and you have a number for "how well does this audio
support this spelling".

**It never involves a recording of you.** A term you have never said scores
exactly the same way as one you say daily.

The app uses it twice. The **rescorer** compares the spelling the decoder wrote
against a term's spelling over the same audio. The **keyword spotter** searches
the whole clip for a term's sound, with no decoded word to compare against.

A real line, from arm A of another sentence in the same pass:

```
vocabulary: "general" -> "Redcrawl" proposed (raw -7.88 vs -8.12, bonus 5.85)
    (CTC-vs-CTC: 'Redcrawl'=-2.03 > 'general'=-8.12)
```

The speaker said "in general". The audio scored `Redcrawl` above `general` and
the app wrote the name. **Read the numbers carefully.** `-2.03` includes a flat
`+5.85` bonus every vocabulary term gets, so it is not a like-for-like
comparison. Take the bonus off and `Redcrawl` is `-7.88` against `general`'s
`-8.12` — still ahead, by 0.24, and still wrong.

That is not a one-off. Over 33 correct and 66 wrong proposals, this comparison
separates right from wrong at **AUC 0.318**. Chance is 0.500, so it is not weak.
It is pointing the wrong way.

A spotter line looks like this, and the number is on its own scale:

```
vocabulary: "dataset" -> "Praisy" heard in the audio (spotter -4.48)
```

The spotter is a good detector and a bad chooser. It separates "something is
here" from "nothing is here" well. Among candidates it is near chance. It is
also noisy by design: every term scores against every stretch of audio, so a
19-second clip yields about ninety hits.

### `heard:` rules — text against text

A rendering compares nothing to the audio. It is a string substitution with a
word boundary either side, case-insensitive.

**It cannot be wrong about the sound.** It can only be wrong about the meaning:
`Versailles` really is a way `Vercel` comes out, and it is also a castle. The
rule has no way to tell those apart, because it never looks at anything but the
letters.

There is no near-miss either. `Praises` does not match `Praise's`, so a
rendering one apostrophe away from what the decoder wrote does nothing at all.

### MFCC and DTW — your audio against *your own recordings*

This is the clip bank, and it is a prototype. It exists on an unmerged branch
and does not run in the shipped app.

**MFCC** stands for mel-frequency cepstral coefficients. Read it as: a way of
describing a slice of audio with a short list of numbers that captures the shape
of the sound and throws away loudness and microphone. The prototype takes a
25 ms slice every 10 ms and reduces each one to 12 numbers.

**DTW** stands for dynamic time warping. Two people saying the same word take
different amounts of time over each part of it. DTW stretches one sequence
against the other to find the best alignment, and reports how well the two
matched once aligned. The result is a distance: small means alike.

So the question this asks is different from the other two. Not "does this audio
support this spelling" but **"is this audio like the times I have heard this
person say this name"**.

Measured, the distance carries real signal — it separates "the name was said"
from "the name was not said" at AUC 0.935 on a set built from labels, and 7 of
the 8 words the app really did write a name over sit farther from that name than
every genuine recording of it.

**A rule built on that distance has not yet been shown to work.** The prototype's
version scored 104 of 141 clips; simply rejecting every proposal without
measuring anything scored 103. That is the state of it.

## Where the numbers on this page come from

Every measured claim here is from `docs/proposals/vocabulary-v3.md`, which
carries the branch and the run behind each one. Two cautions from it apply to
everything above.

**The clip-bank numbers are in-sample.** The recordings were taken from the same
audio archive they are scored against. The true numbers are worse by an unknown
margin.

**Eight sentences dictated once is not a rate.** The two arms above show
mechanisms, clip by clip, from the log. They do not measure how often anything
happens.
