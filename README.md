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

## What else it does

**It writes code the way you say it.** *"read user dot name"* → `read user.name`,
*"a python constant called max retry count"* → `MAX_RETRY_COUNT`. In terminals
and editors only — *"point"* is an ordinary word in an email.

**It learns your vocabulary.** Say *"hey parrot, elastic search is one word and
takes a capital E"* and it is right from then on. A fuzzy pass catches spellings
you never taught it, so *"super bays"* still reaches `Supabase`.

**Slack mentions, when you ask for them.** *"hey parrot, use Slack mentions"* →
`tell @marie.dupont the deadline moved`. Never automatic: a wrong handle pings
the wrong person.

**Spoken numbers and dates, English or French.** *"two hundred forty-three"* →
`243`. *"on a dépensé deux cents euros"* → `on a dépensé 200 euros`.

**Nothing leaves your Mac.** Parakeet TDT v3 on the Neural Engine, about a
second for a sentence. The stages that need judgement ask a Gemma 4B on your own
[Ollama](https://ollama.com); dictation works without it.

Every rewrite here has a scored case set in [`tests/`](tests/) — including the
cases it still fails, which stay in rather than being dropped to flatter a
number.

## Program it

Other dictation tools let you configure what someone else decided to expose.
Here it is a list you own. This is the whole of what produced the table above,
with the app patterns shortened:

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

Reorder it, delete a line, scope a stage to one app. A stage is a regex, a
prompt to the local model, or **a script of yours** — transcript on stdin,
rewrite on stdout, in any language. If one fails, times out, or the model is not
running, your sentence comes through exactly as you said it.

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
