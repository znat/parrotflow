<div align="center">

<img src="Resources/logo.svg" width="88" height="88" alt="ParrotFlow logo">

# ParrotFlow

## Dictation for builders

Local dictation you can extend with rules, prompts, and code.

Small, specialized models keep dictation fast, accurate, and on your Mac.
No LLM cleanup required—unless you want it.

**[Install ParrotFlow](#install)** · [Explore the extensions](docs/guides/extensions.md) · [Read the docs](docs/README.md)

<sub>Apple silicon · macOS 15+ · Open source · GPL-3.0</sub>

</div>

## Install

```sh
brew install znat/tap/parrotflow
```

Local dictation needs no cloud account or API key. Models download during setup;
optional prompt transforms may need additional models or a provider you configure.

<details>
<summary>Install without Homebrew</summary>

The installer script downloads the app and starts setup:

```sh
curl -fsSL https://raw.githubusercontent.com/znat/parrotflow/main/scripts/install.sh | sh
```

[Releases](https://github.com/znat/parrotflow/releases) · [Setup and permissions](docs/guides/setup.md)

</details>

<br>

https://github.com/user-attachments/assets/d00a56ea-3b7f-403b-8021-d858e3be6797

<div align="center">

<sub>The native app, in motion. Configuration on the left. What it changes on the right.</sub>

</div>

## Useful from the first dictation

**The right term in the right context.** Your teammate Mik writes code.
Your friend Mick plays guitar. Teach ParrotFlow your vocabulary and the context
that distinguishes one name from another.

**Less cleanup after you speak.** Turn “the the prompt” into “the prompt,”
“nine fifteen AM” into “9:15 AM,” and “forty nine dollars and ninety nine cents”
into “$49.99.”

**Your wording, with the changes you choose.** Built-in cleanup uses targeted
rules and small local models. A broader rewrite—grammar, tone, or structure—is
a prompt transform you control.

[How vocabulary works](docs/guides/vocabulary.md) · [See the built-in transforms](docs/guides/extensions.md#what-works-out-of-the-box)

## Make it yours

The PR links and Slack mentions in the demo are examples of what you can build.
They use the same extension points available to you.

| When you want to… | Reach for… |
| --- | --- |
| Replace a phrase or recognize a pattern | A YAML replacement, with optional regex |
| Look up a handle or apply your own logic | A script: text in, text out |
| Fix grammar or reshape a message | A prompt, using a model you choose |

Run a transform automatically, offer it after dictation, or invoke it with a key
or your voice. Scope it to an app, a language, or a condition on the text.

### A spoken PR number becomes a link where formatted text is supported

This replacement turns `PR 478` into `#478`, linked to your repository in
destinations that accept formatted text:

```yaml
transforms:
  - name: github_refs
    description: spoken PR and issue numbers as links
    replace:
      '[#$1](https://github.com/OWNER/REPO/pull/$1)':
        ['/\b(?:pull request|PR)\s*(?:(?:number|nr|no|hash)\s+)?#?(\d+)\b/']
```

Set `OWNER/REPO` to your repository and add `github_refs` to your transcription
pipeline. The existing number-normalization stage can run before it.

That same approach can link your issue tracker, normalize project terminology,
or format the identifiers you say every day.

<details>
<summary><strong>Give a script a keyboard shortcut</strong></summary>

The shipped Slack transform offers an **S** action after dictation:

```yaml
transforms:
  - name: slack_mentions
    description: turn people's names into Slack mentions
    display: Slack Mentions
    offer: true
    key: s
    say: [slack mentions, mentions]
    command: slack_mentions.py
```

Fill the roster in `transforms/slack_mentions/slack_mentions.py` beside your
config. Dictate a name, then press **S** to replace it with the configured handle.
It changes the text; it does not send the message.

A `command:` transform runs a program on your Mac. Use scripts you trust.

[Write your own script transform](docs/guides/transforms.md#scripts)

</details>

<details>
<summary><strong>Compose transforms into a pipeline</strong></summary>

Order matters: normalize spoken numbers before turning them into PR links.

```yaml
transcription:
  pipeline:
    - transform: numbers_en
    - transform: github_refs
```

This is an excerpt, not a replacement for your whole pipeline. Keep the existing
vocabulary and cleanup stages you want.

Conditions let you apply a transform only where it belongs—for example, a grammar
prompt in chat and mail, but not in your coding agent.

[Explore pipelines and conditions](docs/guides/pipelines.md)

</details>

<details>
<summary><strong>Add a prompt when the job needs a language model</strong></summary>

Grammar, an email draft, a shorter message, or a list: prompt transforms handle
changes that need more than a replacement or a script.

Choose a local model through Ollama, or configure a remote provider. A remote
prompt sends the text it processes to that provider; local dictation does not
require that choice.

The shipped [grammar transform](docs/guides/extensions.md#grammar) is a starting point,
with its own test cases.

[Configure models](docs/guides/configuration.md#models-and-privacy) · [Write a prompt transform](docs/guides/transforms.md#prompts)

</details>

<br>

## Bring your coding agent

Point your agent at [AGENTS.md](AGENTS.md), describe the behavior you want, and
ask it to implement and test a transform. The repository includes authoring
instructions, command-line checks, and evaluation cases.

Start with one small thing you keep correcting by hand.

## Go deeper

[Configure ParrotFlow](docs/guides/configuration.md) ·
[Write a transform](docs/guides/transforms.md) ·
[Use the CLI](docs/guides/cli.md) ·
[Understand the architecture](docs/guides/architecture.md)

[All documentation](docs/README.md) ·
[Contribute](CONTRIBUTING.md) ·
[Ask a question](https://github.com/znat/parrotflow/discussions)

---

<div align="center">

**Make dictation part of your toolkit.**

[Install ParrotFlow](#install) · [Build your first extension](docs/guides/transforms.md)

</div>
