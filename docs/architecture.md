# How it works

| Piece | Where | Note |
| --- | --- | --- |
| Global hotkey | `HotKeyManager.swift` | Carbon `RegisterEventHotKey` — no Accessibility permission needed, and it swallows the keystroke so it doesn't leak into the app you're typing in |
| Bare modifiers | `ModifierKey.swift` | `RegisterEventHotKey` can't express these, so they poll `CGEventSource.flagsState` for the device-dependent left/right bits — also permission-free |
| Audio capture | `Recorder.swift` | `AVAudioEngine` tap → `AVAudioConverter` → 16 kHz mono WAV |
| Transcription | `Transcriber.swift` | Parakeet TDT v3 via [FluidAudio](https://github.com/FluidInference/FluidAudio), CoreML on the Neural Engine |
| The pipeline | `Pipeline.swift` | Stages, conditions, app gating — [pipelines.md](pipelines.md) |
| Replacements | `Replacements.swift` | Literal, regex and fuzzy substitution |
| Numbers | `NumberGrammar*.swift` | Spoken numbers as digits, English and French, no model |
| Transforms | `PromptRunner.swift`, `CommandRunner.swift` | A prompt to the local model, or a program of yours on stdin/stdout |
| Routing | `Router.swift`, `FreeForm.swift` | Which transform an instruction reaches, and what happens when none does |
| Spoken commands | `LocalLLM.swift` | HTTP to a local Ollama; degrades to "unavailable" when it isn't there |
| Config | `Config.swift` | Yams + a `DispatchSource` file watcher for live reload |
| Permissions | `Permissions.swift` | `AVCaptureDevice` for mic, `AXIsProcessTrusted` for Accessibility |
| Text insertion | `TextInserter.swift`, `SelectionReader.swift` | Paste-via-clipboard, then the pasteboard is put back |
| Where the words go | `Destination.swift` | Asks the focused element whether it takes text, at the press — decides the pill's icon and whether the transcript is typed or copied |
| Menu bar & wiring | `AppDelegate.swift` | |
| Logging | `Log.swift` | `~/Library/Logs/ParrotFlow.log` — a menu bar app has no console |
| Floating surfaces | `RecordingOverlay.swift`, `PreviewPanel.swift`, `NoticeHUD.swift`, `ParrotStyle.swift` | Borderless non-activating `NSPanel`s, one look between them |
| Variants | `AppVariant.swift` | Dev and released builds are separate apps — [development.md](development.md) |

## Two wrinkles about push-to-talk

Carbon only reports the release of the *character* key. Let go of ⌃ before
Space and no release event ever arrives, so `AppDelegate` also polls
`NSEvent.modifierFlags` while recording as a backstop.

Bare modifiers are polled rather than tapped. An event tap could swallow the
keystroke, but it costs the Accessibility permission and a keystroke-monitoring
prompt — a steep price when a bare modifier types nothing on its own, so there
is nothing to swallow. Polling `CGEventSource.flagsState` every 25 ms needs no
permission at all. The trade is ~25 ms of latency and no way to stop the key
also reaching the frontmost app.

## Where the time goes

| Step | Cost |
| --- | --- |
| Hotkey down → capture running | ~60–70 ms, warmed at launch |
| Bare-modifier polling | 25 ms, on top of the above |
| Transcription of a normal sentence | about a second after you let go |
| `replacements`, `fuzzy`, `numbers`, a `replace:` transform | 0.035 s measured on a line |
| A `command:` transform | one process start — ~30 ms for `python3`, ~5 ms for a shell script |
| A `prompt:` transform, model warm | ~1.5 s |
| A `prompt:` transform, model cold | 6.7 s, which `llm.keep_loaded` exists to avoid |

The gap between the last three rows is the reason stages carry conditions: a
`when:` that costs nothing is what keeps a stage that costs a second off the
transcripts that never needed it.

### Start-up latency

`AVAudioEngine` needs a moment to open the input stream, so the first fraction
of a second after the hotkey isn't captured. Warming the engine up at launch
brings that down to roughly 60–70 ms, which a natural pause after pressing the
key covers.

Getting to zero means keeping the mic open continuously and buffering into a
ring — which also means the orange recording indicator is lit the entire time
the app runs. Not the right default for a tool whose pitch is that it doesn't
listen to you. Worth revisiting as an opt-in setting if the clipping ever
actually bites.

## What the app does not do

**It does not stream.** A clip is finished before anything looks at it, which
is what lets the whole pipeline run on a complete sentence and what lets a
stage be skipped on the text as it stands at that point.

**It does not learn anything on its own.** Every rule in your config got there
because you put it there, or confirmed a panel that proposed it.

**It ships no model weights and no inference engine.** Parakeet is fetched once
by FluidAudio; the language model is Ollama's, on localhost. Every LLM feature
degrades to "not available" rather than failing.

## See also

- [transcription.md](transcription.md) — why Parakeet rather than Whisper, why
  it cannot be prompted, and what covers that instead
- [pipelines.md](pipelines.md) — the stage model in full
- [distribution.md](distribution.md) — signing, updates, why this ships by curl
