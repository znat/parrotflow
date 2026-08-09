# Is the 110M CTC model the constraint on the vocabulary pass?

**Unanswered, because the bigger model is broken. `parakeet-ctc-0.6b-coreml`
returns NaN on 64% of the frames under an uncertain span. It is not weaker
evidence than the 110M model — on most spans it is no evidence at all, so there
was never anything to compare.**

The transcript is written by `parakeet-tdt-0.6b-v3`. The names are decided by a
second, smaller model: `parakeet-ctc-110m`, chosen by the default argument of
`CtcModels.downloadAndLoad()`. Nobody had ever asked whether that default was
right. Every dead end in the vocabulary work traces back to weak evidence — on
the spans that matter the best non-blank token sits at -7 to -9, where a
confident clip reaches -0.4 to -3. This spike asked whether a five-times-larger
CTC model moves that.

The question stands. The 0.6B CoreML export in FluidAudio 0.15.5 is broken, so
the experiment ruled out a model rather than testing a hypothesis. **Do not read
this as evidence that CTC model size does not help.**

## What was built

`PARROTFLOW_CTC_MODEL=110m|0.6b` selects the model, defaulting to `110m`, so
nothing changes for a user who sets nothing. One build, one flag, and it is the
shape this would ship in. `CtcChoice.variant` in `Sources/ParrotFlow/Vocabulary.swift`
resolves it; `BoostEvalCommand` and `SpotCommand` read the same switch so the
diagnostics cannot disagree with the pass.

The per-frame log-prob dump (`PARROTFLOW_LOGPROB_DUMP`) was ported from the
`spike/onset-pilot` branch. It is what metric 1 is measured from.

## The five metrics

Pre-registered before the run, and not moved.

| | metric | 110m | 0.6b | moved? |
|---|---|---|---|---|
| 1 | frames that are entirely NaN | **0/1378 (0%)** | **471/732 (64%)** | **worse** |
| 1 | spans with no usable frame at all | **0/144** | **62/91 (68%)** | **worse** |
| 1 | best-of-two score, per span, median | **-8.50** | **-16.49** (finite ones only) | **worse** |
| 2 | argmax vs the constant | 33/66 vs **45/66** | 16/56 vs **39/56** | no |
| 3 | hit rate monotone in gap? | no | not measurable | no |
| 4 | fixed / broken / regressed | 22 / 38 / 18 | **not measured** | — |
| 5 | recall / picked | 112/141 / 86/141 | **not measured** | — |

Metrics 4 and 5 were cancelled for 0.6b once metric 1 came back, along with the
latency comparison. They replay 145 clips three times through a model that
returns no evidence on two thirds of its frames; the verdict rows would have
measured the NaN. The 110m columns were run to completion and are kept, because
they re-record the gate baselines on the full set — see the correction below.

### 1. Confidence — the leading indicator

**It did not move toward zero. It stopped being a number.**

The dump prints, per frame, the top 8 non-blank tokens. Over the 145 labelled
clips:

| | 110m | 0.6b |
|---|---|---|
| spans dumped | 144 | 91 |
| frames under those spans | 1378 | 732 |
| frames where all 1024 tokens are NaN | **0 (0%)** | **471 (64.3%)** |
| spans touched by a NaN frame | 0 | 62 |
| spans with no usable frame at all | 0 | **62** |

NaN is spread through the clip, not bunched at an edge: the median NaN frame
sits at 2.45s, the median usable frame at 6.94s.

On the 29 spans that still produced numbers, the distribution has collapsed
rather than sharpened. The best token per frame reaches -0.00, but on tokens
that are not in the audio. Frame 44 of clip `17-47-45`, under "retry":

    110m   f44   ▁in -6.35   , -6.90   . -7.34   ▁is -8.10  …
    0.6b   f44   ross -0.01  _T -4.57   _hundred -7.33  th -8.27  …

`ross -0.01` is near-certainty on a token nothing said. That is what a broken
conversion looks like, and it is why the naive reading of metric 1 — "the best
non-blank log-prob improved from -2.50 to -0.00" — is wrong. The median *frame*
did not improve at all: -4.71 under 110m, -5.08 under 0.6b.

The scores the pass actually decides on got worse in the same motion. Of the
score lines written into the menu cache, **0 of 85 saturate under 110m and 53 of
72 (74%) saturate under 0.6b** at multiples of `-FLT_MAX`, which is NaN
propagated through the rescorer's sum. The 19 finite ones have a median of
-16.49 against 110m's -8.50 — about 8 nats worse.

### 2. Primary — does the score beat the constant?

**No, under either model, and 0.6b is much further from it.**

`scripts/gap-signal.py` over a cache harvested with each model.

| cache | reachable menus | uncertain spans | scored spans | argmax | keep what the decoder wrote |
|---|---|---|---|---|---|
| committed cache (as documented) | 53 | 77 | 57 | 28/57 (49%) | **34/57 (60%)** |
| fresh 110m harvest | 60 | 88 | 66 | 33/66 (50%) | **45/66 (68%)** |
| fresh 0.6b harvest | 57 | 76 | 56 | 16/56 (29%) | **39/56 (70%)** |

The first row reproduces the documented round-4 baseline exactly from the
committed cache, which is how the harness was checked before the comparison was
trusted. **The 110m row is a re-harvest and is the number the 0.6b row must be
read against** — the committed cache predates PR #70 and covers 130 clips; both
fresh rows cover the 145 of `tests/menu-cases.yaml`.

Argmax under 0.6b is 29%, below the 41% you get by guessing a reading at
random. The constant did not move (68% → 70%), which is expected: it does not
read the scores.

### 3. Is the gap predictive?

**Not measurable under 0.6b, and still not monotone under 110m.**

Under 0.6b only 10 of 56 scored spans have a finite gap at all; the rest are
differences between two saturated sentinels, running to 2.6e38 nats. 47 of 56
"reach" the shipped `decide_above: 3.0` — an artefact of the sentinel, not
evidence. Ten spans across four buckets is a count, not a rate.

Under the fresh 110m cache the old finding stands: 14/31, 6/12, 9/14, 4/9 across
the gap buckets. No trend, and the widest bucket is argmax's worst against the
constant (4/9 against 9/9).

### 4. Fewer overwrites, and 5. recall must not fall

**Not measured for 0.6b — cancelled, not failed.** Both harnesses replay every
clip three times through the vocabulary pass. Under a model that returns NaN on
64% of frames the verdicts describe the NaN, and the machine time buys nothing
the first metric has not already said.

The 110m runs were completed, because the plan owed a re-record of these gates
on the full 145-clip set:

| | documented (127 clips) | re-recorded (141 labelled) |
|---|---|---|
| `before-after.py --runs 3` | 20 fixed / 26 broken / 11 regressed / 70 kept | **22 / 38 / 18 / 63** |
| `menu-recall.py --runs 3` | recall 102/127, picked 90/127 | **recall 112/141, picked 86/141** |

Recall holds as a rate (80.3% → 79.4%). Picked falls (70.9% → 61.0%) and
regressions rise (8.7% → 12.8%). Block 3 is harder than the set the floors were
set on, so the floors in the plan describe a set that no longer exists. 2 clips
flipped between runs in each harness (F12a).

## Comparability

Re-harvesting with a different model changes which spans reach a menu, so the
two runs above score different span sets. Restricted to the **64 spans present
in both caches**:

| | spans | scored | argmax | keep decoded | median best-of-two |
|---|---|---|---|---|---|
| 110m (shared) | 64 | 54 | **31/54 (57%)** | 38/54 (70%) | -8.67 |
| 0.6b (shared) | 64 | 51 | **15/51 (29%)** | 38/51 (75%) | saturated |

24 spans are 110m-only, 12 are 0.6b-only.

**The intersection agrees with the full sets.** Argmax under 0.6b is 29% both
ways; under 110m it is 50% on the full set and 57% on the shared spans. On the
26 shared spans where the two models disagree about the answer, **110m is right
on 21 and 0.6b on 5**.

## The costs

| | 110m | 0.6b |
|---|---|---|
| download / on disk | **99 MB** | **2.2 GB** (22x) |
| model load, warm | 0.16-0.25s | 0.14-0.16s |
| first-run download | seconds | ~8 minutes |
| added latency per dictation | **not measured** | **not measured** |

The latency comparison was cancelled with metrics 4 and 5. Timing a model that
returns NaN on most frames prices work nobody would ship. Load time is from the
smoke runs and is not the number that would have mattered.

## Why it is broken, and what it is not

It is not a tokenizer mismatch. The two `tokenizer.json` files use the same
SentencePiece `▁` word boundary and the same ids — `▁are` is 111 in both — so
`CtcTokenizer.encode` produces identical token sequences for every term. The
terms tokenise, the spotter fires, and the spans line up. The `vocab.json`
files differ cosmetically (the 0.6B one writes a plain space where the 110M one
writes `▁`), which affects only the id-to-name table the dump prints.

It is the encoder output, and FluidAudio says so itself in
`CtcModels.swift:7-11`:

    /// - ctc110m: Blank-dominant (CTC head is auxiliary loss), greedy produces ~113% WER
    /// - ctc06b: CoreML conversion issue causes greedy to produce ~158% WER (should be ~14%)
    ///
    /// Recommended approach: Use TDT for transcription + CTC for vocabulary scoring
    /// via constrained CTC rescoring.

The recommendation in that same comment is the constrained-CTC path this pass
already uses, which is why the model was worth measuring rather than dismissed
on the warning. Measured, the conversion damage is not confined to greedy
decoding: it reaches the per-frame log-probs the constrained path reads, as NaN.

## A correction to round 4, found on the way

**On the fuller set the acoustic score is further behind the constant than
round 4 reported, not closer.** Same model, same code, larger cache:

| | round 4 (130 clips) | re-harvest (145 clips) |
|---|---|---|
| scored spans | 57 | 66 |
| argmax raw score | 28/57 (49%) | 33/66 (50%) |
| **keep what the decoder wrote** | **34/57 (60%)** | **45/66 (68%)** |
| argmax's deficit | 11 points | **18 points** |

Argmax stayed at chance; the constant gained 8 points. Round 4's conclusion —
"a predictor that loses to a constant carries no signal" — is stronger on the
better set, not weaker. **Quote the re-harvest row, not the committed one**, for
anything measured against this set.

## What this settled, and what it did not

**Settled: `parakeet-ctc-0.6b-coreml` is unusable as exported.** NaN on 471 of
732 frames, 62 of 91 spans with no usable frame at all, 53 of 72 score lines
saturated at multiples of `-FLT_MAX`. That is enough to keep it out of the app.

**Not settled: whether weak acoustic evidence is the binding constraint on the
vocabulary pass.** That question is still open, because the larger model never
produced usable evidence to compare against. Nothing here is evidence that CTC
model size does not help. A broken export is not a null result and must not be
filed as one.

## Recommendation

**Do not ship `parakeet-ctc-0.6b`, and do not read this as closing the
model-size question.** The flag and both harnesses stay, so re-measuring against
a fixed release is one command per model.

**What would unblock the original question:** a working 0.6B CTC export, or the
untried hybrid `parakeetTdtCtc110m` (`ModelNames.swift:55`), or reporting the
NaN upstream to FluidInference and waiting for a re-export.

**Meanwhile the next move is still the menu, not the model.** Round 4 said
measure what is lost by not building the menu at all. Nothing here changes that,
and the re-harvest makes the case stronger than round 4 could.

Measured against FluidAudio 0.15.5, `gemma4:e4b`, temperature 0, nothing else
loaded, on the 145 labelled clips of `tests/menu-cases.yaml`. Build only, never
installed; the running app was left alone.
