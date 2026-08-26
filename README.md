<div align="center">

<img src="Resources/parrot.svg" width="56" alt="">

# ParrotFlow

### A fast and programmable dictation app you can shape around your work

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

[Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), NVIDIA's speech model, runs locally and fast. Most dictations land in under half a second.

Everything else — the hotkey, the pipeline, every transform — lives in one
plain YAML file, `config.yaml` you can edit it by hand or with your coding agent.
> To find it: the 🦜 icon in the menu bar → Settings → Edit Config…

<br>

### Transcriptions follow your rules

Use regexes, scripts or prompts to customize your dictations.



**Example: add PR links to your dictations**

```yaml
transforms:
  - name: github_refs
    description: spoken PR and issue numbers as links
    replace:
      '[#$1](https://github.com/OWNER/REPO/pull/$1)':
        ['/\b(?:pull request|PR)\s*(?:(?:number|nr|no|hash)\s+)?#?(\d+)\b/']
```

*"merged P R one two three, ready to ship"* → *"merged **#123**, ready to
ship"*, where #123 links straight to the pull request.

The rule writes a Markdown link and the paste turns it into a real one — see
[bullets, bold and links](docs/configuration.md#bullets-bold-and-links). The
spoken digits are already `123` by then: the built-in `numbers` stage turned
"one two three" into it first.

![Dictating "merged P R one two three, ready to ship" and the github_refs rule
turning PR123 into a clickable #123 that points at
github.com/znat/parrotflow/pull/123](Resources/refs.gif)

**Example: Automatically add Slack handles.**

```yaml
transforms:
  - name: slack_handles
    description: use Slack handles for the people named
    command: slack_handles.py
```
Where `slack_handles.py` is:

```python
#!/usr/bin/env python3
# roster.json sits beside this file: {"Ada": "@ada.lovelace", ...}
import json, pathlib, re, sys

roster = json.loads((pathlib.Path(__file__).parent / "roster.json").read_text())
text = sys.stdin.read()

for name, handle in roster.items():
    # Skip a name already written as a handle, and a name used as an
    # ordinary word — "mark it as done" is a verb.
    text = re.sub(rf"(?<![@\w.]){re.escape(name)}\b", handle, text, flags=re.I)

sys.stdout.write(text)
```
![Dictating "Ada and Mark are both on it", and the slack_handles script turning
the names into "@ada.lovelace and @mark.reyes"](Resources/handles.gif)

**Combine transforms in a pipeline**

```yaml
transcription:
  pipeline:
    - numbers                 # "one two three" -> 123, so github_refs has digits
    - transform: github_refs
    - transform: slack_handles
```

![Dictating "merged P R one two three, Ada can you take a look", and the
github_refs and slack_handles rules turning it into "merged #123,
@ada.lovelace can you take a look"](Resources/rules.gif)

<br>

### Use language models only when they're needed

Add models to your config:

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
dictation.

![Dictating into Slack: the pill shows the Slack icon, the grammar step runs,
and "the panel dont show up sometimes" becomes "The panel doesn't show up
sometimes."](Resources/grammar.gif)


Or you can run the grammar fix in chat and mail apps (but not in coding agents, for instance) for all dictations:

```yaml
transcription:
  pipeline:
    - transform: grammar
      app: /slack|outlook/    # Grammar only checked in Slack and Outlook
```

> See [examples/transforms/grammar](examples/transforms/grammar) for a more elaborate version.

**A remote model** for harder jobs. A spoken correction
needs judgment a fixed rule or a too small local model does not have.

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

### Vocabulary

Colleagues' names, internal jargon, acronyms, vendor names — the words a
general speech model has never heard. Correct it a few times and it stays fixed.

Press `V` on the pill after any dictation and say what the word should be.

![Teaching the app that Versailles means Vercel, then dictating a sentence
with Versailles twice: one becomes Vercel, the castle is left
alone](Resources/vocabulary.gif)


Enabling `review` allows an LLM to intelligently decide when a vocabulary
term should be applied: there is no Vercel Castle, and Versailles won't
deploy your apps.

```yaml
transcription:
  pipeline:
    - stage: vocabulary
      review: gpt
    - numbers
```

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
