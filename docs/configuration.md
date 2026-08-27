# Configuration

Every setting, what it does, and what happens when it is wrong.

`~/.config/parrotflow/config.yaml`, created on first launch. Save the file and
the app picks it up immediately — no restart. `config.example.yaml` in the repo
is the same file with every comment kept.

**Validate before you trust it:** `--check-config` prints what the app would
actually use, and names anything it had to ignore. See [cli.md](cli.md).

```yaml
hotkey:
  key: right_command    # a bare modifier, or a character key + modifiers
  modifiers: []         # required for a character key, ignored for a modifier
  mode: push_to_talk    # or toggle
  release_tail_seconds: 0.3   # keep recording this long after you let go
  press_delay_seconds: 0.18   # hold a bare modifier this long before it counts

audio:
  output_dir: ~/Recordings/ParrotFlow
  speech_gate: true     # skip clips with no speech in them
  second_opinion: true  # decode each clip twice and keep the longer decode

transcription:
  insert_mode: paste    # or clipboard
  activation_phrases: [hey parrot, by the way parrot]
  languages: [en]       # en and fr are the supported values
  rewrite_line: true
  pipeline: …           # see pipelines.md
  transforms: …         # see pipelines.md

models:                 # every model, under names you pick
  gemma:
    api: ollama         # ollama | openai | anthropic — the protocol, not the vendor
    model: gemma4:e4b
    keep_loaded: true
    default: true       # what runs whatever names no model
  gpt:
    api: openai
    model: gpt-5.6-luna
    reasoning: off      # off | minimal | low | medium | high

commands:               # which model does each part of "hey parrot, …"
  router: gemma
  spelling: gpt
  catch_all: gpt        # or false, to refuse what no capability covers

updates:
  after_days: 0

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
| The shipped examples | `~/.config/parrotflow/transforms/examples/` — refreshed from the app on every launch, not yours to edit in place |

The menu bar item shows the current state and offers *Open Recordings
Folder* — the wavs, if `logging.audio` is on, and `trace.jsonl` — *Settings*,
which holds *Edit Config…* (`config.yaml`) and *Open Config Folder* —
everything you own, so `vocabulary.yaml`, `transforms/` and `voice/` too —
and *Permissions…*. Both open in VS Code if it is installed, and in whatever
the system would otherwise use if it is not. See [`logging`](#logging).

### A folder per transform

A transform named `X` owns `transforms/X/`. Everything belonging to it lives
inside, so it can be written, scored and handed to someone else as one thing:

```
~/.config/parrotflow/
  config.yaml
  transforms/
    examples/                # every shipped example — the app's, refreshed
      code_identifiers/      # on every launch, not yours to edit in place
        code_identifiers.py
        cases.yaml
      punctuation/
        punctuation.py
        cases.yaml
    slack_mentions/          # yours
      slack_mentions.py
      cases.yaml
      roster.json            # data the transform owns
```

That folder is both where the transform's files are looked for **and the
working directory its command runs in** — which is what pays for the extra
directory. A script can open `roster.json` as a bare relative path, so the
folder is self-contained: copy it to another machine and it works.

A bare name is only ever looked for in that folder. A path with a directory in
it — `command: examples/punctuation/punctuation.py` — may also name a file
elsewhere under `transforms/`, which is how the config that ships points every
transform that uses a shipped example at the one copy in `transforms/examples/`
instead of a copy per transform. The working directory still does not move: a
shared script runs in the folder of whichever transform called it, so it reads
its own data files from `__file__` rather than by bare relative name.

`transforms/examples/` is the app's folder: refreshed from the copy that ships
every time ParrotFlow starts, so an edit made there does not survive the next
launch. The refresh also removes a file this version no longer ships, so an
example a past version installed and this one dropped or renamed stops
resolving through its old `examples/...` path instead of quietly going stale.
`transforms/<name>/` is yours: nothing here ever writes it, and nothing in it
is ever overwritten. To change a shipped example, copy its folder from
`transforms/examples/` into `transforms/<name>/` and point `command:` at the
bare name there.

Beyond that there is no flat alternative to fall back to: a `command:` that
names neither a file under `transforms/` nor anything the shell can find on
`PATH` is reported by `--check-config` as a fault, rather than failing quietly
once per transcript. Writing the path out in full — `transforms/slack/slack.md`
— names the same file, because people write both.

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

### `press_delay_seconds`

A bare modifier is never really bare. ⌘ is the front half of every shortcut in
every app. ⌥ is a live character key on most non-US layouts — on the French
layout it types `#`, `{`, `|` and `~` — and everywhere it is ⌥← to jump a word
and ⌥⌫ to delete one. Taken at face value, every ⌘S opened the mic.

So a bare modifier has to be held **alone** for this long before it starts a
dictation, and anything else arriving while it is still down — a key, a click,
a scroll, a second modifier — drops the dictation it started. That happens
silently: you pressed ⌘S to save, and a notice about a dictation you never
started would be an apology for something you were not supposed to see.

The wait costs nothing. `release_tail_seconds` exists because the hand beats
the mouth on the way *up*; there is no matching problem on the way down, since
nobody starts a word within 180 ms of pressing the key. Raise it if a shortcut
still slips through, `0` to start on the down edge as before.

Bare modifiers only — a `⌃⌥Space`-style combo is unambiguous by construction
and goes through Carbon, which swallows it.

Keys and clicks are seen through a global event monitor, which needs
Accessibility. Without it only the second-modifier check works, and the log
says so at launch.

### Bare modifiers want push-to-talk

On `toggle`, right ⌥ would start recording every time you used it to type an
accented character. Hold-to-talk is the mode that makes sense for these; it's
also why apps in this category gravitate to `fn` or a right-hand modifier.

### Tap it to bring the offer back

One key, three lengths. The tap means "me"; what you do next says what.

| Gesture | What happens |
|---|---|
| **Hold** | Dictate. Unchanged. |
| **Tap** | The pill comes back, with its commands on it |
| **Tap, then hold** | Speak an instruction — any command, not just the chips |

A tap is a press shorter than `press_delay_seconds`. Tap and hold again within
0.4s and the hold is the second half of one gesture rather than a dictation.

| What is selected | What the gesture is about |
|---|---|
| A selection, anywhere | Those words, and the pill appears under them |
| Nothing | The last dictation, and the pill stays where it was |

**Tap-then-hold speaks the whole catalogue.** The chips are a short list; what
you say is routed the way `"hey parrot, …"` is routed, so it reaches every
transform and the catch-all besides — with no phrase to remember, because the
key already said it was an instruction. The pill says **editing the selection**
or **say an edit** while you hold, and ⎋ cancels.

**And no router.** A key said this was an instruction, so the question the
router exists to answer — *was that even an edit?* — is already answered.
What is left is which tool, and that is decided without a model:

1. Does the sentence contain the name of one of your transforms, or one of the
   words its `say:` lists? Then run it. No model call at all.
2. Otherwise the catch-all takes the whole sentence as its specification. One
   model call.

Never two waits in a row. Often none. `"hey parrot, …"` keeps the router,
because that one is *found* in a sentence and really does have to guess.

Step 1 is not an optimisation, it is what keeps the rest of your catalogue
reachable. The catch-all is a prompt. A `command:` script and a `replace:`
table are not, so nothing can stand in for them — "flag this" sent to the
catch-all does not file your text, it rewords it. `say:` is how a tool named
`slack_handles` gets reached by someone saying "use our slack handles".

`scripts/check-keyed.sh` scores this against `tests/keyed-cases.yaml`, with no
model and in about a second.

**It applies in place**, whatever the transform's `confirm:` says — the same
rule a chip on the pill already follows. The target was named on the pill
before you spoke, ⎋ was live the whole time you were speaking, and
`"hey parrot, undo"` puts the substitution back. A preview after all three is
a question that was answered before it was asked. `"hey parrot, …"` still
previews: that command is *found* in a sentence rather than declared by a key,
so being wrong about it is a real possibility.

A bare tap waits 0.4s before the pill appears, because that is how long it
takes to find out whether a hold is coming. Nothing waits on a pill; the
dictation path is untouched.

The selection wins because it is what you are pointing at now, and it is the
only target the tap can have in an app ParrotFlow has never written into:
select a paragraph in Word, tap, and press a chip's letter.

This is why the offer's six seconds are not a deadline. It is not kept on
screen against the chance that you want it — you ask for it again.

**Select what it just wrote and the pill comes back on its own**, with no key
at all. All or part of it — select three words out of a sentence you dictated
and those three words are the target.

Only for words ParrotFlow wrote, in the field it wrote them into, and only
while they are still the last thing it wrote. Every other selection gets
nothing, because selecting text is mostly how you copy it, delete it or type
over it, and a surface that appeared each time would be wrong far more often
than right. It never appears twice for the same words either: the pill returns
when you *select* something, not while you have something selected.

It costs no polling. A selection is made by a drag, a shift-arrow or ⌘A, so the
question is asked at those three moments and never in between.

**`Vocabulary` is left off the pill for words nothing here dictated.** The
panel behind it maps what was *heard* to what it should be, and there is no
hearing behind a paragraph somebody else typed — a rule taught from their typo
would fire on your own future dictations, correcting a mistake the decoder
never made. Every other chip is a rewrite and applies to any text, so they
stay.

**Bare modifiers only.** A `⌃⌥Space`-style combo goes through Carbon, which
delivers the press on the down edge and swallows the keystroke, so there is no
short press left over to claim: a tap there is a dictation, and a brief one.
At `press_delay_seconds: 0` there is no tap either, for the same reason.

Nothing is summoned while a dictation is recording or still decoding. On
`toggle` the key is what stops a recording, and a stop that came out short is
still a stop.

`--watch-taps` says which edge each press comes out as — see
[cli.md](cli.md). The case worth checking by hand is that ⌘S prints nothing.

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

## Bullets, bold and links

A transcript that carries a Markdown **list, heading, code block or quote**,
over more than one line, reaches an app that takes it as real formatting rather
than as `**stars**`. Inside it, bold, italic, code spans, a real second level of
bullets, numbered lists and links all survive.

A single line qualifies too, but only for a **link written out as
`[words](url)`** or a **code span** — `[the PR](https://…)` and
`` `user.name` ``. Emphasis on a single line does not: `Call **Dana** about it`
is pasted as you said it, markers and all. That is deliberate — see *What counts
as formatting* below.

**Slack only, so far.** It is the one app measured. Every other app gets plain
text, byte for byte as before. There is nothing to configure and nothing to
turn on — the app is either measured or it is not, and an unmeasured one is
never sent markup it might show as tags. Plain text also rides along beside
every rich flavour, so an app that takes neither still gets the sentence.

**Nothing turns speech into Markdown yet.** This is the delivery half. It
carries what a transform already emits, so a prompt of yours that returns a
bullet list lands as a bullet list. Dictating *"bullet point call the client"*
does not, and that is separate work.

### What counts as formatting

Two ways in.

**Block structure** — a list, a heading, a code block, a quote — spread over
more than one line.

**Or a link or a code span, on any number of lines.** Both take characters a
speaker only produces on purpose: brackets, parentheses, backticks. A transform
that emits `[#123](https://…)` means it. Scanned over 1355 lines of the case
files, there were no links at all and the only two code spans were a transform's
own output.

It is the **syntax** that counts, not what the link says. `[https://x](https://x)`
is deliberate even though its words are its address. A bare URL the parser
noticed on its own is not, however it reads — accepting those would send a whole
sentence as markup for mentioning an address.

**Or emphasis you asked for.** Asterisks, and not inside a word — which is what
*"start bold … end bold"* produces through `punctuation`. Underscores never
count, and neither does an asterisk inside a word. Those are the two ways
ordinary dictation trips over emphasis:

| dictated | would have become |
|---|---|
| `use the __init__ method` | bold "init", underscores gone |
| `we need __slots__ on that class` | bold "slots" |
| `multiply a*b*c and check the result` | an italic *b*, the asterisks gone |
| `rate is 3*4*5` | an italic *4* |
| `1. Draft 2. Review` | a numbered list |

Each loses characters you said, and `__init__` is a word a developer dictates.
All of them stay exactly as you said them. What separates them from `**Dana**`
is the delimiter and the position: underscores, or an asterisk pressed against a
letter. Nothing you dictate produces a word wrapped in loose asterisks unless
you asked for it.

### Measuring your own app

An app of yours that takes formatting and is not on the list can be measured.
Put the fixture on the clipboard and paste it in yourself:

```sh
/Applications/ParrotFlow.app/Contents/MacOS/ParrotFlow --paste-probe all
```

Then score seven things: bold, italic, code, bullet, nested bullet, numbered
list, and the link — twice, once for its words and once for the URL behind
them. [cli.md](cli.md) has the flags,
[proposals/formatted-paste.md](proposals/formatted-paste.md) has the table to
fill and what promoting an app costs.

Adding one is a line in `AppProfile.swift` today, so it needs a release. Making
it a config setting is [#197](https://github.com/znat/parrotflow/issues/197).

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

## `transcription.replacements` is retired

It held two kinds of rule and neither belongs there now.

A name the recogniser mangles goes in `vocabulary.yaml`, where the `vocabulary`
stage matches it and then has a model read the sentence before keeping it —
"Versailles" is sometimes the castle, and only something reading the sentence
can tell.

A mechanical rule — a deletion, a regex template — goes in a transform's
`replace:`, which needs no such review and already takes regexes, deletions,
`{{lists}}` and `when:`/`app:` conditions:

```yaml
transforms:
  - name: fillers
    description: delete hesitation sounds
    replace:
      "": ['/[,]?\s*\b(?:u+m+|u+h+|erm+|hmm+)\b[,]?/']
```

Nothing was left in the middle, which is why the table went. A rule that needs
judging is a name; a rule that does not is a transform. `--check-config`
refuses the old key and says this.

## `lists`

Word lists, written once and named. A pattern refers to one as `{{name}}`:

```yaml
lists:
  determiners: ["the", "a", "an", "le", "la", "les", "un", "une"]

transforms:
  - name: dotted
    description: spoken dotted paths as code
    replace:
      '$1.': ['/\b(?!(?:{{determiners}})\b)(\w+) dot (?=\w)/']
```

`{{determiners}}` becomes the words as a regex alternation, longest first —
otherwise `colon` sitting earlier in the list eats `semi colon`. It works in
`replacements:` and in any `replace:` transform.

`--check-config` refuses a name nothing defines, and a list defined with no
words in it, and says which rule named it. If one reaches the app anyway it is
left as the literal `{{name}}`, so the rule matches nothing — an emptied
alternation matches everywhere, and a guard that silently stops guarding is the
worse of the two failures.

`lists` is a reserved name. The words are published under `lists.*` before any
stage runs, so a transform declared with that name would write over them. It is
dropped where transforms are assembled, and `--check-config` says so — the same
treatment an entry with no body gets. `text`, `app`, `bundle_id`, `language`,
`instruction`, `asr`, `vad` and `vocabulary` are reserved for the same reason.

A transform that is a program reads the same words from
`ctx["vars"]["lists"]["determiners"]`, joined by `; `. So one list serves a
table and a script, and adding a language is adding words here.

**Quote every entry.** `on`, `no` and `off` are booleans in YAML 1.1, which is
what the check scripts in `scripts/` parse with. An unquoted `on` reaches them
as the word `true`, so the list silently stops holding the word you wrote.

The lists are not split by language. `dotted` merges English and French into
one alternation and measures clean, because the words do not collide.

## `commands`

Which model does each part of a spoken command. The router matches what you
said to a capability; `spelling` and `catch_all` are two of the things it can
pick, which is why all three bind together.

| Key | What it decides | Default |
|---|---|---|
| `router` | "hey parrot, …" — the call you wait on with the pill on screen | the default model |
| `spelling` | reading a rule out of "Tasmin spells T A S M E E N" | the default model |
| `catch_all` | an instruction no capability covers; `false` refuses them | the default model |

Keep `router` local for as long as you can. It runs on every "hey parrot", it
is timed in tenths of a second, and it sees every word you say.

`spelling` is the opposite case. It runs only when you ask, and reading loose
capitals out of speech is the job a small local model is worst at — so it is
the first one worth pointing somewhere bigger.

The KEEP/REVERT review is not here. It belongs to the `vocabulary` pipeline
stage that runs it, and binds there as `review:` — see
[pipelines.md](pipelines.md). It binds on the step, so two `vocabulary` steps
under different conditions can reach different models.

There is no `enabled:` key any more. A config that defines no `models:` calls
no model, which says the same thing and cannot fall out of step with itself.

## `models`, and pinning

`keep_loaded: true` pins the model in RAM at launch. Ollama otherwise drops it
after five minutes idle and the next command waits for a reload — measured
**6.7 s cold against 1.5 s warm**, so in practice almost every correction paid
for one. The cost is the model sitting in memory for as long as the app runs:
9.6 GB for `gemma4:e4b`. On a 16 GB Mac, turn it off. On 32 GB, do not. It is
an Ollama setting; the other protocols have nothing to pin.

`default: true` marks the model everything falls back to — a `prompt:`
transform that names none, and any binding left unwritten. With one model it is
implied. With several, exactly one must claim it: none and more than one are
both refused rather than guessed at.

## `models`

Every model this config can reach, under a name you choose. The name is the
only thing a transform mentions.

```yaml
models:
  gpt:
    api: openai
    model: gpt-5.6-luna
    endpoint: https://api.openai.com/v1
    reasoning: off
    timeout_seconds: 30

  claude:
    api: anthropic
    model: claude-sonnet-5
    reasoning: off

  fast:
    api: openai              # Ollama's own OpenAI surface, same server
    endpoint: http://localhost:11434/v1
    model: gpt-oss:20b
```

| Key | What it is |
|---|---|
| `api` | The protocol: `ollama`, `openai` or `anthropic`. Not the vendor — everyone else speaks one of the three. |
| `model` | The model id, as that provider spells it. |
| `endpoint` | Where to send it. Left out, the default for the protocol. |
| `api_key` | Where the key is — see below. Omit it for the keychain. Not needed by `ollama`. |
| `reasoning` | `off`, `minimal`, `low`, `medium` or `high`. |
| `temperature` | Sent only if you write it. The reasoning models reject it. |
| `max_tokens` | Replaces whatever budget the caller worked out. |
| `timeout_seconds` | How long before the transcript is let through untouched. |
| `keep_loaded` | Ollama only. |
| `params` | Put into the request body untouched — see below. |

### `reasoning` is one ladder

Five rungs that mean the same thing everywhere. Each protocol maps them to
whatever it actually has:

| | `off` | `low`, `medium`, `high` |
|---|---|---|
| `ollama` | `think: false` | `think: <rung>` |
| `openai` | `reasoning_effort: none` | `reasoning_effort: <rung>` |
| `anthropic` | thinking disabled | adaptive thinking, `effort: <rung>` |

`minimal` is OpenAI's own rung; on Anthropic it is sent as `low`. A provider
with no such knob gets nothing extra in the body rather than an error.

Reasoning text never reaches your document. `reasoning_content` is not read,
Anthropic thinking blocks are skipped, and a `<think>` block inlined into the
answer is cut out — which some OpenAI-compatible servers do.

### `params` reaches everything else

Merged into the request body last, unchecked. It is what makes a provider this
app has never been run against usable without a new release:

```yaml
  deepseek:
    api: openai
    endpoint: https://api.deepseek.com/v1
    model: deepseek-chat
    params:
      top_p: 0.9
```

A key here replaces whatever the envelope worked out under the same name, and
`null` **removes** it:

```yaml
    params:
      reasoning_effort: null    # this server has no such field
```

That is the way out of any field this app sends by default and a given server
refuses. One special case is handled without it: naming `max_tokens` removes
the `max_completion_tokens` that goes out by default, for a server that only
knows the older name.

### Where the key comes from

Leave `api_key:` out. A model whose `api` is not `ollama` and which names no
key reads your keychain, and nothing about the key goes in `config.yaml`:

```yaml
models:
  gpt:
    api: openai
    model: gpt-5.6-luna
```

The first time the app loads a config like that, it asks for the key and puts
it in the keychain. Declining is fine — the model stays unusable, a transform
naming it declines with your transcript untouched, and the menu says so until
you add one. From a terminal:

```
ParrotFlow --set-key gpt              # prompts, and does not echo
printf '%s' "$KEY" | ParrotFlow --set-key gpt
ParrotFlow --set-key gpt --forget
```

The key is read from stdin, never from an argument, so it stays out of `ps` and
out of your shell history.

Keys are stored under the service `ParrotFlow`, or `ParrotFlow Dev` for the dev
build, with the model's own name as the account. The dev and release apps
therefore never see each other's keys, the same split as `~/.config/parrotflow`
and `~/.config/parrotflow-dev`.

**Keychain access follows the code signature.** The installed app is signed and
keeps its access across upgrades. A `swift build` binary is not, so macOS asks
you to allow it — once per build, because an unsigned binary's identity changes
every compile. Use `file:` during development if that gets tiring.

`api_key:` still takes a reference for the setups that need one:

| Written | Read from |
|---|---|
| *omitted* | the keychain, for any `api` but `ollama` |
| `keychain` | the keychain, said out loud |
| `env:OPENAI_API_KEY` | the environment |
| `file:~/.config/parrotflow/openai.key` | that file, trimmed |
| anything else | taken as the key itself |

ParrotFlow launches from Finder, which hands it none of your shell's
environment — so `env:` works for `--pipeline` and `--eval` and is empty in the
app. `file:` is the form that works in both. A key written in full works too,
and `--check-config` announces it as plain text in your config every time.

### Naming one on a transform

```yaml
transforms:
  - name: terse
    description: shorten text without losing anything it says
    model: gpt
    prompt: |
      …

  - name: plan
    description: turn what I said into a short plan
    model:
      use: gpt          # a name from `models:`
      reasoning: low    # gpt is `off` by default; this prompt gets to think
      max_tokens: 800
    prompt: |
      …
```

The mapping form may change `reasoning`, `temperature`, `max_tokens`,
`timeout_seconds` and `params` — the settings of one call. It may not change
`api`, `model`, `endpoint` or `api_key`: a different connection is another
entry in `models:`, not an override buried in a transform. Writing one there is
refused by name.

A name nothing defines falls back to the default model rather than failing.
`--check-config` refuses it by name — a typo should cost you the model you
meant, never the sentence.

### Failing open

Every way a model call goes wrong leaves the transcript exactly as it arrived:
no key, an expired key, a rate limit, a timeout, a dead network. This is the
same rule Ollama has always had here, and a cloud model needs it more, not
less.

## `updates`

One call a day to GitHub's release API — no account, nothing about you, nothing
about what you dictate.

The number is a waiting period, not a frequency: `-1` never asks, `0` offers a
release the day it is published, `7` only offers one that has existed for a
week. `0` is the default.

A wait has a point — a bad release is one that gets noticed and pulled, and a
week of distance means your Mac never saw it. Set `after_days: 7` if you want
that; the default takes the release the day it ships.

When one is offered you get a panel with the release notes and three answers:
**Update and restart**, which downloads, checks and replaces the app; **Skip
this version**, which never offers that version again; and **Later**. A dev
build offers the install command instead of the button — see
[distribution.md](distribution.md#updates).

## `commands.catch_all`

Do what was asked even when no transform description matches: "hey parrot, use
the 24 hour clock". A remark that was never an instruction is still refused,
and you see every result before it replaces anything. `false` goes back to a
fixed menu of transforms; a model name runs it on that model.

It was `free_form: true` at the top level. It is here because it is one of the
router's answers rather than a setting of its own, and because it is the case
that most deserves its own model — the free-form prompt is where a small local
one is measured at its ceiling.

## `audio.speech_gate`

Skips clips with no speech in them, so a key pressed by accident costs nothing.
Gated on speech being *present*, not on how much — a one-word dictation is a
real one.

## `audio.second_opinion`

Decodes the clip a second time, with silence added at both ends, and keeps that
decode when it reaches further into the audio than the first one did. On by
default: every dictation pays about 100ms so that the ~2% that lose words stop
losing them. Set it to `false` to keep the 100ms. A config written from an
older template carries `second_opinion: false` explicitly and keeps it.

**What it fixes.** Parakeet predicts a token and a duration at every step — how
many encoder frames to skip before it looks again. A frame is 80ms and the
model may skip 4 of them, so one prediction can pass over 320ms of audio
without examining it. Words inside a skipped span are never seen. They are not
mis-heard; they are not looked at. The result is a dictation that quietly loses
its ending, or loses words mid-sentence. Measured rate: 3 of 150 random live
dictations, about 2%.

**Why a second decode and not a check.** Nothing in the output says a span was
skipped, because the decoder leaves no record of frames it never examined. Five
signals were measured over the archive — the timing gap to the last speech, how
much of the speech span the words cover, tokens per second, decoder confidence,
and the longest stretch of detected speech with no word on it. All five put the
broken clips inside the healthy distribution, and on the last one the broken
clips score *better* than the median healthy clip. Padding the clip moves the
speech against the frame grid, so a different set of frames gets skipped. That
is the only thing that finds it.

**When the second decode wins.** Three guards. It has to reach further into the
clip than the first pass did, it has to say everything the first pass said in
order before it says anything new, and it has to actually add words.

The first two are shared with the long-pause retry. The second is what stops a
recovered ending being paid for with a silently rewritten opening. It also
refuses some genuinely good recoveries. That is the trade: nobody re-reads the
part that was already right.

The third guard is this setting's own. A decode that says the same words is
still a different decode — a different token split, different casing — and
swapping one in buys nothing. Over 60 archived clips it was the only thing the
second opinion ever did, on 2 of them: "RXV" for "RX V", and "red rock roadmap"
for "Red Rock Roadmap". With the guard in, those 60 clips come back identical
with the setting on and off.

Two pads are tried, so two decodes can clear all three guards. The one that
recovered the most words wins. Reach cannot separate them — a word running past
the end of the clip is clamped back to the clip's length, and on a short clip
every decode lands there.

**What it costs.** Two padded decodes — 0.5s and 1.0s of silence, the same
ladder the empty-decode retry uses — run at the same time as the first pass,
each on its own decoder. The model weights are shared, so the extra memory is
about 12MB per decode, not another copy of the ~1GB model. Measured on a 1.86s
clip, release build, 9 runs each: 138ms median for the first pass alone, 238ms
median for all three together. One decode costs about 140ms, so running them
one after another would cost roughly three times as much.

Needs `speech_gate`, which is what reads the clip as samples. With the gate off
this setting does nothing, and `--check-config` says so. Clips too long to fit
one decoder window with the padding on are left to the first pass.

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

`sound_volume` is how loud the chimes are, from 0 to 1, on top of system
volume. Default 0.3. The macOS system sounds are mixed to be heard once, as an
alert; dictation plays them several times a sentence, and at 1.0 that is a lot
of chime for something you already know happened. Set it to 1.0 for the alert
level. Values outside the range are clamped.

**Where the pill appears.** Next to the place your words are about to go, so you
can see where they are headed before you have said any of them. Where the app
will not say where that is, it sits at the bottom of the screen instead. That is
where it always used to be.

Terminals split two ways, and it is worth knowing which one you are in. A pane
running a full-screen program shows only what fits on the screen. Claude Code,
vim and less all work this way, and the pill follows your words there. A pane
sitting at an ordinary shell prompt keeps everything you have run in it, and the
pill goes to the bottom of the screen.

A rewrite that lands says nothing. The text is the confirmation — it changes
where you are already looking, with the pill sitting under it — so a notice
would be describing what you just watched happen. A chime plays and the log
records it. Every way of *not* landing still speaks: nothing to change, the app
refused the edit, the words went to the clipboard instead.

`correct_offer` is what the pill does after a dictation. It stays where it
is and names what can be done to the words, one chip per command:
`Vocabulary` first, then every transform with `offer: true` — see
[pipelines.md](pipelines.md#offer-and-key-or-getting-on-the-pill).
`Vocabulary` opens the teach-a-word panel over what was just dictated; a transform rewrites it
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
| a chip's letter — `V`, `G` | Runs that command |
| a click on a chip | Runs that command |
| a click anywhere else | Dismisses, and reaches whatever you clicked untouched |
| any other key | Dismisses, and reaches whatever it was headed for untouched |
| `esc` | Dismisses |
| `↩` | Dismisses, and reaches the app underneath untouched |
| the dictation hotkey | Starts the next dictation, exactly as before |

It fades rather than vanishing. It stands at full strength for four seconds,
thins out over the next two, and then it is gone. The keys, the click, and the
chips work the whole way down — the fading only says how long is left. Putting
the pointer on the pill stops the clock, and taking it off starts the six
seconds again. Any of the endings above takes the pill at once.

**The letters are taken from every app for those six seconds.** The pill
never holds keyboard focus, so it swallows a chip's own letter system-wide or
it does not get it at all. Only that bare letter runs a command — a letter
with a modifier on it is somebody else's shortcut and is left alone, `⌘C`
still copies and `⇧G` still types a capital G. Every other key you press ends
the offer instead, the same as clicking anywhere but the pill does, and is
passed straight through: it still lands wherever it was headed. So a dictation
followed straight away by a sentence starting with `V` or `G` runs a command
on that first keystroke — the offer is up, and that is still its letter — but
every keystroke after it is safe, because the offer is already gone. Pick a
chip's letter with that in mind: one you are unlikely to start a word with
right after dictating.

Off by setting it to `false`. Then no key is taken at any time.

### `confidence` — how sure the decoder was

Off by default. Set `feedback.confidence: true` and the offer carries the
sentence you just dictated above the chips, one colour per word: white where
the decoder was sure, then amber, then scarlet where it was not.

It needs `correct_offer`. There is no offer to draw it on without one.

**There is no published threshold this could be read against.** Parakeet gives
one probability per token and documents nothing about what a value means.
NVIDIA's own guidance for NeMo is that a raw probability is a weak correctness
signal and that the operating point has to be found on your own data. So the
colours are anchored on percentiles of the archive in `trace.jsonl` — the
median word scores 0.995 and 68% sit at 1.0, so a ramp over the raw 0–1 scale
would paint the whole sentence white. White is the top 75% of words, amber is
around the bottom 10%, scarlet is the bottom 1%. Those numbers came from one
person's voice and one microphone; `docs/cli.md` has the `jq` for measuring
your own.

Under the sentence sits one number: the decoder's own confidence for the whole
utterance, printed raw. It is `ASRResult.confidence`, the mean over the tokens,
the same value a pipeline condition reads as `asr.confidence` and the same one
`trace.jsonl` records.

It takes the same three colours as the words but not the same numbers. A mean
over every token moves in a far narrower range than one word does: over 16,513
dictations here it runs 0.73 at p1, 0.83 at p10 and 0.93 at the median. So its
bands are the percentiles of that column — white above 0.89, amber around 0.83,
scarlet at 0.73 and below. On the word bands three dictations in four would
print white and the colour would say nothing.

Read it knowing it barely moves. Of the dictations holding a word below the
amber band, only 13% fall under its own p10. A sentence with one bad name in it
still scores near 0.93 — the word colour catches that, and this number does
not.

A grey word is one with no reading at all: nothing the decoder said became it.
That happens where a stage inserted a word — the question mark a punctuation
pass added, a sentence a prompt rewrote whole. It is rare: 19 dictations in
15,394 have one. A word the vocabulary or a substitution *replaced* is not
grey — it takes the score of the decoded word it replaced, because that is the
same piece of audio, and a name corrected from a shaky decode is exactly the
word worth colouring.

The pill grows to hold the sentence: up to 640pt wide and three lines, then it
truncates. That is a lot of pill after every dictation, which is why this is
off unless you ask for it. It is worth turning on for a while to learn which
words your own dictation is weak at, and turning off again.

### `low_confidence` — when the words may not be your words

On by default, unlike `confidence`. A dictation that went fine costs nothing.

```yaml
feedback:
  low_confidence:
    sentence: 0.80   # the decode was poor overall
    word: 0.50       # and it holds a word this bad
```

When both trip, the pill comes up amber — washed ground, amber rim, amber glow
— and carries one line above the chips: `This may not be what you said`, then
the word. The colour is the signal. The line says what it means.

It needs `correct_offer`. It does not need `confidence`: the coloured sentence
and the score are a separate, off-by-default view for tuning, and the warning
is meant to work without them.

**Both, not either.** Each threshold alone is noise. A mean over every token
stays high through one mangled name — over 16,640 dictations here, one where
the vocabulary pass had to fix a name scores a median 0.931 and one where it
did not scores 0.931, identically. And one low word is ordinary: a fifth of all
dictations hold a word under 0.40, usually a clipped `the` or a trailing `uh`
that changes nothing. What is worth stopping for is a decode that is poor
throughout *and* holds a word the decoder could not place.

At the defaults that is 3.9% of dictations on this machine — about one in 26.
The earlier either-one rule was 21.8%, better than one in five.

| | rate |
|---|---|
| `sentence: 0.85`, `word: 0.50` | 11.0% |
| `sentence: 0.80`, `word: 0.50` | 3.9% |
| `sentence: 0.80`, `word: 0.40` | 3.2% |
| `sentence: 0.75`, `word: 0.50` | 1.1% |

Zero for either turns the warning off.

**The reflex Return is held.** For 1.5 seconds after a warned dictation lands,
a bare Return is taken instead of typed: the pill turns scarlet and says
`Enter held · check what was written, then press it again`. The one after it
goes through.

```yaml
feedback:
  low_confidence:
    hold_return: 1.5   # seconds; 0 lets every Return through
```

The number is what makes this a guard rather than a mode. What it catches is
the Return already on its way down as the words land, before anything has been
read. Past a second and a half, pressing Return is a decision — the warning is
still on screen, and the key goes through anyway.

Four more things bound it. It only arms on the 3.9% of dictations that raised
the warning. It takes one key and disarms itself as it takes it, inside the
tap, so nothing downstream can hold a keyboard even if it hangs. It only takes
a bare Return — `⌘↩`, which is how most chat apps send, goes straight through.
And it cannot outlive the offer: the tap is destroyed with the pill.

It rides on the same `CGEvent` tap the offer's letters use, so it needs Input
Monitoring in System Settings. Without that grant the tap is created and fed
nothing — the log says so at every offer, and Return simply works as usual. A
terminal with Secure Event Input on blocks it the same way.

Set it to `0` to keep the warning and let every Return through.

**Words the vocabulary pass wrote do not count.** A substituted word carries the
score of the decode it replaced — see `confidence` above — and that score is low
by definition, because a shaky decode is what made the pass fire. Measured here,
38.8% of the words substitutions replaced were under 0.60 against 9.9% of words
generally. Without this rule the warning would shout loudest about the names the
app has just fixed for you.

Worth knowing: at the defaults this rule changes nothing. All 651 warnings in
the archive fire either way, because a decode poor enough to be under 0.80
always holds a second bad word besides the substituted one. Loosen `sentence`
to 0.90 and it starts to matter — 117 warnings suppressed there.

**It cannot catch a confident mistake.** Confidence says how sure the decoder
was, not whether it was right. The same archive has the vocabulary pass
correcting words the decoder scored 0.987 and 1.000. A low score is good
evidence something is wrong; a high one is not evidence anything is right.

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

- [pipelines.md](pipelines.md) — `pipeline:`, `transforms:`, conditions, apps
- [corrections.md](corrections.md) — teaching it a word, spoken corrections
- [cli.md](cli.md) — validating a config, and testing a change without speaking
- [permissions.md](permissions.md) — what needs Accessibility and what does not
