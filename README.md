<div align="center">

# ParrotFlow

### Local dictation for people who type for a living

Hold a key, talk, and the text lands where your cursor is — editor, terminal,
browser, chat. Nothing you say leaves your Mac.

[![Release](https://img.shields.io/github/v/release/znat/parrotflow?color=0c8c7c&label=release)](https://github.com/znat/parrotflow/releases)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B%20·%20Apple%20silicon-1d1d1f?logo=apple&logoColor=white)
![License MIT](https://img.shields.io/badge/license-MIT-0c8c7c)
![No cloud](https://img.shields.io/badge/audio-never%20leaves%20your%20Mac-39cdb6)

**[Install](#install) · [Documentation](docs/README.md) · [Pipelines](docs/pipelines.md) · [Writing a transform](docs/authoring.md)**

</div>

---

An **open source, programmable** alternative to Wispr Flow, for developers and
anyone else who would rather configure a tool than be configured by it.

Speech recognition runs on the Neural Engine. Everything the app then does to
your words — fixing the names it mishears, turning spoken numbers into digits,
writing `user.name` when you say "user dot name" — is a line in a config file
you own, in an order you choose, and you can add your own in a substitution
table, a prompt, or a script in any language. There is no account, no API key
and no server, which is the whole point: most of what a developer dictates is a
bug report, a customer name, or a half-finished idea about their own product.

Two things use the network, and neither carries your audio or your text: the
speech model downloads once on first use, and once a day the app asks GitHub
whether a newer version exists. `updates.after_days: -1` stops the second one.

## Install

**Requires** an Apple Silicon Mac on macOS 14 or later.

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
   other apps. `transcription.insert_mode: clipboard` needs no permission at
   all, and you press ⌘V yourself.
3. Hold **right ⌥**, say something, let go.

The first dictation downloads the speech model (about 1.2 GB) and takes a
couple of minutes. Everything after that is immediate.

Spoken corrections and `prompt:` transforms need [Ollama](https://ollama.com)
0.22 or later with `ollama pull gemma4:e4b`. Optional — dictation works without
it.

Building from source: [docs/development.md](docs/development.md).

## Why this one

### It is fast

A normal sentence is text about a second after you let go of the key, and the
rewrites that fix your vocabulary cost nothing measurable on top. Only a stage
that asks the local model costs real time, which is why any stage can be made
conditional — see [where the time goes](docs/architecture.md#where-the-time-goes).

### It gets your vocabulary right

Speech models mishear exactly the words you use most: library names, CLI tools,
your teammates' names. Teach it one and it is right from then on — select the
word, hold the hotkey, and say:

```
"hey parrot, Tasmin spells T A S M E E N"
"hey parrot, Elastic search is one word"
"hey parrot, Mathieu ne prend qu'un seul t"
```

The rule is written to your `config.yaml`, and a fuzzy pass catches renderings
you never taught it, so "super bays" still reaches Supabase.

Nothing here is tuned by eye. Every rewrite the app ships has a scored case set
in `tests/` — 62 spelling corrections, 97 number cases, 56 dotted paths, 75
spoken identifiers — and the cases it *cannot* do are kept in the sets, failing,
rather than dropped to make a number look better.

### It is programmable, which is the actual difference

A transcript runs through a pipeline you define. Stages can be conditional on
the text, on the language, or on the app you dictated into:

```yaml
pipelines:
  default:
    - replacements                      # the names you taught it
    - fuzzy                             # and the ways they come out wrong
    - numbers                           # "two hundred forty-three" -> 243
    - transform: dotted                 # "user point name" -> user.name
      app: /term|ghostty|code|cursor/   #   but only where you write code
    - transform: prose                  # a local model tidies the sentence
      when: /\b(genre|du coup|basically)\b/   #   only when it needs it
```

A transform is a substitution table, a prompt to the local model, **or a
program of yours** — transcript on stdin, rewrite on stdout, in whatever
language you like. That contract is why the app stops needing new features:

```yaml
transforms:
  - name: code_identifiers
    description: spoken names as identifiers
    command: code_identifiers.py    # ships as an example; it is yours to edit
```

"a python function called max retries" comes out as
`…called max_retries`, in the convention of the language you named. If a
transform fails, times out, or the model is not running, your sentence comes
through exactly as you said it — a dictation tool can afford to skip a stage
and cannot afford to lose a sentence.

Full reference: [docs/pipelines.md](docs/pipelines.md). Writing your own, with
the measurement loop: [docs/authoring.md](docs/authoring.md).

### It is a text file, not a settings pane

`~/.config/parrotflow/config.yaml`, reloaded on save, commentable, diffable,
committable. `--check-config` tells you what the app would actually run before
you trust it. MIT, no paid tier, no telemetry.

## Documentation

**[docs/README.md](docs/README.md)** — configuration, pipelines, writing a
transform, the command line, permissions, architecture, and why it is built
this way.

Working on this with an agent? [AGENTS.md](AGENTS.md) is the entry point.

## License

MIT.

<div align="center">

macOS dictation · offline speech to text · local voice typing · open source
Wispr Flow alternative · privacy-first transcription · Parakeet · Ollama

</div>
