# Transcription: picking a Parakeet runtime

Research notes for the step after v0.1. Nothing here is implemented yet.

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

### 1. Custom vocabulary — for names and jargon

This is the real answer to "get proper nouns right", and it's better than the
string substitution originally sketched out.

FluidAudio ships
[context biasing](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/CustomVocabulary.md):
a CTC keyword spotter scores your terms against the frame-level acoustic
evidence, then a rescorer decides whether the acoustic support for your term
beats what the decoder emitted. If you say "NVIDIA" and the model writes "in
video", the spotter finds *NVIDIA* in the audio itself and swaps it.

That's the important distinction from post-hoc substitution: a find-and-replace
on "in video" → "NVIDIA" corrupts a genuine sentence about video. Biasing looks
at the acoustics and only fires when the audio actually supports the term.

> **Measured, 2026-07-30 — context biasing did not work.** Everything below
> about how it *should* work is from FluidAudio's documentation. On a 6.3 s
> clip with a 5-term vocabulary the rescorer ran and reported `Replacements: 0`
> in every configuration tried, including one where a vocabulary term exactly
> equalled the word the model had produced. See "What actually happened" below.

Two things the docs get wrong, both verified by reading the checked-out source:

**The documented API does not exist.** FluidAudio's CustomVocabulary page shows
`asrManager.transcribe(samples, customVocabulary: vocabulary)`. No released
version has it — not 0.15.5, not `main`. The only shipped path is
`SlidingWindowAsrManager.configureVocabularyBoosting(vocabulary:ctcModels:)`,
i.e. the *streaming* manager, which pulls a second model (`CtcModels`, ~98 MB).

**Aliases are not spotter targets.** `CustomVocabularyContext.swift:291` does
`ctcTokenizer.encode(term.text)` — only `text` is tokenized and searched for
acoustically. Aliases appear in `VocabularyRescorer+Utilities` solely to widen
a string-similarity gate *after* a candidate is found. So the "spell the alias
phonetically, get the canonical spelling back" trick does not work; if `text`
isn't spelled the way the word sounds, the spotter has nothing to look for.

```swift
let manager = SlidingWindowAsrManager(config: dictationConfig)
try await manager.loadModels()
try await manager.configureVocabularyBoosting(
    vocabulary: CustomVocabularyContext(terms: [CustomVocabularyTerm(text: "Zilbershtayn")]),
    ctcModels: try await CtcModels.downloadAndLoad()
)
```

### What actually happened

One real bug found and fixed. `SlidingWindowAsrConfig.default` gates rescoring
behind `minContextForConfirmation: 10s` and a 0.85 confidence floor — so on any
clip shorter than 10 seconds the rescorer **never ran at all**. Dictation clips
are mostly shorter than that. `Transcriber.dictationConfig` drops both, and the
logs confirm the rescorer now runs (`CONFIRMED (0.929, 6.3s context)`).

It still produced zero replacements. Tried: phonetic spelling in `text`;
aliases matching the model's exact output; a term identical to the emitted
word. The CTC spotter runs, produces 79 frames of log-probs, and detects
nothing. Not pursued further.

**So `replacements` is what fixes names today** — a literal, word-boundary,
case-insensitive swap applied last. On the test clip it took

    Hi, my name is Ilbushtane... with Tasman and Mick... called Carrot Flow.

to

    Hi, my name is Zylbersztejn... with Tasmeen and Mik... called ParrotFlow.

The workflow is: dictate, run `--transcribe`, see what the model wrote, map it.
Less elegant than acoustic biasing and it can't generalise to a mispronunciation
you haven't seen — but it works, and it's honest about what it does.

Re-test biasing on each FluidAudio upgrade; if a batch API appears, try that.

FluidAudio documents 99.4% recall, no latency impact up to ~100 terms. Not
reproduced here. The YAML shape is in place either way:

```yaml
vocabulary:
  - Parakeet
  - ParrotFlow
  - Zylbersztejn
  - text: Häagen-Dazs
    aliases: [Hagen Das]
```

Caveat: biasing needs the complete log-probability matrix, so it is
weaker in streaming mode. Not a problem for us — we transcribe a finished clip.

### 2. A local LLM pass — for everything else

Free-form instructions ("strip filler words", "format as bullets", "keep it
terse") belong in a second stage that reads the finished transcript. On macOS
26+ Apple's Foundation Models framework gives a local LLM with no download and
no dependency; an MLX model is the fallback for older systems.

Worth keeping optional and off by default. It adds latency to every dictation
and can rewrite things you meant literally.

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
- [WWDC25: SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)
- [parakeet-coreml-swift](https://github.com/mweinbach/parakeet-coreml-swift)
