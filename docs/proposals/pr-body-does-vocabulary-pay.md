# Intended PR body — do not open the PR from a tool

Written to a file on purpose. The loss list quotes dictation and names
recording paths, and this repository is public. Whoever opens the PR should
read [tests/vocabulary-losses.txt](../../tests/vocabulary-losses.txt) first and
decide what belongs in a public description.

---

## test: does the vocabulary pass pay for itself, and the last CTC arm

**Marginal, and it lands where nobody had looked. 28 wins, 19 losses, net +9
over 141 clips — +18 on the 68 clips about a term, −9 on the 73 controls.
Every one of the 19 losses is an overwrite.**

Four rounds of judge work never asked whether the pass under the judge is
worth having. This measures it: every labelled clip in `tests/menu-cases.yaml`
replayed three times with the pass on and three times with the whole pass off,
same build, same day, same audio.

| | clips | wins | losses | net | flips |
|---|---|---|---|---|---|
| all | 141 | 28 | 19 | **+9** | 5 |
| about a term | 68 | 28 | 10 | **+18** | 3 |
| controls | 73 | **0** | 9 | **−9** | 2 |

Metrics and the decision rule were written down before the run. Net +9 falls
in the "0 to +15 — marginal, the lever is proposing less" band. Five clips
disagreed with themselves across runs and only one carries its verdict, so net
is +8 to +13 however they resolve.

### What is worth acting on

- **The controls have no wins.** None. Every control the pass touches, it
  breaks. A clip with no vocabulary term in it cannot be improved by writing
  one, so this column is free to fix.
- **All 19 losses are overwrites.** There is no second failure mode.
- **Three terms have never won.** `Redcrawl`, `Supabase` and `Ollama`: 0 wins,
  9 losses between them, 6 of the losses with no other term involved.
  `Vercel` is 9 to 1 the other way.

### `--no-vocab` does not switch the pass off

It sets `vocabulary.acoustic = false` and stops. The `heard:` lists still
become `replacements` rules, and those rules still fire the `vocabulary:`
judge stage. On one clip the flag changes nothing at all. The off arm here is
an empty `terms:` in a scratch `vocabulary.yaml`. **`scripts/calibrate.py`
uses `--no-vocab` and believes it is reading the raw decoder.**

### The last cheap acoustic arm is closed

`parakeet-tdt-ctc-110m` was already downloaded and never tried. It is the
transducer half of the hybrid checkpoint — no CTC head, no per-frame
posterior. Added as `PARROTFLOW_CTC_MODEL=tdt-ctc-110m`, kept failing, so the
next person gets the answer in one command. Better acoustic evidence now needs
a model that is not on this machine.

### What is in here

- `scripts/vocab-ablation.py` — the two-arm replay.
- `scripts/vocab-losses.py` — the loss list, with overwrites split out.
- `tests/vocabulary-losses.txt` — all 19, with label, off text and on text.
- `docs/proposals/judge-framings.md` — round 5 and round 5b.
- `docs/proposals/vocabulary-v2.md` — findings F19, F20, F21.
- `Sources/ParrotFlow/Vocabulary.swift` — `PARROTFLOW_CTC_MODEL`, cherry-picked
  from `spike/ctc-06b` and given the third arm.

No behaviour change to what ships. The env var defaults to what shipped, and
nothing else on the transcription path moved.
