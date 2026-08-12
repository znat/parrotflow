# Configuration

Every setting, what it does, and what happens when it is wrong.

`~/.config/parrotflow/config.yaml`, created on first launch. Save the file and
the app picks it up immediately — no restart. `config.example.yaml` in the repo
is the same file with every comment kept.

**Validate before you trust it:** `--check-config` prints what the app would
actually use, and names anything it had to ignore. See [cli.md](cli.md).

```yaml
hotkey:
  key: right_option     # a bare modifier, or a character key + modifiers
  modifiers: []         # required for a character key, ignored for a modifier
  mode: push_to_talk    # or toggle
  release_tail_seconds: 0.3   # keep recording this long after you let go

audio:
  output_dir: ~/Recordings/ParrotFlow
  speech_gate: true     # skip clips with no speech in them

transcription:
  insert_mode: paste    # or clipboard
  activation_phrases: [hey parrot, by the way parrot]
  languages: [en]       # en and fr are the supported values
  rewrite_line: true
  pipelines: …          # see pipelines.md
  replacements: …       # see below
  transforms: …         # see pipelines.md

llm:
  enabled: true
  model: gemma4:e4b
  endpoint: http://localhost:11434
  keep_loaded: true

updates:
  after_days: 7

free_form: true

feedback:
  sound: true
  overlay: true
  correct_offer: true

logging:
  text: true    # ~/Library/Logs/ParrotFlow.log
  audio: false  # keep each dictation's recording on disk
```

## Where things live

| | |
|---|---|
| Config | `~/.config/parrotflow/config.yaml` |
| Transforms | `~/.config/parrotflow/transforms/<name>/` — one folder each |
| Recordings | `~/Recordings/ParrotFlow` — empty unless `logging.audio: true` |
| Trace | `~/Recordings/ParrotFlow/trace.jsonl` |
| Log | `~/Library/Logs/ParrotFlow.log` — off with `logging.text: false` |
| The example transform | `~/.config/parrotflow/transforms/code_identifiers/`, written on first launch and never overwritten |

The menu bar item shows the current state and offers *Correct a Word…*, *Open
Recordings Folder* — the wavs, if `logging.audio` is on, and `trace.jsonl` —
*Settings*, which holds *Edit Config…* (`config.yaml`) and *Open Config
Folder* — everything you own, so `vocabulary.yaml`, `transforms/` and `voice/`
too — and *Permissions…*. Both open in VS Code if it is installed, and in
whatever the system would otherwise use if it is not. See [`logging`](#logging).

### A folder per transform

A transform named `X` owns `transforms/X/`. Everything belonging to it lives
inside, so it can be written, scored and handed to someone else as one thing:

```
~/.config/parrotflow/
  config.yaml
  transforms/
    code_identifiers/
      code_identifiers.py    # the entry point, named after the transform
      cases.yaml             # what --eval scores it against
    slack_mentions/
      slack_mentions.py
      cases.yaml
      roster.json            # data the transform owns
```

That folder is both where the transform's files are looked for **and the
working directory its command runs in** — which is what pays for the extra
directory. A script can open `roster.json` as a bare relative path, so the
folder is self-contained: copy it to another machine and it works.

That folder is the only place a transform's files are looked for. There is no
flat alternative to fall back to: a `command:` that names neither a file in its
folder nor anything the shell can find on `PATH` is reported by
`--check-config` as a fault, rather than failing quietly once per transcript.
Writing the path out in full — `transforms/slack/slack.md` — names the same
file, because people write both.

The dev build keeps its own copies of all of these; see
[development.md](development.md).

## `hotkey`

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

### `release_tail_seconds`

Keeps the mic open after you let go, because the hand is faster than the mouth
and the last syllable lands after the key is up. Push-to-talk only. Raise it if
endings still get clipped, `0` to stop the moment you release.

### Bare modifiers want push-to-talk

On `toggle`, right ⌥ would start recording every time you used it to type an
accented character. Hold-to-talk is the mode that makes sense for these; it's
also why apps in this category gravitate to `fn` or a right-hand modifier.

## `transcription.insert_mode`

`paste` types the transcript into the app you are in and needs the
Accessibility permission. `clipboard` copies it and needs no permission at all;
you press ⌘V. See [permissions.md](permissions.md).

**With no cursor in a field, neither one types.** A Finder window, a video, a
page you are reading — they are frontmost and they have nowhere to put a
sentence, and a ⌘V sent there does whatever that window makes of it. So the
pill leaves the app icon out while you talk, which is the warning, and when the
transcript arrives it goes to your clipboard with a notice saying where it went.
Terminals are the exception: what they show macOS is a screen rather than a
field, so they are recognised by name and always counted as somewhere to write.

**If you move, it copies rather than pastes.** A transcript arrives seconds
after you stop talking — a decoder, then whatever the pipeline runs — and the
paste goes to whatever is in front by then. Dictate an instruction into one
terminal pane, switch to the next while it works, and it used to land in the
wrong session.

So the field is checked against the one you dictated into, and a transcript that
no longer has a home there goes to the clipboard with a notice instead. It does
not try to put focus back: that would mean asking an app to restore a pane and
trusting it to, which is a guess. The clipboard is not a guess.

This is a comparison of the focused element, so it catches a move between panes
of the same app, which is the case that actually happens.

If the field cannot be read at all — a busy app that does not answer in time —
that counts as moved and the transcript is copied. Not knowing is not the same
as knowing it is fine, and a transcript on your clipboard is recoverable in a
way that one typed into somebody else's window is not.

## Escape stops a dictation

Press ⎋ while recording, or while it is transcribing, and the dictation ends.
Nothing is written.

It works with the hotkey still held, which is the point of it: in push-to-talk
the key is down for the whole sentence, and letting go is what commits the
recording. Say the wrong thing and you can stop before it lands.

With `logging.audio: true`, a recording that is cancelled is still kept in your
recordings folder — it is where you go to hear what the app heard, and the
moment you most want that is the moment you cancelled. It is simply never
transcribed. With `logging.audio` at its default of `false`, the clip is
discarded like any other.

Cancelling during transcription cannot make the decoder stop sooner. The model
call is not interruptible. What it guarantees is that nothing is written when it
finishes.

Escape is not swallowed. The app you are typing into still sees it, which is
usually what you want when you are stopping a dictation into a terminal.

## `transcription.languages`

Not passed to the speech model — Parakeet transcribes multilingually by itself
and reports no language back. The list is what ParrotFlow uses to work out
which language a transcript was in, so naming only what you actually speak
makes that more accurate, and it selects the correction prompt written for that
language. One entry means no detection runs at all.

Most spoken first: the first entry is the fallback for transcripts too short to
judge, under four words. Supported values are `en` and `fr`.

## `transcription.activation_phrases`

Say one of these instead of dictating and what follows is an instruction:
"hey parrot, make that a bullet list". An empty list disables spoken commands.

One of them **mid-sentence** turns the rest into an instruction about the words
before it, in the same breath — which is why there are two. See
[corrections.md](corrections.md).

## `transcription.rewrite_line`

Terminals only. Their accessibility value is a picture of a screen rather than
an editable buffer, so the only thing that writes there is keystrokes: the input
line is cleared with ⌃A ⌃K and retyped corrected. Destructive by nature, which is
why it is a setting — but it is checked rather than hoped, and a clear that
cannot be read back is a refusal rather than a guess.

Everywhere else — a field, a browser, Slack, Outlook — edits a range directly and
never touches this. It used to be the fallback for those too, which is how a
correction ended up appended to the end of a line instead of replacing a word in
it: ⌃K clears nothing in a composer, and the paste that followed landed on the
end of what was still there.

## `transcription.replacements`

Patterns and deletions, hand-written. Whole words, case-insensitive. A name
the recogniser mangles does not go here — say "hey parrot" and fix it in the
panel, and it lands in `vocabulary.yaml` instead — but a pattern with no fixed
spelling, or a deletion, has nowhere else to live.

```yaml
replacements:
  "": ['/[,]?\s*\b(?:u+m+|u+h+|erm+|hmm+)\b[,]?/']
  '$1.$2': ['/\b(\w+) dot (\w+)\b/']
```

A source in `/slashes/` is a regular expression, and with one the target is a
template, so `$1` writes back what the pattern captured. An **empty target
deletes** rather than substitutes, which is how filler words go, punctuation
and spacing included.

The table runs as the `replacements` stage — a pipeline stage, so whether it
runs at all is [pipelines.md](pipelines.md).

## `llm`

The local Ollama model behind spoken commands and every `prompt:` transform.
Without it dictation still works and those stages stop.

`keep_loaded: true` pins the model in RAM at launch. Ollama otherwise drops it
after five minutes idle and the next command waits for a reload — measured
**6.7 s cold against 1.5 s warm**, so in practice almost every correction paid
for one. The cost is the model sitting in memory for as long as the app runs:
9.6 GB for `gemma4:e4b`. On a 16 GB Mac, turn it off. On 32 GB, do not.

## `updates`

One call a day to GitHub's release API — no account, nothing about you, nothing
about what you dictate.

The number is a waiting period, not a frequency: `-1` never asks, `0` offers a
release the day it is published, `7` only offers one that has existed for a
week. The wait is the point — a bad release is one that gets noticed and
pulled, and a week of distance means your Mac never saw it.

## `free_form`

Do what was asked even when no transform description matches: "hey parrot, use
the 24 hour clock". A remark that was never an instruction is still refused,
and you see every result before it replaces anything. Turn it off to go back to
a fixed menu of transforms.

## `audio.speech_gate`

Skips clips with no speech in them, so a key pressed by accident costs nothing.
Gated on speech being *present*, not on how much — a one-word dictation is a
real one.

## The microphone

Whatever the system input device is, picked in System Settings. There is
nothing to set here: the app follows that choice, the menu bar names the device
in use, and `--check-config` prints it.

**A Bluetooth microphone costs you words, and the app says so once.** AirPods
and most headsets record over a Bluetooth voice profile. That profile carries
less of your voice than a wired mic does, its noise reduction mutes quiet
pauses and soft consonants, and the wireless delay makes the recogniser drop
words in fast speech. What you see is a transcript missing its trailing words,
with nothing on screen to say why.

So a notice appears in the bottom right after a dictation, saying which
microphone it is and to use the built-in one instead. *Why* opens the three
reasons; *Got it* dismisses it. It is said once for as long as you stay on that
microphone — not at launch, when you are not dictating and it would be advice
about nothing, and not every time, which is nagging. Dictate on another
microphone and come back to this one and it is said again: that is a decision
being revisited.

The microphone it names is the one that recorded the words, read when the
recording starts. Change the input device while a transcript is still coming
back and the notice still talks about the microphone you actually used.

The transport is what is asked about, not the name. A list of brands is wrong
the day somebody buys a headset nobody thought of, and the transport is the
thing that costs you the words.

## `feedback`

`sound` is the chime when a transcript lands. `overlay` is the floating pill
that shows the mic is hot. Both on by default; the pill is the only thing on
screen that says recording is happening, so turning it off is a real choice.

**Where the pill appears.** Next to the place your words are about to go, so you
can see where they are headed before you have said any of them. Where the app
will not say where that is, it sits at the bottom of the screen instead. That is
where it always used to be.

Terminals split two ways, and it is worth knowing which one you are in. A pane
running a full-screen program shows only what fits on the screen. Claude Code,
vim and less all work this way, and the pill follows your words there. A pane
sitting at an ordinary shell prompt keeps everything you have run in it, and the
pill goes to the bottom of the screen.

`correct_offer` is what the pill does after a dictation. It stays where it
is and names what can be done to the words, one chip per command:
`Correct` first, then every transform with `offer: true` — see
[pipelines.md](pipelines.md#offer-and-key-or-getting-on-the-pill). `Correct`
opens the per-word panel over what was just dictated; a transform rewrites it
straight away, with no preview.

**After every dictation, not only one that landed in a field.** A word the
recogniser got wrong is worth fixing whether or not the sentence reached a text
field. A dictation that ended on the clipboard — focus moved, nowhere to type,
`insert_mode: clipboard`, or no Accessibility grant — gets the same offer, and
what a command produces goes back to the clipboard. So the ⌘V you were about to
press pastes the corrected version. The notices those endings used to put on the
pill are in the menu bar now, under the parrot.

Only over the dictation itself. Copy something else while the panel is open, or
while a transform is running, and the clipboard is yours rather than the
dictation's — the result is not written over it, and the menu bar says so.

| | Does |
|---|---|
| a chip's letter — `C`, `G` | Runs that command |
| a click on a chip | Runs that command |
| a click anywhere else | Dismisses, and reaches whatever you clicked untouched |
| any other key | Dismisses, and reaches whatever it was headed for untouched |
| `esc` | Dismisses |
| `↩` | Dismisses, and reaches the app underneath untouched |
| the dictation hotkey | Starts the next dictation, exactly as before |

It fades rather than vanishing. It arrives just below full strength and thins
out over nine seconds, and then it is gone. The keys, the click, and the chips
work the whole way down — the fading only says how long is left. Putting the
pointer on the pill stops the clock, and taking it off starts the nine seconds
again. Any of the endings above takes the pill at once.

**The letters are taken from every app for those nine seconds.** The pill
never holds keyboard focus, so it swallows a chip's own letter system-wide or
it does not get it at all. Only that bare letter runs a command — a letter
with a modifier on it is somebody else's shortcut and is left alone, `⌘C`
still copies and `⇧G` still types a capital G. Every other key you press ends
the offer instead, the same as clicking anywhere but the pill does, and is
passed straight through: it still lands wherever it was headed. So a dictation
followed straight away by a sentence starting with `C` or `G` runs a command
on that first keystroke — the offer is up, and that is still its letter — but
every keystroke after it is safe, because the offer is already gone. Pick a
chip's letter with that in mind: one you are unlikely to start a word with
right after dictating.

Off by setting it to `false`. Then no key is taken at any time.

## `logging`

What gets written to disk about a dictation, apart from the transcript itself.
Two separate switches, because the two artifacts have nothing in common but
where they end up.

`text` controls the line-by-line log at `~/Library/Logs/ParrotFlow.log` — see
[Where things live](#where-things-live). On by default: it is how every
problem in this app gets diagnosed, from a hotkey that will not register to a
pipeline stage that silently did nothing. Turn it off and the app still works
exactly the same; it just stops narrating itself to that file.

`--peek` and `--edit-test`/`--span-test` write to the log whatever this says.
Both are meant to be run as `open -na ParrotFlowDev --args --peek`, the only
way to carry the app's own Accessibility grant from a terminal, and
LaunchServices throws away the stdout of a process launched that way — the log
is the one transport that survives, and the harnesses built on these commands
read it back out.

`audio` controls whether each dictation's recording is kept on disk, in
`audio.output_dir`. **Off by default** — a recording of your voice should not
accumulate there unless you asked for it. This is a change from earlier
versions, which always kept every clip.

Turn it on to get the old behaviour back: every recording, including a
cancelled one (see [Escape stops a dictation](#escape-stops-a-dictation)) and
one whose ending was lost to a device change, stays in your recordings folder.
Turn it on before you want to build up a history of clips to work from — for
calibration, or to re-run against a change with `--transcribe`.

With it off, a clip exists on disk only for as long as the app needs it to
transcribe your words, and is removed the moment that is done. With
`transcription: { enabled: false }` nothing transcribes it at all, so nothing
is kept either. Commands you run yourself from the terminal — `--record`,
`--transcribe <file>`, `--spot` — are unaffected either way: they write and
keep the file you asked them to, because you asked for it by running them.

## See also

- [pipelines.md](pipelines.md) — `pipelines:`, `transforms:`, conditions, apps
- [corrections.md](corrections.md) — teaching it a word, spoken corrections
- [cli.md](cli.md) — validating a config, and testing a change without speaking
- [permissions.md](permissions.md) — what needs Accessibility and what does not
