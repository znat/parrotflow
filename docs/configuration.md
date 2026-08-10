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
```

## Where things live

| | |
|---|---|
| Config | `~/.config/parrotflow/config.yaml` |
| Transforms | `~/.config/parrotflow/transforms/<name>/` — one folder each |
| Recordings | `~/Recordings/ParrotFlow` |
| Trace | `~/Recordings/ParrotFlow/trace.jsonl` |
| Log | `~/Library/Logs/ParrotFlow.log` |
| The example transform | `~/.config/parrotflow/transforms/code_identifiers/`, written on first launch and never overwritten |

The menu bar item shows the current state and offers *Correct a Word…*, *Open
Recordings Folder* — the wavs and `trace.jsonl` — *Settings*, which holds *Edit
Config…* (`config.yaml`) and *Open Config Folder* — everything you own, so
`vocabulary.yaml`, `transforms/` and `voice/` too — and
*Permissions…*. Both open in VS Code if it is installed, and in whatever the
system would otherwise use if it is not.

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

A recording that is cancelled is still written to your recordings folder — it is
where you go to hear what the app heard, and the moment you most want that is
the moment you cancelled. It is simply never transcribed.

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

The spelling you want, and the ways it comes out wrong. Whole words,
case-insensitive.

```yaml
replacements:
  Tasmeen: [Tasmid, Tasmin, Tasmine]
  Supabase: [super base, superbees]
  "": ['/[,]?\s*\b(?:u+m+|u+h+|erm+|hmm+)\b[,]?/']
```

A source in `/slashes/` is a regular expression, and with one the target is a
template, so `$1` writes back what the pattern captured. An **empty target
deletes** rather than substitutes, which is how filler words go, punctuation
and spacing included.

Grouped by the spelling you want rather than one line per mistake, because the
same name comes out wrong a dozen ways and they all mean one thing.

The table runs as the `replacements` stage; the `fuzzy` stage runs the same
table against renderings you never taught it. Both are pipeline stages, so
whether they run at all is [pipelines.md](pipelines.md).

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

## `feedback`

`sound` is the chime when a transcript lands. `overlay` is the floating pill
that shows the mic is hot. Both on by default; the pill is the only thing on
screen that says recording is happening, so turning it off is a real choice.

`correct_offer` is what the pill does after the words land. It stays where it
is for three seconds and reads `Wrong?  <your hotkey>  to fix it`. Tap that key
— press and let go, faster than a dictation — and the whole sentence opens in
an editable box. Fix it, press Replace, and it goes back over what was written.
Hold the key as usual and you start the next dictation, exactly as before.

The threshold is `audio.min_duration_seconds`, which is already the app's line
between a press and a dictation: below it the recording is deleted, so a tap
has never done anything. Nothing that used to be a dictation becomes a tap.

This is the sentence, not the vocabulary. Nothing is written to `replacements:`
— fixing one sentence is not the same as teaching a word, and most of a
misheard sentence is words that will never come up again. To teach a word, say
"Hey parrot, correct" or use the menu bar, which open the per-word panel.

Off by setting it to `false`.

## See also

- [pipelines.md](pipelines.md) — `pipelines:`, `transforms:`, conditions, apps
- [corrections.md](corrections.md) — teaching it a word, spoken corrections
- [cli.md](cli.md) — validating a config, and testing a change without speaking
- [permissions.md](permissions.md) — what needs Accessibility and what does not
