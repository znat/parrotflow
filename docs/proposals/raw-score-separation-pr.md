# Intended PR body — `spike/raw-score-separation`

Not opened with `gh pr create`. A PR body on this public repository would quote
dictation transcripts, so the text lives here and a human decides whether it
goes up. Open it by hand from
<https://github.com/znat/parrotflow/pull/new/spike/raw-score-separation> if you
want it.

Title: **test: ask the raw acoustic score to reject a wrong term, and measure
that it cannot**

---

## What this answers

Round 4 found that the score block the judge is shown predicts the answer worse
than a constant. One objection was open. The rescorer decides on the *boosted*
score, so every number that reaches a menu is the residue of a decision the
vocabulary bonus already took — the raw score had never been asked on its own.

This spike takes the bonus out and asks again, over all 145 clips of
`tests/menu-cases.yaml` rather than the 53 cached menus.

Three groups, over every proposal the pass makes:

- **A** — the label puts the term at this span.
- **B** — the label puts an ordinary word there. The failures.
- **C** — every other vocabulary term the spotter scored over the same span,
  restricted to terms absent from the whole label. The noise floor.

The statistic is the spotter's raw score for the term over the span, in nats per
token. It has to be one scale for all three, and group C has no decoded word to
subtract. The rescorer's gap — the number the judge is actually shown — is
reported beside it for the two groups that have one.

## The answer: it cannot reject, and the floor is the only thing worth moving

| | n | median | | AUC, rescorer proposals only | |
|---|---:|---:|---|---|---:|
| A term was said | 33 | -6.81 | | A vs B | 0.425 |
| B term was NOT said | 66 | -4.88 | | **A vs C** | **0.454** |
| C random terms | 917 | -7.10 | | B vs C | 0.526 |

- **B sits above A, not apart from it.** A wrongly proposed term is heard 1.9
  nats *more* clearly than a correctly proposed one. AUC(A vs B) over all
  proposals is **0.318** — below a coin.
- **100% of B falls inside A's range. 88% falls inside C's.**
- On the rescorer's own proposals, a term that **was** said is at chance against
  a term that is not in the sentence at all: **0.454**, with 100% of A inside
  C's range. A term that was **not** said does no worse, at 0.526.
- The only rescorer-path column above chance is the gap against the decoded
  word, **0.593**. Fitted and scored on the same rows it gets 38/60 where the
  constant gets 30/60.

## But the two paths are not the same, and one has a usable floor

A proposal reaches a menu from the rescorer, which scores both spellings, or
from the spotter, which has no decoded-word score at all. **The gap AUC never
saw the majority of the failures** — the spotter path is 40 of 66 B at cbw 0 and
32 of 92 today. Asked per path:

| statistic | path | AUC(A vs B), cbw 0 | today |
|---|---|---|---|
| the gap | rescorer | 0.593 | 0.668 |
| raw term score, per token | rescorer | **0.487** | 0.457 |
| spotter score at the span | rescorer | 0.425 | 0.459 |
| spotter score at the span | spotter | **0.814** | 0.945 |

Per-token normalisation is not the explanation: the rescorer's own per-token
term score is 0.487, a coin. **On the rescorer path nothing separates.**

On the spotter path its score does, and `Vocabulary.spotterFloor` is where that
number is already used as a gate. It is -5.0 and admits every wrong spotter
proposal in the set.

| floor | A kept | B kept | B cut | A cut |
|---|---|---|---:|---:|
| **-5.00** (today) | 7/7 | 40/40 | 0 | 0 |
| -4.75 | 6/7 | 24/40 | 16 | 1 |
| -4.50 | 6/7 | 14/40 | 26 | 1 |
| **-4.25** | **6/7** | **7/40** | **33** | **1** |
| -4.00 | 5/7 | 5/40 | 35 | 2 |

Over the whole set at today's cbw, a -4.25 floor takes **A from 39 to 39 and B
from 92 to 64.**

**It is smaller than it looks, and this is the part to read.** AUC(A vs C) is
0.999 and AUC(B vs C) is 0.997 on the same rows: the score separates "something
is here" from "nothing is here", not right from wrong. The two highest scores in
the whole set are a correct `Vercel` over "Versailles" at -2.28 and a wrong
`Vercel` over "universal" at -2.51, in the same clip. Of the eight
collision-class clips only three carry a spotter proposal and only `11-19-17` is
fixed by cutting it — **seven of the eight fail on the rescorer path.** It is
in-sample on 47 proposals, the floor's existing sweep stopped at -4.8, and
`spotterFloor` also gates `spottedAnything`, so raising it can silence a clip
entirely. **Nobody should move it without `menu-recall.py --runs 3` across the
range.** Nothing in this PR changes it.

## The bonus is not the bug

| | rescorer | applied | proposed | dropped | spotter | wider | total |
|---|---|---|---|---|---|---|---|
| today, cbw 4.5 | 111 | 14 | 95 | 2 | 33 | 195 | **339** |
| cbw 0 | 59 | 18 | 41 | 0 | 41 | 101 | **201** |

`shouldReplace` is FluidAudio's and it is computed on the boosted score, so cbw 0
is a different pass rather than a quieter one: a candidate only surfaces where
the audio already preferred the term. Rescorer proposals nearly halve, and the
ones that go are not the wrong ones — the mix of failures to successes survives
at about two to one. **Keep `cbw` where it is.**

## Replay noise settles it on its own

870 replays, three per clip per condition. Median run-to-run spread 0.00, but
one proposal in twenty moves more than a nat, and the worst moves 5.7 nats at
cbw 0 and 8.1 today — against an A-versus-B separation of 0.49 nats on the gap.
**13 of 107 proposals do not appear in all three replays of the same file.**

## Per term

`Redcrawl`, `Supabase` and `Ollama` do not look different from `Praisy` and
`Vercel`. The ablation's 0 wins and 9 losses has a simpler reading: those three
are almost never right in this set at all — 0, 1 and 1 A cases. Their wrong
proposals are loud, not quiet. `Ollama`'s wrong median is -4.57 against
`Praisy`'s correct median of -8.00, and AUC(B vs C) is **1.00** for `Ollama` and
0.99 for `Tasmeen`: for those names the score endorses the wrong term over every
term that is genuinely absent.

## What is added

| | |
|---|---|
| `PARROTFLOW_CBW` | the vocabulary bonus, defaulting to FluidAudio's 4.5 |
| `PARROTFLOW_SPOTTER_DUMP` | now also writes one machine-readable line per proposal, on the axis its `word` and `spotter:` lines already used — same mechanism, no second one |
| `scripts/raw-score-separation.py` | the sweep, the labelling rule and the report |
| `tests/raw-score-separation.json` | the cache, so the report needs no clips |
| `docs/proposals/raw-score-separation.md` | every proposal, one line each |

Round 5 in `docs/proposals/judge-framings.md`, recorded as **F19** in
`docs/proposals/vocabulary-v2.md`.

## Nothing changed for the user

With `PARROTFLOW_CBW` unset the override is the old expression, and every dump
line is behind the env var. Checked rather than argued: three clips through the
installed `78d7ba2` and through this branch's build, same scratch config, same
`vocabulary:` lines on two of the three. The third differed and five replays per
binary show why — the *installed* binary produces both readings of the same span
on the same file. That is F12a.

No judge, no Ollama, no menu, no model call anywhere. Build only, no install.

## What this does not settle

The set was replayed, not dictated. `menu-cases.yaml` still holds no clip where
a non-word decoding was what the speaker said (F18), and this round does not add
one. Group C is censored at FluidAudio's own `-15.0` spotter minimum, which is
far below anything that matters here but is a floor all the same. And the two
scores compared come from the same dynamic program over different windows — the
rescorer scores a window it is given, the spotter finds its own. That is the one
seam in the comparison and it is stated in the script's own docstring.
