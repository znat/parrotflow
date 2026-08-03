<div align="center">

# ParrotFlow

### Local dictation for people who type for a living

Open source Wispr Flow alternative. No need to create an account or subscribe. Install, hold a key, talk, and get work done.

[![Release](https://img.shields.io/github/v/release/znat/parrotflow?color=0c8c7c&label=release)](https://github.com/znat/parrotflow/releases)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B%20·%20Apple%20silicon-1d1d1f?logo=apple&logoColor=white)
![License Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-0c8c7c)
![No cloud](https://img.shields.io/badge/audio-never%20leaves%20your%20Mac-39cdb6)

**[Install](#install) · [Documentation](docs/README.md) · [Pipelines](docs/pipelines.md) · [Writing a transform](docs/authoring.md)**

</div>

---

A fully featured open source alternative to Wispr Flow:


- **Dictate anywhere** — hold a key, talk, and the text lands at your cursor:
  editor, terminal, browser, chat.
- **Small, efficient local models** — Parakeet TDT v3 runs on the Neural Engine,
  and anything needing judgement asks a Gemma 4B model through Ollama. Both fit in
  RAM you already have.
- **Really Fast** — a normal sentence is text about a second after you let go of the
  key. Follow ups are conditional or activated with voice commands, so you pay for it where you want it.
- **Your vocabulary, taught out loud** — say "hey parrot, elastic search is one
  word and takes a capital E" and it is right from then on, with a fuzzy pass for the spellings you
  never taught it.
- **Spoken numbers, paths and identifiers** — "two hundred forty-three" → `243`,
  "user point name" → `user.name`, "a function called max retries" →
  `max_retries`.
- **Spoken commands** — select some text and say "hey parrot, use Slack handles"
  or "hey parrot, format the function names for TypeScript". A transform that
  describes the job runs; otherwise the model does what was asked, and you see
  the result before it replaces anything.
- **A programmable pipeline** — every stage of your own pipeline is a `transform`. A `transform` can be a regex, a prompt, or a script in any language running on your Mac. No limits.
- **A prompt tuner** — so a 4B model on your Mac get a chance to approximate frontier accuracy
  on a narrow text transform. Need a new prompt? Ask Claude to tune it with ParrotFlow's prompt tuner.

No account, no API key, no server. It uses local models and your audio or text
never leaves your Mac.

## Install

**Requires** an Apple Silicon Mac on macOS 14 or later.

Paste this into Claude Code, or any agent that can run shell commands:

```text
Set up ParrotFlow on my Mac by following
https://raw.githubusercontent.com/znat/parrotflow/main/docs/setup.md
```

It installs the app, walks you through the two macOS permissions, and confirms
transcription works. About five minutes.

By hand, the app itself is one command — the rest is in
[docs/setup.md](docs/setup.md):

```sh
curl -fsSL https://raw.githubusercontent.com/znat/parrotflow/main/scripts/install.sh | sh
```

## Why ParrotFlow

Other dictation tools let you configure what someone else decided to expose.
Here your transcript runs through stages you wrote, in the order you chose:

```yaml
pipelines:
  default:
    - replacements                      # the names you taught it
    - numbers                           # "two hundred forty-three" -> 243
    - transform: dotted                 # "user point name" -> user.name
      app: /term|ghostty|code|cursor/   #   but only where you write code
```

It is a text file, not a settings pane. `~/.config/parrotflow/config.yaml`,
reloaded on save, commentable, diffable, committable. Apache 2.0, no paid tier,
no telemetry.

Pipelines: [docs/pipelines.md](docs/pipelines.md) · Writing a transform:
[docs/authoring.md](docs/authoring.md) · Where the time goes:
[docs/architecture.md](docs/architecture.md#where-the-time-goes)

## Documentation

**[docs/README.md](docs/README.md)** — configuration, pipelines, transforms, the
command line, permissions, architecture. Working on this with an agent?
[AGENTS.md](AGENTS.md).

## License

[Apache 2.0](LICENSE).

<div align="center">

macOS dictation · offline speech to text · local voice typing · open source
Wispr Flow alternative · privacy-first transcription · Parakeet · Ollama

</div>
