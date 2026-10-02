# Pipeline on a sentence

`--pipeline <fixture.yaml> "<text>"` runs the stages a fixture lists on one
sentence and prints what each stage did. It is the same pipeline code a
dictation runs after decoding: the vocabulary pass, `replace:` tables,
`command:` scripts, conditions. A fixture carries its own languages,
vocabulary, transforms and pipeline, so the result does not depend on any config.

## Sub-features

- `pipeline-vocabulary` writes a vocabulary term over a `heard:` rendering.
- `pipeline-replace` applies a `replace:` table, such as the filler deletion.
- `pipeline-vars` publishes per-stage variables, read with `--vars`.
- `pipeline-no-prompts` skips the vocabulary stage and prompt stages.
- `pipeline-trace` prints each stage's before and after without `--quiet`.

## How to get to it (user POV)

- A user never runs this. It is how a developer checks a stage without
  speaking. Live, the same stages run after every dictation; see
  [live-dictation.md](./live-dictation.md).
- From a terminal: `.build/release/ParrotFlow --pipeline <fixture> "<text>"`.
- `scripts/check-pipeline.sh` and `scripts/check-replacements.sh` drive it
  over `tests/pipeline-cases.yaml` and `tests/replacement-cases.txt`.

## Driving it with pf.sh

Preconditions:

- A run is open (`RUN` from `start.sh`). `doctor.sh` says `✓ matches the tree`.
- `tests/pipelines/replacements.yaml` exists. It defines the terms `Vercel`
  (heard `Versailles`, `Versal`), `Supabase`, `Tasmeen`, `Matthieu`, `Mik`,
  and the transforms `fillers` and `dotted`.

- **Term over a rendering.** Run
  `.claude/skills/verify-parrotflow/scripts/pf.sh "$RUN" pipeline-vocabulary --pipeline tests/pipelines/replacements.yaml "our app is deployed on Versailles" --app "" --quiet --vars`.
  Exit `0`. The last line is `our app is deployed on Vercel`. The output
  contains `var   vocabulary.protected = "Vercel"` and
  `var   vocabulary.changes = "Versailles -> Vercel"`. This is a case in
  `tests/pipeline-cases.yaml`. About 4 s, most of it the gate (`vocabulary.gate_ms`).
- **Filler removed, stage by stage.** Run
  `.claude/skills/verify-parrotflow/scripts/pf.sh "$RUN" pipeline-trace --pipeline tests/pipelines/replacements.yaml "our app is um deployed on Vercel" --app ""`.
  Exit `0`. Output has `in:   our app is um deployed on Vercel`, then
  `· vocabulary  — ran, changed nothing`, then `→ transform` with
  `Our app is deployed on Vercel` and `fillers.count = 1`, and ends with
  `out:  Our app is deployed on Vercel`.
- **Model stages off.** Run
  `.claude/skills/verify-parrotflow/scripts/pf.sh "$RUN" pipeline-no-prompts --pipeline tests/pipelines/replacements.yaml "our app is deployed on Versailles" --app "" --no-prompts`.
  Exit `0`. Output has `⊘ vocabulary  — skipped, prompts are off on this path`
  and ends `out:  our app is deployed on Versailles`.
- **Proof.** Keep `NN-pipeline-vocabulary.out` and `.exit`. Run `finish.sh`
  and keep `state-diff.txt`. Measured on the first call of a run: the only
  shared change is about 37 new lines in `~/Library/Logs/ParrotFlow.log`.

## Gotchas

- Each call appends to `~/Library/Logs/ParrotFlow.log`, the release app's log.
  About 2 to 5 lines: `build: unstamped`, plus the vocabulary and pipeline
  lines, with your sentence in them. The first call of a run adds about 33
  `config: wrote ...` lines, because the binary loads (and seeds) the config
  at start even for `--pipeline`. No env var redirects the log. The bare
  binary has no bundle id, so it runs as the release variant.
- Without `--no-prompts` the vocabulary stage runs its sound pass. It can
  rewrite `~/Library/Application Support/ParrotFlow/phonemes-multilingual-g2p.json`,
  the release app's phoneme cache, when a word is not cached yet. No env var
  redirects it. It never downloads; it only loads the model from
  `~/.cache/fluidaudio/Models/kokoro`.
- The vocabulary stage asks the word vectors to load in the background, then
  logs `sentence gate: the word vectors are not loaded yet; skipped`. That is
  normal for a one-shot run. `--warm` makes it wait, and downloads what is
  missing, so `pf.sh` refuses it. The background load also downloads
  (about 400 MB) when the model is missing, and the process may exit halfway.
  Before a run without `--no-prompts`, check that
  `~/Library/Application Support/ParrotFlow/models/qwen3-embedding-0.6b-4bit`
  exists. If it does not, use `--no-prompts` or ask the user.
- The binary loads the config dir at start, and the stage reads `voice/` and
  `vocabulary-uses.yaml` from it. Without `PARROTFLOW_CONFIG_DIR` that is the
  live `~/.config/parrotflow/`, and the load rewrites its
  `transforms/built-in/`. That is why even `--pipeline` runs under the
  scratch config.
- The verbose run prints notices about the fixture (`- vocabulary` is not a
  step any more, renderings written the old way). They are about the fixture
  file, not failures.
- A fixture with a `command:` transform runs that script (for example
  `tests/pipelines/everything.yaml` runs Python). A fixture with a `prompt:`
  transform or a `models:` block calls Ollama unless you pass `--no-prompts`.
- `fuzzy` depends on `NSSpellChecker`, which times out now and then. Do not
  prove anything on a single `fuzzy` result.
- `--app ""` means nothing was in front. Leaving `--app` out means the same
  here. Pass `--app Slack` to reach a stage with an `app:` condition.
