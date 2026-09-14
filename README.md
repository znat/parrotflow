<div align="center">

<img src="Resources/parrot.svg" width="56" alt="">

# ParrotFlow

### Local and extensible dictation you can shape around your work

[![Release](https://img.shields.io/github/v/release/znat/parrotflow?color=0c8c7c&label=release)](https://github.com/znat/parrotflow/releases)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B%20·%20Apple%20silicon-1d1d1f?logo=apple&logoColor=white)
![License Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-0c8c7c)

**[Install](#install)** · [Documentation](docs/README.md)

<img src="Resources/hero.webp" width="680" alt="Four dictations into one field.
Mick is corrected to Mik and the app offers to remember it, then Mik to Mick;
the last two sentences name both people and both are written right. Then one
Slack message: PR 478 arrives as a link, and Siobhan becomes @Sio.">

</div>

<div align="center">

<pre>brew install znat/tap/parrotflow</pre>

macOS 15+ &nbsp;·&nbsp; Apple silicon &nbsp;·&nbsp; 3 GB &nbsp;·&nbsp; <a href="#install">other ways to install</a>

</div>

---

<div align="center">

Most *local* dictation apps simply wrap Parakeet or Whisper (ASRs) in a prompt<br>that sends your text to the cloud to repair the ASR output.

**ParrotFlow uses the language properties of very small models**, such as mmBERT,<br>the Qwen3 0.6B family and spaCy, to apply your custom vocabulary terms<br>in context, correct hesitations and repair raw ASR output.

</div>

<br>

<div align="center">

<table align="center">
<thead>
<tr><th></th><th>ParrotFlow</th><th>Local<sup>1</sup></th><th>Cloud<sup>2</sup></th></tr>
</thead>
<tbody>
<tr><td>🔒 Truly local</td><td align="center">✅</td><td align="center">✅</td><td align="center">❌</td></tr>
<tr><td>✍️ Keeps your wording<sup>3</sup> (doesn't rewrite with an LLM)</td><td align="center">✅</td><td align="center">❌</td><td align="center">❌</td></tr>
<tr><td>📖 Understands how to use your vocabulary in context</td><td align="center">✅</td><td align="center">❌</td><td align="center">❌</td></tr>
<tr><td>🧩 Extensible with your own rules and scripts</td><td align="center">✅</td><td align="center">❌</td><td align="center">❌</td></tr>
<tr><td>🔑 No cloud key for any built-in step</td><td align="center">✅</td><td align="center">❌<sup>4</sup></td><td align="center">❌</td></tr>
</tbody>
</table>

<sub><sup>1</sup> Handy, VoiceInk, MacWhisper, FluidVoice. &nbsp;<sup>2</sup> Wispr Flow, Aqua, Willow. &nbsp;<sup>3</sup> Built-in steps never rewrite. A prompt step that does is yours to add. &nbsp;<sup>4</sup> FluidVoice bundles a local rewrite model.</sub>

</div>

<br>

<div align="center">

### Built in

Every dictation runs these steps. They are lines in `config.yaml`.<br>Turn one off, reorder the pipeline, or test a step against its own case file.

<table align="center">
<tr>
<td align="center">📖</td><td><b>Vocabulary</b></td>
<td>Your terms, applied in context.<br><i>"Marc reviewed the PR"</i> writes <b>Marc</b> &nbsp;·&nbsp; <i>"mark it as done"</i> is left alone</td>
</tr>
<tr>
<td align="center">🔇</td><td><b>Hesitations, repeats<br>and false starts</b></td>
<td><code>um</code> and <code>uh</code>, a word said twice, a phrase begun again.<br><i>"so uh in the ter in the terminal run the the tests"</i><br>→ <i>"so in the terminal run the tests"</i></td>
</tr>
<tr>
<td align="center">🔢</td><td><b>Numbers, dates<br>and times</b></td>
<td>Written as digits, English and French.<br><i>"March third at quarter past nine"</i> → <i>"March 3 at 9:15"</i><br><i>"two hundred forty three tests, ninety seven percent"</i> → <i>"243 tests, 97%"</i></td>
</tr>
<tr>
<td align="center">✂️</td><td><b>Sentence repair</b></td>
<td>A pause makes the recogniser end the sentence early.<br>This reads the boundary and removes the mark.<br><i>"I ran the tests on. Both branches"</i> → <i>"I ran the tests on both branches"</i></td>
</tr>
</table>

</div>

Everything lives in one config folder — a `config.yaml` and your own scripts,
easy to hack with your coding agent.

> To find it: the 🦜 icon in the menu bar → Settings → Edit Config…

---


## Install

ParrotFlow needs Apple silicon and macOS 15+. It uses about 3 GB of disk
and 1 GB of memory.

```sh
brew install znat/tap/parrotflow
```

<details>
<summary>Not using <a href="https://brew.sh">Homebrew</a>?</summary>

<br>

The script installs the same app, in the same place.

```sh
curl -fsSL https://raw.githubusercontent.com/znat/parrotflow/main/scripts/install.sh | sh
```

</details>


---


### Extensible with rules, prompts and scripts

What makes ParrotFlow truly unique is that you can fully customize it with regular expressions, prompts or scripts.
All you have to do is point your coding agent to your `config.yaml` file and ask what you need.

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
spoken digits are already `123` by then: the shipped `numbers_en` transform turned
"one two three" into it first.


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

**Combine transforms in a pipeline**

```yaml
transcription:
  pipeline:
    - transform: numbers_en   # "one two three" -> 123, so github_refs has digits
    - transform: github_refs
    - transform: slack_handles
```

<br>

### Use language models only when they're needed

You can use LLMs for prompt transforms, for example fixing grammar, formatting your dictation as an email, bulletizing an enumeration, anything.
> Note: An LLM is not required to benefit from all the features above.

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

**A small local model** does quick, solid rewrites on your Mac: grammar, tone,
structure. Gemma through [Ollama](https://ollama.com/download) is the one this
example names.

```yaml
transforms:
  - name: grammar
    description: fix grammar and punctuation
    model: gemma       # stays on your Mac
    offer: true        # put a chip on the pill after every dictation
    key: g             # press G to run it
    say: [Fix grammar] # Hold the hotkey, say "Fix grammar"
    prompt: Fix grammar and punctuation...
```

> See [examples/transforms/grammar](examples/transforms/grammar) for a more elaborate version.

Or you can run the grammar fix in chat and mail apps (but not in coding agents, for instance) for all dictations:

```yaml
transcription:
  pipeline:
    - transform: grammar
      app: /slack|outlook/    # Grammar only checked in Slack and Outlook
```

You can define very granular conditions for pipeline stages — on the text so
far, on the app being dictated into, or on your own variables. See
[Conditions](docs/pipelines.md#conditions) and [Apps](docs/pipelines.md#apps).

### More examples

Each with its own test cases, in [examples/transforms](examples/transforms).
`fillers`, `dates`, `numbers` and `disfluency` are in the pipeline a new install
gets; the rest ship with no step — see [What ships
unwired](docs/pipelines.md#what-ships-unwired).

- [numbers](examples/transforms/numbers) — spoken numbers as digits, one
  script per language: *"two hundred forty-three"* → `243`,
  *"soixante-quinze pour cent"* → `75%`.
- [disfluency](examples/transforms/disfluency) — what you did not mean to say,
  taken out: a word said twice, *"the the prompt"* → *"the prompt"*; a phrase
  begun again, *"in the ter in the terminal"*; and a marker that carries
  nothing, *"so use like you know five"* → *"so use five"*. Only that last one
  wants a parse; the rest are string work.
- [dates](examples/transforms/dates) — a dictated date or time in the shape it
  was said, *"at ten fifteen"* → *"at 10:15"*. One script per language, above
  the numbers step; English is in the pipeline and French is two lines of
  config away.

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
