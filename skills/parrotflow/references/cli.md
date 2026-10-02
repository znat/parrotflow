# The flags this skill uses

`$PF` is the `binary=` path from `scripts/pf.sh`. Every flag below runs and
exits. Use no other flag. With no flag at all, the binary starts a second copy
of the app.

Every command reads the config in `~/.config/parrotflow/` (the dev app:
`~/.config/parrotflow-dev/`). `PARROTFLOW_CONFIG_DIR=<dir>` points one command at
another folder. Use that for experiments, never in a shell profile. A command
run on an empty folder writes a fresh default config into it.

## Read

| Command | Answers |
|---|---|
| `"$PF" --check-config` | Is the config valid, and what will run? Exit 1 on an error. |
| `"$PF" --schema` | Every key, its type, default and help, as JSON Schema. Only when `pf.sh` says `schema=yes`. |
| `"$PF" --version` | The build's commit hash. The release number is in `pf.sh`'s `app_version=`. |
| `"$PF" --microphones` | Every microphone attached, the exact names `audio.microphones` matches, and which one wins now. |
| `"$PF" --bug-report` | Version, macOS, permissions, the whole `--check-config` and the last 50 log lines. Read `diagnose.md` first. |

`--check-config` cannot see Accessibility. macOS credits a check from a terminal
to the terminal, so it always looks missing there. The app writes the real
answer to its log at launch: `grep "launched —" ~/Library/Logs/ParrotFlow.log | tail -1`
(ask first: the log holds dictated text).

## Try a sentence

```sh
"$PF" --replace "<text>" --app "<App name>"
```

Runs the user's configured pipeline on one sentence, prompts skipped, and prints
the result. This is the main check after an edit. `--app` is the app to pretend
is in front. Without it, a step with an `app:` condition never runs. An empty
`--app ""` means no app was in front.

```sh
"$PF" --route "hey parrot, make that a list"     # which transform a spoken command reaches
"$PF" --route "use slack mentions" --keyed       # the tap-then-hold path, no model
"$PF" --prompt <name> "<instruction>" "<text>"   # one prompt transform from the config
```

`--route` and `--prompt` call the model when there is one. `--route --keyed`
does not.

## Score a transform

```sh
"$PF" --eval <name>                     # transforms/<name>/cases.yaml, or its tests: file
"$PF" --eval <name> --cases other.yaml  # another set in the same folder
"$PF" --eval <name> --probe <probe> --verbose
```

It runs the transform the config names, the same code the app runs. It prints
two halves: cases that must change, and cases that must stay as they were
(`keep`). Read both. A rewrite that changes well and keeps badly makes the user
proof-read every dictation. Exit 0 when it scored, whatever the number.

`cases.yaml`:

```yaml
# What counts as a case here, and what is out of scope.
cases:
  - probe: spoken
    input:  I'll go arrow left
    expect: I'll go → left
  - probe: keep
    input:  an arrow function       # no expect: it must come back unchanged
```

## A pipeline fixture

`--pipeline` runs a pipeline written in its own file, not the config. Use it
for a prompt stage, for `--vars`, and for the fail-open test.

```sh
"$PF" --pipeline <fixture.yaml> "<text>" --app "<App name>" [--vars] [--quiet] [--no-prompts] [--lang en,fr]
```

A fixture has no `transcription:` level. `languages`, `pipeline`, `transforms`,
`lists` and `models` sit at the top, written as in the config:

```yaml
languages: [en, fr]
pipeline:
  - transform: grammar
    app: /slack/
transforms:
  - name: grammar
    description: fix grammar
    model: gemma
    prompt: |
      Correct grammar and punctuation. Return only the text.
models:
  gemma: {api: ollama, model: "gemma4:e4b-mlx"}
```

In a fixture, name the model on each prompt transform with `model:`. A fixture
does not apply `default: true`, and a prompt with no `model:` fails with
`Model "" isn't installed`.

A fixture finds transform folders beside itself, in `transforms/`. So put it in
a scratch folder with a link to the real one:

```sh
mkdir -p /tmp/pf-try && ln -sfn "<config_dir>/transforms" /tmp/pf-try/transforms
```

Without that link, a `command:` the fixture cannot find stops `--pipeline` with
exit code 141 and no output.

`--vars` prints every variable the stages published, and a skipped stage names
the values that skipped it. `--no-prompts` skips model calls.

## Fail open

A stage that calls a model must leave the sentence unchanged when the model is
gone. Prove it without stopping the user's Ollama: copy the stage into a
fixture, give it `model: gone`, point that model at a port where nothing
listens, and run it.

```yaml
models:
  gone: {api: ollama, model: "gemma4:e4b-mlx", endpoint: "http://127.0.0.1:9"}
```

The `out:` line must equal the `in:` line. Run it once with the real model too,
so you know the fixture reaches a model at all. For a `command:` that calls a
model, do the same with whatever it calls.

## Words

```sh
"$PF" --learn "<heard>" "<written>"     # writes one rule to vocabulary.yaml
```

Back up `vocabulary.yaml` first. See `spoken-commands.md`.

## Only the user runs these

```sh
"$PF" --set-key <model>             # asks for an API key and stores it in the keychain
"$PF" --set-key <model> --forget    # removes it
```

The key is typed into the prompt, not passed as an argument. Give the user the
command. Never ask them to paste a key to you.
