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

You say it once, holding <kbd>right ⌥</kbd>:

> *"hi marie um the staging deploy is broken again can you take a look when you
> get a chance thanks nathan"*

What gets typed depends on the window it lands in.

| Where you were | What got typed |
| --- | --- |
| **A terminal**<br><sub>Ghostty, Warp, Claude Code</sub> | Hi marie the staging deploy is broken again can you take a look when you get a chance thanks nathan |
| **Slack** | Hi Marie, the staging deploy is broken again. Can you take a look when you get a chance? Thanks, Nathan. |
| **Outlook**<br><sub>Mail, Superhuman, Missive</sub> | Hi Marie,<br><br>The staging deploy is broken again. Can you take a look when you get a chance?<br><br>Thanks,<br>Nathan |

The terminal keeps your words and drops the *um*. Slack gets one clean
paragraph and no markup it cannot render. The mail window gets a greeting on
its own line and a signature on theirs. **That is the config it ships with**,
not one you have to write.

## Fast, and none of it leaves your Mac

Text at your cursor a second after you let go. Small models on hardware you own
— Parakeet on the Neural Engine, a Gemma 4B through your own
[Ollama](https://ollama.com). No account, no key, no bill.

## It gets your words right

*"read user dot name"* → `read user.name`. *"two hundred forty-three"* → `243`.
It mishears a name? Fix it out loud, once.

## There is no ceiling

Every stage is yours — a regex, a prompt, or a script in any language. This is
the whole of what produced the table above:

```yaml
pipelines:
  default:
    - replacements                       # the names you taught it
    - numbers                            # "two hundred forty-three" -> 243
    - transform: dotted                  # "user point name" -> user.name
      app: /term|ghostty|warp|slack/     #   but never in an email
    - transform: email                   # greeting, paragraphs, signature
      app: /mail|outlook|superhuman/
    - transform: slack                   # one paragraph, no markup
      app: /slack/
```

Or skip the file and just say it: *"hey parrot, use Slack mentions"*.

[Pipelines](docs/pipelines.md) · [Writing a transform](docs/authoring.md) ·
[Where the time goes](docs/architecture.md#where-the-time-goes)

## Install

**Requires** an Apple Silicon Mac on macOS 14 or later.

> [!TIP]
> **Let an agent do it.** Paste the block below into Claude Code, or any other agent.

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
