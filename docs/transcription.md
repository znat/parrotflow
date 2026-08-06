# Transcription: picking a Parakeet runtime

Implemented in `Transcriber.swift`. Findings below are measured, not quoted.

## Can Parakeet be prompted?

**No.** Parakeet has no text input, and this is architectural rather than a
missing feature.

Whisper's decoder is an autoregressive transformer over text, so you can prefix
it with `initial_prompt` and the model conditions on those tokens. Parakeet TDT
is a Token-and-Duration Transducer: a Conformer encoder feeding a small
prediction network that only ever sees the tokens it has already emitted. There
is no slot for an instruction. Of NVIDIA's ASR family only
[Canary](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3/discussions/8)
takes text prompts.

So "transcribe this as bullet points" or "the speaker is French" cannot be
passed to the model. Two things cover what you'd actually want from a prompt:

### 1. A replacements map — for names and jargon

Rare names are fixed by literal, word-boundary, case-insensitive substitution
on the finished transcript, taught through the correction panel.

A source wrapped in slashes is a regular expression instead, and an empty
target deletes rather than substitutes. That combination is what handles
filler words, which a literal map cannot: `um` arrives as "um", "umm",
"ummm", "uh", "erm", "hmm", "mm-hmm", and each one drags punctuation along
with it.

```yaml
replacements:
  "": ['/[,]?\s*\b(?:mm[-‑]?hmm|uh[-‑]?huh|u+m+|u+h+|erm+|hmm+|mm+)\b[,]?/']
```

The punctuation in that pattern matters more than it looks. Deleting only the
word leaves "And uh, if" as "And, if"; taking the trailing comma too gives
"And if", and a filler sitting between commas loses both so the clause reads
straight through. A tidy pass then closes the remaining gaps — doubled spaces,
a space stranded before a comma, a lowercase word left starting the sentence.

Word boundaries do the rest of the work: "umbrella" and "hummingbird" contain
fillers and are left alone. Fuzzy matching skips regex and deletion rules
entirely — they are exact by construction.

A regex source can also write back what it captured. `$1` in the target refers
to the first group, and that is the only way to express a rule whose output
depends on its input:

```yaml
replacements:
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
acoustic: true
min_similarity: 0.75

terms:
  Tasmeen:                     # nothing close in this speaker's speech
  Mirza:
    floor: 0.85                # "Mira" lands at 0.80
  Praisy:
    floor: 0.90                # "praise" lands at 0.83
    heard: [Prissy, Pressy, Precy, Prezi]
  Claude:
    floor: off
    heard: [clut, cloud]
```

A term has two ways in, and most need one.

**`floor`** is how close a decoded word must sound before it is replaced, from
0 to 1. Omitted, `min_similarity` applies.

**`heard`** is a list of exact renderings. Use it for the ones no floor can
reach: "Prezi" is 0.33 from "Praisy", and a threshold that low would swallow
every "praise".

**`floor: off`** turns sound matching off for one term. Use it when the
recogniser writes the term and an ordinary word identically. Measured on one
machine: "Claude" and "cloud" both come back as `cloud`, "Matthieu" and
"Matthew" both as `Matthew`. No threshold separates them, because the
distinction is gone before anything downstream can look.

Terms shorter than five letters are dropped, as are terms with a digit or a
dot. A short term aligns to almost any run of frames. A term the decoder could
not have produced is not a term.

#### Choosing a floor

Set it just above the closest ordinary word. `scripts/calibrate.py confusables
<term> --lang en,fr` lists what is in reach:

    Praisy   praise 0.83   raise 0.67   pray 0.67     -> floor 0.90
    Redrock  bedrock 0.86  redock 0.86                -> floor 0.90
    Vercel   vessel 0.67   vertex 0.67                -> floor 0.75

Pass only the languages you dictate in. "Praisy" is 0.83 from the English
"praise" and 0.67 from the French "vrais", so the floor differs by 0.16
depending on who is speaking.

Two things to check that a word list does not tell you. `NSSpellChecker`
accepts any all-caps run as a word, so `XQZPT` looks known — ask about the
lowercase form. And a term shaped like a verb-particle pair is unsafe whatever
its neighbourhood: "turn down the volume" glues to `Turndown` at 1.00.

`floor: off` in YAML is the boolean `false`, not the string. So are `on`,
`yes` and `no`. The decoder reads both.

#### What it costs

Matching by sound downloads a ~98 MB model on first use and adds a CTC pass
per clip. `acoustic: false` skips both; the `heard` rules still apply.

Over 400 archived clips, with the shipped settings, damage — clips containing
no vocabulary term that came out different — falls with the floor:

| floor | clips damaged | terms recovered |
| --- | --- | --- |
| 0.65 | 10/386 | 5/8 |
| 0.75 | 4/386 | 3/8 |
| 0.85 | 0/386 | 2/8 |

Higher floors are safer and catch less. There is no setting that catches
everything and breaks nothing.

#### Checking the result

Neither mechanism reads the sentence, so both replace ordinary words that
resemble a term: "blocking merge" became "blocking Vercel".

`verify_names` asks a local model one question per substitution and puts back
the ones it declines. It answers YES or NO and never returns text. It runs only
when something was substituted — `when: vocabulary.count > 0` — which is about
one dictation in twenty.

Scored on `tests/judge-cases.yaml`, 58 proposals from real recordings:

| | approve | decline | overall | latency |
| --- | --- | --- | --- | --- |
| a spell-check gate, no model | 17/20 | 38/38 | 95% | 0.00s |
| gemma4:e4b | 17/20 | 36/38 | 91% | 0.88s |
| gemma4:12b | 19/20 | 35/38 | 93% | 1.88s |

The gate scores higher and cannot do the job alone. Its rule is "never replace
a real word", so it cannot fix `cloud` -> `Claude` or `Versailles` -> `Vercel`.
Those need the sentence.

Every exchange is written to `trace.jsonl` under the stage's variables, so a
verdict can be replayed rather than guessed at.

The case set is 17% short sentences; real dictation here is 36%. The numbers
above are therefore measured on inputs that favour a judge, since context is
what it uses.

A literal substitution cannot generalise to a mishearing you have not seen, so
that half of the map grows one entry at a time. It also cannot corrupt a
transcript that was already right, which turned out to matter more — and a
pattern rule gives that property up in exchange for reach, which is the trade
`app:` exists to bound.

### 3. A local LLM pass — for everything else

Free-form instructions ("format as bullets", "keep it terse") belong in a
second stage that reads the finished transcript. On macOS 26+ Apple's
Foundation Models framework gives a local LLM with no download and no
dependency. An MLX model is the fallback for older systems.

Keep it optional and off by default. It adds latency to every dictation and
can rewrite text you meant literally. Filler words are not a job for it — a
regex removes them for free.

## Runtime options

| Option | Language | Ships as | Verdict |
| --- | --- | --- | --- |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Swift | SPM package, CoreML on ANE | **Recommended** |
| [parakeet-coreml-swift](https://github.com/mweinbach/parakeet-coreml-swift) | Swift | SPM package, CoreML | Leaner, fewer features |
| [parakeet-mlx](https://github.com/senstella/parakeet-mlx) | Python | pip + MLX | Needs a Python runtime |
| [Apple SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/) | Swift | OS framework | No model to ship at all |

**parakeet-mlx is out.** It would mean bundling a Python interpreter and its
wheels into a Mac app, or making users manage a venv. That contradicts the
whole "small, lightweight, one download" goal.

**FluidAudio is the pick.** Apache 2.0, one SPM line, runs on the Neural Engine,
~190× real-time on an M4 Pro, and it already solves the vocabulary problem —
which is otherwise the hardest part of this project to do well.

Its input format is "16 kHz mono Float32", which is exactly what `Recorder.swift`
already writes. That was the point of fixing the audio format in v0.1.

```swift
let models = try await AsrModels.downloadAndLoad(version: .v3)
let asrManager = AsrManager(config: .default)
try await asrManager.configure(models: models)
let result = try await asrManager.transcribe(samples, source: .system)
```

### Apple SpeechAnalyzer deserves a look

macOS 26 added `SpeechAnalyzer` / `SpeechTranscriber` — on-device, streaming,
with models the OS downloads and manages. Reportedly ~2× faster than Whisper
Large V3 Turbo.

It is genuinely tempting: **zero model bytes to ship**, no first-run download,
no ~1 GB in the app's cache, and Apple maintains it. The costs are macOS 26+
only, less control over the model, and no equivalent of FluidAudio's acoustic
context biasing (the older `contextualStrings` is a weaker mechanism).

Worth a spike before committing to Parakeet. If quality is comparable on your
voice, it removes the single largest chunk of complexity in shipping this app.
It's also a sensible fallback on machines where the Parakeet download fails.

## Model size — the thing that shapes the install

The HuggingFace repo for v3 CoreML totals **~3.0 GB**, but that's every variant
in both `.mlpackage` and compiled `.mlmodelc` form. A working set is roughly:

| File | Size |
| --- | --- |
| MelEncoder | 595 MB |
| Encoder (fp) | 445 MB |
| Encoder (int4 alternative) | 298 MB |
| ParakeetDecoder | 37 MB |
| JointDecision | 13 MB |

So **~700 MB–1.1 GB** downloaded on first run, depending on the encoder variant.

This must not go in the app bundle — it would make a ~1 GB download for
something that is otherwise a few hundred KB, and it breaks the Homebrew route.
Download on first launch into `~/Library/Caches`, with visible progress,
a resumable transfer, and a working app (record-only) until it lands.

## Proposed order

1. Spike Apple `SpeechTranscriber` — cheapest possible path, decide on quality.
2. Wire FluidAudio behind a `transcription.engine` config key, so both can coexist.
3. Insert text into the frontmost app (needs Accessibility — see
   [distribution.md](distribution.md)).
4. Custom vocabulary from YAML.
5. Optional LLM cleanup pass, off by default.

## Sources

- [FluidAudio](https://github.com/FluidInference/FluidAudio) · [Custom Vocabulary docs](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/CustomVocabulary.md) · [Getting Started](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/GettingStarted.md)
- [parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml)
- [Can Parakeet be prompted? (NVIDIA discussion)](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3/discussions/8)
- [NeMo word boosting](https://docs.nvidia.com/nemo-framework/user-guide/latest/nemotoolkit/asr/asr_customization/word_boosting.html)
- [NeMo inverse text normalization](https://docs.nvidia.com/nemo-framework/user-guide/latest/nemotoolkit/nlp/text_normalization/wfst/wfst_text_normalization.html)
- [WWDC25: SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)
- [parakeet-coreml-swift](https://github.com/mweinbach/parakeet-coreml-swift)

## Voice corrections

Saying "hey parrot, <name> spells T A S M E E N" adds a replacement rule. A
local model picks which words in the previous transcript were meant; the
spelling comes from the letters by regex, never from the model.

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
