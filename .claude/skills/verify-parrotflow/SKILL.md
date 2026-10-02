---
name: verify-parrotflow
description: Verify ParrotFlow, the macOS dictation app, by building its binary from this tree and driving its command line (--pipeline, --replace, --check-config, --route, --eval, --transcribe) under a scratch config, with evidence kept outside the repo. Use when you need proof that a change works, before saying a feature works, or when the app's behaviour is in question. Live dictation (hotkey, mic, paste) is not agent-driveable; this skill says how to ask the user for it.
---

# Verify ParrotFlow

ParrotFlow is a menu bar app. The user holds a hotkey, speaks, and the text
is pasted into the frontmost app. That path needs a person: **live dictation
is not agent-driveable.** Two copies run all day on this Mac and the user is
using them. You must not touch them.

What you can drive is the command line of the same binary, built from this
tree. Each flag runs one part of the app and exits. It runs the real pipeline
code on text or a clip you give it. It has no hotkey, no microphone, no paste
and no frontmost app, so it is not the same as live dictation. Say which one
you verified.

The feature map is in [features/README.md](features/README.md). Read it, then
the feature file you need.

## Hard rules

- Never run `make run`, `make install`, `make stop`, `make uninstall`,
  `make uninstall-dev`, `make uninstall-release`, `make clean`,
  `make reset-permissions`, `make fresh-setup`, `make try-install`, or
  `scripts/install.sh`. They quit, replace or reset the user's apps.
- Never kill or signal a process you did not start. No `pkill`, no `kill` by
  name or pid. The live apps are `/Applications/ParrotFlowDev.app` and
  `/Applications/ParrotFlow.app`, plus the Dev app's Python `runner.py` child.
- Never run the binary with no flag. With no terminal attached, the bare
  binary starts a menu bar app as the release variant, a third live copy.
- Never run it without `PARROTFLOW_CONFIG_DIR` set to a fresh scratch dir. A
  bare run loads `~/.config/parrotflow/` and prunes its `transforms/built-in/`.
  `scripts/pf.sh` sets it for you; call the binary only through `pf.sh`.
- Never run flags that record, listen to keys, touch the clipboard, paste,
  read the frontmost app, write the keychain, download, or open surfaces:
  `--record`, `--microphones --set`, `--watch-modifiers`, `--watch-taps`,
  `--audio-recovery`, `--peek`, `--edit-test`, `--span-test`,
  `--clipboard-test`, `--paste-probe`, `--field-dump`, `--context-test`,
  `--set-key`, `--warm`, `--warm-models`, `--slot-model`, `--sentence-model`,
  `--phonemes`, `--setup-parsing`, `--update-check`, `--update-install`,
  `--panels`, and the image writers `--panel-sheet`, `--tutorial-sheet`,
  `--tour-film`, `--onboarding-film`. Never read another app's tree
  (`--tree-read`, `--tree-test`). `pf.sh` refuses all of these, and any flag
  not listed under Drive. `--panels` is useless anyway: nobody can
  see the screen, and `screencapture` fails (no Screen Recording grant).
- Never send keystrokes, clicks or Apple Events to an app the user works in.
- `--transcribe` loads a ~1 GB model. Ask the user first.
- Ollama: read-only checks only. Never pull a model. One model call at a time.
- Do not run `make test`, `scripts/check-routing.sh`,
  `scripts/check-pipeline.sh` or `scripts/check-replacements.sh` as part of a
  verification. Those scripts (and `make test`, which runs two of them) call
  the binary without `PARROTFLOW_CONFIG_DIR`. The binary loads the config at
  start, so they load the live release config and rewrite its
  `transforms/built-in/`.

## Launch

There is no server. Launch means build the binary once, from the repo root:

```sh
swift build -c release
```

The binary is `.build/release/ParrotFlow`, the same one `scripts/check-*.sh`
use. Ready means the build printed `Build complete!` and
`scripts/doctor.sh` says `✓ matches the tree`. A no-op build does not touch
the binary's mtime.

If the build fails with `unable to spawn process '.../metal'`, the Metal
toolchain moved after a reboot. Delete `.build/manifest.pif` and
`.build/out/Intermediates.noindex/XCBuildData` and build again (about two
minutes). If it still fails, report it.

Then open a run. It makes the evidence dir and the scratch config, and takes
a snapshot of shared state:

```sh
RUN=$(.claude/skills/verify-parrotflow/scripts/start.sh); echo "$RUN"
```

Shell variables do not survive between tool calls. Write the printed path
down and pass it literally to every later call.

Teardown is `finish.sh` (see Cleanup). Each CLI call exits by itself; there is
nothing else to stop.

## Doctor

Run this first, and again whenever something looks off. It only reads.

```sh
.claude/skills/verify-parrotflow/scripts/doctor.sh            # binary and live apps
.claude/skills/verify-parrotflow/scripts/doctor.sh --ollama   # also Ollama, for --route and prompt stages
```

It reports:

- **Binary vs tree.** `--version` prints `unstamped`: the bare SwiftPM binary
  has no build stamp. So it checks that no file under `Sources/`,
  `Package.swift` or `Package.resolved` is newer than the binary.
  `✗ stale` lists the newer files; rebuild. `built-in/` is read from the repo
  at run time, so a change there needs no rebuild.
- **Live instances.** pid, start time, path, child processes, and the log each
  one writes: `ParrotFlowDev.app` → `~/Library/Logs/ParrotFlow-Dev.log`,
  `ParrotFlow.app` → `~/Library/Logs/ParrotFlow.log`. Never signal them. A
  line `✗ a tree binary is running` means a copy of `.build/release/ParrotFlow`
  is up. If you started it with no flag, it is a menu bar app; tell the user.
- **Installed stamps.** The commit each installed app was built from.
  Compare with `git rev-parse --short HEAD`. Live dictation runs these, not
  the tree.
- **Ollama** (`--ollama`). `pulled:` is `/api/tags`, `loaded:` is `/api/ps`.
  The default config routes with `gemma4:e4b-mlx` and keeps it loaded. If it
  is not loaded, a model call loads it; ask first.

Exit `0` means fine. Exit `1` means stale binary, no binary, a binary that
fails `--version`, a stray tree binary, or Ollama down when asked.

## Drive

Every call goes through `pf.sh`, from the repo root:

```sh
.claude/skills/verify-parrotflow/scripts/pf.sh <run-dir> <label> --flag [args...]
```

It runs `.build/release/ParrotFlow` with `PARROTFLOW_CONFIG_DIR` set to the
run's scratch dir and the repo root as working dir, so `tests/pipelines/...`
resolves. It prints stdout and `exit=<code>`. It refuses a call with no flag,
with more than one mode flag, or with any flag outside the table below and
its modifiers (`--app`, `--quiet`, `--vars`, `--no-prompts`, `--keyed`,
`--cases`, `--probe`, `--verbose`, `--no-vocab`).

The default proof feature, with its expected result. It runs the vocabulary
stage, which loads the word vectors in the background and downloads them
(about 400 MB) if they are missing. First check that
`~/Library/Application Support/ParrotFlow/models/qwen3-embedding-0.6b-4bit`
exists. If it does not, ask the user before the call.

```sh
.claude/skills/verify-parrotflow/scripts/pf.sh <run-dir> pipeline-vocabulary --pipeline tests/pipelines/replacements.yaml "our app is deployed on Versailles" --app "" --quiet --vars
```

Exit `0`. The last line is `our app is deployed on Vercel`, and the output
has `var   vocabulary.protected = "Vercel"`. Other features and their exact
commands are in `features/`.

The flags, and what they need:

| Flag | Feature file | Needs |
|---|---|---|
| `--pipeline <fixture> "<text>"` | `pipeline.md` | nothing |
| `--replace "<text>"` | `replace.md` | `python3` |
| `--check-config`, `--seed-config` | `check-config.md` | nothing |
| `--route "<text>" --keyed` | `route.md` | nothing |
| `--route "<text>"` | `route.md` | Ollama, `gemma4:e4b-mlx` |
| `--eval <transform>` | `eval.md` | `python3`; Ollama for a `prompt:` transform |
| `--transcribe <wav>` | `transcribe.md` | the user's yes; ~1 GB model in memory |
| live dictation | `live-dictation.md` | the user |

The full flag list is in `docs/cli.md`.

## Evidence

Evidence goes to `~/Documents/parrotflow-scratch/verify/<YYYYMMDD-HHMMSS>/`,
outside the repo. Set `PF_EVIDENCE_ROOT` to put the timestamped dir elsewhere.
Cleanup never touches it.

Per call, `pf.sh` writes `NN-<label>.cmd` (the exact command line), `.out`
(stdout), `.err` (stderr: the app's `NSLog` lines land here), `.exit`, and
`.log` (the lines added to `~/Library/Logs/ParrotFlow.log` during the call;
the live release app writes to the same file, so some may be its lines). Per run,
`start.sh` writes `run.env` and `state-before.txt`. `finish.sh` writes
`state-after.txt`, `state-diff.txt`, `scratch-contents.txt`, `cleanup.txt`,
and `scratch-recordings/` if a trace was written.

A proof needs:

- The command, its stdout and its exit code, from the files above. Not a
  summary.
- The user path that matches the claim. A stage change is proved through
  `--pipeline` or `--replace`, the same code a dictation runs. A change to
  recording, hotkeys, or paste can only be proved by the user (see
  `features/live-dictation.md`).
- `state-diff.txt`. It shows what the run changed outside the scratch dir.
  Expected: release log lines added. A run with the vocabulary stage may also
  change the mtime of `phonemes-multilingual-g2p.json` in the release support
  dir block (see below). Nothing else should come from you. Lines in the Dev
  log and `live` trace rows are the user dictating.

Side effects that no env var or flag redirects. Each is also listed next to
the command in its feature file.

- **Release log.** Every call except `--version` appends to
  `~/Library/Logs/ParrotFlow.log`, the live release app's log: a
  `build: unstamped` line, then what the command logs, often with your text in
  it. Almost every flag loads the config at start, so the first call of a run
  seeds the scratch dir and adds about 33 `config: wrote ...` lines.
  The same lines go to the unified log through `NSLog`. `logging.text: false`
  does not stop them. The file truncates itself at 1 MB, so a line count can
  go down.
- **Phoneme cache.** The vocabulary stage's sound pass (`--pipeline` without
  `--no-prompts`, `--transcribe` without `--no-vocab`) can rewrite
  `~/Library/Application Support/ParrotFlow/phonemes-multilingual-g2p.json`,
  the live release app's cache, when it meets an uncached word. The same
  stage starts a background load of the word vectors, which downloads them
  if `models/qwen3-embedding-0.6b-4bit` is missing there.
- **Model loads.** `--transcribe` starts background loads from
  `~/Library/Application Support/ParrotFlow/models/` and loads the speech
  model from `~/Library/Application Support/FluidAudio/Models/`. A missing
  model is downloaded. `--route` without `--keyed`, and a `prompt:` stage or
  transform, call Ollama, which may load `gemma4:e4b-mlx` and keep it.
- **Programs.** `--replace`, `--eval` of a `command:` transform, and a
  fixture with `command:` run Python from the scratch dir.

Redirected by the scratch config: `config.yaml`, `vocabulary.yaml`,
`transforms/`, `voice/`, `vocabulary-uses.yaml`, and `recordings/`
(`trace.jsonl`, `spans.jsonl`), as long as `audio.output_dir` is unset.

## Cleanup

```sh
.claude/skills/verify-parrotflow/scripts/finish.sh <run-dir>
ls -la <run-dir>
```

`finish.sh` takes the after-snapshot and writes the diff. It copies any
`recordings/*.jsonl` out of the scratch dir. If a copy fails, it keeps the
scratch dir and exits `1`. Otherwise it removes the scratch config
dir, and only that: it refuses a path that is not a `parrotflow-verify.*` dir
under `$TMPDIR`. It never removes the evidence dir. Run it after a failed
attempt too, then start a new run.

It cannot undo what is listed under shared side effects above. Do not try:
never edit or truncate the user's logs, caches or traces.

## Helpers

All in `.claude/skills/verify-parrotflow/scripts/`, executable, bash. Run them
by path from the repo root.

| Script | Call | Does |
|---|---|---|
| `start.sh` | `start.sh` | Makes the evidence dir and a `mktemp -d` scratch config, writes `run.env`, snapshots shared state. Prints the run dir. |
| `doctor.sh` | `doctor.sh [--ollama]` | Read-only health check. See Doctor. |
| `pf.sh` | `pf.sh <run-dir> <label> --flag [args...]` | One binary call under the scratch config, with evidence files. Refuses any flag this page does not list. `PF_ALLOW_TRANSCRIBE=1` unlocks `--transcribe` after the user agreed. |
| `snapshot.sh` | `snapshot.sh <out-file>` | Line and byte counts of both logs, row and `cli` row counts of the four traces, mtimes (to the nanosecond) and sizes under the release support dir, `git status --short`. |
| `finish.sh` | `finish.sh <run-dir>` | After-snapshot, diff, scratch removal. See Cleanup. |

A complete run, end to end:

```sh
swift build -c release
.claude/skills/verify-parrotflow/scripts/doctor.sh
ls -d "$HOME/Library/Application Support/ParrotFlow/models/qwen3-embedding-0.6b-4bit"   # missing: ask the user first
RUN=$(.claude/skills/verify-parrotflow/scripts/start.sh); echo "$RUN"
.claude/skills/verify-parrotflow/scripts/pf.sh "$RUN" pipeline-vocabulary --pipeline tests/pipelines/replacements.yaml "our app is deployed on Versailles" --app "" --quiet --vars
.claude/skills/verify-parrotflow/scripts/finish.sh "$RUN"
ls -la "$RUN"
```

In separate tool calls, replace `"$RUN"` with the path `start.sh` printed.

## Keeping this skill true

When a flag, a fixture, a default or a side effect changes, update the feature
file and this page. If the `maintain-verification-skill` skill is installed
(it is a personal skill, not in this repo), use it to check the map against
the app.
