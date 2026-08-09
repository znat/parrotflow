# Intended PR body — `spike/reference-matching`

Not opened. `gh pr create` was not run. Title:

> test: compare the audio to recordings of the term, and measure the separation

---

**A span of audio sits closer to a recording of the term when the term was
actually said. AUC(A vs B) 0.812, against 0.333 for the raw acoustic score on
the same rows. The control holds and length does not explain it. Four terms
only, 21 of the 30 A spans are `Praisy`, and `Redcrawl` — the term costing
clips — has no recording at all.**

## Why

Round 5 (`spike/raw-score-separation`) took the vocabulary bonus out and asked
whether the raw acoustic score knows a term was said. It does not: AUC 0.318,
with B sitting above A rather than apart from it.

Every acoustic number tried so far scores a **spelling** against audio. The
decoder is asked what it thinks of `Praisy` as a string. This round asks the
other question. `scripts/mine-pronunciations.py` already cut the speaker
actually saying these names into `tests/acoustic/`. Compare the span to those
and no spelling is involved.

## What was measured

Round 5's proposals, condition `cbw0`, deduplicated its way — one row per clip,
term stem, word range and kind. Restricted to the four terms with recordings.

| term | recordings | A | B |
|---|---|---|---|
| Praisy | 17 | 21 | 37 |
| Vercel | 7 | 6 | 5 |
| Matthieu | 2 | 3 | 3 |
| Supabase | 1 | 0 | 1 |
| **total** | **27** | **30** | **46** |

Per proposal: cut the span padded 0.05s each side, 12 MFCCs at 25ms/10ms with
c0 dropped and per-segment mean/variance normalisation, DTW with a symmetric
step pattern normalised by n + m, take the nearest recording.

## The result

| | AUC(A vs B) |
|---|---|
| chance | 0.500 |
| the raw acoustic score, round 5, all 33 A / 66 B | 0.318 |
| **the raw acoustic score on these same 30 / 46** | **0.333** |
| the spotter score on its own path, round 5 | 0.814 |
| **nearest recording of the term** | **0.812** |

Per term: `Praisy` 0.882 (21/37), `Vercel` 0.800 (6/5), `Matthieu` 0.556 (3/3),
`Supabase` no pair.

## The controls

**Different term.** Matched is nearer than mismatched on 27/30 A spans (90%)
and 37/46 B spans (80%); chance is 50%. AUC(matched vs mismatched) 0.893 on A.

**Generic cleanliness.** The mismatched distance alone separates A from B at
0.670, so some of the effect is not term-specific. `mismatched − matched`
cancels that and still separates at 0.755.

**Length.** Span duration alone is 0.472. Hold the length gap equal inside each
A/B pair and the distance separates at 0.891 over 385 pairs. Hold the distance
equal and the length gap falls to 0.370 over 207 pairs. Length is not doing the
work.

**Self-comparison.** The recordings were mined from these same clips, so a
recording can be the very span it is compared to, and the filename does not say
where it came from. Every recording is traced to its source clip by searching
the archive for its exact samples, and held out when the proposal comes from
that clip. It costs `Praisy` 1 of 17 on the clips that carry one, and costs
`Supabase` its only A case.

## Dropped

23 of round 5's 33 A / 66 B. 21 for a term with no recording — `Claude` ×5,
`Tasmeen` ×4, `Mirza` ×4, `Redcrawl` ×3, `Ollama` ×3, `Redrock`, `Arexvy`. 2
for the hold-out, both `Supabase`.

## The limitation

`Redcrawl` has zero recordings and `Supabase` has one. Those are the terms
actually costing clips. **This measures the method, not the failures that
matter.** It says the idea works on a name with 17 recordings. It does not say
what happens on a name with two, and `Matthieu` at 0.556 is a hint that the
answer may be "nothing".

The ranges also overlap and the scale differs per term — `Matthieu`'s whole A
range sits above `Praisy`'s whole B range. This is a separation, not a decision
rule. Anything built on it normalises per term.

## What to do next

1. **Record the terms that have none.** Ten readings each of `Redcrawl`,
   `Redrock`, `Supabase`, `Tasmeen`, `Mirza`, `Claude`, `Arexvy` puts 23 rows
   back and turns a four-term result into a vocabulary-wide one.
   `tests/acoustic/reading.json` on `feat/vocabulary-skills-only` is already a
   script of this shape; it covers the wrong terms.
2. **Do not ship MFCC + DTW.** It was chosen to be cheap. The same comparison
   over a speech encoder's frames, or one embedding per recording with a
   cosine, is stronger and cheaper at run time than a dynamic program per
   recording per span.
3. **Do not blend it with the acoustic score.** A rank-average of the two lands
   at 0.597, worse than the distance alone — what you get from averaging a good
   predictor with an inverted one.

## Files

- `scripts/reference-matching.py` — the whole measurement, numpy and stdlib.
  Fetches `tests/raw-score-separation.json` from `spike/raw-score-separation`
  and `tests/acoustic/` from `feat/vocabulary-skills-only` on first run.
- `docs/proposals/judge-framings.md` — round 6.
- `docs/proposals/vocabulary-v2.md` — F20. F19 is round 5 and not merged; this
  takes the next ID so the two do not collide.
- `docs/proposals/reference-matching-distances.md` — every proposal, its
  distance, its nearest recording, and every dropped row with the reason.

`tests/acoustic/` is gitignored and stays that way: it is a person's voice.
`scripts/check-no-voice.sh` passes 5/5.

No model call, no decoder, no Ollama, no build, no install. It reads wavs and
does arithmetic. `~/.config/parrotflow-dev/` untouched;
`feat/vocabulary-skills-only` read only.
