# Config check and seeding

`--check-config` reads `config.yaml` and prints what the app will actually use:
hotkey, audio, pipeline, transforms, models, which entries run a program, and
the permission state. `--seed-config` writes what a first launch writes and says
which files it wrote or refreshed. A user meets these when an agent sets up or
changes their config.

## Sub-features

- `config-seed` writes `config.yaml`, `vocabulary.yaml`, `transforms/slack_mentions/` and `transforms/built-in/`.
- `config-report` prints what survived parsing, line by line.
- `config-programs` names every `command:` transform as config that executes code.
- `config-refuse` exits non-zero with the reason when the YAML is wrong.

## How to get to it (user POV)

- An agent configuring ParrotFlow runs it after every change (see `AGENTS.md`).
- From a terminal: `.build/release/ParrotFlow --check-config` and `--seed-config`.

## Driving it with pf.sh

Preconditions:

- A run is open (`RUN` from `start.sh`), and this is its first call. Any
  earlier call already seeded the scratch dir, so the seed step would find
  the files already there.

- **Seed a fresh dir.** Run
  `.claude/skills/verify-parrotflow/scripts/pf.sh "$RUN" seed --seed-config`.
  Exit `0`. Output starts `config: <scratch dir>`, then
  `✓ config.yaml — written`, `✓ vocabulary.yaml — written`, one
  `✓ transforms/built-in/... — written` line per file, and
  `N example file(s) written, 0 refreshed.` (31 on this Mac).
- **Report.** Run
  `.claude/skills/verify-parrotflow/scripts/pf.sh "$RUN" check --check-config`.
  Exit `0`. The output contains `✓ hotkey            Right ⌘  (push-to-talk, polled)`,
  a `· pipeline          sentence_repair → vocabulary → ...` line,
  `· transforms: "numbers_en" runs a program — built-in/numbers/en.py`,
  `gemma  ollama  gemma4:e4b-mlx  http://localhost:11434`, and
  `· accessibility     needed, but not checkable from a terminal`.
- **Refused config.** Overwrite `config.yaml` in the scratch dir (the `CFG=`
  line of `$RUN/run.env`) with the single line `hotkey: [`. Run
  `.claude/skills/verify-parrotflow/scripts/pf.sh "$RUN" check-broken --check-config`.
  Exit `1`. Output is `config: <scratch dir>/config.yaml`, then
  `✗ 2:1: error: parser: while parsing a flow node in line 2, column 1` and
  `did not find expected node content`.
- **Proof.** Keep both `.out` files and `.exit` files.

## Gotchas

- The hotkey reads `Right ⌘` because the bare binary has no bundle id and
  takes the release defaults. It says nothing about the Dev app, whose
  default is Right ⌥.
- `· microphones` and `✓ input device` read the real audio devices. Reading
  is all it does. `✓ microphone Granted` is the terminal's grant.
- Accessibility cannot be checked from a terminal. The app logs its real
  state at launch: `grep "launched —" ~/Library/Logs/ParrotFlow.log | tail -1`.
  That line may be gone: the log truncates at 1 MB.
- `models 1 reachable` means one model is defined. It does not contact Ollama.
- The first config load in a run writes about 34 lines to
  `~/Library/Logs/ParrotFlow.log`. Later loads write 1. No redirect.
- Never run these against the live config. Without `PARROTFLOW_CONFIG_DIR`,
  loading rewrites and prunes `~/.config/parrotflow/transforms/built-in/`.
  Read a live setting with `grep`, not with the binary.
