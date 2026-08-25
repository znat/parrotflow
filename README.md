<div align="center">

<img src="Resources/parrot.svg" width="56" alt="">

# ParrotFlow

### A local, fast and programmable dictation app shaped around your voice and your work

[![Release](https://img.shields.io/github/v/release/znat/parrotflow?color=0c8c7c&label=release)](https://github.com/znat/parrotflow/releases)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B%20·%20Apple%20silicon-1d1d1f?logo=apple&logoColor=white)
![License Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-0c8c7c)

**[Install](#install)** · [Documentation](docs/README.md)

<img src="Resources/hero.gif" width="760" alt="Three dictations. Versal becomes
Vercel in Slack; in a terminal, P one becomes P1 and max retries becomes
max_retries; in Mail, pressing S drops a spoken correction.">

</div>

---
<table>
<tr><td><strong>Dictate anywhere</strong></td><td>Click where you'd normally type, hold <code>⌘ Right</code>, speak, release. The text lands almost instantly.</td></tr>
<tr><td><strong>Local-first</strong></td><td>Ships with Parakeet for speech and a small Gemma model for rewrites. Both run on your Mac.</td></tr>
<tr><td><strong>Learns your vocabulary</strong></td><td>Teammates, internal jargon, products, vendor names. Correct one out loud, once, and it stays fixed.</td></tr>
<tr><td><strong>Fast</strong></td><td>Text lands at your cursor in under half a second for most dictations, up to about two seconds for harder ones.</td></tr>
<tr><td><strong>Programmable and promptable</strong></td><td>Build transforms out of substitutions, prompts, or scripts, and arrange them into your own pipeline.</td></tr>
</table>

## Install

ParrotFlow requires Apple silicon and macOS 14 or later.

```sh
curl -fsSL https://raw.githubusercontent.com/znat/parrotflow/main/scripts/install.sh | sh
```

This also downloads Parakeet, the speech model, about 1.2 GB.

Spoken commands and the vocabulary check need a language model as well, and that part is optional. Run one on your own Mac with [Ollama](https://ollama.com/download) (e.g. [Gemma4](https://ollama.com/library/gemma4:e4b-mlx)), or use a hosted one (e.g. OpenAI).

---

## Not everything you say needs a remote AI provider

[Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), NVIDIA's state-of-the-art, open-source speech model, runs locally and fast. Most dictations land in under half a second.

Everything else — the hotkey, the pipeline, every transform — lives in one
plain YAML file, `config.yaml`. Edit it by hand, or with your coding agent.
To find it: the 🦜 icon in the menu bar → Settings → Edit Config…

<br>

### Transcriptions follow your rules

**Regex or script transforms** run in milliseconds, for a fixed rule: issue
links, priority codes, date formats, dropping "um" and "uh".

```yaml
transforms:
  - name: github_refs
    description: spoken PR and issue numbers as links
    replace:
      '[#$1](https://github.com/OWNER/REPO/pull/$1)':
        ['/\b(?:pull request|PR)\s*(?:(?:number|nr|no|hash)\s+)?#?(\d+)\b/']
```

*"P R one two three is ready"* → *"[#123](https://github.com/OWNER/REPO/pull/123) is ready"*

In Slack that arrives as a clickable **#123**, not as brackets — see
[bullets, bold and links](docs/configuration.md#bullets-bold-and-links). The
spoken digits are already `123` by the time this runs: the built-in `numbers`
stage turned "one two three" into it first.

```yaml
transforms:
  - name: priorities
    description: spoken priority levels as P1 to P4
    replace:
      "P1": ['/\bp\s*(?:one)\b/']
      "P2": ['/\bp\s*(?:two)\b/']
      "P3": ['/\bp\s*(?:three)\b/']
      "P4": ['/\bp\s*(?:four)\b/']
```

*"that's a P one, this one's a P two"* → *"that's a P1, this one's a P2"*

A rule too fiddly for a regex is a script instead. This one runs after the
built-in `numbers` stage, which already turned "fourteen" into `14`:

```yaml
transforms:
  - name: dates
    description: spoken dates as DD/MM
    command: dates.py
```

```python
#!/usr/bin/env python3
import re, sys
months = ("january", "february", "march", "april", "may", "june",
          "july", "august", "september", "october", "november", "december")
text = sys.stdin.read()
for n, month in enumerate(months, start=1):
    text = re.sub(
        rf"\b{month}\s+(\d{{1,2}})\b",
        lambda m: f"{int(m.group(1)):02d}/{n:02d}",
        text, flags=re.I,
    )
sys.stdout.write(text)
```

*"let's meet march 14"* → *"let's meet 14/03"*

Both are rules. Both cost nothing and run on every dictation. A pipeline says
in what order:

```yaml
transcription:
  pipelines:
    default:
      - numbers                 # "twenty two" -> 22, so dates has digits to work with
      - transform: priorities
      - transform: dates
```

*"let's resolve the P one before february twenty two"* →
*"let's resolve the P1 before 22/02"*

![Dictating "let's resolve the P one before february twenty two", and the
priorities and dates rules turning it into "let's resolve the P1 before
22/02"](Resources/rules.gif)

<br>

### Use language models only when they're needed

Name every model you want to reach, once:

```yaml
models:
  gemma:               # on your Mac, through Ollama
    api: ollama
    model: gemma4:e4b-mlx
    default: true      # what a transform runs on when it names no model
  gpt:                 # remote, for the harder jobs
    api: openai
    model: gpt-5.6-luna
```

**A small local model**, like Gemma, does quick, solid rewrites on your Mac:
grammar, tone, structure.

```yaml
transforms:
  - name: grammar
    description: fix grammar and punctuation
    model: gemma       # stays on your Mac
    offer: true        # put a chip on the pill after every dictation
    key: g             # press G to run it
    prompt: Fix grammar and punctuation...
```

Say *"hey parrot, fix the grammar"*, or press `G` on the pill after any
dictation. A version tuned and scored against real transcripts is in
[examples/transforms/grammar](examples/transforms/grammar).

You can run the grammar fix only in chat and mail apps, and not in coding
agents, to avoid the latency:

```yaml
transcription:
  pipelines:
    default:
      - transform: grammar
        app: /slack|outlook/    # Grammar only checked in Slack and Outlook
```

The pill shows the app your words are going to, and that is what the step is
scoped on.

![Dictating into Slack: the pill shows the Slack icon, the grammar step runs,
and "the panel dont show up sometimes" becomes "The panel doesn't show up
sometimes."](Resources/grammar.gif)

**A remote model** is worth it for the harder jobs. A spoken correction
needs judgment a fixed rule does not have, and GPT-5.6 Luna does this
efficiently, at low cost.

```yaml
transforms:
  - name: self_correction
    description: correct me — drop what I said by mistake and keep what I meant
    model: gpt
    offer: true       # put a chip on the pill
    key: s            # press S to run it
    prompt: |
      The speaker corrected themselves out loud. Keep only what they meant
      to say. Return only the corrected text.
```

Say *"hey parrot, correct me"*, or press `S` on the pill after any
dictation. A longer version, tuned and scored against real transcripts, is in
[examples/transforms/self_correction](examples/transforms/self_correction).

![Dictating "let's ship Friday, no wait, Thursday", then pressing S on the pill
to get "let's ship Thursday"](Resources/self-correct.gif)

<br>

### The parrot learns your vocabulary

Colleagues' names, internal jargon, acronyms, vendor names — the words a
general speech model has never heard. Correct one once and it stays fixed.

Press `V` on the pill after any dictation and say what the word should be.

![Teaching the app that Versailles means Vercel, then dictating a sentence
with Versailles twice: one becomes Vercel, the castle is left
alone](Resources/vocabulary.gif)

> *"deploying the app on Versailles, visiting the Versailles castle"* →
> *"deploying the app on Vercel, visiting the Versailles castle"*

Enabling `review` allows an LLM to intelligently decide when a vocabulary
term should be applied: there is no Vercel Castle, and Versailles won't
deploy your apps.

```yaml
transcription:
  pipelines:
    default:
      - stage: vocabulary
        review: gpt    # Currently, Gemma struggles in some cases
      - numbers
```

### Build your own pipeline

Your transcriptions can follow a complex workflow based on how you work, with
several steps and conditions.

```yaml
transcription:
  pipelines:
    default:
      - stage: vocabulary
        review: gemma                 # names first, before anything edits the text
      - numbers                       # "fourteen" -> 14, so dates has digits to work with
      - transform: priorities         # "P one" -> P1, free, every dictation
      - transform: dates              # "march 14" -> 14/03, free, every dictation
      - transform: grammar
        app: /slack|outlook/          # only there; a terminal gets the raw transcript
```

`self_correction` is not in the list. It deletes words, so it runs only when
you ask: hold `⌘` and say *"hey parrot, correct me"*, or press `S` on the pill
after any dictation.

A transform that returns Markdown reaches Slack as real formatting rather than
as `**stars**` — a list as a list, and `[#123](https://…)` as a link you can
click. Emphasis on its own is left alone: a lone `**bold**` in a sentence stays
exactly as you said it, so an ordinary dictation is never reinterpreted. Other
apps get plain text until they are measured, and plain text rides along either
way, so nothing is lost to an app that does not take it. See
[bullets, bold and links](docs/configuration.md#bullets-bold-and-links).

### More examples

Each with its own test cases, in [examples/transforms](examples/transforms):

- [code_identifiers](examples/transforms/code_identifiers) — spoken names
  cased for the language, *"a python function called max retries"* →
  `max_retries`.
- [repetitions](examples/transforms/repetitions) — drops disfluencies, a word
  said twice by accident: *"the the prompt"* → *"the prompt"*.
- [punctuation](examples/transforms/punctuation) — spoken marks as
  punctuation, *"is that true question mark"* → *"is that true?"*.
- [self_correction](examples/transforms/self_correction) — the prompt above,
  and the 89 cases it is scored on: *"my config my vocabulary"* →
  *"my vocabulary"*.

[Pipelines](docs/pipelines.md) · [Writing a transform](docs/authoring.md) ·
[Where the time goes](docs/architecture.md#where-the-time-goes)

---

## Documentation

> [!TIP]
> Point your coding agent at this
> repo and say what you want. It can edit `config.yaml`, write a transform's
> prompt or script, and harden it against real test cases before you trust
> it — start at [AGENTS.md](AGENTS.md).

**[docs/README.md](docs/README.md)** — configuration, pipelines, transforms, the
command line, permissions, architecture.

**[CONTRIBUTING.md](CONTRIBUTING.md)** — build it, test it, send a change.
Questions that are not bugs go to
[Discussions](https://github.com/znat/parrotflow/discussions).

---

## License

[Apache 2.0](LICENSE).

The parrot is by Md Moniruzzaman, from the [Noun
Project](https://thenounproject.com), used under CC BY. The outline is his; the
plumage is ours — see [docs/development.md](docs/development.md#the-icons).

<div align="center">

macOS dictation · offline speech to text · local voice typing · open source
Wispr Flow alternative · privacy-first transcription · Parakeet · Ollama

</div>
