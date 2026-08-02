#!/usr/bin/env python3
"""Score a prompt against tests/spelling-cases.yaml on a local Ollama model.

    scripts/validate-prompt.py gemma4:e4b
    scripts/validate-prompt.py gemma4:e4b --variant v8 --verbose
    scripts/validate-prompt.py none --code-only    # the no-model control

Prompt variants live in this file so they can be compared directly; the
winner gets copied into LocalLLM.swift.

Two numbers, because they answer different questions. "spans" is what the model
alone got right. "APP" adds the letters, described_edit and interpret()'s
snap-to-transcript repair, and is the only one that says what a user would see.

Scoreboard (APP). English is tests/spelling-cases.yaml, French is
tests/french-cases.yaml, where the dictated sentence is French. The sets grew
twice: the rows marked 62/45 are on the current sets, which added two-in-a-
breath corrections and described changes; the 44/30 rows are the sets before
that; anything older is indicative, not comparable.

                        English  French  latency  size
    -- 62 / 45 cases
    gemma4:e4b   v26      89%      -      1.41s   9.6GB  <- shipped, English
    gemma4:e4b   v23       -      96%     1.5s    9.6GB  <- shipped, French
    granite4:3b  v26      89%      -      0.22s   2.1GB  <- level, six times faster
    granite4:3b  v23       -      69%     0.41s   2.1GB
    gemma4:e4b   v24      87%      -      1.5s           arrow back on: -2 on spans
    gemma4:e4b   v28      87%      -      1.4s           v26 + one prose clause
    gemma4:e4b   v27      85%      -      1.4s           v26 + an extra example
    gemma4:e4b   v25      85%      -      1.31s          v26 without the described NO MATCH
    gemma4:e4b   v22      81%      -      1.51s          first attempt at both shapes
    gemma4:e4b   v14      71%      -      1.17s          what shipped before
    gemma4:e4b   v13       -      89%     1.46s          what shipped before
    (no model)            50%     40%       -     <- the control to beat
    -- 44 / 30 cases
    gemma4:e4b   v14      98%     -       1.15s   9.6GB
    gemma4:e4b   v13       -      93%     1.5s    9.6GB
    gemma4:e4b   v8       98%     87%     1.33s   9.6GB
    gemma4:12b   v8       98%      -      2.96s   7.6GB  <- twice the wait
    gemma4:12b   v13       -      97%     3.29s   7.6GB
    gemma4:e2b   v13       -      80%     1.0s    7.2GB
    gemma4:e2b   v8       86%     60%     0.9s    7.2GB
    granite4:3b  v8       92%     68%     0.3s    2.1GB
    granite4:3b  v13       -      48%     0.3s    French prompt HURTS it
    (no model)            59%     48%       -
    -- older sets, indicative only
    gemma4:e4b   v4       97%      -      1.4s
    gemma4:e4b   v9       95%      -      1.5s    over-took spans
    granite4:3b  v4       90%      -      0.3s
    granite4:3b  v9       87%      -      0.3s
    qwen3.5:0.8b v5       62%      -      0.4s    1.0GB
    qwen3.5:2b   v8       49%     12%     0.7s    2.7GB
    qwen3.5:0.8b v4       46%      -      0.5s
    qwen3.5:0.8b v7       36%      -      0.4s    correction-first, worse
    qwen3.5:0.8b v6        8%      -      0.4s    by word number: all NONE
    qwen3.5:0.8b v5        8%      -      5.3s    --think: 11x slower, worse

The described changes are the clearest instance yet of the rule that anything
mechanical belongs in code. "Mathieu ne prend qu'un seul t" has no letters to
read, so the obvious move is to let the model write the corrected name. On the
ten described cases in the English set that scores 5/10 on gemma4:e4b and 8/10
on gemma4:12b, and the failures are not misunderstandings — "Phillip with one
l" came back "Phill" and "Philp", "Elisabeth with a z" came back "Elizabith".
described_edit applies the change instead and scores 10/10 on both. A bigger
model was worth three points here; moving the job out of the model was worth
five, and it is free.

That change also paid for the prompt. With no spelling for the model to write,
v25/v26 could go back to answering with the span alone, and the span is where
the accuracy is: v22 and v24, which restore the arrow, truncate two-word spans
that v14 got right ("Locks me" to "Locks", "Oluwa shane" to "Oluwa"). Writing
the name out evidently pulls the model toward the shortest span it can spell.
French still keeps the arrow, because there it pulls the other way — v19
measured span-only French and lost ten points to under-trimming.

granite4:3b reaching gemma's English score at a sixth of the latency is new,
and it is the repair layer doing the work: granite's raw spans score 74%
against gemma's 89%. The more of the answer that is built from the text, the
less the model has to be good at.

Latency here is prefill, not generation, and that is the single most useful
thing on this page. Measured on e4b with v8: 420 prompt tokens in against 6
out, 0.87s reading the prompt against 0.13s writing the answer. Ollama reuses
its KV cache only when the new prompt strictly extends the cached one — an
appended token is free, a changed last character is not — and a fresh
dictation never extends anything, so every call re-reads the whole prompt at
about 2.1ms per token. Prompt length *is* the latency. num_ctx was swept from
32768 down to 1024 and changed nothing (0.91-0.93s throughout); it is a memory
setting, not a speed one, worth about 5GB of resident size but no time.

So the length ladder, English, all span-only (the model's right-hand side is
discarded and rebuilt by regex, so it is waste in the output and in the
prompt):

                 prompt   model's part   APP    latency
    v8 (was)     420 tok      100%       98%     1.33s
    v14          359 tok      100%       98%     1.15s  <- shipped
    v15          282 tok       95%       93%     0.99s
    v16          186 tok       86%       86%     0.82s
    v18          291 tok       93%       91%     1.02s  compressed prose

v14 is free: the deleted tokens were the ones nothing read. Below it the
examples start earning their keep, and they fail in the expensive direction —
v15 and v16 both broke by inventing matches for "The weather is nice today"
and "I like apples", having dropped one of the two NO MATCH examples. v18 kept
all seven examples and compressed the prose instead, and was worse again, so
the rules are load bearing too. v17 (five examples, both negatives kept)
scored 95%, which says it is not simply the negatives.

French does not take the same edit: v19 is v13 span-only and fell 93% -> 83%,
twice, under-trimming "Say goal enn" to "Say goal". Writing the target name
out evidently makes the model commit to a span long enough to spell, and
French needs that crutch where English does not. Two further French attempts
scored 93% with the identical two failures and are not worth repeating: a
product-name negative (v20) against the false positive, and a three-word
example (v21) against the short span.

Read this way. Only gemma clears the control on French by a margin worth
paying for; qwen is far below it, so on French dictation qwen is worse than
deleting the model call. The 2b's failure is a single stubborn one, returning
the whole source sentence as the span, and no variant shifted it.

gemma4:e2b is the one to read past the score on. It is only a quarter smaller
than e4b (7.2GB against 9.6GB) and about a third quicker, for twelve points of
English and thirteen of French — but the shape of what it loses is the reason
not to take it. Of the six negative cases across the two sets it fails all
six, where e4b fails one. It cannot say NO MATCH, and on this feature that is
the expensive direction to fail in: a miss costs one correction, while a false
positive writes a rule into transcription.replacements that then rewrites
every future transcript. Scores treat those two as one point each; the user
does not.

The per-language prompt is a gemma-only win, and the size of that asymmetry
is the point: v13 takes gemma from 84% to 92% and granite from 68% down to
48%, which is the control. A prompt written for the task in the user's
language does not rescue a model that was already struggling with the task —
it costs it the English scaffolding it was leaning on.

Two fixes to spelledOutWord were worth more than any prompt on French. The
trigger list learning "ça s'écrit" / "s'épelle" took it from 76% to 84%, and
the stop list learning "pas / non / plutôt / mais" from 79% to 93% — the
second only became necessary because of the first, since before it French
missed the trigger entirely and fell through to a fallback that stopped on
its own. Neither moved English, which stayed at 98%.

Three cautions when reading these. Ollama is not bit-reproducible for every
model — qwen moved by a case or two between identical runs, though gemma
repeated a French score exactly three times, so check before trusting a small
delta. "Sam => Sam" fails for every model by design: the app refuses to add a
rule mapping a word to itself, so the set's expectation is what is wrong
there. And v13's two remaining French losses are one under-trimmed three-word
span and one false positive on a negative — the latter is the failure class
worth watching, since it writes a wrong rule rather than missing one.
"""
import argparse, json, sys, time, urllib.request, pathlib, re

try:
    import yaml
except ImportError:
    sys.exit("pip install pyyaml")

ROOT = pathlib.Path(__file__).resolve().parent.parent

VARIANTS = {
# What is in LocalLLM.swift today: silence for the no-match case.
"v1": """Map a misheard word to the spelling the speaker just read out.

You get a source transcription, and a correction transcription in which the speaker says a word then spells it letter by letter.

Output exactly one line:
<word exactly as it appears in the source> => <the spelled letters joined up>

Output nothing at all if no word in the source plausibly matches.

- Copy the word from the SOURCE. The correction transcription mishears it; ignore its version.
- The source span may be more than one word.
- Join the spelled letters and capitalise naturally.

source: I work with Tasmin
correction: Das mean spells T-A-S-M-E-E-N
Tasmin => Tasmeen

source: I work with Sarah
correction: Tasmin spells T-A-S-M-E-E-N

source: We deployed to Versal yesterday
correction: Versoff spells V E R C E L
Versal => Vercel""",

# Emitting zero tokens is unnatural for a model; give the null case a token.
"v2": """Map a misheard word to the spelling the speaker just read out.

You get a source transcription, and a correction transcription in which the speaker says a word then spells it letter by letter.

Reply with exactly one line, and nothing else:
<span exactly as it appears in the source> => <the spelled letters joined up>
or
NO MATCH

- The left side must be copied character for character from the SOURCE. The correction transcription mishears the name a second time; ignore how it spells it there.
- The source span is often two or three words, because recognition splits names it does not know.
- The right side is only the spelled-out letters, joined and capitalised normally.
- Reply NO MATCH when nothing in the source sounds like the spelled word.

source: I work with Tasmin
correction: Das mean spells T-A-S-M-E-E-N
Tasmin => Tasmeen

source: I work with Sarah
correction: Tasmin spells T-A-S-M-E-E-N
NO MATCH

source: We deployed to Versal yesterday
correction: Versoff spells V E R C E L
Versal => Vercel

source: The Coober netties cluster is down
correction: Kuber nettis spells K U B E R N E T E S
Coober netties => Kubernetes""",

# v2 plus: the span is the name only; letters are copied exactly; casing is
# fixed; and a second NO MATCH example where an ordinary English word is the
# nearest thing in the source.
"v3": """Map a misheard name to the spelling the speaker just read out.

You get a source transcription, and a correction transcription in which the speaker says a name then spells it letter by letter.

Reply with exactly one line, and nothing else:
<span exactly as it appears in the source> => <the spelled letters joined up>
or
NO MATCH

Left side:
- Copy it character for character from the SOURCE. The correction transcription mishears the name a second time; ignore how it appears there.
- Include only the name itself. Never include ordinary words around it such as is, the, and, was, on.
- It is often two or three words, because recognition splits names it does not know.

Right side:
- Use the spelled letters exactly, in the order given. Do not add, drop or reorder any.
- One capital at the start, the rest lowercase.

Reply NO MATCH when nothing in the source sounds like the spelled name — including when the only nearby candidate is a common English word.

source: I work with Tasmin
correction: Das mean spells T-A-S-M-E-E-N
Tasmin => Tasmeen

source: I work with Sarah
correction: Tasmin spells T-A-S-M-E-E-N
NO MATCH

source: I like apples
correction: Oranges spells O-R-A-N-G-E-S
NO MATCH

source: We deployed to Versal yesterday
correction: Versoff spells V E R C E L
Versal => Vercel

source: The Coober netties cluster is down
correction: Kuber nettis spells K U B E R N E T E S
Coober netties => Kubernetes

source: When is handling the deploy
correction: New yen spells N G U Y E N
When => Nguyen""",

# v2's span behaviour (v3's "never include ordinary words" over-trimmed
# "Anna ees" to "Anna"), plus v3's extra NO MATCH example. Examples teach
# trimming better than a rule does.
"v4": """Map a misheard name to the spelling the speaker just read out.

You get a source transcription, and a correction transcription in which the speaker says a name then spells it letter by letter.

Reply with exactly one line, and nothing else:
<span exactly as it appears in the source> => <the spelled letters joined up>
or
NO MATCH

- The left side must be copied character for character from the SOURCE. The correction transcription mishears the name a second time; ignore how it spells it there.
- The source span is often two or three words, because recognition splits names it does not know. Take the whole name, and only the name.
- The right side is the spelled letters, in the order given, joined up with one capital at the start.
- Reply NO MATCH when nothing in the source sounds like the spelled name, including when the nearest candidate is an ordinary English word.

source: I work with Tasmin
correction: Das mean spells T-A-S-M-E-E-N
Tasmin => Tasmeen

source: I work with Sarah
correction: Tasmin spells T-A-S-M-E-E-N
NO MATCH

source: I like apples
correction: Oranges spells O-R-A-N-G-E-S
NO MATCH

source: We deployed to Versal yesterday
correction: Versoff spells V E R C E L
Versal => Vercel

source: The Coober netties cluster is down
correction: Kuber nettis spells K U B E R N E T E S
Coober netties => Kubernetes

source: When is handling the deploy
correction: New yen spells N G U Y E N
When => Nguyen

source: Anna ees joined the design team
correction: Anna east spells A N A I S
Anna ees => Anais""",

# v4, minus the right side. The spelling already comes from the regex, so the
# letters were only ever a way for the model to lose marks; a 0.8b spends its
# format-following budget on them and then echoes the placeholder instead of
# filling it in. Span only: one decision, one line.
"v5": """Find the words in the source line that the speaker is correcting.

You get a source transcription, and a correction transcription in which the speaker says a name then spells it letter by letter.

Reply with those words copied from the source line, and nothing else.
Or reply NO MATCH.

- Copy the words from the SOURCE line. The correction line mishears the name a second time; never answer with words from the correction line.
- The source span is often two or three words, because recognition splits names it does not know. Take the whole name, and only the name.
- Reply NO MATCH when nothing in the source sounds like the spelled name, including when the nearest candidate is an ordinary English word.

source: I work with Tasmin
correction: Das mean spells T-A-S-M-E-E-N
Tasmin

source: I work with Sarah
correction: Tasmin spells T-A-S-M-E-E-N
NO MATCH

source: I like apples
correction: Oranges spells O-R-A-N-G-E-S
NO MATCH

source: We deployed to Versal yesterday
correction: Versoff spells V E R C E L
Versal

source: The Coober netties cluster is down
correction: Kuber nettis spells K U B E R N E T E S
Coober netties

source: When is handling the deploy
correction: New yen spells N G U Y E N
When

source: Anna ees joined the design team
correction: Anna east spells A N A I S
Anna ees""",

# Every v5 failure but one was the model answering with the correction line's
# words. Rules and seven examples did not stop it, so stop asking it to copy:
# number the source words and take back the indices. Code rebuilds the span,
# which makes "verbatim from the source" structural instead of instructed.
"v6": """The speaker dictated a source line, then said a name and spelled it out letter by letter. Decide which numbered words of the source line are that name.

Reply with those numbers, and nothing else.
Or reply NONE.

- The numbers refer only to the source line. The correction line mishears the name a second time; it is never the answer.
- A name is often split across two or three numbered words, because recognition splits names it does not know. Take the whole name, and only the name.
- Reply NONE when nothing in the source sounds like the spelled name, including when the nearest candidate is an ordinary English word.

source: 1 I 2 work 3 with 4 Tasmin
correction: Das mean spells T-A-S-M-E-E-N
4

source: 1 I 2 work 3 with 4 Sarah
correction: Tasmin spells T-A-S-M-E-E-N
NONE

source: 1 I 2 like 3 apples
correction: Oranges spells O-R-A-N-G-E-S
NONE

source: 1 We 2 deployed 3 to 4 Versal 5 yesterday
correction: Versoff spells V E R C E L
4

source: 1 The 2 Coober 3 netties 4 cluster 5 is 6 down
correction: Kuber nettis spells K U B E R N E T E S
2 3

source: 1 When 2 is 3 handling 4 the 5 deploy
correction: New yen spells N G U Y E N
1

source: 1 Anna 2 ees 3 joined 4 the 5 design 6 team
correction: Anna east spells A N A I S
1 2""",

# v5's wording, with the two lines swapped so the source is the last thing read
# before the answer. Nothing in v5's rules or examples stopped the model
# answering from the correction line; this is the same instruction expressed as
# position rather than as prose.
"v7": """Find the words in the source line that the speaker is correcting.

You get a correction transcription, in which the speaker says a name then spells it letter by letter, and then the source transcription they want fixed.

Reply with those words copied from the source line, and nothing else.
Or reply NO MATCH.

- Copy the words from the SOURCE line. The correction line mishears the name a second time; never answer with words from the correction line.
- The source span is often two or three words, because recognition splits names it does not know. Take the whole name, and only the name.
- Reply NO MATCH when nothing in the source sounds like the spelled name, including when the nearest candidate is an ordinary English word.

correction: Das mean spells T-A-S-M-E-E-N
source: I work with Tasmin
Tasmin

correction: Tasmin spells T-A-S-M-E-E-N
source: I work with Sarah
NO MATCH

correction: Oranges spells O-R-A-N-G-E-S
source: I like apples
NO MATCH

correction: Versoff spells V E R C E L
source: We deployed to Versal yesterday
Versal

correction: Kuber nettis spells K U B E R N E T E S
source: The Coober netties cluster is down
Coober netties

correction: New yen spells N G U Y E N
source: When is handling the deploy
When

correction: Anna east spells A N A I S
source: Anna ees joined the design team
Anna ees""",

# v4 without "including when the nearest candidate is an ordinary English
# word". That clause was meant to protect the negative cases, but on granite it
# fired on Becker/Bekir and Clark/Clerk — ordinary English words that are the
# match. The two NO MATCH examples already teach the boundary, and "When =>
# Nguyen" already teaches the exception; the prose only over-applied it.
"v8": """Map a misheard name to the spelling the speaker just read out.

You get a source transcription, and a correction transcription in which the speaker says a name then spells it letter by letter.

Reply with exactly one line, and nothing else:
<span exactly as it appears in the source> => <the spelled letters joined up>
or
NO MATCH

- The left side must be copied character for character from the SOURCE. The correction transcription mishears the name a second time; ignore how it spells it there.
- The source span is often two or three words, because recognition splits names it does not know. Take the whole name, and only the name.
- The right side is the spelled letters, in the order given, joined up with one capital at the start.
- Reply NO MATCH when nothing in the source sounds like the spelled name.

source: I work with Tasmin
correction: Das mean spells T-A-S-M-E-E-N
Tasmin => Tasmeen

source: I work with Sarah
correction: Tasmin spells T-A-S-M-E-E-N
NO MATCH

source: I like apples
correction: Oranges spells O-R-A-N-G-E-S
NO MATCH

source: We deployed to Versal yesterday
correction: Versoff spells V E R C E L
Versal => Vercel

source: The Coober netties cluster is down
correction: Kuber nettis spells K U B E R N E T E S
Coober netties => Kubernetes

source: When is handling the deploy
correction: New yen spells N G U Y E N
When => Nguyen

source: Anna ees joined the design team
correction: Anna east spells A N A I S
Anna ees => Anais""",

# v8 plus a three-word span. Every example span was one or two words, and
# "Graph on a" came back as "Graph" — the model stopped where the examples
# stopped. The new one is deliberately not a case from the set.
"v9": """Map a misheard name to the spelling the speaker just read out.

You get a source transcription, and a correction transcription in which the speaker says a name then spells it letter by letter.

Reply with exactly one line, and nothing else:
<span exactly as it appears in the source> => <the spelled letters joined up>
or
NO MATCH

- The left side must be copied character for character from the SOURCE. The correction transcription mishears the name a second time; ignore how it spells it there.
- The source span is often two or three words, because recognition splits names it does not know. Take the whole name, and only the name.
- The right side is the spelled letters, in the order given, joined up with one capital at the start.
- Reply NO MATCH when nothing in the source sounds like the spelled name.

source: I work with Tasmin
correction: Das mean spells T-A-S-M-E-E-N
Tasmin => Tasmeen

source: I work with Sarah
correction: Tasmin spells T-A-S-M-E-E-N
NO MATCH

source: I like apples
correction: Oranges spells O-R-A-N-G-E-S
NO MATCH

source: We deployed to Versal yesterday
correction: Versoff spells V E R C E L
Versal => Vercel

source: The Coober netties cluster is down
correction: Kuber nettis spells K U B E R N E T E S
Coober netties => Kubernetes

source: We moved it to Post grey sequel last year
correction: Postgres quel spells P O S T G R E S Q L
Post grey sequel => Postgresql

source: When is handling the deploy
correction: New yen spells N G U Y E N
When => Nguyen

source: Anna ees joined the design team
correction: Anna east spells A N A I S
Anna ees => Anais""",

# v8 plus one example whose source line is not English. Every example in v8 is
# an English sentence, and on non-English sentences the smaller models start
# returning the whole line as the span — so the question is whether that is the
# model or just the absence of a demonstration. Swedish, which is deliberately
# not one of the probe's languages.
"v10": """Map a misheard name to the spelling the speaker just read out.

You get a source transcription, and a correction transcription in which the speaker says a name then spells it letter by letter.

Reply with exactly one line, and nothing else:
<span exactly as it appears in the source> => <the spelled letters joined up>
or
NO MATCH

- The left side must be copied character for character from the SOURCE. The correction transcription mishears the name a second time; ignore how it spells it there.
- The source span is often two or three words, because recognition splits names it does not know. Take the whole name, and only the name.
- The right side is the spelled letters, in the order given, joined up with one capital at the start.
- Reply NO MATCH when nothing in the source sounds like the spelled name.
- The source may be in any language. Reply with the name only, never the whole sentence.

source: I work with Tasmin
correction: Das mean spells T-A-S-M-E-E-N
Tasmin => Tasmeen

source: I work with Sarah
correction: Tasmin spells T-A-S-M-E-E-N
NO MATCH

source: I like apples
correction: Oranges spells O-R-A-N-G-E-S
NO MATCH

source: We deployed to Versal yesterday
correction: Versoff spells V E R C E L
Versal => Vercel

source: The Coober netties cluster is down
correction: Kuber nettis spells K U B E R N E T E S
Coober netties => Kubernetes

source: Jag pratade med Yuhan igar om projektet
correction: Johan spells J O H A N
Yuhan => Johan

source: When is handling the deploy
correction: New yen spells N G U Y E N
When => Nguyen

source: Anna ees joined the design team
correction: Anna east spells A N A I S
Anna ees => Anais""",

# Splitting v10, which changed two things at once: v11 is the non-English
# example alone, v12 the "any language, name only" rule alone.
"v11": """Map a misheard name to the spelling the speaker just read out.

You get a source transcription, and a correction transcription in which the speaker says a name then spells it letter by letter.

Reply with exactly one line, and nothing else:
<span exactly as it appears in the source> => <the spelled letters joined up>
or
NO MATCH

- The left side must be copied character for character from the SOURCE. The correction transcription mishears the name a second time; ignore how it spells it there.
- The source span is often two or three words, because recognition splits names it does not know. Take the whole name, and only the name.
- The right side is the spelled letters, in the order given, joined up with one capital at the start.
- Reply NO MATCH when nothing in the source sounds like the spelled name.

source: I work with Tasmin
correction: Das mean spells T-A-S-M-E-E-N
Tasmin => Tasmeen

source: I work with Sarah
correction: Tasmin spells T-A-S-M-E-E-N
NO MATCH

source: I like apples
correction: Oranges spells O-R-A-N-G-E-S
NO MATCH

source: We deployed to Versal yesterday
correction: Versoff spells V E R C E L
Versal => Vercel

source: The Coober netties cluster is down
correction: Kuber nettis spells K U B E R N E T E S
Coober netties => Kubernetes

source: Jag pratade med Yuhan igar om projektet
correction: Johan spells J O H A N
Yuhan => Johan

source: When is handling the deploy
correction: New yen spells N G U Y E N
When => Nguyen

source: Anna ees joined the design team
correction: Anna east spells A N A I S
Anna ees => Anais""",

"v12": """Map a misheard name to the spelling the speaker just read out.

You get a source transcription, and a correction transcription in which the speaker says a name then spells it letter by letter.

Reply with exactly one line, and nothing else:
<span exactly as it appears in the source> => <the spelled letters joined up>
or
NO MATCH

- The left side must be copied character for character from the SOURCE. The correction transcription mishears the name a second time; ignore how it spells it there.
- The source span is often two or three words, because recognition splits names it does not know. Take the whole name, and only the name.
- The right side is the spelled letters, in the order given, joined up with one capital at the start.
- Reply NO MATCH when nothing in the source sounds like the spelled name.
- The source may be in any language. Reply with the name only, never the whole sentence.

source: I work with Tasmin
correction: Das mean spells T-A-S-M-E-E-N
Tasmin => Tasmeen

source: I work with Sarah
correction: Tasmin spells T-A-S-M-E-E-N
NO MATCH

source: I like apples
correction: Oranges spells O-R-A-N-G-E-S
NO MATCH

source: We deployed to Versal yesterday
correction: Versoff spells V E R C E L
Versal => Vercel

source: The Coober netties cluster is down
correction: Kuber nettis spells K U B E R N E T E S
Coober netties => Kubernetes

source: When is handling the deploy
correction: New yen spells N G U Y E N
When => Nguyen

source: Anna ees joined the design team
correction: Anna east spells A N A I S
Anna ees => Anais""",

# Phase 0 of the localisation plan: v8's structure, written in French, with
# French examples. The question it answers is whether a per-language prompt is
# worth the machinery — adding French examples to the English prompt (v10, v12)
# was a wash, but a wholly French prompt had never been tried. Baseline to beat
# is gemma4:e4b on tests/french-cases.yaml with v8, which is a stable 79%.
#
# The example names are deliberately not ones from the French set. "marche =>
# Marc" is the French counterpart of v8's "When => Nguyen": an ordinary word
# that is in fact the misheard name.
"v13": """Associe un nom mal transcrit a l'orthographe que la personne vient d'epeler.

Tu recois une transcription source, et une transcription de correction dans laquelle la personne dit un nom puis l'epelle lettre par lettre.

Reponds par une seule ligne, et rien d'autre :
<les mots exactement comme ils apparaissent dans la source> => <les lettres epelees assemblees>
ou
NO MATCH

- La partie gauche doit etre copiee caractere par caractere depuis la SOURCE. La transcription de correction se trompe une seconde fois sur le nom ; ignore la facon dont il y apparait.
- Le nom occupe souvent deux ou trois mots dans la source, parce que la reconnaissance vocale decoupe les noms qu'elle ne connait pas. Prends le nom entier, et rien que le nom.
- La partie droite est constituee des lettres epelees, dans l'ordre donne, assemblees avec une majuscule au debut.
- Reponds NO MATCH si rien dans la source ne ressemble au nom epele.

source: J'ai vu Ni cola hier au bureau
correction: Nicolas s'ecrit N I C O L A S
Ni cola => Nicolas

source: J'ai vu Sophie hier au bureau
correction: Nicolas s'ecrit N I C O L A S
NO MATCH

source: Il pleut beaucoup en ce moment
correction: Oranges s'ecrit O R A N G E S
NO MATCH

source: On utilise Post gres pour les donnees
correction: Postgresse s'ecrit P O S T G R E S
Post gres => Postgres

source: Le cluster Elastic serge est lent
correction: Elastic search s'ecrit E L A S T I C S E A R C H
Elastic serge => Elasticsearch

source: Il faut que ca marche demain
correction: Marc s'ecrit M A R C
marche => Marc

source: Cle mence a rejoint l'equipe hier
correction: Clemence s'ecrit C L E M E N C E
Cle mence => Clemence""",

# --- The length ladder ---------------------------------------------------
#
# Latency here is prefill, not generation. Measured on e4b: 420 prompt tokens
# in, 6 out, 0.87s prefill against 0.13s generate. Ollama's cache only helps
# when the new prompt strictly extends the cached one, and a fresh dictation
# never does, so every call re-reads the whole prompt at ~2.1ms/token. Prompt
# length *is* the latency.
#
# Two things make it safe to cut. The pipeline scores 100% on English, so
# there is no accuracy being defended. And `pipeline` equals `APP`, which says
# the model's right-hand side is thrown away and rebuilt by regex — so every
# token spent teaching, and emitting, that right side is waste.
#
# v14 is v8 with the right side gone and nothing else changed. v15 and v16
# then cut examples, which is where the risk actually is.

# v8, span-only. The right-side rule is deleted with it. Deliberately NOT v5:
# v5 carries the "ordinary English word" clause that v8 measured and removed.
"v14": """Find the words in the source line that the speaker is correcting.

You get a source transcription, and a correction transcription in which the speaker says a name then spells it letter by letter.

Reply with those words copied from the source line, and nothing else.
Or reply NO MATCH.

- Copy the words from the SOURCE. The correction transcription mishears the name a second time; ignore how it appears there.
- The source span is often two or three words, because recognition splits names it does not know. Take the whole name, and only the name.
- Reply NO MATCH when nothing in the source sounds like the spelled name.

source: I work with Tasmin
correction: Das mean spells T-A-S-M-E-E-N
Tasmin

source: I work with Sarah
correction: Tasmin spells T-A-S-M-E-E-N
NO MATCH

source: I like apples
correction: Oranges spells O-R-A-N-G-E-S
NO MATCH

source: We deployed to Versal yesterday
correction: Versoff spells V E R C E L
Versal

source: The Coober netties cluster is down
correction: Kuber nettis spells K U B E R N E T E S
Coober netties

source: When is handling the deploy
correction: New yen spells N G U Y E N
When

source: Anna ees joined the design team
correction: Anna east spells A N A I S
Anna ees""",

# v14 with three examples dropped. The four kept are the four categories: a
# one-word name, a negative, a multi-word split, and a name that is an
# ordinary English word.
"v15": """Find the words in the source line that the speaker is correcting.

You get a source transcription, and a correction transcription in which the speaker says a name then spells it letter by letter.

Reply with those words copied from the source line, and nothing else.
Or reply NO MATCH.

- Copy the words from the SOURCE. The correction transcription mishears the name a second time; ignore how it appears there.
- The source span is often two or three words, because recognition splits names it does not know. Take the whole name, and only the name.
- Reply NO MATCH when nothing in the source sounds like the spelled name.

source: I work with Tasmin
correction: Das mean spells T-A-S-M-E-E-N
Tasmin

source: I work with Sarah
correction: Tasmin spells T-A-S-M-E-E-N
NO MATCH

source: The Coober netties cluster is down
correction: Kuber nettis spells K U B E R N E T E S
Coober netties

source: When is handling the deploy
correction: New yen spells N G U Y E N
When""",

# The floor: one positive, one negative, rules compressed to two lines.
"v16": """Find the words in the source line that the speaker is correcting.

The correction line says a name and then spells it letter by letter. Reply with the matching words copied from the source line, and nothing else — often two or three words, because recognition splits names it does not know. Take the whole name and only the name, never words from the correction line. Reply NO MATCH when nothing in the source sounds like the spelled name.

source: The Coober netties cluster is down
correction: Kuber nettis spells K U B E R N E T E S
Coober netties

source: I work with Sarah
correction: Tasmin spells T-A-S-M-E-E-N
NO MATCH""",

# v15 and v16 both broke in the same place: they invented a match for "The
# weather is nice today" and for "I like apples". Both had dropped one of the
# two NO MATCH examples. So the negatives are load-bearing and the positives
# may not be — v17 keeps both negatives and drops two positives instead.
"v17": """Find the words in the source line that the speaker is correcting.

You get a source transcription, and a correction transcription in which the speaker says a name then spells it letter by letter.

Reply with those words copied from the source line, and nothing else.
Or reply NO MATCH.

- Copy the words from the SOURCE. The correction transcription mishears the name a second time; ignore how it appears there.
- The source span is often two or three words, because recognition splits names it does not know. Take the whole name, and only the name.
- Reply NO MATCH when nothing in the source sounds like the spelled name.

source: I work with Tasmin
correction: Das mean spells T-A-S-M-E-E-N
Tasmin

source: I work with Sarah
correction: Tasmin spells T-A-S-M-E-E-N
NO MATCH

source: I like apples
correction: Oranges spells O-R-A-N-G-E-S
NO MATCH

source: The Coober netties cluster is down
correction: Kuber nettis spells K U B E R N E T E S
Coober netties

source: When is handling the deploy
correction: New yen spells N G U Y E N
When""",

# The other axis: keep all seven of v14's examples, compress the prose. If the
# examples are what carry the accuracy, the rules should be the cheap part.
"v18": """Find the words in the source line that the speaker is correcting.

The correction line says a name and then spells it letter by letter. Reply with the matching words copied from the source line and nothing else, or NO MATCH. Never answer with words from the correction line, which mishears the name a second time.

source: I work with Tasmin
correction: Das mean spells T-A-S-M-E-E-N
Tasmin

source: I work with Sarah
correction: Tasmin spells T-A-S-M-E-E-N
NO MATCH

source: I like apples
correction: Oranges spells O-R-A-N-G-E-S
NO MATCH

source: We deployed to Versal yesterday
correction: Versoff spells V E R C E L
Versal

source: The Coober netties cluster is down
correction: Kuber nettis spells K U B E R N E T E S
Coober netties

source: When is handling the deploy
correction: New yen spells N G U Y E N
When

source: Anna ees joined the design team
correction: Anna east spells A N A I S
Anna ees""",

# v13, span-only. Same edit as v8 -> v14, on the French prompt.
"v19": """Trouve les mots de la ligne source que la personne est en train de corriger.

Tu recois une transcription source, et une transcription de correction dans laquelle la personne dit un nom puis l'epelle lettre par lettre.

Reponds avec ces mots copies depuis la ligne source, et rien d'autre.
Ou reponds NO MATCH.

- Copie les mots depuis la SOURCE. La transcription de correction se trompe une seconde fois sur le nom ; ignore la facon dont il y apparait.
- Le nom occupe souvent deux ou trois mots dans la source, parce que la reconnaissance vocale decoupe les noms qu'elle ne connait pas. Prends le nom entier, et rien que le nom.
- Reponds NO MATCH si rien dans la source ne ressemble au nom epele.

source: J'ai vu Ni cola hier au bureau
correction: Nicolas s'ecrit N I C O L A S
Ni cola

source: J'ai vu Sophie hier au bureau
correction: Nicolas s'ecrit N I C O L A S
NO MATCH

source: Il pleut beaucoup en ce moment
correction: Oranges s'ecrit O R A N G E S
NO MATCH

source: On utilise Post gres pour les donnees
correction: Postgres s'ecrit P O S T G R E S
Post gres

source: marche est en conge cette semaine
correction: Marc s'ecrit M A R C
marche

source: Cle mence a rejoint l'equipe hier
correction: Clemence s'ecrit C L E M E N C E
Cle mence""",

# v13's two remaining French losses, one hypothesis each.
#
# v20: the false positive. "On livre vendredi prochain" against a spelled
# K U B E R N E T E S came back as a match. Every negative in v13 is an
# ordinary given name (Nicolas, Oranges); none is a product name, which is
# exactly the shape that failed. This adds one, generated.
"v20": """Associe un nom mal transcrit a l'orthographe que la personne vient d'epeler.

Tu recois une transcription source, et une transcription de correction dans laquelle la personne dit un nom puis l'epelle lettre par lettre.

Reponds par une seule ligne, et rien d'autre :
<les mots exactement comme ils apparaissent dans la source> => <les lettres epelees assemblees>
ou
NO MATCH

- La partie gauche doit etre copiee caractere par caractere depuis la SOURCE. La transcription de correction se trompe une seconde fois sur le nom ; ignore la facon dont il y apparait.
- Le nom occupe souvent deux ou trois mots dans la source, parce que la reconnaissance vocale decoupe les noms qu'elle ne connait pas. Prends le nom entier, et rien que le nom.
- La partie droite est constituee des lettres epelees, dans l'ordre donne, assemblees avec une majuscule au debut.
- Reponds NO MATCH si rien dans la source ne ressemble au nom epele.

source: J'ai vu Ni cola hier au bureau
correction: Nicolas s'ecrit N I C O L A S
Ni cola => Nicolas

source: J'ai vu Sophie hier au bureau
correction: Nicolas s'ecrit N I C O L A S
NO MATCH

source: Il pleut beaucoup en ce moment
correction: Oranges s'ecrit O R A N G E S
NO MATCH

source: On se voit lundi matin
correction: Dock heure s'ecrit D O C K E R
NO MATCH

source: On utilise Post gres pour les donnees
correction: Postgres s'ecrit P O S T G R E S
Post gres => Postgres

source: marche est en conge cette semaine
correction: Marc s'ecrit M A R C
marche => Marc

source: Cle mence a rejoint l'equipe hier
correction: Clemence s'ecrit C L E M E N C E
Cle mence => Clemence""",

# v21: the under-trimmed span. "Say goal enn" came back as "Say goal" — every
# positive example in v13 splits into exactly two words, so three is a shape
# the prompt never shows. Note v9 tried this on English and made spans
# over-run, so it is measured here rather than assumed.
"v21": """Associe un nom mal transcrit a l'orthographe que la personne vient d'epeler.

Tu recois une transcription source, et une transcription de correction dans laquelle la personne dit un nom puis l'epelle lettre par lettre.

Reponds par une seule ligne, et rien d'autre :
<les mots exactement comme ils apparaissent dans la source> => <les lettres epelees assemblees>
ou
NO MATCH

- La partie gauche doit etre copiee caractere par caractere depuis la SOURCE. La transcription de correction se trompe une seconde fois sur le nom ; ignore la facon dont il y apparait.
- Le nom occupe souvent deux ou trois mots dans la source, parce que la reconnaissance vocale decoupe les noms qu'elle ne connait pas. Prends le nom entier, et rien que le nom.
- La partie droite est constituee des lettres epelees, dans l'ordre donne, assemblees avec une majuscule au debut.
- Reponds NO MATCH si rien dans la source ne ressemble au nom epele.

source: J'ai vu Ni cola hier au bureau
correction: Nicolas s'ecrit N I C O L A S
Ni cola => Nicolas

source: J'ai vu Sophie hier au bureau
correction: Nicolas s'ecrit N I C O L A S
NO MATCH

source: Il pleut beaucoup en ce moment
correction: Oranges s'ecrit O R A N G E S
NO MATCH

source: On a croise Al ex andre au bureau
correction: Alexandre s'ecrit A L E X A N D R E
Al ex andre => Alexandre

source: On utilise Post gres pour les donnees
correction: Postgres s'ecrit P O S T G R E S
Post gres => Postgres

source: marche est en conge cette semaine
correction: Marc s'ecrit M A R C
marche => Marc

source: Cle mence a rejoint l'equipe hier
correction: Clemence s'ecrit C L E M E N C E
Cle mence => Clemence""",

# --- Two corrections at once, and corrections that are described ------------
#
# v22 is v14 with the right-hand side put back and two capabilities added: an
# utterance can carry more than one correction, and a correction can describe
# the change ("with a G at the beginning") instead of spelling it.
#
# The right side has to come back. v14 dropped it because the regex rebuilt the
# spelling from the letters and the model's version was thrown away — but a
# described change has no letters in it, so for that shape the model's right
# side is the only spelling there is. It also gives the code something to match
# the regex candidate against, which is how the two are told apart now:
# see spelling_segments/choose_spelling below.
"v22": """Find the words in the source line that the speaker is correcting.

You get a source transcription, and a correction transcription in which the \
speaker names a word and then says how it is written — either by spelling it \
letter by letter, or by describing what to change.

Reply with one line per correction, and nothing else:
<the words exactly as they appear in the source> => <the corrected spelling>
Or reply NO MATCH.

- Copy the left side from the SOURCE. The correction transcription mishears \
the name a second time; ignore how it appears there.
- The source span is often two or three words, because recognition splits \
names it does not know. Take the whole name, and only the name.
- When the change is described rather than spelled, apply exactly what was \
described to the source word and change nothing else about it.
- One utterance can carry two corrections. Give each its own line.
- Reply NO MATCH when nothing in the source sounds like the name.

source: I work with Tasmin
correction: Das mean spells T-A-S-M-E-E-N
Tasmin => Tasmeen

source: I work with Sarah
correction: Tasmin spells T-A-S-M-E-E-N
NO MATCH

source: I like apples
correction: Oranges spells O-R-A-N-G-E-S
NO MATCH

source: We deployed to Versal yesterday
correction: Versoff spells V E R C E L
Versal => Vercel

source: The Coober netties cluster is down
correction: Kuber nettis spells K U B E R N E T E S
Coober netties => Kubernetes

source: When is handling the deploy
correction: New yen spells N G U Y E N
When => Nguyen

source: Anna ees joined the design team
correction: Anna east spells A N A I S
Anna ees => Anais

source: Steven is reviewing the doc
correction: Steven with a p h
Steven => Stephen

source: Matthew and Jon are on the call
correction: Matthew takes only one t and Jon is spelled with an h
Matthew => Mathew
Jon => John""",

# v22's three added examples all had a one-word span, and the model learned
# exactly that: seven two-word spans that v14 got right came back as their
# first word ("Say goal enn" as "Say goal", "Locks me" as "Locks"). The
# examples teach the boundary, and v22's taught the wrong one.
#
# So v24 keeps v22's rules and rebuilds the three: a described change over a
# two-word span, a described change that replaces the first letter, and a
# two-correction line whose first span is two words. It also gives the removal
# shape somewhere to be learnt — v22 answered "Phillip with one l" with
# "Phill", truncating rather than applying the change — and stops "with a G at
# the beginning" being read as "the name that starts with G", which is how
# Jerome came back George.
"v24": """Find the words in the source line that the speaker is correcting.

You get a source transcription, and a correction transcription in which the \
speaker names a word and then says how it is written — either by spelling it \
letter by letter, or by describing what to change.

Reply with one line per correction, and nothing else:
<the words exactly as they appear in the source> => <the corrected spelling>
Or reply NO MATCH.

- Copy the left side from the SOURCE. The correction transcription mishears \
the name a second time; ignore how it appears there.
- The source span is often two or three words, because recognition splits \
names it does not know. Take the whole name, and only the name.
- When the change is described rather than spelled, apply exactly what was \
described to the source word and change nothing else about it.
- One utterance can carry two corrections. Give each its own line.
- Reply NO MATCH when nothing in the source sounds like the name.

source: I work with Tasmin
correction: Das mean spells T-A-S-M-E-E-N
Tasmin => Tasmeen

source: I work with Sarah
correction: Tasmin spells T-A-S-M-E-E-N
NO MATCH

source: I like apples
correction: Oranges spells O-R-A-N-G-E-S
NO MATCH

source: We deployed to Versal yesterday
correction: Versoff spells V E R C E L
Versal => Vercel

source: The Coober netties cluster is down
correction: Kuber nettis spells K U B E R N E T E S
Coober netties => Kubernetes

source: When is handling the deploy
correction: New yen spells N G U Y E N
When => Nguyen

source: Anna ees joined the design team
correction: Anna east spells A N A I S
Anna ees => Anais

source: The Rabbit em queue broker is down
correction: Rabbit MQ is one word
Rabbit em queue => Rabbitmq

source: Katia opened the ticket
correction: Katia with a C at the beginning
Katia => Catia

source: Anna ees and Emmilie are on the call
correction: Anna east spells A N A I S and Emmilie takes one m
Anna ees => Anais
Emmilie => Emilie""",

# The right-hand side, deleted again.
#
# v14 dropped it and it had to come back for v22, because a described change
# has no letters and only the model could write the corrected name. Now that
# described_edit applies the change in code, that reason is gone — and with it
# the cost, which was measurable: v22 and v24 both truncate two-word spans that
# v14 got right ("Locks me" to "Locks", "Oluwa shane" to "Oluwa"). Writing the
# name out evidently pulls the model toward the shortest span it can spell.
#
# So v25 is v14's span-only reply, told about the two new shapes. The model
# names the words; everything to the right of the arrow is now code.
"v25": """Find the words in the source line that the speaker is correcting.

You get a source transcription, and a correction transcription in which the \
speaker names a word and then says how it is written — either by spelling it \
letter by letter, or by describing what to change about it.

Reply with those words copied from the source line, and nothing else. \
One line per correction. Or reply NO MATCH.

- Copy the words from the SOURCE. The correction transcription mishears the \
name a second time; ignore how it appears there.
- The source span is often two or three words, because recognition splits \
names it does not know. Take the whole name, and only the name.
- Never write the corrected spelling. Only the words being corrected.
- One utterance can carry two corrections. Give each its own line.
- Reply NO MATCH when nothing in the source sounds like the name.

source: I work with Tasmin
correction: Das mean spells T-A-S-M-E-E-N
Tasmin

source: I work with Sarah
correction: Tasmin spells T-A-S-M-E-E-N
NO MATCH

source: I like apples
correction: Oranges spells O-R-A-N-G-E-S
NO MATCH

source: We deployed to Versal yesterday
correction: Versoff spells V E R C E L
Versal

source: The Coober netties cluster is down
correction: Kuber nettis spells K U B E R N E T E S
Coober netties

source: When is handling the deploy
correction: New yen spells N G U Y E N
When

source: Anna ees joined the design team
correction: Anna east spells A N A I S
Anna ees

source: The Rabbit em queue broker is down
correction: Rabbit MQ is one word
Rabbit em queue

source: Anna ees and Emmilie are on the call
correction: Anna east spells A N A I S and Emmilie takes one m
Anna ees
Emmilie""",

# v25 plus a NO MATCH whose correction describes a change rather than spelling
# one. Both negative examples in v25 are spelled, and v22/v24/v25 all answer
# "apples => Oranges" to a case that is in the prompt verbatim as NO MATCH —
# teaching the described shape evidently made the model readier to find a
# match in general, and the boundary has to be taught in that shape too. It
# pairs with the Katia example: same words, opposite answer.
"v26": """Find the words in the source line that the speaker is correcting.

You get a source transcription, and a correction transcription in which the \
speaker names a word and then says how it is written — either by spelling it \
letter by letter, or by describing what to change about it.

Reply with those words copied from the source line, and nothing else. \
One line per correction. Or reply NO MATCH.

- Copy the words from the SOURCE. The correction transcription mishears the \
name a second time; ignore how it appears there.
- The source span is often two or three words, because recognition splits \
names it does not know. Take the whole name, and only the name.
- Never write the corrected spelling. Only the words being corrected.
- One utterance can carry two corrections. Give each its own line.
- Reply NO MATCH when nothing in the source sounds like the name.

source: I work with Tasmin
correction: Das mean spells T-A-S-M-E-E-N
Tasmin

source: I work with Sarah
correction: Tasmin spells T-A-S-M-E-E-N
NO MATCH

source: I like apples
correction: Oranges spells O-R-A-N-G-E-S
NO MATCH

source: We are shipping on Friday
correction: Katia with a C at the beginning
NO MATCH

source: We deployed to Versal yesterday
correction: Versoff spells V E R C E L
Versal

source: The Coober netties cluster is down
correction: Kuber nettis spells K U B E R N E T E S
Coober netties

source: When is handling the deploy
correction: New yen spells N G U Y E N
When

source: Anna ees joined the design team
correction: Anna east spells A N A I S
Anna ees

source: Katia opened the ticket
correction: Katia with a C at the beginning
Katia

source: The Rabbit em queue broker is down
correction: Rabbit MQ is one word
Rabbit em queue

source: Anna ees and Emmilie are on the call
correction: Anna east spells A N A I S and Emmilie takes one m
Anna ees
Emmilie""",

# v26 with one clause added to the span rule, and nothing else. v27 tried
# teaching the same thing with an extra example and scored two points lower;
# this is the cheaper half of that change, measured on its own.
"v28": """Find the words in the source line that the speaker is correcting.

You get a source transcription, and a correction transcription in which the \
speaker names a word and then says how it is written — either by spelling it \
letter by letter, or by describing what to change about it.

Reply with those words copied from the source line, and nothing else. \
One line per correction. Or reply NO MATCH.

- Copy the words from the SOURCE. The correction transcription mishears the \
name a second time; ignore how it appears there.
- The source span is often two or three words, because recognition splits \
names it does not know. Take the whole name, and only the name, even when \
part of it is an ordinary word.
- Never write the corrected spelling. Only the words being corrected.
- One utterance can carry two corrections. Give each its own line.
- Reply NO MATCH when nothing in the source sounds like the name.

source: I work with Tasmin
correction: Das mean spells T-A-S-M-E-E-N
Tasmin

source: I work with Sarah
correction: Tasmin spells T-A-S-M-E-E-N
NO MATCH

source: I like apples
correction: Oranges spells O-R-A-N-G-E-S
NO MATCH

source: We are shipping on Friday
correction: Katia with a C at the beginning
NO MATCH

source: We deployed to Versal yesterday
correction: Versoff spells V E R C E L
Versal

source: The Coober netties cluster is down
correction: Kuber nettis spells K U B E R N E T E S
Coober netties

source: When is handling the deploy
correction: New yen spells N G U Y E N
When

source: Anna ees joined the design team
correction: Anna east spells A N A I S
Anna ees

source: Katia opened the ticket
correction: Katia with a C at the beginning
Katia

source: The Rabbit em queue broker is down
correction: Rabbit MQ is one word
Rabbit em queue

source: Anna ees and Emmilie are on the call
correction: Anna east spells A N A I S and Emmilie takes one m
Anna ees
Emmilie""",

# v26 plus a span whose second word is an ordinary English word. Every
# multi-word example ends in something that is not a word — "Anna ees", "Coober
# netties" — and the spans that come back short all end in one that is: "Jang
# way" as "Jang", "Koval chick" as "Koval", "Graph on a" as "Graph". The model
# stops where the examples stop.
"v27": """Find the words in the source line that the speaker is correcting.

You get a source transcription, and a correction transcription in which the \
speaker names a word and then says how it is written — either by spelling it \
letter by letter, or by describing what to change about it.

Reply with those words copied from the source line, and nothing else. \
One line per correction. Or reply NO MATCH.

- Copy the words from the SOURCE. The correction transcription mishears the \
name a second time; ignore how it appears there.
- The source span is often two or three words, because recognition splits \
names it does not know. Take the whole name, and only the name, even when part \
of it is an ordinary word.
- Never write the corrected spelling. Only the words being corrected.
- One utterance can carry two corrections. Give each its own line.
- Reply NO MATCH when nothing in the source sounds like the name.

source: I work with Tasmin
correction: Das mean spells T-A-S-M-E-E-N
Tasmin

source: I work with Sarah
correction: Tasmin spells T-A-S-M-E-E-N
NO MATCH

source: I like apples
correction: Oranges spells O-R-A-N-G-E-S
NO MATCH

source: We are shipping on Friday
correction: Katia with a C at the beginning
NO MATCH

source: We deployed to Versal yesterday
correction: Versoff spells V E R C E L
Versal

source: The Coober netties cluster is down
correction: Kuber nettis spells K U B E R N E T E S
Coober netties

source: When is handling the deploy
correction: New yen spells N G U Y E N
When

source: The Data dog agent is noisy
correction: Datadog spells D A T A D O G
Data dog

source: Anna ees joined the design team
correction: Anna east spells A N A I S
Anna ees

source: Katia opened the ticket
correction: Katia with a C at the beginning
Katia

source: The Rabbit em queue broker is down
correction: Rabbit MQ is one word
Rabbit em queue

source: Anna ees and Emmilie are on the call
correction: Anna east spells A N A I S and Emmilie takes one m
Anna ees
Emmilie""",

# v13 with the same two additions, in French. The described-change example
# carries accents where the rest of the prompt does not: preserving the source
# word's accents while applying only what was described is exactly the
# behaviour being taught, and it cannot be taught in an unaccented example.
"v23": """Associe un nom mal transcrit a l'orthographe que la personne vient d'indiquer.

Tu recois une transcription source, et une transcription de correction dans \
laquelle la personne dit un nom puis indique comment il s'ecrit — soit en \
l'epelant lettre par lettre, soit en decrivant ce qu'il faut changer.

Reponds par une ligne par correction, et rien d'autre :
<les mots exactement comme ils apparaissent dans la source> => <l'orthographe corrigee>
ou
NO MATCH

- La partie gauche doit etre copiee caractere par caractere depuis la SOURCE. \
La transcription de correction se trompe une seconde fois sur le nom ; ignore \
la facon dont il y apparait.
- Le nom occupe souvent deux ou trois mots dans la source, parce que la \
reconnaissance vocale decoupe les noms qu'elle ne connait pas. Prends le nom \
entier, et rien que le nom.
- Quand la personne epelle, la partie droite est constituee des lettres \
epelees, dans l'ordre donne, assemblees avec une majuscule au debut.
- Quand la personne decrit le changement au lieu de l'epeler, applique \
exactement ce qui est decrit au mot de la source, et ne change rien d'autre.
- Une seule phrase peut porter deux corrections. Donne une ligne a chacune.
- Reponds NO MATCH si rien dans la source ne ressemble au nom.

source: J'ai vu Ni cola hier au bureau
correction: Nicolas s'ecrit N I C O L A S
Ni cola => Nicolas

source: J'ai vu Sophie hier au bureau
correction: Nicolas s'ecrit N I C O L A S
NO MATCH

source: Il pleut beaucoup en ce moment
correction: Oranges s'ecrit O R A N G E S
NO MATCH

source: On utilise Post gres pour les donnees
correction: Postgresse s'ecrit P O S T G R E S
Post gres => Postgres

source: Le cluster Elastic serge est lent
correction: Elastic search s'ecrit E L A S T I C S E A R C H
Elastic serge => Elasticsearch

source: Il faut que ca marche demain
correction: Marc s'ecrit M A R C
marche => Marc

source: Cle mence a rejoint l'equipe hier
correction: Clemence s'ecrit C L E M E N C E
Cle mence => Clemence

source: Frederic a relu la maquette
correction: Frédéric avec des accents sur les e
Frederic => Frédéric

source: Nathalie et Philipe sont sur l'appel
correction: Nathalie sans le h et Philipe avec deux p
Nathalie => Natalie
Philipe => Philippe""",
}

# Prompts to use per detected language, English falling back to itself. This is
# the table the plan's Phase 2 would move into LocalLLM.swift.
BY_LANGUAGE = {"en": "v8", "fr": "v13"}

# Variants whose reply is the span alone, so there is no full line to score.
SPAN_ONLY = {"v5", "v6", "v7", "v14", "v15", "v16", "v17", "v18", "v19", "v25", "v26", "v27", "v28"}
# Variants that answer with word numbers; the span is rebuilt from the source.
INDEXED = {"v6"}
# Variants that read the correction first, so the source is nearest the answer.
SOURCE_LAST = {"v7"}

def user_prompt(variant, src, corr):
    """What goes to the model. Indexed variants see the source words numbered."""
    if variant in INDEXED:
        src = " ".join(f"{i} {w}" for i, w in enumerate(src.split(), 1))
    if variant in SOURCE_LAST:
        return f"correction: {corr}\nsource: {src}"
    return f"source: {src}\ncorrection: {corr}"

def decode(variant, reply, src):
    """The span the model named, however it named it.

    For indexed variants the model returns word numbers, so the span is looked
    up in the source rather than copied by the model — out-of-range numbers are
    dropped, and a reply with nothing usable in it means no rule, which is the
    same outcome the app gives for NO MATCH.
    """
    if variant not in INDEXED:
        return reply
    if re.search(r"\bnone\b|\bno match\b", reply, re.I):
        return "NO MATCH"
    words = src.split()
    picked = [words[n - 1] for n in map(int, re.findall(r"\d+", reply))
              if 1 <= n <= len(words)]
    return " ".join(picked) if picked else "NO MATCH"

def ask(model, system, prompt, think, predict, num_ctx=None, meter=None):
    options = {"temperature": 0, "num_predict": predict}
    # Left unset, Ollama sizes the KV cache from the model's own context length
    # — 32k for gemma4 — which is orders of magnitude more than a one-line
    # answer needs. Passing it makes that cost measurable.
    if num_ctx:
        options["num_ctx"] = num_ctx
    body = {"model": model, "system": system,
            "prompt": prompt,
            "stream": False, "think": think,
            "options": options}
    req = urllib.request.Request("http://localhost:11434/api/generate",
        data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    t = time.time()
    with urllib.request.urlopen(req, timeout=600) as r:
        d = json.load(r)
    # Where the time went, split prefill from generation. Prefill that stays
    # cheap across calls means Ollama is reusing the KV cache for the system
    # prompt, and prompt length is nearly free; prefill that does not means
    # shortening the prompt is the lever.
    if meter is not None:
        for key in ("prompt_eval_count", "eval_count",
                    "prompt_eval_duration", "eval_duration", "load_duration"):
            meter[key] = meter.get(key, 0) + (d.get(key) or 0)
        meter["calls"] = meter.get("calls", 0) + 1
    return (d.get("response") or "").strip(), time.time() - t

NO_MATCH = re.compile(r"\bno match\b|\bnone\b|\[nothing\]", re.I)

def rules_of(value):
    """A case's `expect`, or a model's reply, as a list of "span => spelling".

    One utterance can now carry more than one correction, so an expectation is
    a list and NO MATCH is the empty list. A single-rule case keeps the plain
    string form it always had, which is why nothing above the new groups in the
    case files had to change.
    """
    if isinstance(value, str):
        value = [line for line in value.splitlines()]
    out = []
    for line in value:
        line = " ".join(str(line).split())
        if not line or NO_MATCH.search(line):
            continue
        # Bullets and numbering, which small models add unasked.
        line = re.sub(r"^\s*(?:[-*•]|\d+[.)])\s*", "", line)
        if line:
            out.append(line)
    return out

def split_rule(rule):
    """"span => spelling" as a pair. A reply with no arrow is all span, which
    is what the span-only variants answer with."""
    if "=>" in rule:
        span, spelling = rule.split("=>", 1)
        return span.strip(), spelling.strip()
    return rule.strip(), ""

LETTERS = re.compile(r"\b(?:[A-Za-z0-9][\s\-.]+){2,}[A-Za-z0-9]\b")
# "spells" in English, "ça s'écrit" / "s'épelle" in French. The French forms
# have to be here rather than left to the single-letter fallback: the fallback
# only matches a run of separated letters, and recognition stops separating
# them partway through ("M A T H Ieu"), so the two together yielded "Math".
TRIGGER = re.compile(
    r"(?:\b(?:spells?|spelled|spelling)\b"
    r"|s['’]\s*(?:é|e)(?:crit|pelle)"
    r"|\b(?:é|e)(?:crit|pelle)\b)", re.I)
# "spelled S U P A B A S E not super base" — the spelling ends here, in either
# language. Never applied to the first token: recognition merges letters into
# syllables, so "Pascal s'écrit Pas cal" opens with something that looks like a
# stop word, and breaking there would return no spelling at all.
STOP_WORDS = {"not", "instead", "rather", "but", "no",
              "pas", "non", "plutôt", "plutot", "mais"}
# What joins two corrections in one breath: "T A S M E E N and Mick spells
# M I K". Without these the first spelling ran to the end of the sentence and
# came back "Tasmeenandmickspellsmik".
#
# The risk is a spelling that merges INTO the conjunction — "Alexander spells
# A L E X and er" is a real rendering — so a conjunction only ends a segment
# when at least two tokens follow it. "and er" does not end one; "and Mick
# spells M I K" does.
CONJUNCTIONS = {"and", "et", "puis", "then", "ensuite", "also", "aussi"}

def tokens_with_breaks(text):
    """(token, punctuation before it), Unicode-alphanumeric runs.

    The punctuation flag is what lets ", Priyanka spells" end a segment when
    there is no conjunction to break on. An ASCII-only split turned "plutôt"
    into "plut", which is how a stop word goes missing on accented input.
    """
    out, cur, punct = [], [], False
    for ch in text:
        if ch.isalnum():
            cur.append(ch)
        else:
            if cur:
                out.append(("".join(cur), punct))
                cur, punct = [], False
            if ch in ",;:":
                punct = True
    if cur:
        out.append(("".join(cur), punct))
    return out

def spelling_segments(correction):
    """Every spelling read out in the utterance, in order, as (letters, read
    out as letters?) — taken from the text rather than from the model.

    Mirrors LocalLLM.spellingSegments. Everything after a trigger is the
    spelling, however the recogniser chunked it — matching only runs of single
    letters loses the tail, because recognition stops treating them as letters
    partway through ("T A S M Een" gave "Tasm", "Tas Meen" gave nothing).

    What is new is that a trigger no longer runs to the end of the sentence: a
    second trigger later in the text lets a comma end the segment too, and a
    conjunction ends it whenever real words follow.

    A described change ("s'écrit avec un G au début") matches a trigger and
    yields "Avecungaudebut" here. Nothing tries to detect that; choose_spelling
    below throws it away because it looks nothing like what the model answered.
    """
    triggers = list(TRIGGER.finditer(correction))
    if not triggers:
        m = LETTERS.search(correction)
        if not m:
            return []
        joined = re.sub(r"[^A-Za-z0-9]", "", m.group(0))
        if len(joined) < 3:
            return []
        return [(joined[:1].upper() + joined[1:].lower(), True)]

    out = []
    for i, trigger in enumerate(triggers):
        end = triggers[i + 1].start() if i + 1 < len(triggers) else len(correction)
        bounded = i + 1 < len(triggers)
        toks = tokens_with_breaks(correction[trigger.end():end])
        letters, taken, broke = "", [], False
        for pos, (token, punct) in enumerate(toks):
            low = token.lower()
            # A conjunction always ends a bounded segment: whatever follows it
            # belongs to the next clause. Unbounded, it has to earn the break
            # with two real tokens after it, or "A L E X and er" loses its tail.
            conjunction = low in CONJUNCTIONS and (bounded or len(toks) - pos - 1 >= 2)
            if letters and (low in STOP_WORDS or conjunction or (punct and bounded)):
                broke = True
                break
            letters += token
            taken.append(token)
        # Nothing ended it and another clause follows: what is left on the end
        # is that clause's name ("... M I K" has none, "... and Mick" does).
        if bounded and not broke and len(taken) > 1:
            letters = letters[:len(letters) - len(taken[-1])]
            taken.pop()
        if len(letters) >= 2:
            # Most of a spelled segment arrives as single characters even when
            # the tail merges into syllables, and no description of a change
            # does. It is the cheap half of telling the two apart; the
            # expensive half is agreement with the model, in choose_spelling.
            singles = sum(1 for t in taken if len(t) == 1)
            letterish = len(taken) >= 2 and singles / len(taken) >= 0.6
            out.append((letters[:1].upper() + letters[1:].lower(), letterish))
    return out

# ---- Changes the speaker describes instead of spelling ---------------------
#
# "Mathieu ne prend qu'un seul t" has no letters in it, so the regex that has
# always built the spelling has nothing to read. The obvious answer is to let
# the model write the corrected name — and it is the wrong one. Measured on the
# ten described cases in the English set, gemma4:e4b scores 50% and gemma4:12b
# 80%, and the failures are not misunderstandings: "Phillip with one l" came
# back "Phill" and "Philp", "Elisabeth with a z" came back "Elizabith". It is
# the same weakness the spelled path already routes around — a model asked to
# copy characters loses some — and the answer is the same. The model finds the
# span; code applies the change.
#
# What is not recognised here falls back to the model, so "Jon is spelled with
# an h" still works: it needs to know that Jon becomes John, which is knowledge
# rather than character surgery.

# Letters as recognition renders them when they are dictated on their own —
# "one t" arrives as "one tea", "un seul t" as "un seul thé". Only ever
# consulted in a slot the pattern has already decided is a letter, which is
# what makes it safe to include forms like "en" and "el".
LETTER_WORDS = {
    "tea": "t", "tee": "t", "zed": "z", "zee": "z", "see": "c", "sea": "c",
    "ex": "x", "why": "y", "are": "r", "ar": "r", "you": "u", "jay": "j",
    "kay": "k", "el": "l", "em": "m", "en": "n", "oh": "o", "pea": "p",
    "pee": "p", "cue": "q", "queue": "q", "ess": "s", "vee": "v", "bee": "b",
    "dee": "d", "eff": "f", "gee": "g", "aitch": "h", "eye": "i",
    "thé": "t", "the": "t", "té": "t", "cé": "c", "dé": "d", "gé": "g",
    "jé": "j", "pé": "p", "vé": "v", "bé": "b", "zède": "z", "ixe": "x",
    "ache": "h", "esse": "s", "èsse": "s", "effe": "f", "elle": "l",
    "emme": "m", "enne": "n", "erre": "r", "ka": "k", "ku": "q",
}

def as_letter(token):
    """The letter a slot names, however recognition rendered it."""
    token = token.strip("'’ ").lower()
    if len(token) == 1 and token.isalpha():
        return token
    return LETTER_WORDS.get(token)

L = r"([^\W\d_]{1,5}['’]?)"          # a letter, or the word for one
POSITION_FIRST = r"(?:at\s+the\s+(?:beginning|start)|au\s+d[ée]but|en\s+premier)"
POSITION_LAST = r"(?:at\s+the\s+end|[àa]\s+la\s+fin|en\s+dernier)"
ACCENTS = {"aigu": "́", "grave": "̀", "circonflexe": "̂",
           "chapeau": "̂", "tréma": "̈", "trema": "̈",
           "cédille": "̧", "cedille": "̧"}

# Ordered: "without the h" has to be read before "with ... h", and "one l"
# before "a G at the beginning", or the looser pattern eats the tighter one.
DESCRIBED = [
    ("join",   r"\b(?:in|en)\s+(?:one|a|un)\s+(?:single\s+|seul\s+)?(?:word|mot)\b"),
    ("join",   r"\b(?:is|est)\s+one\s+word\b"),
    ("hyphen", r"\b(?:hyphens?|hyphenated|dash|trait\s+d['’ ]?union|tiret)\b"),
    ("strip",  r"\b(?:without|sans)\s+(?:the\s+)?accents?\b"),
    ("accent", r"\b(?:accents?|tr[ée]ma|c[ée]dille)\b(?:\s+\w+)*?\s+"
               r"(?:sur|on)\s+(?:l[ea]s?|the)?\s*" + L),
    ("double", r"\b(?:two|double|deux)\s+" + L + r"\b"),
    ("single", r"\b(?:only\s+)?(?:one|a\s+single|un\s+seul|une\s+seule)\s+" + L + r"\b"),
    ("first",  r"\b(?:with|avec)\s+(?:an?|un|une)\s+" + L + r"\b[^.]*?" + POSITION_FIRST),
    ("last",   r"\b(?:with|avec)\s+(?:an?|un|une)\s+" + L + r"\b[^.]*?" + POSITION_LAST),
    ("remove", r"\b(?:without|sans)\s+(?:the\s+|de\s+|d['’])?" + L + r"\b"),
    # Bare "with a z", no position and no count. Which letter it replaces is
    # left to the confusable table: recognition heard something for the letter
    # actually written, so the one it can be swapped for is the one that sounds
    # like it. "Elisabeth with a z" has exactly one candidate, the s.
    ("swap",   r"\b(?:with|avec)\s+(?:an?|un|une)\s+" + L + r"\b"),
]

def described_edit(clause, word):
    """The word with the described change applied, or None if nothing in the
    clause describes one this code knows how to make."""
    for op, pattern in DESCRIBED:
        m = re.search(pattern, clause, re.I)
        if not m:
            continue
        letter = as_letter(m.group(1)) if m.groups() else None
        if op in ("accent", "double", "single", "first",
                  "last", "remove", "swap") and not letter:
            continue
        out = apply_described(op, letter, word, clause)
        if out and out.lower() != word.lower():
            return out
    return None

def apply_described(op, letter, word, clause):
    import unicodedata
    if op == "join":
        return re.sub(r"[\s\-]+", "", word)
    if op == "hyphen":
        return re.sub(r"\s+", "-", word)
    if op == "strip":
        return "".join(c for c in unicodedata.normalize("NFD", word)
                       if not unicodedata.combining(c))
    if op == "accent":
        mark = next((v for k, v in ACCENTS.items() if re.search(k, clause, re.I)), "́")
        # "des accents sur les e" is every e; "un accent sur le e" is the first.
        every = re.search(r"\b(?:des|les|tous|all)\b", clause, re.I) is not None
        out, done = [], False
        for ch in unicodedata.normalize("NFD", word):
            out.append(ch)
            if ch.lower() == letter and (every or not done):
                out.append(mark)
                done = True
        return unicodedata.normalize("NFC", "".join(out))
    if op == "double":
        if re.search(letter + letter, word, re.I):
            return word
        i = word.lower().rfind(letter)
        return word[:i] + word[i] + word[i:] if i >= 0 else None
    if op == "single":
        return re.sub("(" + letter + ")\\1+", r"\1", word, flags=re.I)
    if op == "first":
        if not word:
            return None
        head = letter.upper() if word[0].isupper() else letter
        return head + word[1:]
    if op == "last":
        return word if word.lower().endswith(letter) else word + letter
    if op == "remove":
        return re.sub(letter, "", word, flags=re.I)
    if op == "swap":
        if letter in word.lower():
            return None
        for i, ch in enumerate(word):
            if sub_cost(ch.lower(), letter) == 0.5:
                swapped = letter.upper() if ch.isupper() else letter
                return word[:i] + swapped + word[i + 1:]
        return None
    return None

def clauses_of(correction):
    """The utterance split where one correction ends and the next begins."""
    parts = re.split(r"\b(?:and|et|puis|then|ensuite)\b|[,;]", correction, flags=re.I)
    return [p.strip() for p in parts if p and p.strip()]

def clause_for(span, proposed, correction):
    """The clause a given output line came from, so "Anna east spells A N A I S
    and Emmilie takes one m" applies its "one m" to Emmilie and not to Anais."""
    parts = clauses_of(correction)
    if len(parts) < 2:
        return correction
    best, score = correction, 0.0
    for part in parts:
        words = words_of(part)
        for size in (1, 2):
            for start in range(0, len(words) - size + 1):
                window = " ".join(words[start:start + size])
                s = max(similarity(window, span),
                        similarity(window, proposed) if proposed else 0.0)
                if s > score:
                    best, score = part, s
    return best

def choose_spelling(proposed, span, candidates, used, floor=0.55):
    """The spelling to actually use: the letters when they were read out, the
    model's own answer when they were not.

    The letters are exact and the model's copy of them is not, so the letters
    win wherever they exist — that is the whole reason interpret() has never
    trusted the model's right-hand side. But a described change has no letters,
    and the trigger regex happily returns "Avecungaudebut" for it. Rather than
    a list of description words, which would have to grow forever and would
    misfire on spellings that merge into ordinary words, the two are told apart
    by agreement: a candidate nothing else corroborates, and that does not read
    as letters on its own, is not a spelling.

    Corroboration is not only the model's answer. The span is the same name
    heard once already, so a real spelling resembles it — "Tasmin" against
    "Tasmeen" — and a description does not: "Jon is spelled with an h" yields
    "Withanh", which looks nothing like Jon. That matters because the reply may
    carry no spelling at all to compare against.
    """
    best, score = None, 0.0
    for i, (cand, letterish) in enumerate(candidates):
        if i in used:
            continue
        agreement = max(similarity(cand, proposed) if proposed else 0.0,
                        similarity(cand, span) if span else 0.0)
        # Read out as letters. Only which line it belongs to can be wrong, so
        # the best available agreement still decides the pairing.
        s = max(agreement, floor) if letterish else agreement
        if s > score:
            best, score = i, s
    if best is not None and score >= floor:
        used.add(best)
        return candidates[best][0]
    return None

# ---- The repair step in LocalLLM.swift, ported so the score reflects it ----
#
# interpret() does not trust the span: when it is not in the transcript, it
# snaps it to the nearest one- or two-word window using an edit distance that
# discounts the letter pairs recognition swaps. A model that answers with the
# correction line's word ("Lakshmi" for "Locks me") is repaired here, not
# prompted away — so a prompt scored without this step is scored against code
# the app does not run.

CONFUSABLE = [set("bp"), set("dt"), set("gk"), set("vf"), set("zs"), set("mn"),
              set("lr"), set("jg"), set("ck"), set("cs"), set("aeiouy")]

def sub_cost(a, b):
    if a == b:
        return 0.0
    return 0.5 if any(a in g and b in g for g in CONFUSABLE) else 1.0

def similarity(a, b):
    x = [c for c in a.lower() if not c.isspace()]
    y = [c for c in b.lower() if not c.isspace()]
    if not x or not y:
        return 0.0
    if x == y:
        return 1.0
    prev = [float(v) for v in range(len(y) + 1)]
    for i in range(1, len(x) + 1):
        cur = [float(i)] + [0.0] * len(y)
        for j in range(1, len(y) + 1):
            cur[j] = min(cur[j - 1] + 1, prev[j] + 1,
                         prev[j - 1] + sub_cost(x[i - 1], y[j - 1]))
        prev = cur
    return 1 - prev[len(y)] / max(len(x), len(y))

def words_of(text):
    """Swift's CharacterSet.alphanumerics is Unicode, so an ASCII-only class
    here would split "parlé" into "parl" and drop CJK entirely — measuring a
    tokenizer the app does not have, on exactly the text that needs it."""
    out, cur = [], []
    for ch in text:
        if ch.isalnum() or ch in "'-":
            cur.append(ch)
        elif cur:
            out.append("".join(cur))
            cur = []
    if cur:
        out.append("".join(cur))
    return out

def contains_word(word, transcript):
    needle = [w.lower() for w in words_of(word)]
    hay = [w.lower() for w in words_of(transcript)]
    if not needle or len(needle) > len(hay):
        return False
    return any(hay[i:i + len(needle)] == needle
               for i in range(len(hay) - len(needle) + 1))

def closest_word(target, transcript):
    words = words_of(transcript)
    best = None
    for size in (1, 2):
        for start in range(0, len(words) - size + 1):
            cand = " ".join(words[start:start + size])
            score = similarity(cand, target)
            if best is None or score > best[1]:
                best = (cand, score)
    return best[0] if best and best[1] >= 0.6 else None

def app_rules(reply, correction, source):
    """The rules VoiceCommand.interpret would actually add, in order.

    A line whose span is neither in the source nor close to anything in it is
    dropped rather than kept. That is what makes a half-heard utterance —
    "Kubernetes spells ... and Postgres spells ..." against a source with only
    Kubernetes in it — produce one rule instead of one rule and one invention.
    """
    candidates = spelling_segments(correction)
    used, rules = set(), []
    for rule in rules_of(reply):
        span, proposed = split_rule(rule)
        if not span:
            continue
        # The letters, when they were read out. Nothing else is trusted ahead
        # of them, because they are the only exact thing in the utterance.
        letters = choose_spelling(proposed, span, candidates, used)
        if source and not contains_word(span, source):
            scored = [(m, similarity(m, cand))
                      for cand in (letters or proposed, span) if cand
                      for m in [closest_word(cand, source)] if m]
            if not scored:
                continue
            resolved = max(scored, key=lambda t: t[1])[0]
        else:
            resolved = span
        # No letters: the change was described, so apply it to the source word.
        # Only if nothing recognisable was described does the model's own
        # spelling get used.
        spelling = letters or described_edit(
            clause_for(span, proposed, correction), resolved) or proposed
        if not spelling:
            continue
        # A rule mapping a word to itself is not a rule.
        if resolved.lower() == spelling.lower():
            continue
        candidate = f"{resolved} => {spelling}"
        if candidate.lower() not in {r.lower() for r in rules}:
            rules.append(candidate)
    return rules

def control_rules(correction, source):
    """The control: no model at all. Every spelling read out, snapped onto the
    nearest thing in the transcript. A model that does not beat this line is
    not earning its place — and it now has to beat it on multi-rule utterances
    too, where the letters alone carry further than they used to."""
    rules = []
    for spelling, _ in spelling_segments(correction):
        match = closest_word(spelling, source) if source else None
        if match and match.lower() != spelling.lower():
            rules.append(f"{match} => {spelling}")
    return rules

def same(got, want):
    return sorted(r.lower() for r in got) == sorted(r.lower() for r in want)

def show(rules):
    return " | ".join(rules) if rules else "NO MATCH"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("--variant", default="v22", choices=sorted(VARIANTS))
    ap.add_argument("--think", action="store_true")
    ap.add_argument("--predict", type=int, default=48)
    ap.add_argument("--num-ctx", type=int, default=None,
                    help="KV cache size; unset lets Ollama use the model's own 32k")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--cases", default="tests/spelling-cases.yaml",
                    help="path to a case file, for probing a set you do not want to ship")
    ap.add_argument("--code-only", action="store_true",
                    help="no model at all: snap the spelled word to the transcript")
    args = ap.parse_args()

    path = pathlib.Path(args.cases)
    if not path.is_absolute():
        path = ROOT / path
    cases = yaml.safe_load(path.read_text())["cases"]
    system = VARIANTS[args.variant]

    meter = {}
    if not args.code_only:
        ask(args.model, system,
            user_prompt(args.variant, "warm up", "warm up spells W A R M"),
            args.think, args.predict, args.num_ctx)

    spans_ok = app_ok = 0
    invented = missed = wrong = 0
    total_time = 0.0
    failures = []
    for case in cases:
        source, correction = str(case["source"]), str(case["correction"])
        want = rules_of(case["expect"])

        if args.code_only:
            got, dt = control_rules(correction, source), 0.0
            model_spans = [split_rule(r)[0] for r in got]
        else:
            reply, dt = ask(args.model, system,
                            user_prompt(args.variant, source, correction),
                            args.think, args.predict, args.num_ctx, meter)
            reply = decode(args.variant, reply, source)
            model_spans = [split_rule(r)[0] for r in rules_of(reply)]
            got = app_rules(reply, correction, source)
        total_time += dt

        spans_ok += same(model_spans, [split_rule(r)[0] for r in want])
        ok = same(got, want)
        app_ok += ok
        if not ok:
            # Split by cost. A miss loses one correction; an invented rule is
            # written into transcription.replacements and rewrites every
            # transcript from then on.
            if len(got) > len(want):
                invented += 1
            elif len(got) < len(want):
                missed += 1
            else:
                wrong += 1
            failures.append((source, show(got), show(want)))
        if args.verbose:
            print(f"  {'✓' if ok else '✗'} {dt:5.2f}s {show(got)[:46]!r:48} want {show(want)[:36]!r}")

    n = len(cases)
    print(f"\n{args.model}  variant={args.variant}  think={args.think}  ({path.name}, {n} cases)")
    print(f"  spans       {spans_ok}/{n} = {100*spans_ok/n:.0f}%  <- what the model must get right")
    print(f"  APP         {app_ok}/{n} = {100*app_ok/n:.0f}%  <- + the letters and interpret()'s repair")
    print(f"  {total_time/n:.2f}s avg")
    if meter.get("calls"):
        c = meter["calls"]
        print(f"  tokens      {meter['prompt_eval_count']/c:.0f} in, {meter['eval_count']/c:.0f} out per call"
              f"  |  prefill {meter['prompt_eval_duration']/c/1e9:.2f}s, generate {meter['eval_duration']/c/1e9:.2f}s")
    if invented:
        print(f"  {invented} invented a rule  <- the expensive direction")
    if wrong:
        print(f"  {wrong} wrong span or spelling")
    if missed:
        print(f"  {missed} missed")
    if failures:
        print("  failures:")
        for src, got, want in failures:
            print(f"    {src[:44]!r}\n      got  {got!r}\n      want {want!r}")

main()
