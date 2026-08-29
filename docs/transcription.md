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
acoustic: false            # the default
offer_below: 0.50
decide_above: 3.0

terms:
  Tasmeen:                     # nothing close in this speaker's speech
  Praisy:
    pronunciations:
      - heard: Prissy
        seen: 6
        from: mined
      - heard: Pressy
        seen: 4
        from: mined
  Claude:
    floor: off
    kind: person
    pronunciations:
      - heard: cloud
        from: correction
```

#### The two numbers

What a spelling makes worth looking at, and what the audio can veto, are two
different questions. Each has its own number.

**`offer_below`** is how far a decoded word's spelling may sit from a term and
still be put to the judge, from 0 to 1, where 1.0 is the term written out
exactly. It decides what is looked at, not what is written. Being offered costs
one more change the model answers about; being missed cannot be recovered
downstream at any price, so it is set low.

**`decide_above`** is how hard the audio has to argue against a reading, in
nats, before the reading is dropped rather than offered. Raw scores: the
rescorer's own margin carries the vocabulary bonus, and a term can win a span
its sound lost badly — `Redcrawl` beat "general" by 0.57 boosted and lost by
5.28 raw.

Both ship untuned at the values above. They are the mechanism, not a
measurement.

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
longer a word that gets overwritten — it is one more change the judge answers
about, and the sentence decides.

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
judge](pipelines.md#the-name-judge). The stage shows the local model the
sentence the recogniser wrote, the same sentence after the pass, and what
changed, and takes one KEEP or REVERT per change; the model never writes the
transcript. It runs only when something was found —
`when: vocabulary.count > 0`.

**How often is not four percent.** Counting the first trace entry per clip, of
the 190 live dictations whose pipeline had a `vocabulary` stage at all, the
judge was asked on 77 — 41%. The 4% figure that was here divided by every live
clip, and most of those predate the stage.

Scored on 74 substitutions from one speaker's own dictation, `--runs 3`, zero
flips:

| | all | name was said | name was not |
| --- | --- | --- | --- |
| one KEEP or REVERT per change | 63/74 | 21/22 | 42/52 |
| the retired lettered menu | 29/74 | 18/22 | 11/52 |
| the stage switched off | 22/74 | 22/22 | 0/52 |
| the vocabulary rules switched off | 52/74 | 0/22 | 52/52 |

The two bottom rows are the blind controls, and they are the point: a mechanism
that does not beat its own blind version has not been shown to work.

A word-list gate cannot do this job alone. Its rule is "never replace a word
somebody has already written", so it cannot fix `cloud` -> `Claude` or
`Versailles` -> `Vercel`. Those need the sentence.

**Which words the gate lets through, then.** A few substitutions never reach
the judge — the sound already agrees, and nobody wants a question about
`Versal` -> `Vercel`. That is decided by two word lists, and both have to say
they have never seen the decoded word:

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
is refused before the lists are asked, and the proposal goes to the judge.
Dropping a possessive changes what the sentence says — "Mirza's thoughts" is
not "Mirza thoughts" — and only something that reads the sentence can decide
it. The other direction is untouched: `Matthew at` -> `Matthieu's` is a term
carrying a possessive the decoded span does not, and that correction is right.

If the list cannot be read the gate stops auto-applying entirely and every
proposal goes to the judge. `--word-gate <word>` prints both verdicts and the
decision, and `--word-gate <word> <term>` prints the possessive verdict and the
decision for that pair; `scripts/check-word-gate.sh` scores them.

Every exchange is written to `trace.jsonl` under the stage's variables, so a
verdict can be replayed rather than guessed at.

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
