<div align="center">

# ParrotFlow

### Local dictation for people who type for a living

An open source alternative to Wispr Flow. No account, no subscription, no cloud —
your audio never leaves your Mac.

[![Release](https://img.shields.io/github/v/release/znat/parrotflow?color=0c8c7c&label=release)](https://github.com/znat/parrotflow/releases)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B%20·%20Apple%20silicon-1d1d1f?logo=apple&logoColor=white)
![License Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-0c8c7c)
![No cloud](https://img.shields.io/badge/audio-never%20leaves%20your%20Mac-39cdb6)

**[Install](#install)** · [Documentation](docs/README.md)

</div>

---

Hold <kbd>right ⌥</kbd>, say the words on the left, let go. What lands at your
cursor is on the right.

| You say | You get |
| --- | --- |
| *"read user dot name"* | `read user.name` |
| *"lis config point port"* | `lis config.port` |
| *"the meeting is December 3rd"* | `the meeting is 3/12` |
| *"on a dépensé deux cents euros"* | `on a dépensé 200 euros` |
| *"a typescript function named get user profile"* | `a typescript function named getUserProfile` |
| *"a python constant called max retry count"* | `a python constant called MAX_RETRY_COUNT` |

Every row is a case in [`tests/`](tests/), scored on each change rather than
checked by eye — including the ones that still fail, which stay in the sets.

## Install

**Requires** an Apple Silicon Mac on macOS 14 or later.

> [!TIP]
> **Let an agent do it.** Paste the block below into Claude Code, or anything
> else that can run shell commands. It installs the app, walks you through the
> two macOS permissions, and confirms transcription works before it hands over.
> About five minutes.

```text
Set up ParrotFlow on my Mac by following
https://raw.githubusercontent.com/znat/parrotflow/main/docs/setup.md
```

Or install it yourself. The app is one command; the permissions that follow are
in [docs/setup.md](docs/setup.md).

```sh
curl -fsSL https://raw.githubusercontent.com/znat/parrotflow/main/scripts/install.sh | sh
```

Your first dictation downloads the speech model, about 1.2 GB. Everything after
that is immediate.

## Talk to it

**Teach it a word.** Say *"hey parrot, elastic search is one word and takes a
capital E"* and it is right from then on. A fuzzy pass catches the spellings you
never taught it, so *"super bays"* still reaches `Supabase`.

**Give it an instruction.** Select some text and say *"hey parrot, use Slack
handles"* or *"hey parrot, format the function names for TypeScript"*. You see
the result before it replaces anything.

**It runs on your own hardware.** Parakeet TDT v3 on the Neural Engine turns
speech into text — that part needs nothing else, and a normal sentence lands
about a second after you let go. Teaching it words and giving it instructions
ask a Gemma 4B through your own [Ollama](https://ollama.com); dictation works
without it.

## Program it

Other dictation tools let you configure what someone else decided to expose.
Here the transcript runs through stages you wrote, in the order you chose, each
one conditional on the text, the language, or the app you dictated into:

```yaml
pipelines:
  default:
    - replacements                      # the names you taught it
    - numbers                           # "two hundred forty-three" -> 243
    - transform: dotted                 # "user point name" -> user.name
      app: /term|ghostty|code|cursor/   #   but only where you write code
```

A stage is a regex, a prompt to the local model, or **a script of yours** —
transcript on stdin, rewrite on stdout, in any language. If one fails, times
out, or the model is not running, your sentence comes through exactly as you
said it.

It is a text file, not a settings pane: `~/.config/parrotflow/config.yaml`,
reloaded on save, commentable, diffable, committable. No paid tier, no
telemetry.

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
