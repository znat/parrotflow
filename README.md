# ParrotFlow

Dictation for people who type for a living. Hold a key, talk, and the text
lands in whatever you are in — editor, terminal, browser, chat.

Everything runs on your Mac. No account, no API key, no network call. The
audio never leaves the machine, which is the whole point: most of what a
developer dictates is a bug report, a customer name, or a half-finished idea
about their own product.

It also learns the words you actually use. Say a library name once, tell it
how the name is spelled, and it gets it right from then on.

**Requires** an Apple Silicon Mac on macOS 14 or later.

## Install

### Let Claude Code do it

Paste this into Claude Code, or any agent that can run shell commands:

```
Set up ParrotFlow on my Mac by following
https://raw.githubusercontent.com/znat/parrotflow/main/docs/setup.md
```

It installs the app, walks you through the two macOS permissions, checks your
Ollama version, sizes the model settings to your RAM, and confirms transcription
works before it hands over. About five minutes of attention. The instructions it
follows are [docs/setup.md](docs/setup.md) — worth reading first if you would
rather know what is about to run.

### Or by hand

```sh
curl -fsSL https://raw.githubusercontent.com/znat/parrotflow/main/scripts/install.sh | sh
```

Downloads the latest release, checks it against its published SHA-256, and puts
`ParrotFlow.app` in `/Applications`. Then:

1. Say yes to the microphone prompt.
2. Grant **Accessibility** in System Settings — that is what lets it type into
   other apps.
3. Hold **right ⌥**, say something, let go.

The first dictation downloads the speech model (about 1.2 GB) and takes a
couple of minutes. Everything after that is immediate.

Spoken corrections need [Ollama](https://ollama.com) 0.22 or later with
`ollama pull gemma4:e4b`. Optional — dictation works without it.

### Or from source

```sh
git clone https://github.com/znat/parrotflow && cd parrotflow
make dev-certificate    # once, so permissions survive rebuilds
make hooks              # once, so commit subjects can cut releases
make install
```

Needs the Xcode command line tools. No Xcode project, no Apple developer
account. Note that this installs **ParrotFlow Dev**, a separate app from the
released one — see [Working on it](#working-on-it).

## Using it

Hold **right ⌥**, talk, let go. A second or so later the text is typed where
your cursor is.

Set `transcription.insert_mode: clipboard` to have it copied instead of typed —
that mode needs no Accessibility permission, but you press ⌘V yourself.

Audio is kept in `~/Recordings/ParrotFlow` and every transcript is logged to
`~/Library/Logs/ParrotFlow.log`.

The menu bar item shows the current state and offers *Correct a Word…*, *Open
Recordings Folder*, *Settings…* — which opens `config.yaml` — and *Permissions…*.

## Teaching it a word

When a name comes out wrong, select it in whatever app you're in, hold the
hotkey and say **"hey parrot"**. A panel opens showing what it heard and a
field for what it should have written.

    HEARD AS         SHOULD BE
    Tasmin      →   [Tasmeen            ]  ×
    and         →   [                   ]  ×
    Mick        →   [Mik                ]  ×
    return Save   esc Cancel              2 rules

You get a row per word, because rules are per-word — a phrase you selected
once will never recur verbatim. Leave a row blank and it is skipped, so
selecting a whole sentence to fix two names costs nothing. × drops a row you
do not want to think about.

Saving writes each filled-in rule to `config.yaml` — comments and your other
settings untouched — and puts the corrected phrase back where it came from,
punctuation and spacing intact.

### Saying the spelling instead

You can skip the panel entirely and just say the correction:

    "hey parrot, Tasmin spells T A S M E E N"
    "hey parrot, Mick is spelled M I K"
    "hey parrot, it's spelled S U P A B A S E not super base"

A local model works out which word was wrong; the panel opens prefilled so you
confirm with one keystroke rather than trusting it blindly.

The spelled-out letters are read from the text, not the model — a run of single
letters can only be the target spelling, and relying on the model for that got
the direction backwards on "X spells Y" phrasing in three of seven test cases.

The word being corrected is found in your **previous transcript**, not in the
command. The command is dictated too, so the name gets misheard a second time:
saying "Tasmine spells T A S M E E N" can come through as "Das mean spells…",
and a rule for "Das mean" matches nothing you will ever say. Since the target
spelling is already known from the letters, the closest match to it in the last
transcript is the word that needs fixing.

Needs Ollama running with the model in `llm.model` (`ollama pull gemma4:e4b`).

ParrotFlow loads that model at launch and asks Ollama to keep it there. Ollama
otherwise drops it after five minutes idle, and reloading is most of what you
wait for: measured 6.7s cold against 1.5s warm, so in practice almost every
correction paid for a reload. The cost is the model sitting in memory for as
long as the app runs — 9.6 GB for `gemma4:e4b`. Set `llm.keep_loaded: false` to
have the RAM back and the wait with it. On a 16 GB Mac that is the right
setting; on 32 GB it is not.

`tests/spelling-cases.yaml` holds 35 names — French, Indian, Chinese, Turkish,
Vietnamese, Korean, Nigerian, Polish, Irish, Arabic — plus product names
recognition splits, and negative cases. Score a model or a prompt against it
with `scripts/validate-prompt.py gemma4:e4b`. Without a model, `"hey parrot"`
and `"hey parrot, fix vocabulary"` still open the panel — those are matched
without one.

*Correct a Word…* in the menu does the same without speaking,
`--learn <heard> <corrected>` adds a rule from the terminal, and
`--command "<what you'd say>"` shows how a phrase would be routed.

Needs the Accessibility permission — reading your selection is exactly what
that permission governs. Change the trigger with `transcription.activation_phrase`.

**In a terminal**, selections are fragile: they get dropped on a keystroke or
when focus moves, often before the transcript comes back. ParrotFlow snapshots
the selection the moment the hotkey goes down, which covers most of it, and
falls back to your clipboard when there is nothing to read. So if a terminal
selection does not come through, copy it first — select, ⌘C, then say the
phrase. The panel always opens either way, with a row you can type into.

## Configuration

`~/.config/parrotflow/config.yaml`, created on first launch. Save the file and
the app picks it up immediately — no restart.

```yaml
hotkey:
  key: right_option     # a bare modifier, or a character key + modifiers
  modifiers: []         # required for a character key, ignored for a modifier
  mode: push_to_talk    # or toggle

audio:
  output_dir: ~/Recordings/ParrotFlow
  speech_gate: true     # skip clips with no speech in them

transcription:
  insert_mode: paste    # or clipboard
  activation_phrase: hey parrot
  languages: [en]       # en and fr are the supported values

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

**`languages`** is not passed to the speech model — Parakeet transcribes
multilingually by itself and reports no language back. The list is what
ParrotFlow uses to work out which language a transcript was in, so naming only
what you actually speak makes that more accurate, and it selects the correction
prompt written for that language. One entry means no detection runs at all.

### Bare modifiers want push-to-talk

On `toggle`, right ⌥ would start recording every time you used it to type an
accented character. Hold-to-talk is the mode that makes sense for these; it's
also why apps in this category gravitate to `fn` or a right-hand modifier.

## Checking things from the terminal

The binary inside the bundle takes a few diagnostic flags — useful when a
hotkey isn't firing and you want to know whether the config is the reason, or
when you want to prove the microphone is reaching the app.

```sh
PF=/Applications/ParrotFlow.app/Contents/MacOS/ParrotFlow

$PF --check-config       # validate the YAML, print what the app would use
$PF --record 3           # record 3s and verify the file it produced
$PF --watch-modifiers    # print which modifier keys are physically down, live
$PF --transcribe a.wav   # transcribe a clip
$PF --panels preview 20  # put one floating surface on screen and leave it there
$PF --panel-sheet s.png  # draw every surface into one PNG, light beside dark
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

`--panels` takes `pill`, `notice`, `caution`, `failure`, `thinking`,
`vocabulary`, `rule` or `preview`, and shows that one surface for as long as
you ask. It is how the floating surfaces get looked at without dictating
anything; `--panel-sheet` draws all of them at once, which is where drift
between them shows up.

You can make a test clip without a microphone at all — `say` writes exactly the
format the model wants:

```sh
say -o /tmp/t.wav --data-format=LEI16@16000 --channels=1 "testing one two three"
$PF --transcribe /tmp/t.wav
```

**Accessibility is the one thing these flags cannot tell you.** macOS credits a
permission check made from a terminal to the terminal, not to ParrotFlow, so
`--check-config` reports it as missing even when it is granted. The app tests it
properly at launch and writes the answer down:

```sh
grep "launched —" ~/Library/Logs/ParrotFlow.log | tail -1
```

The log (`make logs` tails it) records the hotkey, both permission states and
every clip written, which is the fastest way to tell "the hotkey never fired"
from "the recording was thrown away for being too short".

## Permissions

**Microphone** — required. Requested on first launch.

**Accessibility** — required for `insert_mode: paste` (the default) and for
spoken corrections, because reading your selection is exactly what that
permission governs. `insert_mode: clipboard` works without it.

### Why permissions don't survive a rebuild

TCC — the subsystem behind these grants — identifies an app by its **code
signature**, not its path. With an ad-hoc signature the designated requirement
pins the binary's `cdhash`, which changes on every single build.

So the grant you gave to yesterday's build does not apply to today's. Worse,
the entry stays in System Settings pointing at a binary that no longer exists,
so it *looks* granted. Un-ticking and re-ticking that entry doesn't help —
it reuses the same dead record. Accessibility enforces this strictly;
Microphone is more forgiving but still breaks when the bundle is replaced.

The symptom is unmistakable: System Settings shows the app ticked, and the app
insists the permission isn't granted.

**The fix, once:**

```sh
make dev-certificate                 # asks for your password
make install                         # picks the identity up automatically
```

That creates a self-signed code-signing certificate. The designated requirement
then keys on the certificate rather than the binary hash, so grants survive
every rebuild. Grant permissions *after* that install, not before.

Released builds are signed with a stable certificate for the same reason, so
upgrading does not cost you your permissions.

Since the dev build is a separate application, this only ever costs you the dev
app's grants. The copy you rely on is untouched by anything you rebuild.

If a grant is already stuck, `make reset-permissions` deletes the record
properly — un-ticking the box in System Settings does not, it leaves the dead
entry in place, which is why re-ticking it never helps.

## How it works

| Piece | Where | Note |
| --- | --- | --- |
| Global hotkey | `HotKeyManager.swift` | Carbon `RegisterEventHotKey` — no Accessibility permission needed, and it swallows the keystroke so it doesn't leak into the app you're typing in |
| Bare modifiers | `ModifierKey.swift` | `RegisterEventHotKey` can't express these, so they poll `CGEventSource.flagsState` for the device-dependent left/right bits — also permission-free |
| Audio capture | `Recorder.swift` | `AVAudioEngine` tap → `AVAudioConverter` → 16 kHz mono WAV |
| Transcription | `Transcriber.swift` | Parakeet TDT v3 via [FluidAudio](https://github.com/FluidInference/FluidAudio), CoreML on the Neural Engine |
| Spoken commands | `LocalLLM.swift` | HTTP to a local Ollama; degrades to "unavailable" when it isn't there |
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

## Working on it

The build you are changing and the build you use to get work done are **two
separate applications**. Both can be installed, and both can run at once.

|  | Released | Dev |
| --- | --- | --- |
| App | `ParrotFlow.app` | `ParrotFlowDev.app` |
| Bundle id | `com.parrotflow.app` | `com.parrotflow.app.dev` |
| Hotkey | right ⌥ | right ⌘ |
| Config | `~/.config/parrotflow/` | `~/.config/parrotflow-dev/` |
| Log | `ParrotFlow.log` | `ParrotFlow-Dev.log` |
| Recordings | `~/Recordings/ParrotFlow` | `~/Recordings/ParrotFlow Dev` |
| Menu bar | `mic` | `mic.circle` |

This is not tidiness. macOS grants microphone and Accessibility **per bundle
identifier**, so one identifier for both means every rebuild is revoking and
re-granting permissions on the app you actually rely on — and a half-finished
config change can break it. Separate identifiers make that impossible.

Different hotkeys are what let both run at once: same key and both would record
the same sentence and both paste it. You choose which build hears you by which
key you hold.

Everything in the Makefile works on the dev build by default:

```sh
make run                  # build and launch ParrotFlow Dev
make logs                 # tail the dev log
make which                # print what this variant resolves to
make stop                 # quit dev; the installed app keeps running

VARIANT=release make logs  # act on the shipped app instead
```

`scripts/variant.sh` is the one place the two identities are defined, and
`AppVariant.swift` is where the app derives its own paths from the identifier it
was built with.

## Releasing

Nobody picks a version number. release-please reads the commit subjects since
the last tag and works it out: a `feat:` bumps the minor, a `fix:` or `perf:`
the patch, and anything else releases nothing at all. It keeps a release PR open
with that version and the changelog it derived, and **merging that PR is the
release** — it tags, builds on a macOS runner, signs, and attaches the archive
that `install.sh` downloads.

So the subject line is not housekeeping. A commit written without a type is
invisible to all of this: no bump, no changelog entry, and no warning that it
was skipped. `make hooks` points git at `.githooks/commit-msg`, which refuses
one before it lands. Run it once per clone — hooks are not cloned.

```
feat:  a capability that was not there before   -> minor
fix:   behaviour that was wrong is now right    -> patch
perf:  same behaviour, measurably faster        -> patch
docs: refactor: test: build: ci: chore:         -> no release
```

The body of the message is unaffected. It is still the place to say what broke
and how you know it is fixed.

```sh
make hooks                       # once per clone
scripts/release-certificate.sh   # once, ever — see the warning in the file
scripts/release.sh               # build the artefacts locally to inspect them
```

Re-running the workflow by hand (Actions → release → Run workflow) recomputes
the release PR. It cannot force a release: with no releasable commits since the
last tag there is nothing to open a PR for.

## Design notes

- [docs/setup.md](docs/setup.md) — the guided install an agent follows
- [docs/transcription.md](docs/transcription.md) — picking a Parakeet runtime,
  why the model can't be prompted, and what to do instead
- [docs/distribution.md](docs/distribution.md) — why this ships by curl rather
  than Homebrew, and what notarization would change

## Roadmap

- [ ] Developer ID signing + notarization, then a Homebrew cask
- [ ] App icon
- [ ] Spike Apple `SpeechTranscriber` (macOS 26+) — no model download at all
- [ ] Custom vocabulary as acoustic context biasing, not find-and-replace
- [ ] Optional pre-roll buffer for zero-latency capture
- [ ] Double-tap and long-press activation
- [ ] More correction-prompt languages than `en` and `fr`

## License

MIT
