<div align="center">

<img src="Resources/parrot.svg" width="56" alt="">

# ParrotFlow

### A local, fast and programmable dictation app shaped around your voice and your work



[![Release](https://img.shields.io/github/v/release/znat/parrotflow?color=0c8c7c&label=release)](https://github.com/znat/parrotflow/releases)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B%20·%20Apple%20silicon-1d1d1f?logo=apple&logoColor=white)
![License Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-0c8c7c)
![No cloud](https://img.shields.io/badge/audio-never%20leaves%20your%20Mac-39cdb6)

**[Install](#install)** · [Documentation](docs/README.md)

</div>

---

- **Dictate anywhere.** Click where you'd normally type, hold `⌘ Right`,
  speak, release. The text lands almost instantly.
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
  - name: Fix grammar
    description: fix grammar
    offer: true        # put a chip on the pill after every dictation
    key: g             # press G to run it
    prompt: Fix grammar and punctuation...
```

Say *"hey parrot, fix the grammar"*, or press `G` on the pill after any
dictation, and it does.

See a more complete example, tuned and scored against real transcripts, in
[examples/transforms/grammar](examples/transforms/grammar).

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

    - name: gram                              # not in the pipeline: on demand only
      description: fix grammar
      offer: true                             # put a chip on the pill
      key: g                                  # press G to run it
      prompt: Fix grammar and punctuation...
```

`hesitations` and `priorities` run on every dictation, because they are in the
pipeline. `gram` is not, so it only runs when you ask: hold right `⌘` and say
*"hey parrot, fix the grammar"*, or press `G` on the pill after any
dictation.

More examples, each with its own test cases, in
[examples/transforms](examples/transforms):

- [code_identifiers](examples/transforms/code_identifiers) — spoken names
  cased for the language, *"a python function called max retries"* →
  `max_retries`.
- [repetitions](examples/transforms/repetitions) — drops disfluencies, a word
  said twice by accident: *"the the prompt"* → *"the prompt"*.
- [grammar](examples/transforms/grammar), [email](examples/transforms/email),
  [punctuation](examples/transforms/punctuation),
  [priorities](examples/transforms/priorities),
  [dotted](examples/transforms/dotted), and
  [verify_names](examples/transforms/verify_names).

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
