# Scoring a transform

`--eval <transform>` runs a transform from the config over its own case set and
prints the score: the `change` half (cases that should be rewritten), the `keep`
half (cases that must come back byte for byte), a breakdown by probe, latency,
and every failing case. For a user, the score is how often the transform does
the right thing to their dictation.

## Sub-features

- `eval-score` prints `change`, `keep` and `overall` for a transform's `cases.yaml`.
- `eval-probe` breaks the score down by `probe:`.
- `eval-failures` lists each failing case with `got` and `want`.
- `eval-cases` scores another set with `--cases <file>`.

## How to get to it (user POV)

- An agent or developer runs it before and after changing a prompt, a
  pattern or a script (see `docs/authoring.md`).
- From a terminal: `.build/release/ParrotFlow --eval <transform> [--cases <file>] [--probe <name>] [--verbose]`.

## Driving it with pf.sh

Preconditions:

- A run is open (`RUN` from `start.sh`). The scratch config is the shipped
  default, which defines `disfluency` as a `command:` transform with
  `built-in/disfluency/cases.yaml` beside it. No model is involved.

- **Score disfluency.** Run
  `.claude/skills/verify-parrotflow/scripts/pf.sh "$RUN" eval-disfluency --eval disfluency`.
  Exit `0`. Takes about 40 s. The output contains
  `change   55/58 = 95%`, `keep     44/44 = 100%   <- must come back byte for byte`,
  `overall  99/102 = 97%`, a `by probe` block (`marker    5/7  ←`,
  `word      24/25  ←`), and three `✗` cases, the first
  `So I'd like to consolidate consolidate that on something  [change, word]`.
- **Proof.** Keep `.out` and `.exit`. Quote the three summary lines.

## Gotchas

- Exit `0` means it scored, whatever the number. Exit `1` means it could not
  score at all. Compare numbers, not exit codes.
- The numbers above are for this tree. A change to
  `built-in/transforms/disfluency/` moves them; that is the point. The
  bare binary reads `built-in/` from the repo at run time, so a script change
  needs no rebuild.
- It runs the Python script once per case from the scratch dir and writes
  about 170 lines to `~/Library/Logs/ParrotFlow.log` (each rewrite's before
  and after). No redirect.
- A `prompt:` transform (`grammar`, for one) calls Ollama once per case, plus
  a warm-up call. Check `doctor.sh --ollama` first and ask the user if the
  model is not loaded. Do not run two at once.
- `numbers`, `dates` and `money` keep `cases-en.yaml` and `cases-fr.yaml`,
  not `cases.yaml`, and are scored by `built-in/transforms/<name>/score.py`.
