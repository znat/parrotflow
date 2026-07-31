#!/usr/bin/env python3
"""Score a prompt against tests/spelling-cases.yaml on a local Ollama model.

    scripts/validate-prompt.py gemma4:e4b
    scripts/validate-prompt.py gemma4:e4b --variant v8 --verbose
    scripts/validate-prompt.py none --code-only    # the no-model control

Prompt variants live in this file so they can be compared directly; the
winner gets copied into LocalLLM.swift.

Three numbers, because they answer different questions. "pipeline" is the
model's span plus the regex spelling. "APP" adds interpret()'s snap-to-
transcript repair, and is the only one that says what a user would see.

Scoreboard (APP). English is tests/spelling-cases.yaml, 44 cases; French is
tests/french-cases.yaml, 30 cases, where the dictated sentence is French.
Only the gemma v8/v13 rows below were re-measured after the sets grew and
spelledOutWord learned the French spelling verbs and stop words; the rest are
from the 39/25-case sets and are indicative, not comparable.

                        English  French  latency  size
    gemma4:e4b   v13       -      93%     1.5s    9.6GB  <- French prompt
    gemma4:e4b   v8       98%      -      1.5s    9.6GB  <- shipped, English
    gemma4:e4b   v4       97%      -      1.4s
    gemma4:e4b   v9       95%      -      1.5s    over-took spans
    granite4:3b  v8       92%     68%     0.3s    2.1GB  <- best small model
    granite4:3b  v4       90%      -      0.3s
    granite4:3b  v9       87%      -      0.3s
    granite4:3b  v13       -      48%     0.3s    French prompt HURTS it
    qwen3.5:0.8b v5       62%      -      0.4s    1.0GB
    (no model)            59%     48%       -     <- the control to beat
    qwen3.5:2b   v8       49%     12%     0.7s    2.7GB
    qwen3.5:0.8b v4       46%      -      0.5s
    qwen3.5:0.8b v7       36%      -      0.4s    correction-first, worse
    qwen3.5:0.8b v6        8%      -      0.4s    by word number: all NONE
    qwen3.5:0.8b v5        8%      -      5.3s    --think: 11x slower, worse

Read this way. Only gemma clears the control on French by a margin worth
paying for; qwen is far below it, so on French dictation qwen is worse than
deleting the model call. The 2b's failure is a single stubborn one, returning
the whole source sentence as the span, and no variant shifted it.

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
}

# Prompts to use per detected language, English falling back to itself. This is
# the table the plan's Phase 2 would move into LocalLLM.swift.
BY_LANGUAGE = {"en": "v8", "fr": "v13"}

# Variants whose reply is the span alone, so there is no full line to score.
SPAN_ONLY = {"v5", "v6", "v7"}
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
        return normalise(reply)
    if re.search(r"\bnone\b|\bno match\b", reply, re.I):
        return "NO MATCH"
    words = src.split()
    picked = [words[n - 1] for n in map(int, re.findall(r"\d+", reply))
              if 1 <= n <= len(words)]
    return " ".join(picked) if picked else "NO MATCH"

def ask(model, system, prompt, think, predict):
    body = {"model": model, "system": system,
            "prompt": prompt,
            "stream": False, "think": think,
            "options": {"temperature": 0, "num_predict": predict}}
    req = urllib.request.Request("http://localhost:11434/api/generate",
        data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    t = time.time()
    with urllib.request.urlopen(req, timeout=600) as r:
        d = json.load(r)
    return (d.get("response") or "").strip(), time.time() - t

def normalise(text):
    text = " ".join(text.split())
    # "I like apples => NO MATCH" is the right decision, clumsily formatted.
    if not text or re.search(r"\bno match\b|\bnone\b|\[nothing\]", text, re.I):
        return "NO MATCH"
    return text

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

def alnum_tokens(text):
    """Runs of Unicode alphanumerics, matching Swift's
    CharacterSet.alphanumerics.inverted. An ASCII-only split turned "plutôt"
    into "plut", which is how a stop word goes missing on accented input."""
    out, cur = [], []
    for ch in text:
        if ch.isalnum():
            cur.append(ch)
        elif cur:
            out.append("".join(cur))
            cur = []
    if cur:
        out.append("".join(cur))
    return out

def spelled_out(correction):
    """The spelling, taken from the text rather than the model — this is what
    LocalLLM.swift does, and it is why the model's right side does not matter.

    Mirrors LocalLLM.spelledOutWord: everything after "spells" is the spelling,
    however the recogniser chunked it. Matching only runs of single letters
    loses the tail, because recognition stops treating them as letters partway
    through — "T A S M Een" gave "Tasm" and "Tas Meen" gave nothing at all.
    """
    trigger = TRIGGER.search(correction)
    if trigger:
        letters = ""
        for token in alnum_tokens(correction[trigger.end():]):
            if letters and token.lower() in STOP_WORDS:
                break
            letters += token
        if len(letters) >= 2:
            return letters[:1].upper() + letters[1:].lower()

    # No trigger word: fall back to a run of single letters anywhere.
    m = LETTERS.search(correction)
    if not m:
        return None
    joined = re.sub(r"[^A-Za-z0-9]", "", m.group(0))
    return joined[:1].upper() + joined[1:].lower() if len(joined) >= 3 else None

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

def app_outcome(span, correction, source):
    """The rule VoiceCommand.interpret would actually add, or NO MATCH."""
    if span == "NO MATCH":
        return "NO MATCH"
    corrected = spelled_out(correction)
    if not corrected:
        return "NO MATCH"
    if source and not contains_word(span, source):
        scored = [(m, similarity(m, cand))
                  for cand in (corrected, span)
                  for m in [closest_word(cand, source)] if m]
        resolved = max(scored, key=lambda t: t[1])[0] if scored else span
    else:
        resolved = span
    # A rule mapping a word to itself is not a rule.
    if resolved.lower() == corrected.lower():
        return "NO MATCH"
    return f"{resolved} => {corrected}"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("--variant", default="v2", choices=sorted(VARIANTS))
    ap.add_argument("--think", action="store_true")
    ap.add_argument("--predict", type=int, default=24)
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

    if not args.code_only:
        ask(args.model, system,
            user_prompt(args.variant, "warm up", "warm up spells W A R M"),
            args.think, args.predict)

    passed, total_time, failures = 0, 0.0, []
    left_passed = [0]
    pipe_passed = [0]
    pipe_failures = []
    app_passed = [0]
    app_failures = []
    for case in cases:
        if args.code_only:
            # The control: what the app gets with no model in the loop, i.e.
            # the spelled word snapped onto the transcript. A model that does
            # not beat this line is not earning its place.
            got_n, dt = spelled_out(case["correction"]) or "NO MATCH", 0.0
        else:
            got, dt = ask(args.model, system,
                          user_prompt(args.variant, case["source"], case["correction"]),
                          args.think, args.predict)
            got_n = decode(args.variant, got, case["source"])
        total_time += dt
        want_n = normalise(case["expect"])
        ok = got_n.lower() == want_n.lower()
        passed += ok
        left_ok = (got_n.split("=>")[0].strip().lower()
                   == want_n.split("=>")[0].strip().lower())
        left_passed[0] += left_ok

        # The real pipeline: model picks the span, regex builds the spelling.
        if got_n == "NO MATCH":
            span = "NO MATCH"
            pipeline = "NO MATCH"
        else:
            span = got_n.split("=>")[0].strip()
            spelling = spelled_out(case["correction"])
            pipeline = f"{span} => {spelling}" if spelling else got_n
        pipe_ok = pipeline.lower() == want_n.lower()
        pipe_passed[0] += pipe_ok

        # And what the app would end up doing, repair step included. The span
        # only — interpret() never sees the model's right side.
        app = app_outcome(span, case["correction"], case["source"])
        app_ok = app.lower() == want_n.lower()
        app_passed[0] += app_ok
        if not app_ok:
            app_failures.append((case["source"], app, want_n))
        if not pipe_ok:
            pipe_failures.append((case["source"], pipeline, want_n))
        if not ok:
            failures.append((case["source"], got_n, want_n))
        if args.verbose:
            print(f"  {'✓' if ok else '✗'} {dt:5.2f}s {got_n[:44]!r:46} want {want_n[:34]!r}")

    print(f"\n{args.model}  variant={args.variant}  think={args.think}")
    n = len(cases)
    if args.variant in SPAN_ONLY:
        print(f"  full line   n/a — this variant replies with the span alone")
    else:
        print(f"  full line   {passed}/{n} = {100*passed/n:.0f}%")
    print(f"  left side   {left_passed[0]}/{n} = {100*left_passed[0]/n:.0f}%  <- what the model must get right")
    print(f"  pipeline    {pipe_passed[0]}/{n} = {100*pipe_passed[0]/n:.0f}%  <- model span + regex spelling")
    print(f"  APP         {app_passed[0]}/{n} = {100*app_passed[0]/n:.0f}%  <- + interpret()'s snap-to-transcript")
    print(f"  {total_time/n:.2f}s avg")
    if app_failures:
        print("  app failures:")
        for src, got, want in app_failures:
            print(f"    {src[:40]!r}  got {got!r}  want {want!r}")
    if failures and not args.verbose:
        print("  failures:")
        for src, got, want in failures:
            print(f"    {src[:40]!r}\n      got  {got!r}\n      want {want!r}")

main()
