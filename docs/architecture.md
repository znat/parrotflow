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
| Spoken commands | `LLM.swift`, `LocalLLM.swift` | One call, three protocols — `ollama`, `openai`, `anthropic`. `ModelSpec.swift` is what a config resolves to; every failure degrades to "unavailable" rather than costing the transcript |
| Config | `Config.swift` | Yams + a `DispatchSource` file watcher for live reload |
| Permissions | `Permissions.swift` | `AVCaptureDevice` for mic, `AXIsProcessTrusted` for Accessibility |
| Text insertion | `TextInserter.swift`, `SelectionReader.swift` | Paste-via-clipboard, then the pasteboard is put back |
| Editing in place | `Surface.swift` | The field as one string plus one span, and the ladder that substitutes a range of it — [below](#editing-text-that-is-already-there) |
| Where the words go | `Destination.swift` | Asks the focused element whether it takes text, at the press — decides the pill's icon and whether the transcript is typed or copied |
| Menu bar & wiring | `AppDelegate.swift` | |
| Logging | `Log.swift` | `~/Library/Logs/ParrotFlow.log` — a menu bar app has no console |
| The record | `Trace.swift` | `trace.jsonl` beside the recordings — one line per dictation, with word timings and confidences the log cannot hold |
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

## Editing text that is already there

Dictation writes at the caret. Everything else — a correction, a transform over
a selection, a rewrite of the sentence you just said — has to change text that
is already on screen without disturbing the rest of it. That is `Surface`.

It answers two questions and nothing else. **What is in the field**, as one
string, and **what is selected**, as offsets into that same string. A caller
that knows which characters it wants changed says so; nothing searches for
anything.

    let surface = Surface.read()
    surface.content        // the whole editable text
    surface.span           // the selection, as offsets into it
    surface.replace(range, with: "Jerry")

Two kinds, because only one distinction survives contact with real apps:

| Kind | What `content` is | How it is written |
| --- | --- | --- |
| `editable` | the accessibility value itself | a range write, else a selection plus a paste, else the caret is walked to the span |
| `screen` | the input box, read back out of a terminal's picture of itself | the line is cleared and retyped whole |

A native field, a browser, an Electron composer and a webview are all
`editable`. They are not told apart in advance, because the thing that
distinguishes them cannot be read — it can only be discovered by writing and
looking. A terminal is named rather than examined, the same way `Destination`
names it.

### The three rules that keep this safe

**Nothing is trusted to have worked because it returned success.** Setting an
accessibility attribute reports `.success` in surfaces that ignore it entirely.
Every branch reads the value back and looks for the replacement *with the
characters that should surround it* — an append produces the replacement but
never the neighbourhood, which is the difference between "Jerry is on vacation"
and "Jery is on vacationJerry is on vacation".

**Nothing is written blind.** The old retype pressed ⌃A ⌃K and typed whatever
happened next, which in anything that is not a terminal cleared nothing and
appended everything. A clear that cannot be verified is now a refusal.

**A request is not an action.** Selecting a range, pasting, and killing a line
are all things you ask an app to do and it does when it is ready. Reading back
immediately measures the delay, not the write. Every check here polls — and the
one place that did not is why the caret-walking branch below exists at all.

### What each surface actually does

Measured with `--peek` and `--span-test`, not assumed:

- **A native field** takes the range write, the first and cheapest branch.
- **Chromium** — so Slack, the new Outlook, and every browser — accepts
  `AXSelectedTextRange`, returns `.success`, and applies it *a beat later*. Read
  immediately it reports the caret exactly where it was, which is
  indistinguishable from refusing. Polling for half a second is the whole fix.
  It reports `""` for the selected text of a contenteditable however the
  selection was made, so the range it echoes back is the evidence, not the text.
- **A terminal** — Terminal.app, Ghostty and iTerm all behave the same way —
  refuses everything but keystrokes, so the line is cleared and retyped, and the
  clear is checked between presses because ⌃K kills to the end of a *visual* row
  and a wrapped line takes several. The full case set scores 8/8 in each of the
  three.
- **Ghostty hands back the window for a moment after it comes forward**, and its
  text view only once focus has landed. Peeked in that gap it reports no value
  at all, which reads exactly like a terminal that publishes nothing — it was
  misread that way here, and written up as an app that could not be edited
  before the harness was pointed at it and scored 6/8 rather than 0. The two
  failures were empty reads, not bad writes. Retrying the read for 0.6 s makes
  it 8/8. Nothing about Ghostty needed working around; the read simply had to
  wait, which is the same lesson as every poll in this file.

The caret-walking branch is the last resort for an `editable` that will not move
its selection on request: the caret is stepped to the span with arrow keys and
the span selected with ⇧←, checking the app's own reported range at every step.
Arrow keys change no text, so everything up to the paste is free to fail.

### When it goes wrong anyway

A paste that lands somewhere unintended is undone with ⌘Z — the app's own edit
history, which is the one mechanism guaranteed to work in a surface that has
just proved it does not honour accessibility writes. Only when the value
actually changed: if the paste landed nowhere, ⌘Z would undo whatever the person
did before we arrived.

And every substitution leaves an undo record, which is what `"hey parrot, undo"`
puts back. It compares what is on screen against what it wrote and refuses if
the text has moved on, because an undo fired against edited text is not an undo.

## Where the time goes

| Step | Cost |
| --- | --- |
| Hotkey down → capture running | ~60–70 ms, warmed at launch |
| Bare-modifier polling | 25 ms, on top of the above |
| Transcription of a normal sentence | about a second after you let go |
| `the vocabulary stage`, `fuzzy`, `numbers`, a `replace:` transform | 0.035 s measured on a line |
| A `command:` transform | one process start — ~25 ms for `python3`, ~5 ms for a shell script, ~300 ms if `python3` is a version-manager shim |
| A `prompt:` transform, model warm | ~1.5 s |
| A `prompt:` transform, model cold | 6.7 s, which `keep_loaded:` on the model exists to avoid |

The gap between the last three rows is the reason stages carry conditions: a
`when:` that costs nothing is what keeps a stage that costs a second off the
transcripts that never needed it.

### The version-manager shim

`python3` on a Mac with pyenv, asdf or mise is not the interpreter. It is a
shell script that re-execs through the manager, on every call. Measured on one
Mac with pyenv:

| Command | Through the shim | Through the real interpreter |
| --- | --- | --- |
| `python3 -c pass` | 301 ms | 20 ms |
| `repetitions.py` | 308 ms | 25 ms |

Three Python transforms in a pipeline was about 0.9 s of launcher on every
dictation. That is more than a warm `prompt:` stage costs, and a `command:`
stage usually has no `when:` in front of it.

`CommandRunner` asks the interpreter for `sys.executable` once per run of the
app, then puts that directory in front of `PATH` for every command it starts.
The same `sh -c exec` shape then costs 41 ms. It changes `PATH` rather than the
command, so scripts keep their `#!/usr/bin/env python3` line and still run by
hand.

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

- [transcription.md](transcription.md) — the speech model, its limits, and the
  stages that cover them
- [pipelines.md](pipelines.md) — the stage model in full
- [distribution.md](distribution.md) — signing, updates, and the install
