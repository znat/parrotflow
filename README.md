<div align="center">

# ParrotFlow

### A local, programmable dictation tool, shaped around your voice and your work

An open source alternative to Wispr Flow. No account, no subscription, no cloud.
Your audio never leaves your Mac.

[![Release](https://img.shields.io/github/v/release/znat/parrotflow?color=0c8c7c&label=release)](https://github.com/znat/parrotflow/releases)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B%20·%20Apple%20silicon-1d1d1f?logo=apple&logoColor=white)
![License Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-0c8c7c)
![No cloud](https://img.shields.io/badge/audio-never%20leaves%20your%20Mac-39cdb6)

**[Install](#install)** · [Documentation](docs/README.md)

</div>

---

- **Local-first.** Ships with Parakeet for speech and a small Gemma model for
  rewrites. Both run on your Mac.
- **Learns your vocabulary.** Teammates, internal jargon, products, vendor
  names. Correct one out loud, once, and it stays fixed.
- **Fast.** Text lands at your cursor in under half a second for most
  dictations, up to about two seconds for harder ones.
- **Programmable and promptable.** Build transforms out of substitutions,
  prompts, or scripts, and arrange them into your own pipeline.

## Improve and adapt your dictation

A transform can be a substitution, a prompt, or a script. Here is one of each.

**A regex**, to drop hesitations:

```yaml
transforms:
  - name: hesitations
    description: drop filler words
    replace:
      "": ['/\b(?:u+m+|u+h+|erm+)\b,?\s*/']
```

*"so um, let's ship it"* → *"so, let's ship it"*

**A prompt**, to rewrite in a voice of your choosing:

```yaml
transforms:
  - name: pirate
    description: rewrite like a pirate
    offer: true        # put a chip on the pill after every dictation
    key: p             # press P to run it
    prompt: Rewrite as a pirate would say it. Keep the meaning. Return only the text.
```

Say *"hey parrot, make that sound like a pirate"*, or press `P` on the pill
after any dictation, and it does.

**A script**, for a rule that needs code:

```yaml
transforms:
  - name: priorities
    description: spoken priority levels as P1 to P4
    command: priorities.py
```

Where `priorities.py` looks like:

```python
#!/usr/bin/env python3
import re, sys
text = sys.stdin.read()
levels = ("one un", "two deux", "three trois", "four quatre")
for n, words in enumerate(levels, start=1):
    text = re.sub(r"\bp\s*(?:%s)\b" % words.replace(" ", "|"), f"P{n}", text, flags=re.I)
sys.stdout.write(text)
```

*"that's a P one, this one's a P two"* → *"that's a P1, this one's a P2"*

Put them in a pipeline, or leave them out of it:

```yaml
transcription:
  pipelines:
    default:
      - transform: hesitations                # drop filler words, every dictation
      - transform: priorities                 # "P one" -> P1, every dictation

  transforms:
    - name: hesitations
      description: drop filler words
      replace:
        "": ['/\b(?:u+m+|u+h+|erm+)\b,?\s*/']

    - name: priorities
      description: spoken priority levels as P1 to P4
      command: priorities.py

    - name: pirate                            # not in the pipeline: on demand only
      description: rewrite like a pirate
      offer: true                             # put a chip on the pill
      key: p                                  # press P to run it
      prompt: Rewrite as a pirate would say it. Keep the meaning. Return only the text.
```

`hesitations` and `priorities` run on every dictation, because they are in the
pipeline. `pirate` is not, so it only runs when you ask: hold the hotkey and say
*"hey parrot, rephrase as if I was a pirate"*, or press `P` on the pill after
any dictation.

[Pipelines](docs/pipelines.md) · [Writing a transform](docs/authoring.md) ·
[Where the time goes](docs/architecture.md#where-the-time-goes)

## Install

ParrotFlow requires Apple silicon and macOS 14 or later.

> [!TIP]
> Paste this in Claude Code or any coding agent to set up ParrotFlow.
>
> ```text
> Set up ParrotFlow on my Mac by following
> https://raw.githubusercontent.com/znat/parrotflow/main/docs/setup.md
> ```

Setup will install the Parakeet speech model (1.2 GB,
needed for dictation), and [Ollama](https://ollama.com/download) with a
small [Gemma4](https://ollama.com/library/gemma4:e4b-mlx) model.

## Documentation

**[docs/README.md](docs/README.md)** — configuration, pipelines, transforms, the
command line, permissions, architecture. Working on this with an agent?
[AGENTS.md](AGENTS.md).

## License

[Apache 2.0](LICENSE).

The parrot is by Md Moniruzzaman, from the [Noun
Project](https://thenounproject.com), used under CC BY. The outline is his; the
plumage is ours — see [docs/development.md](docs/development.md#the-icons).

<div align="center">

macOS dictation · offline speech to text · local voice typing · open source
Wispr Flow alternative · privacy-first transcription · Parakeet · Ollama

</div>
