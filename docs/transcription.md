# Transcription

The speech model is Parakeet, run by FluidAudio on the Neural Engine.
`Transcriber.swift` implements it.

## The model takes no instructions

Parakeet has no text input. You cannot tell it "the speaker is French" or
"write this as bullet points". Two things do that work instead, both on the
finished transcript.

### 1. A replacements map — for patterns and deletions

Literal, word-boundary, case-insensitive substitution on the finished
transcript, written by hand in `config.yaml`. A name the recogniser mangles
does not belong here — that is what the vocabulary below is for.

A source wrapped in slashes is a regular expression instead, and an empty
target deletes rather than substitutes. That combination is what handles
filler words, which a literal map cannot: `um` arrives as "um", "umm",
"ummm", "uh", "erm", "hmm", "mm-hmm", and each one drags punctuation along
with it.

```yaml
transforms:
  - name: fillers
    description: delete hesitation sounds
    replace:
      "": ['/[,]?\s*\b(?:mm[-‑]?hmm|uh[-‑]?huh|u+m+|u+h+|erm+|hmm+|mm+)\b[,]?/']
```

The punctuation in that pattern matters more than it looks. Deleting only the
word leaves "And uh, if" as "And, if"; taking the trailing comma too gives
"And if", and a filler sitting between commas loses both so the clause reads
straight through. A tidy pass then closes the remaining gaps — doubled spaces,
a space stranded before a comma, a lowercase word left starting the sentence.

Word boundaries do the rest of the work: "umbrella" and "hummingbird" contain
fillers and are left alone. Near-miss matching in the `vocabulary` stage never
sees these at all — it reads `vocabulary.yaml`, and a pattern is not a spelling
anything could sound like.

A regex source can also write back what it captured. `$1` in the target refers
to the first group, and that is the only way to express a rule whose output
depends on its input:

```yaml
    replace:
      $1.$2: ['/\b(\w+) dot (\w+)\b/']    # "user dot name" -> user.name
```

The slashes switch the target into a template the same way they switch the
source into a pattern. A **literal** source keeps a literal target: a name is a
word you want written exactly, so `$` in one survives and "AT$T" comes out as
typed. That escaping is why a template needs the regex form to be reachable at
all.

A template naming a group its pattern never captures is refused by
`--check-config` and by `--pipeline`, rather than being written as nothing —
the rule would fire, the output would be quietly short, and the log would show
a substitution that looked like it worked.

A rule like this generalises, which is the thing the map otherwise cannot do.
It cuts both ways: `\b(\w+) dot (\w+)\b` joins any two words either side of
"dot", ordinary prose included, and no pattern tells "user dot name" from "the
word dot on" — they are the same sentence to a regex. Scope it to where you
mean it with `app:`, which is in docs/pipelines.md.

### 2. A vocabulary — for words the recogniser gets wrong

Names, brands, jargon, acronyms. Anything you say that the model was not
trained on. A term is matched by sound, so one entry covers renderings you
have never written down.

It lives in `vocabulary.yaml` beside `config.yaml`. The two files have
different owners: you write the config, the app writes the vocabulary — from
corrections, from `--learn`, from the calibrate skill.

```yaml
sound_below: 0.85

terms:
  Tasmeen:                     # nothing close in this speaker's speech
  Praisy:
    pronunciations:
      - heard: Prissy
        seen: 6
        from: mined
      - heard: Preci
        phonemes: pɹɛsi        # espeak reads the spelling "pre-sigh"
        from: correction
  Claude:
    floor: off
    kind: person
    pronunciations:
      - heard: cloud
        from: correction
```

#### The number

**`sound_below`** is how close a run of words must *sound* to a term before the
place is offered at all, from 0 to 1, where 1.0 is the term said exactly. It is
the only threshold the vocabulary has.

`acoustic:`, `offer_below:`, `min_similarity:`, `decide_above:` and a per-term
`floor:` *number* are read and do nothing. They belonged to a search of the
audio itself, on a second 98 MB model, that never worked well enough to switch
on and is gone. They still load so that a file nobody edits by hand does not
stop working, and `--check-config` names each one it finds. `floor: off` is
unaffected: it still means never matched by sound.

It is the one thing spelling cannot do. `geler` is 0.60 from `Gelar` by letters
and identical to it by sound. So are `Ghost E` and `Ghostty`, `cloth code` and
`Claude Code`, `eye brands` and `Ibrance`, `parrot flow` and `ParrotFlow`. A
sound has no spaces in it, so a word boundary the recogniser invented costs
nothing here.

Unlike the two above, this one **was** measured — on 20891 real dictations,
every 1- and 2-word window against every term and every rendering:

| `sound_below` | proposals | per dictation |
| --- | --- | --- |
| 0.70 | 11659 | 0.56 |
| 0.75 | 8262 | 0.40 |
| 0.80 | 826 | 0.04 |
| 0.85 | 147 | 0.007 |

At 0.85 the whole archive holds 41 distinct windows and most are a name that
was lost. Below it the list fills with `praise`, which sounds like `Praisy`
because it is a homophone — that is not a floor's to settle, and the sentence
settles it instead. Nothing is written by sound alone; every match is one more
reading the model votes on.

#### Two ears, and one is optional

Two converters turn a word into sounds, and they are not a replacement for each
other. Measured on 20891 real dictations at `sound_below: 0.85`, scoring every
1- and 2-word window:

| converter | windows found | right | wrong |
| --- | ---: | ---: | ---: |
| espeak-ng | 41 | 36 | 5 |
| the sound model | 46 | 39 | 7 |
| both | 62 | 54 | 8 |

Three false windows more over the whole archive, eighteen true ones. They fail
differently too, which is the strongest sign they belong together: the model
invents `praising → Praisy`, espeak invents `and re → Andrey`, and neither
makes the other's mistake.

What each finds alone says why. The model reads the whole string at once, so it
hears through a word boundary the recogniser invented — `Priss y` (259 times),
`O lama`, `au lama`, `press a`, `versol`. espeak applies letter-to-sound rules,
so it is better on a spelling nobody has ever written — `geler` (45 times),
`Prazi`, `Ghost E`, `Jemma`, `cloth code`.

**The model is the default.** 81 MB, fetched on the first English dictation
with a vocabulary in it, like every other model. Nine languages, French
included. Nothing has to be installed by hand.

**espeak-ng is the improvement.** It is a separate GPL-3 program, so it can
never ship inside the app, and it is not bundled:

    brew install espeak-ng

With the model in place its absence costs coverage rather than the whole
feature. Every proposal names both ears in the log, so which one earned it
stays countable:

    vocabulary sound: "geler" -> Gelar 1.00 by espeak
                      espeak /dʒɛlɚ/ 1.00 Gelar  model /ɡiɫɝ/ 0.75 Gelar

A window's reading is only ever compared with a form's reading **from the same
ear**. The two inventories differ — `ɫ` against `l`, `ɝ` against `ɚ` — so the
better of the two scores wins, and the average of two incomparable numbers
would mean nothing. A pronunciation written by hand under `phonemes:` is
compared against both.

#### A pronunciation can carry its sound

`phonemes:` on a rendering is IPA, and it makes the entry a class of sounds
rather than one spelling. `Silverstein` as a string reaches only
`Silverstein`; as a sound it also reaches `Silberstein`, which this recogniser
writes and nobody wrote down.

Write it when the spelling misleads. espeak sounds out `Preci` as
/pɹɛsaɪ/ — "pre-sigh" — so that entry reaches nothing until the sound is
written down. Left out, the sound is worked out from the spelling, which is
right whenever the spelling is a word.

#### Per term

**`kind`** is what the term names: `person`, `place`, `organization` or `word`.
The correction panel writes it, proposing a value from the macOS word tagger.
Nothing reads it yet. It is here so the stages that will need it have something
to read, the way `seen` and `from` were added to a pronunciation before anything
counted them. A term written before the key existed has no `kind`, and that is
not the same as `word`.

**`pronunciations`** is the ways this term actually comes out of the
recogniser. Each entry does two jobs. It is an exact rule, which is what
reaches the renderings no number can: "Prezi" is 0.33 from "Praisy", and a
threshold that low would swallow every "praise". And its *sound* is registered
with the CTC keyword spotter under the term's name, so the audio search looks
for the rendering and reports the term. That is the only path that reaches a
deep miss: "Versailles" is 0.40 from `Vercel`, and searching for the sound of
"Versailles" finds the term at −2.28 where searching for the sound of "Vercel"
manages −5.28.

A rule alone cannot tell two things apart that are spelled the same. "deployed
on Vercel against the Versailles castle" has both, and the rule rewrites both.
The pronunciation fires where the audio agrees, which separates them by about a
nat on that clip.

Per entry:

| | |
| --- | --- |
| `heard` | the spelling. The only required field. |
| `seen` | how many times it has turned up. 0 means never counted. |
| `from` | `correction`, `mined` or `calibration`. Absent means unknown. |
| `note` | a line for a person. Never parsed. |

Nothing mechanical reads `seen` or `from` yet — they are what a per-term cap
and a prune rule will decide on, and a count that starts being kept the day it
is first needed starts at zero.

A pronunciation is only searched for by sound when its term is: a rendering is
registered under the *term's* name, so one attached to a term the pass does not
look for would report a finding nothing downstream can price. Those are still
rules, and `--check-config` counts them separately.

**`floor: off`** turns sound matching off for one term. Use it when the
recogniser writes the term and an ordinary word identically. Measured on one
machine: "Claude" and "cloud" both come back as `cloud`, "Matthieu" and
"Matthew" both as `Matthew`. No threshold separates them, because the
distinction is gone before anything downstream can look.

It turns the whole term off, its pronunciations included. Those stay exact
rules and stop being search targets — a rendering is registered under the
term's name, and a term switched off has no entry for the spotter to report.
That is the right reading rather than a limitation: a term is usually
`floor: off` because it *sounds* like the ordinary word, and the audio
separates them no better than the spelling does.

`floor: off` in YAML is the boolean `false`, not the string. So are `on`,
`yes` and `no`. The decoder reads both.

Terms shorter than five letters are dropped, as are terms with a digit or a
dot. A short term aligns to almost any run of frames. A term the decoder could
not have produced is not a term.

#### Files written before the two numbers

They still load and still behave. `--check-config` says what was read.

| written | read as |
| --- | --- |
| `min_similarity: 0.75` | `offer_below: 0.75` |
| `floor: 0.85` on a term | that term's `offer_below` |
| `floor: off`, `floor: no` | unchanged — never matched by sound |
| `heard: [Prissy, Pressy]` | `pronunciations:`, each `from: legacy` |

A number under `floor:` is legacy: it now only decides what is offered, and the
setting is `offer_below:` at the top of the file. `floor: off` is not legacy.
It is a switch rather than a threshold, and the two file-level numbers do not
replace it.

#### What is in reach of a term

`scripts/calibrate.py confusables <term> --lang en,fr` lists the ordinary words
a term can be confused with:

    Praisy   praise 0.83   raise 0.67   pray 0.67
    Redrock  bedrock 0.86  redock 0.86
    Vercel   vessel 0.67   vertex 0.67

Pass only the languages you dictate in. "Praisy" is 0.83 from the English
"praise" and 0.67 from the French "vrais", so the neighbourhood differs by 0.16
depending on who is speaking. Under `offer_below` a close neighbour is no
longer a word that gets overwritten — it is one more place the gates settle,
and the sentence decides.

Two things to check that a word list does not tell you. `NSSpellChecker`
accepts any all-caps run as a word, so `XQZPT` looks known — ask about the
lowercase form. And a term shaped like a verb-particle pair is unsafe whatever
its neighbourhood: "turn down the volume" glues to `Turndown` at 1.00.

#### What it costs

Matching by sound downloads a ~98 MB model on first use and adds a CTC pass
per clip. `acoustic: false` skips both; the pronunciation rules still apply,
as rules.

Over 400 archived clips, damage — clips containing no vocabulary term that came
out different — falls as the similarity rises:

| similarity | clips damaged | terms recovered |
| --- | --- | --- |
| 0.65 | 10/386 | 5/8 |
| 0.75 | 4/386 | 3/8 |
| 0.85 | 0/386 | 2/8 |

Measured on the pass that substituted. There was no setting that caught
everything and broke nothing, which is the finding that split one number into
two: a damaged clip at 0.65 is now a question, not a rewritten word.

#### `voice/` — what this machine has heard you say

The vocabulary says which words matter. `voice/`, beside `config.yaml`, says
how they actually come out of your mouth on your microphone.

```
voice/observations.jsonl      one line per rendering seen
voice/calibration.yaml        the bands the calibrate skill measured
voice/samples/<Term>/*.wav    the audio of each rendering, cut out
```

Three reasons it is not in `vocabulary.yaml`. It grows without limit, and a
setting a person reads should not. It is audio, which no YAML file wants. And
it is one person's voice saying their colleagues' names — it stays on the
machine, and `scripts/check-no-voice.sh` refuses a repository that carries any
of it.

The microphone is part of an observation. A rendering is a fact about a mouth
*and* a capture chain, so `mic` is recorded per line; absent means unknown
rather than "the one plugged in today". Samples are cut spans, a few hundred KB
each, never a whole dictation.

`--forget <term>` empties all three for one name — see
[the command line](cli.md#forgetting-what-a-name-sounds-like).

#### Checking the result

Neither mechanism reads the sentence, so both replace ordinary words that
resemble a term: "blocking merge" became "blocking Vercel".

So the pass no longer substitutes what it is unsure about. It proposes, and the
`vocabulary:` stage decides — see [The name
stage](pipelines.md#the-name-stage). It runs only when something was found —
`when: vocabulary.count > 0`.

**There used to be a model here.** Every place the free rules left open went to
a local model, one KEEP or REVERT each. It worked. Scored on 74 substitutions
from one speaker's own dictation, `--runs 3`, zero flips:

| | all | name was said | name was not |
| --- | --- | --- | --- |
| one KEEP or REVERT per change | 63/74 | 21/22 | 42/52 |
| the retired lettered menu | 29/74 | 18/22 | 11/52 |
| the stage switched off | 22/74 | 22/22 | 0/52 |
| the vocabulary rules switched off | 52/74 | 0/22 | 52/52 |

The two bottom rows are the blind controls, and they are the point: a mechanism
that does not beat its own blind version has not been shown to work. On
`tests/judge-cases.yaml` it scored 46 of 50, where reverting every substitution
scores 33 of 50.

It is gone. It cost about 900 ms a dictation and an Ollama on the machine, and
what is left below covers what it covered: two word lists, the slot's part of
speech, and the two tests that read the sentence. **Everything they leave open
keeps what arrived** — a rule substitution keeps the term the rule wrote, a
near miss or a sound match keeps the word that was heard.

A word-list gate cannot do this job alone. Its rule is "never replace a word
somebody has already written", so it cannot fix `cloud` -> `Claude` or
`Versailles` -> `Vercel`. Those need the sentence.

**What the word lists settle.** Some substitutions need nothing else — the
sound already agrees, and nobody wants a question about `Versal` -> `Vercel`.
Two word lists decide that, and both have to say they have never seen the
decoded word:

| list | knows | misses |
| --- | --- | --- |
| `NSSpellChecker`, `en` then `fr` | `subtask`, `repo`, `rebase`, `Mathieu` | ordinary first names — `Sarah`, `Nathan`, `Frederick` |
| `data/wordpiece.txt` | those first names | jargon — `subtask`, `repo`, `rebase` |

Each list has the other's blind spot, which is the whole reason there are two.
The dictionary alone rewrote "Um not Peter, uh Frederick." to "…uh Redrock."
without asking, because no dictionary has `Frederick` in it. `data/wordpiece.txt`
is the whole-word half of `distilbert-base-uncased`'s tokenizer vocabulary
(Apache-2.0, 23694 entries): a tokenizer keeps a word whole when it has seen it
often and chops the rest into fragments, so membership is a frequency fact and
not a lexicographer's. No model runs — the test is a set lookup, and the query
is folded so `Chloé` is looked up as `chloe`.

Some words are missed by both and still auto-apply: `webhook`, `worktree`,
`kubernetes`, and the first names `Priya` and `Siobhan`. Two lists remove most
of that class, not all of it.

One condition is not a list. Both lists are asked about letters, so `Mirza's`
is looked up as `Mirzas` — a form neither has seen, where `Mirza` itself is
known to one of them. So a `'s` the heard text carries and the term does not
is refused before the lists are asked, and the place is left open.
Dropping a possessive changes what the sentence says — "Mirza's thoughts" is
not "Mirza thoughts" — and only something that reads the sentence can decide
it. The other direction is untouched: `Matthew at` -> `Matthieu's` is a term
carrying a possessive the decoded span does not, and that correction is right.

If the list cannot be read the gate stops auto-applying entirely and leaves
every place open. `--word-gate <word>` prints both verdicts and the
decision, and `--word-gate <word> <term>` prints the possessive verdict and the
decision for that pair; `scripts/check-word-gate.sh` scores them.

**What the lists cannot settle, the sentence model can.** The word lists are
about one word. A second tier reads the slot the word sits in, using the
masked language model `SentenceModel` already fetches. Mask the word, take the
ten most likely fillers, put each one back and tag it: the modal tag is what
the slot wants. A name goes in a `Noun`, `Adjective` or `Pronoun` slot and
never in a `Verb`, `Adverb` or `Preposition` one, so `merge` -> `Vercel` and
`ready` -> `Arexvy` are refused. This tier only refuses. It never writes a
term, and everything it does not refuse it leaves open, `Determiner` slots
included: those are modifier positions and names do sit in them (`cloud code`,
`bedrock principles`).

Measured over the 50 English cases of `tests/judge-cases.yaml`: 13 written by
the word lists, 14 refused by the slot, 23 left open, and no error either way.
`scripts/check-slot-gate.sh` is the run. See `SlotGate`. The route label for
"left open" is still `judge`, from when a model answered those.

The model is never waited for. Until it is on disk — and on a language it was
not trained for — every place this tier would judge is simply left open, which
is the behaviour before this tier.

What the stage decided is written to `trace.jsonl` under its variables, so a
decision can be replayed rather than guessed at.

A literal substitution cannot generalise to a mishearing you have not seen, so
that half of the map grows one entry at a time. It also cannot corrupt a transcript that was already
right. A pattern rule gives that property up for reach, and `app:` bounds the
trade.

### 3. A local LLM pass — for everything else

Free-form instructions ("format as bullets", "keep it terse") belong in a
second stage that reads the finished transcript. On macOS 26+ Apple's
Foundation Models framework gives a local LLM with no download and no
dependency. An MLX model is the fallback for older systems.

Keep it optional and off by default. It adds latency to every dictation and
can rewrite text you meant literally. Filler words are not a job for it — a
regex removes them for free.

## A pause is not a full stop

Stop for breath mid-sentence and the transcriber writes a period, then
capitalises the next word. One sentence becomes two:

```
said     "you should see a parrot at the top right of your screen"
written  "You should see a parrot. At the top right of your screen."
```

After the vocabulary pass, every `word. Capital` boundary in an English
transcript is scored by the same masked language model the slot gate uses:
`score = log P(".") − log P(" <next word>")` at one masked position, ±12
words. Two thresholds decide, both under `transcription.sentences`:

| score | what happens |
|---|---|
| below `join_below`, default −4 | the period is removed and nothing is said |
| below `offer_below`, default −2 | the join is offered, not written |
| above it | left alone |

Measured over 194 real periods and 130 synthetic cuts of one speaker's
dictation, −4 repaired 32% of the cuts and joined no real period; −2 repaired
55% and joined 1.2 per 100. A silent rewrite that is wrong costs the words
themselves, so the writing tier sits where nothing was joined by mistake.

Joining removes the period and lowercases the word after it. Not every capital
there is because of the period: "I will ask him. Nathan knows the answer" must
not become "ask him nathan knows". So the rule asks for a reason to lowercase.
`I` and its contractions keep the capital, so does a word in capitals
throughout, so does a `PersonalName`, `PlaceName` or `OrganizationName` from
`NLTagger`, and so does a word `NLTagger` gives no lemma for — the lexicon has
never seen it, which is what a name it has not been told about looks like. A
term in your `vocabulary.yaml` is asked first, because a name that is also an
English word is the one case the lemma rule cannot see.

English only. The model is English-only, and the same probe measured on
`cservan/french-modernbert-large` and `-base` scores near chance. Nothing is
waited for: with no cached model, a probe that throws or a boundary it cannot
read, the text arrives as it was.

`scripts/check-sentence-join.sh` scores the two tiers and needs the model.
`scripts/check-sentence-case.sh` scores the lowercasing and needs none, so it
runs in CI. See `SentenceJoin`.

## Voice corrections

Saying "hey parrot, <name> spells T A S M E E N" adds a pronunciation to
`vocabulary.yaml`. A local model picks which words in the previous transcript
were meant; the spelling comes from the letters by regex, never from the
model.

That split is deliberate and measured. Given the whole job the model returns
the right span but mangles the letters it is copying — "S I O B H A N" came
back "Sibhan". Given only the span it scores 35/35 on
`tests/spelling-cases.yaml`.

Two shapes were added later and both stayed on the same side of that split.
A speaker can describe the change rather than spell it ("Mathieu ne prend
qu'un seul t", "Jerome with a G at the beginning"), and `describedEdit`
applies it in code: gemma4:e4b scored 5/10 writing those names itself and
gemma4:12b 8/10, against 10/10 when the model only names the span. And one
utterance can carry two corrections joined by "and" or "et", which the panel
opens as two rows. End to end, English went from 71% to 89% and French from
89% to 96% on the extended sets.

`scripts/validate-prompt.py <model>` reruns that set in about a minute, and
`.claude/skills/prompt-iteration/SKILL.md` documents how the prompt was
arrived at, including the version that scored worse.

Two settings matter more than the prompt:

- `think: false`. gemma4 models reason by default and spent ~1000 tokens on a
  one-line answer: 98s with it on, 4.5s off.
- `num_predict: 32`. A mapping line cannot need more, and it bounds any
  rambling.

`gemma4:e4b` at 8B matches `gemma4:12b` on this set at half the latency, since
output tokens dominate rather than parameter count.

## Numbers

Parakeet writes numbers as words — "two hundred forty-three" — because inverse
text normalisation is a separate stage in NeMo, not part of the acoustic model.
Something has to run it.

**FluidAudio's `TextNormalizer` is not that something.** It looks like an exact
fit, and its documented examples are precisely the cases wanted here. But the
Swift type is a `dlopen`/`dlsym` shim over a native NeMo library, and the SPM
package does not ship the library. `--normalize` reports what that means:

    native library: NOT LINKED — normalize() is a no-op
    custom rules:   0
      · two hundred
      · five dollars and fifty cents

All ten samples pass through untouched, and would do so silently — a rule that
did not match and a library that is not there look identical from the outside,
which is the reason that command prints the linkage rather than assuming it.
Getting the real thing means vendoring and notarising a native blob for one
pass. Not worth it.

`Numbers.swift` does it instead: no model, no library, a linear scan measured in
microseconds against the seconds an LLM pass would cost. It is off unless
`transcription.numbers` asks for it — alone among these passes it rewrites
transcripts that were already correct, and whether "chapter three" wants a 3 is
a question of house style rather than of accuracy. About seventy words
build every number in English, so it parses a grammar over that vocabulary
rather than enumerating results — a substitution table cannot work when "forty"
means 40 in "forty-three" and 40,000 in "forty thousand".

| | | |
| --- | --- | --- |
| Cardinals | `two hundred and forty-three` | `243` |
| Ordinals | `the twenty third of June` | `the 23rd of June` |
| Decimals | `three point one four` | `3.14` |
| Years | `nineteen eighty-four` | `1984` |
| Spoken digits | `five five five one two three four` | `5551234` |

Under ten a lone number word stays a word, which is both ordinary prose style
and what keeps "one" the pronoun and "a" the article out of reach. Compounds
convert at any size.

### What the guards are for

Addition is the easy half; knowing where a number *ends* is the hard half. A
plain accumulator sums whatever it is handed, so "meet at ten fifteen" comes out
as 25 — wrong in the worst way, because it looks like a number someone said.
Every transition is checked instead, and anything invalid ends the number rather
than folding into it. Two more guards came out of testing:

- **A year is a standalone pair, never a slice of a longer one.** "ten fifteen
  twenty" briefly produced `10 1520`, the year rule having matched the middle
  two of three.
- **Numbers left side by side are left as words.** If the parser could not read
  them as one number they are a time, a ratio or a hesitation — "eleven thirty",
  "sixty forty split", "nine eleven" — and writing them separately gives `11 30`
  and `nine 11`, which nobody would type. Refusing to guess is the only option
  that cannot make a transcript that was already right worse.

The leading group of a year is held to 13–20, covering 1300–2099. That is every
year anyone dictates, and stopping short of ten, eleven and twelve is what keeps
a clock time from becoming one.

`--numbers` runs the set these rules were written against — one line per rule,
one per guard — and `--numbers "<text>"` runs a single line. Both run the pass
whatever the setting says, and print the setting first, so what it *would* do
can be read before it is turned on.
