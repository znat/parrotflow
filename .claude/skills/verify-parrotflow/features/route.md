# Routing a spoken instruction

When a user says "hey parrot, ..." or holds the key for an instruction, the app
picks which transform the instruction reaches. `--route "<what you'd say>"`
prints that choice without running the transform. `--keyed` scores the
tap-and-hold path, which has no model: a transform named anywhere in the
sentence wins. Anything else goes to the catch-all `ANY`, or to `NONE` when
the config turns the catch-all off (`commands.catch_all`).

## Sub-features

- `route-keyed-named` picks a transform named in the sentence, with no model.
- `route-keyed-any` sends an instruction that names nothing to `ANY`.
- `route-model` asks the router model (Ollama) to pick, after the wake phrase is stripped.

## How to get to it (user POV)

- Live: say "hey parrot, make that a bullet list" while holding the hotkey, or
  tap-and-hold the hotkey and speak an instruction.
- From a terminal: `.build/release/ParrotFlow --route "<text>" [--keyed] [--quiet]`.
- `scripts/check-keyed.sh` scores `--keyed` over `tests/keyed-cases.yaml`.
  `scripts/check-routing.sh` scores the model path, a round trip per case.

## Driving it with pf.sh

Preconditions:

- A run is open (`RUN` from `start.sh`). The scratch config is the shipped
  default. Its catalogue is `spelling, vocabulary, grammar, slack_mentions,
  github_refs, dates_en, numbers_en, money_en, fillers, fillers_fr, disfluency, trace`.
- For `route-model` only: `doctor.sh --ollama` lists `gemma4:e4b-mlx` under
  `pulled:`. Check `loaded:` too; see Gotchas.

- **Named outright.** Run
  `.claude/skills/verify-parrotflow/scripts/pf.sh "$RUN" route-keyed --route "turn that into slack mentions" --keyed`.
  Exit `0`. Output ends `→ slack_mentions  (named outright, no model)`.
- **Catch-all.** Run
  `.claude/skills/verify-parrotflow/scripts/pf.sh "$RUN" route-any --route "make it shorter" --keyed --quiet`.
  Exit `0`. Stdout is `ANY`.
- **Model router.** Run
  `.claude/skills/verify-parrotflow/scripts/pf.sh "$RUN" route-model --route "hey parrot, make that a bullet list"`.
  Exit `0`. Output has `instruction: "make that a bullet list"` (wake phrase
  stripped) and `→ ANY  (gemma4:e4b-mlx in 1.22s)  an edit, but no prompt covers it`.
  The time varies.
- **Proof.** Keep `.out` and `.exit` for each.

## Gotchas

- The model path calls Ollama at `localhost:11434` with `gemma4:e4b-mlx`. The
  default config sets `keep_loaded: true`, so a call loads the model if
  `doctor.sh --ollama` does not list it under `loaded:`, and keeps it in RAM.
  If it is not loaded, ask the user before the call. One model call at a time.
  Never pull a model.
- `--keyed` never calls a model. Prefer it when the question is about matching.
- The answer depends on the catalogue, which comes from the config. A change
  to a transform's `description` or `say:` changes the routing.
- `scripts/check-routing.sh` runs the binary without `PARROTFLOW_CONFIG_DIR`.
  It reads the user's live release config and rewrites its
  `transforms/built-in/`. Do not run it in a verification. Route single
  sentences through `pf.sh`.
- Each call writes 1 to 3 lines to `~/Library/Logs/ParrotFlow.log`, plus about
  33 if it is the first call of the run.
