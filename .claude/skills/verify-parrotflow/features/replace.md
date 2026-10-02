# Replacement rules

`--replace "<text>"` runs the pipeline of the config in the config dir on one
sentence, with every stage that would call a model turned off. The user sees
this as what their `replace:` tables and `command:` scripts do to a dictation:
fillers deleted, spoken numbers as digits, dates and money formatted.

## Sub-features

- `replace-fillers` deletes hesitation sounds through the `fillers` table.
- `replace-numbers` turns spoken numbers into digits through `numbers_en`, a Python script.
- `replace-no-model` skips the vocabulary stage and every `prompt:` transform.
- `replace-app` gates a stage on the app in front, with `--app <name>`.

## How to get to it (user POV)

- Live: every dictation runs these stages after decoding, in the order
  `--check-config` prints on its `pipeline` line.
- From a terminal: `.build/release/ParrotFlow --replace "<text>" [--app <name>]`.

## Driving it with pf.sh

Preconditions:

- A run is open (`RUN` from `start.sh`). The scratch config is the shipped
  default. Its pipeline is `sentence_repair → vocabulary → transform fillers →
  transform fillers_fr when language == "fr" → transform dates_en → transform
  numbers_en → transform money_en → transform disfluency`.
- `python3` is on `PATH` (the log names the one it used).

- **Fillers and numbers.** Run
  `.claude/skills/verify-parrotflow/scripts/pf.sh "$RUN" replace-numbers --replace "um we have twenty one users on super base"`.
  Exit `0`. Stdout is the single line `We have 21 users on super base`.
  `super base` stays: the vocabulary stage is off on this path, and the default
  vocabulary is empty anyway.
- **What ran.** Read `NN-replace-numbers.log`. It has
  `pipeline: skipped vocabulary — prompts are off on this path`,
  `pipeline: transform fillers rewrote the transcript`,
  `command: python3 resolves to ...`, and
  `pipeline: transform numbers_en rewrote the transcript`, each with
  `before:` and `after:` lines.
- **Proof.** Keep `.cmd`, `.out`, `.exit`, `.log`. Run `finish.sh` and keep
  `state-diff.txt`.

## Gotchas

- `--replace` loads the config. On a fresh scratch dir that copies `built-in/`
  in and writes about 34 lines (`config: wrote ...`) to
  `~/Library/Logs/ParrotFlow.log`, the release app's log. Later calls in the
  same run write about 10. The log has your sentence in it. No redirect:
  `logging.text: false` is applied after those lines are written.
- It executes Python from the scratch dir: `transforms/built-in/numbers/en.py`,
  `dates/en.py`, `money/en.py`, `disfluency/disfluency.py`. Python then leaves
  `__pycache__/` there, and the next config load prunes it and logs
  `config: removed ... (no longer shipped)`.
- `--seed-config` copies an untracked `built-in/transforms/*/__pycache__/*.pyc`
  from the repo as if it shipped. The file count differs between checkouts.
- Without `PARROTFLOW_CONFIG_DIR` this reads `~/.config/parrotflow/` and
  rewrites its `transforms/built-in/`. That pruned live files once. Only run
  it through `pf.sh`.
- To test your own table, write `config.yaml` into the scratch dir before
  the call. The dir is the `CFG=` line of `$RUN/run.env`.
