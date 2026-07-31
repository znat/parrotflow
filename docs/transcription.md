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

FluidAudio's acoustic context biasing was tried and removed. It is real and
their Earnings22 numbers are real — 91.7% vocabulary F-score — but it is built
for hour-long audio with hundreds of domain terms, where 15% WER is an
acceptable price for recovering jargon. A handful of terms against ordinary
speech is the opposite case, and there are vastly more non-matching words than
matching ones for it to fire on.

Measured against the recordings on disk, boosting altered **48 of 50**
transcripts containing none of its terms:

    "Hey there, my name is Nathan."   ->  "Matthieu my name is Nathan."
    "Something more something more graphic."  ->  "Supabase Tasmeen Matthieu"

Tried on the streaming path, on the batch path their own benchmark uses, with
a shared CTC/TDT encoder, and with the similarity threshold swept to 0.90 —
well past the 0.70 their comments call too conservative. Damage throughout.
Worth knowing that `rescorerConfig(forVocabSize:)` gives *small* vocabularies
the most permissive threshold, which is backwards for this use.

Substitution cannot generalise to a mishearing you have not seen, so the map
grows one entry at a time. It also cannot corrupt a transcript that was
already right, which turned out to matter more.

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

## Voice corrections

Saying "hey parrot, <name> spells T A S M E E N" adds a replacement rule. A
local model picks which word in the previous transcript was meant; the spelling
comes from the letters by regex, never from the model.

That split is deliberate and measured. Given the whole job the model returns
the right span but mangles the letters it is copying — "S I O B H A N" came
back "Sibhan". Given only the span it scores 35/35 on
`tests/spelling-cases.yaml`.

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
