# ParrotFlow

A local dictation tool for macOS. Press a hotkey, talk, get text — with nothing
leaving your machine.

This is **v0.1: the plumbing**. It handles the parts that are annoying to get
right — microphone permission, a global hotkey that works from any app, and
clean 16 kHz mono audio — and stops there. Transcription (Parakeet) and the
cleanup layer on top of it come next.

**What works today**

- Menu bar app, no Dock icon
- Global hotkey, configurable in YAML — a bare modifier like Right ⌥, or a
  combo like ⌃⌥Space — in either **toggle** or **push-to-talk** mode
- Microphone permission handled properly (with a status window so you can see where you stand)
- Records to 16 kHz mono WAV — exactly what Parakeet wants
- Floating pill with a level meter so you know the mic is hot
- Config reloads on save; no restart to try a different key

## Build & run

Requires Xcode command line tools. No Xcode project, no signing account.

```sh
make run
```

That builds `.build/ParrotFlow.app` and launches it. A 🎙 appears in your menu
bar. macOS will ask for microphone access on first launch — say yes.

```sh
make install   # copy to /Applications
make stop      # quit it
make logs      # tail its output
```

## Using it

Default hotkey is **Right ⌥**: hold it, talk, let go. Recordings land in
`~/Recordings/ParrotFlow`.

The menu bar item shows the current state and gives you *Open Recordings
Folder*, *Edit Config…*, and *Settings & Permissions…*.

## Configuration

`~/.config/parrotflow/config.yaml`, created on first launch. Save the file and
the app picks it up immediately — no restart.

```yaml
hotkey:
  key: right_option     # a bare modifier, or a character key + modifiers
  modifiers: []         # required for a character key, ignored for a modifier
  mode: push_to_talk    # or toggle

audio:
  sample_rate: 16000    # Parakeet wants 16 kHz mono; leave it
  output_dir: ~/Recordings/ParrotFlow
  min_duration_seconds: 0.3

feedback:
  sound: true
  overlay: true
```

**Bare modifiers**, used alone: `right_option`, `left_option`,
`right_command`, `left_command`, `right_control`, `left_control`,
`right_shift`, `left_shift`, `fn`. `modifiers` is ignored for these.

**Character keys:** `a`–`z`, `0`–`9`, `f1`–`f20`, `space`, `return`, `tab`,
`escape`, `delete`, arrows, `home`, `end`, `pageup`, `pagedown`, and
punctuation (`comma`, `period`, `slash`, `semicolon`, `quote`, `backslash`,
`leftbracket`, `rightbracket`, `minus`, `equal`, `grave`). These need at least
one modifier from `command`, `control`, `option`, `shift` (aliases `cmd`,
`ctrl`, `alt`, `opt`) — macOS won't hand out a bare character key system-wide.

If a combo is already owned by another app, registration fails and the menu bar
item says so. Pick another one.

### Bare modifiers want push-to-talk

On `toggle`, Right ⌥ would start recording every time you used it to type an
accented character. Hold-to-talk is the mode that makes sense for these; it's
also why apps in this category gravitate to `fn` or a right-hand modifier.

## Checking things from the terminal

The binary inside the bundle takes a few diagnostic flags — useful when a
hotkey isn't firing and you want to know whether the config is the reason, or
when you want to prove the microphone is reaching the app.

```sh
PF=.build/ParrotFlow.app/Contents/MacOS/ParrotFlow

$PF --check-config       # validate the YAML, print what the app would use
$PF --record 3           # record 3s and verify the file it produced
$PF --watch-modifiers    # print which modifier keys are physically down, live
```

```
$ $PF --check-config
config: /Users/you/.config/parrotflow/config.yaml
  ✓ hotkey            Right ⌥  (push-to-talk, polled)
  ✓ sample rate       16000 Hz mono
  ✓ output dir        /Users/you/Recordings/ParrotFlow
  ✓ min duration      0.3s
  · feedback          sound=true overlay=true
  ✓ microphone        Granted
  ✓ input device      MacBook Pro Microphone
```

`--record` checks the result, not just that it ran: sample rate, channel count,
bit depth, peak level, and whether the file is the right size for its duration.
A silent clip or a short file gets a non-zero exit.

`--watch-modifiers` is the one to reach for if a bare-modifier hotkey seems
dead — it shows whether the key is reaching the app at all, and whether left
and right are distinguishable on your keyboard.

The app also logs to `~/Library/Logs/ParrotFlow.log` (`make logs` tails it).
It records the hotkey, permission states and every clip written, which is the
fastest way to tell "the hotkey never fired" from "the recording was thrown
away for being too short".

## Permissions

**Microphone** — required. Requested on first launch; granting it is what makes
recording work at all.

**Accessibility** — not needed yet. It's listed in the settings window because
it's what will let ParrotFlow type the transcript into whatever app you're in,
once transcription lands. You can grant it now or later.

### Why permissions don't survive a rebuild

TCC — the subsystem behind these grants — identifies an app by its **code
signature**, not its path. With an ad-hoc signature (the default here, since it
needs no Apple developer account) the designated requirement pins the binary's
`cdhash`, which changes on every single build.

So the grant you gave to yesterday's build does not apply to today's. Worse,
the entry stays in System Settings pointing at a binary that no longer exists,
so it *looks* granted. Un-ticking and re-ticking that entry doesn't help —
it reuses the same dead record. Accessibility enforces this strictly;
Microphone is more forgiving but still breaks when the bundle is replaced.

The symptom is unmistakable: System Settings shows the app ticked, and the app
insists the permission isn't granted.

**Working around it, in increasing order of effort:**

*Grant permissions to the installed copy, not the build directory.* `make run`
rebuilds `.build/ParrotFlow.app` from scratch each time; `make install` puts a
copy in `/Applications` that only changes when you ask it to. Use the
`/Applications` copy day to day and the grants stay put.

*Clear a stuck entry.* `make reset-permissions` — this runs `tccutil reset`,
which deletes the record properly, unlike un-ticking the box.

*Sign with a stable identity.* This removes the problem entirely: the
designated requirement keys on the certificate instead of the binary hash, so
every rebuild inherits the same grants.

1. Keychain Access → *Certificate Assistant* → *Create a Certificate…*
2. Name it `ParrotFlow Dev`, Identity Type **Self Signed Root**,
   Certificate Type **Code Signing**.
3. Build with it:

```sh
CODESIGN_IDENTITY="ParrotFlow Dev" make install
```

The settings window detects an ad-hoc build and says so, rather than leaving
you to guess why a granted permission reads as missing.

## How it works

| Piece | Where | Note |
| --- | --- | --- |
| Global hotkey | `HotKeyManager.swift` | Carbon `RegisterEventHotKey` — no Accessibility permission needed, and it swallows the keystroke so it doesn't leak into the app you're typing in |
| Bare modifiers | `ModifierKey.swift` | `RegisterEventHotKey` can't express these, so they poll `CGEventSource.flagsState` for the device-dependent left/right bits — also permission-free |
| Audio capture | `Recorder.swift` | `AVAudioEngine` tap → `AVAudioConverter` → 16 kHz mono WAV |
| Config | `Config.swift` | Yams + a `DispatchSource` file watcher for live reload |
| Permissions | `Permissions.swift` | `AVCaptureDevice` for mic, `AXIsProcessTrusted` for Accessibility |
| Menu bar & wiring | `AppDelegate.swift` | |
| Logging | `Log.swift` | `~/Library/Logs/ParrotFlow.log` — a menu bar app has no console |
| Recording pill | `RecordingOverlay.swift` | Borderless non-activating `NSPanel` |

Two wrinkles worth knowing about push-to-talk:

Carbon only reports the release of the *character* key. Let go of ⌃ before
Space and no release event ever arrives, so `AppDelegate` also polls
`NSEvent.modifierFlags` while recording as a backstop.

Bare modifiers are polled rather than tapped. An event tap could swallow the
keystroke, but it costs the Accessibility permission and a keystroke-monitoring
prompt — a steep price when a bare modifier types nothing on its own, so there
is nothing to swallow. Polling `CGEventSource.flagsState` every 25 ms needs no
permission at all. The trade is ~25 ms of latency and no way to stop the key
also reaching the frontmost app.

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

## Roadmap

- [ ] Parakeet transcription (MLX or CoreML), running locally
- [ ] Paste/type the result into the frontmost app
- [ ] Text cleanup layer — dictionary substitutions for names and jargon first,
      optional local LLM pass second
- [ ] App icon
- [ ] Optional pre-roll buffer for zero-latency capture
- [ ] Double-tap and long-press activation

## License

MIT
