# ParrotFlow verification map

This directory is the maintained source for verifying what ParrotFlow does for a
user. Read this index first. Then use the matching feature file as the recipe.

ParrotFlow has two surfaces. The real one is live dictation: hold a hotkey,
speak, and the text is pasted into the frontmost app. An agent cannot drive
it. The second is the command line of the same binary, built from this tree.
It runs the same pipeline code on text you give it. It is not the same as
live dictation: there is no microphone, no hotkey, no paste, no frontmost app.

## Baseline preconditions

- `swift build -c release` has run in the repo root, and `scripts/doctor.sh`
  says `✓ matches the tree`.
- A run is open: `RUN=$(.claude/skills/verify-parrotflow/scripts/start.sh)`.
  It made a fresh scratch config dir with `mktemp -d`. Every call goes through
  `scripts/pf.sh`, which sets `PARROTFLOW_CONFIG_DIR` to that dir.
- The scratch config starts empty. The first call of the run fills it with the
  shipped defaults (`config.example.yaml` and `built-in/`): every flag except
  `--version`, `--seed-config`, `--panel-sheet`, `--tutorial-sheet` and
  `--tour-film` loads the config at start (`Sources/ParrotFlow/main.swift`,
  the `Trace.directory` line). `--pipeline` loads it too, though its fixture
  decides the stages.
- Never drive the installed apps. Never run the binary without a flag.

## Driving conventions

- Paths in these files are relative to the repo root. `pf.sh` runs the binary
  from the repo root, so `tests/pipelines/...` resolves.
- Commands are literal. Keep quotes and flags as written.
- Use `--quiet` when you compare a result. It prints only the result line.
- Use `--vars` with `--quiet` to assert on what a stage published. The result
  is still the last line.
- One call at a time. No loops over the binary in a proof: each call writes
  to the user's release log.

## Proof and skip reporting

- Proof is the files `pf.sh` writes: `NN-<label>.cmd`, `.out`, `.err`,
  `.exit`, `.log`. Quote the command, the result line, and the exit code.
- A proof includes `state-diff.txt` from `finish.sh`: what changed in shared
  state outside the scratch dir.
- Exit code `0` means the command did its job. `--eval` exits `0` at any
  score; read the numbers.
- Report a feature you could not reach with the command you tried and the
  missing precondition (no Ollama, user not available).
- A CLI run never proves live dictation. Say which surface you verified.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph on what the user
sees. Then exactly four H2 sections, in this order: `Sub-features`, `How to get
to it (user POV)`, `Driving it with pf.sh`, `Gotchas`. The driving section
starts with `Preconditions:` and pairs each action with a command and an
observable result.

## Features

- [Pipeline on a sentence](./pipeline.md): `--pipeline` runs a fixture's
  stages on text. Vocabulary, replace tables, conditions, variables. No model.
  This is the default proof feature.
- [Replacement rules](./replace.md): `--replace` runs the config's own
  pipeline with every model stage off.
- [Config check and seeding](./check-config.md): `--check-config` and
  `--seed-config` report what a config adds up to.
- [Routing a spoken instruction](./route.md): `--route --keyed` (no model) and
  `--route` (Ollama) name the transform an instruction reaches.
- [Scoring a transform](./eval.md): `--eval <transform>` scores a transform
  against its case set.
- [Transcribing a clip](./transcribe.md): `--transcribe <wav>`. Loads a ~1 GB
  model. Ask the user first.
- [Live dictation](./live-dictation.md): user-driven only. Hotkey, mic, paste.
