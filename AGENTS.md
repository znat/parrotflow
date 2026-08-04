# Notes for agents

You are most likely here for one of three jobs. Each has a page written for it;
this file is the router.

| Job | Read | Then |
|---|---|---|
| Install ParrotFlow on someone's Mac | [docs/setup.md](docs/setup.md) | Follow it in order. It expects to be followed, not summarised. |
| Configure it — hotkey, languages, replacements, updates | [docs/configuration.md](docs/configuration.md) | Verify with `--check-config` before saying it is done. |
| Write or improve a rewrite — a prompt, a pipeline stage, a substitution table, a script | [docs/authoring.md](docs/authoring.md) | Score it against the case set for the thing you touched. |

The full map is [docs/README.md](docs/README.md).

## Rules that hold across all three

**Validate with the binary, not by reading the file.**

```sh
PF=/Applications/ParrotFlow.app/Contents/MacOS/ParrotFlow

$PF --check-config                                  # what will actually run
$PF --pipeline <file.yaml> "<text>" --app <name>    # a stage, without a mic
$PF --replace "<text>"                              # the substitution tables
$PF --route "<what someone would say>"              # which transform that reaches
```

`--check-config` reports what survived parsing, which is not what the file
says. Everything else is in [docs/cli.md](docs/cli.md).

**Never change a prompt or a pattern without scoring it.** Every rewrite in
this repo has a case set in `tests/` and a runner in `scripts/`. Get the number
before, change one thing, get it after. "It looks better" is how a change fixes
the example in front of you and breaks two you are not looking at.

**Fail open.** A stage that errors, times out or finds no model must leave the
transcript exactly as it arrived. Test it by stopping Ollama and running the
pipeline again — the sentence should come through untouched. Losing a stage
costs a rewrite; losing a sentence costs the sentence.

**Prefer a table or a script to a prompt.** A substitution costs nothing, a
script costs a process start, a model call costs about a second and a half warm
and nearly seven cold. Measured here: the same model scores 68% asked to
rewrite a sentence and 8/8 asked only to identify which words matter, with a
script doing the rest. Split the job before reaching for a bigger prompt.

**A stage that costs a model call needs a condition.** `when:`, `unless:` or
`app:`, so it is skipped on the transcripts that never needed it.

**Say out loud what executes.** A `command:` transform makes `config.yaml` run
a program. If you add one, tell the person whose machine it runs on, in the
same breath as telling them it works.

**Write commit subjects with a type.** `feat:`, `fix:` and `perf:` cut
releases; anything else does not. A subject without one is invisible to the
release machinery and gets no warning. `make hooks` refuses it locally — see
[docs/development.md](docs/development.md).

## What not to change without being asked

- `Config.defaultYAML` and `config.example.yaml` are what a new install gets,
  and several check scripts read the real file rather than a fixture. Changing
  a default changes what everyone gets on first launch.
- The stop lists in the `dotted` pattern and in `examples/transforms/code_identifiers/code_identifiers.py`
  are judgements about how people speak, tuned against scored sets. They are
  meant to be edited by the person whose speech they describe — not silently
  widened to make one sentence work.
