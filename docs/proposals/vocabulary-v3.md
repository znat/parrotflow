# Vocabulary v3 — the acoustic path does not pay

**Status.** Plan. Replaces `docs/proposals/vocabulary-v2.md`, which was written
around improving the LLM judge. That direction was measured over seven rounds
and rejected.

**The headline.** On the 141 labelled clips, throwing away every proposal the
acoustic pass makes — and keeping the `heard:` replacement tables — scores 103
correct against today's 84. All 27 of today's wins survive it, and all 19 of its
losses go. The acoustic proposal path buys no wins the rules do not already
deliver. **The first thing to do is switch it off and confirm that on live
dictation.** It is a config change, not a feature.

**Read part 1 before writing any code.** It is the state of the world. Each item
is a directive with its evidence attached, so you can check it or falsify it. It
exists so nobody spends two more days re-measuring what is already known.

**Where evidence lives.** Some is on `main`. Most is on spike branches that were
never merged. Every claim names its source. Read an unmerged one with
`git show origin/<branch>:<path>`; do not merge the branch.

---

# Part 1 — What is true

## 1. What works, and what does not

**Every loss the pass causes is an overwrite.** 19 losses over 141 clips, and in
all 19 the vocab-off transcript equals the label exactly and a term was written
over an ordinary word the speaker meant. There is no second failure mode: the
pass never truncated a sentence, never half-corrected a name, never lost a clip
to a slow judge. One failure mode is why one blunt remedy addresses all of them.
`tests/vocabulary-losses.txt` on `origin/experiment/does-vocabulary-pay`.

**The pass is net positive only because of the replacement rules.** Net +9 over
141 clips against no vocabulary at all: +18 on the 68 clips about a term, **−9
on the 73 controls, with zero wins there**. Then the prototype separated the two
halves: with the acoustic path vetoed and the rules left running, the wins hold
at 27 and the losses go to 0. The rules earn the +18. The acoustic path spends
the −9.

**Comparing audio to a spelling is inverted. Do not build on it.** Every
acoustic number the pass computes asks the decoder what it thinks of a term as a
*string*. With the vocabulary bonus removed, a term the speaker did **not** say
scores *higher* than one they did: AUC 0.318 over 33 correct and 66 wrong
proposals. On the rescorer's own proposals a term that was said is at chance
against a term absent from the sentence, 0.454. Round 5,
`origin/spike/raw-score-separation`.

**Comparing audio to the speaker's own recordings carries real signal — and it
is not enough.** DTW over MFCCs against `voice/samples/<Term>/` separates a
loss-decisive proposal from a win-decisive one at AUC 0.815, and separates "the
term was said" from "the term was not said" at 0.874 on proposals and 0.935 on a
label-built set. Wired in as a rejection filter it scores 104 of 141. **Vetoing
every proposal blindly scores 103.** Head to head the measured filter wins 8 and
loses 7. See the epitaph in part 2.

**The LLM judge is wrong on the failure class that is left.** On the eight clips
where an ordinary word was overwritten, the shipped prompt scores **0 of 8**, and
it did so in four rounds with ten framings. It is also the most expensive thing
in the pass: on live dictation the `vocabulary` stage takes a median of **1213
ms** (77 dictations, `stages[].vars.ms` in `trace.jsonl`). Replays give 559 ms,
which is where the 575 ms figure in circulation comes from; it describes a warm
model answering the same menus over and over.

**The residue is a term whose rendering is an ordinary English word.** This
speaker says `Praisy` as "praise", and 6 of the 26 recordings in
`voice/samples/Praisy/` *are* the word "praise". Term and word are the same
sound, so no measurement of sound can separate them. Three of the filter's four
remaining losses are that class, and so are the eight clips the judge scores 0
on. **This is the open problem.** It needs context, not audio.

**Three terms have never rescued a clip and have cost nine.** `Redcrawl` 0 wins
/ 4 losses, `Supabase` 0 / 4, `Ollama` 0 / 1. `Vercel` is 9 / 1 and `Praisy` is
18 / 8. Anything global is the wrong shape; measure per term.

**The vocabulary bonus is a flat prior, applied before the app can see it.**
`ContextBiasingConstants.rescorerConfig(forVocabSize:)` returns `cbw: 4.5` at
every vocabulary size; the per-term amount comes from
`adaptiveCbw(baseCbw:tokenCount:)`, so it is keyed to token count and nothing
else. FluidAudio's `shouldReplace` is computed on the *boosted* score
(`VocabularyRescorer+TokenEvaluation.swift:109-113`), so which candidates exist
at all is decided before `Vocabulary.autoApplies` ever runs.

**Do not switch the bonus off as a fix.** `PARROTFLOW_CBW=0` exists on
`origin/spike/raw-score-separation`. At 0 the pass makes 201 proposals instead of
339, the rescorer's own 59 instead of 111, and the ratio of failures to successes
is unchanged. It costs recall and buys nothing. Keep it as a measurement tool.

**The score block in the judge's prompt is decoration.** Argmax on it is 28/57
spans; the constant "keep what the decoder wrote" is 34/57. A 2-nat gap is no
more reliable than a 0.1-nat gap. Round 4, on `main` in
[judge-framings.md](judge-framings.md).

## 2. How to measure here, or you will fool yourself

**Always measure the blind version of your mechanism.** This is the sharpest
lesson of the whole effort. The rejection filter beat the vocab-off arm, beat
today's pass by 20 clips, broke nothing, kept the right term while dropping the
wrong one in the same sentence, and cost a millisecond. It passed every check
anyone had proposed. Then someone set the tolerance to 0.01 so that it rejected
everything without measuring anything, and that scored 103 against the filter's
104. **A mechanism that does not beat its own blind version has not been shown to
work.** Build the stupid control before the clever one.

**Watch for a flat response curve.** The filter's tolerance sweep scores 102–104
everywhere from 0.01 to 1.00 and only falls once it stops removing much. A score
that tracks *how much* a mechanism removes rather than *how well* it chooses is
the same warning in another shape.

**Replayed decoder scores are nondeterministic. Use repeated runs and report
flips.** The same clip replayed ten times gives term scores spread over 5 nats on
a long clip. About one proposal in twenty moves more than a nat between replays;
the worst moves 8.1 nats. That is larger than most margins this work argues
about. Every harness takes `--runs N` and reports how many clips changed outcome
between runs. A single-run number within 2 cases of its baseline decides nothing.

**Report wins and losses separately. Never net alone.** A filter that vetoes
everything looks excellent on net. Report the absolute correct count beside them,
and the arm that does nothing.

**Split the totals by class, always.** 73 of the 145 clips in
`tests/menu-cases.yaml` are controls that no vocabulary term should touch. A
single total hides a control moving right while a term clip moves wrong. The
`# picked up:` comment on each entry says which class it is in.

**Keep the controls in the case set.** They can only be damaged, so they are the
only honest measurement of what the pass costs. Today's pass turns 9 of them
wrong and wins none.

**Compute the do-nothing baseline.** "Keep what the decoder wrote" is right on 34
of 57 scored spans, 60%, and on 47 of 77 spans overall. Most proposals anyone
will make lose to it. Quote it beside every arm.

**Verify the installed binary matches the tree before any live claim.** The app
prints a build stamp under `--version` and as its first log line, e.g. `build:
78d7ba2-dirty`. A stale `/Applications` bundle once produced a whole round of
wrong conclusions.

**`--no-vocab` does not switch the pass off, and `calibrate.py` believes it
does.** It sets `config.vocabulary.acoustic = false` (`TranscribeCommand.swift:28`)
and nothing else. The `heard:`/`pronunciations:` lists still become
`Config.vocabularyRules`, so `replacements` still writes names
(`Pipeline.swift:784-786`); those rules still raise `vocabulary.count`
(`Pipeline.swift:714-731`), so the `vocabulary:` judge stage still fires. On clip
`17-39-40` the flag changes the transcript not at all.
`scripts/calibrate.py:130-133` passes it and calls the output "what the
recogniser heard". It is not.

**Three different off arms, and they are not the same measurement.** Know which
one you want.

| what you want | how |
|---|---|
| no vocabulary at all | empty `terms:` in a scratch `vocabulary.yaml` — no context, no rules, `vocabulary.count == 0`, judge skipped |
| the acoustic path off, rules kept | `acoustic: false` in `vocabulary.yaml`, terms and `pronunciations:` left in place |
| a third of the acoustic path off | `--transcribe --no-vocab`, which is almost never what you meant |

**Say plainly when tuning and reporting use the same set.** Rounds 1 to 4 tuned
and reported on the same 53 cached menus. So did the spotter-floor sweep. So did
the filter's tolerance. None has a held-out set, and each says so. Keep saying
so.

**A wording change worth one case is noise.** Five wordings of one sentence in
the judge prompt scored 38, 39, 40, 41 and 42 on the same 53 cases.

## 3. About the recordings

Recordings are the one asset that gets better with use. Keep collecting them
whatever decides.

**Exemplars carry the session, not just the word.** Scoring read speech against
recordings from the same six minutes gives 0.920 pooled; against spontaneous
recordings from another day it gives 0.856. The same-session advantage is about
**0.06 AUC**. Microphone, room and style all sit inside that number and were not
separated. Treat a recording made in one session as worth less against audio from
another.

**Read speech is not dictation.** The 48 scripted clips are more careful —
steadier pace, fewer fillers, fuller vowels. Any number resting only on them is a
number about careful speech. Keep them in their own block of
`tests/menu-cases.yaml` and never fold them into a gate total.

**The distance scale differs per term, so normalise per term.** `Matthieu`'s
entire correct range sat above `Praisy`'s entire wrong range. No global threshold
can separate both. Normalising is worth about 0.05 AUC (0.815 against 0.768).

**A term with very few recordings may confirm but must not reject.** Below three
usable recordings there is no spread to compare against — two recordings give
exactly one exemplar-to-exemplar distance. Two *good* recordings can still be
worth a lot: `Supabase` separates at 0.991 on two spontaneous ones.

**Some terms have never once been proposed correctly, so they cannot be evaluated
on the proposal set at all.** Five of eleven have no correct-proposal row in the
whole spontaneous archive: `Redcrawl`, `Arexvy`, `Claude`, `Mirza`, `Redrock`.
Recordings cannot create a pair to rank. Those terms need a set built from
labels.

**Recordings mined from the corpus you measure on must be held out by clip.** 49
of the 145 clips are the source of a recording. Without the hold-out a span is
compared against a copy of itself, scores near zero, and is never rejected.
`voice/observations.jsonl` carries `sample` and `wav`, which is what makes the
hold-out possible; anything that writes a recording must write its source clip
too. The hold-out is per clip and does not cover the corpus-level fit — the
archive was mined from this corpus and describes it well, so **every number
resting on `voice/samples/` is better than the truth by an unknown margin.**

**Live dictation holds nothing out.** There is no clip file, so a recording cut
from the dictation being transcribed would be compared against itself. Harmless
today because nothing writes on a correction yet. It stops being harmless the
moment something does.

**A term whose rendering is an ordinary word is out of reach of any acoustic
method.** Know which terms those are and route them elsewhere rather than
pretending.

## 4. About the models and the framework

**FluidAudio decides `shouldReplace` on the boosted score.** The app never sees
the candidates the bonus suppressed. Any reasoning about "what the audio
preferred" must subtract the bonus first — `Vocabulary.apply` does, using the
token counts kept from `prepare`.

**The transcriber and the name-scorer are different models with different
clocks.** The transcript is written by `parakeet-tdt-0.6b-v3`; names are scored
by `parakeet-ctc-110m`, chosen by the default argument of
`CtcModels.downloadAndLoad()`. Timings and scores from one do not describe the
other.

**`parakeet-ctc-0.6b`'s CoreML export returns NaN.** 471 of 732 frames under an
uncertain span come back NaN across all 1024 tokens; 62 of 91 spans have no
usable frame. 110m has zero of either. This ruled out a model, not a hypothesis:
whether a bigger CTC model gives better evidence is still open.
`origin/spike/ctc-06b`.

**`parakeet-tdt-ctc-110m` ships without a CTC head.** The directory is
`Preprocessor`, `Decoder`, `JointDecision` and a vocab file. There is no
`CtcHead.mlmodelc` and no `MelSpectrogram.mlmodelc`; loading it fails.

**`JointDecision` returns a decision, not a distribution.** The joint emits one
`token_id` per step, conditioned on what it already emitted. Transducer rescoring
needs a posterior over the vocabulary per frame, so it needs a re-export, not a
flag.

**A bigger judge is worse.** `gemma4:12b` scores 17/28 where `gemma4:e4b` scores
24/28. Replies parse cleanly; size is not the lever. Benchmark with nothing else
loaded — MLX scores shift with memory state.

## 5. Traps that cost real time

**The app log truncates at 1 MB.** `Log.swift:44-45` truncates to zero at 1
000 000 bytes. That is roughly the last fifteen minutes of replaying. Dump what
you need to a file during the run; do not plan to grep it afterwards.

**Latency is not in the app log at all.** Nothing logs a judge duration. The
number lives in `~/Recordings/ParrotFlow Dev/trace.jsonl`, as `stages[].vars.ms`
on the `vocabulary` stage (written generically for every stage at
`Pipeline.swift:745`), with `vars.asked` giving how many sentences went to the
model and `vars.model` the model id.

**`trace.jsonl` is append-only. Take the first entry per clip.** The newest entry
is the current run, not the original dictation. The archive holds 2616 wavs;
2160 distinct clips have a trace entry, and 2035 of those carry word timings on
their first entry. 456 wavs have no trace entry at all, so any harness that
assumes the trace covers the archive is wrong by about a sixth.

**Do not amend and do not force-push.** Findings are recorded in commits on
branches other people read.

**A harness that hardcodes `/Applications` scores a stale binary.**

**Installing a transform without rebuilding the app can silently disable a
stage.** Check the log for the stage's own lines, not for the absence of errors.

**Report chance in any table that ranks.** Half the cached menus have two
options, so top-3 is nearly free.

## 6. Onboarding needs an empirical confusables method

**`calibrate.py confusables` ranks by spelling distance and misses six of the
eight collisions that actually happen.** It walks a word-frequency list, computes
`1 - levenshtein(a,b) / max(len(a), len(b))`, keeps anything at 0.55 or above and
returns the top 8 (`scripts/calibrate.py:68-125`). Nothing acoustic is involved.
But the live collisions come from the spotter path, and the spotter does not read
spelling at all — it searches for the term's *sound* over the whole clip.
`Praisy` over "proprietary", `Supabase` over "rebase", `Ollama` over "an
explanation", `Arexvy` over "already", `Claude` over "slide", `Matthieu` over
"matches": none of these is within edit distance of its term.

**The method onboarding needs is: run the spotter for a new term across the
speaker's archive and see which ordinary words it fires on.** The pieces exist —
`ParrotFlow --spot <clip> --terms <Term>` and the spotter dump — and 2616 clips
is a corpus. That produces the real confusable list for that term in that mouth,
which is what both the `calibrate` and `vocabulary-corpus` skills are trying to
guess. Build it before adding another spelling heuristic.

---

# Part 2 — The build order

## What the prototype measured, and what killed it

141 labelled clips, `--runs 3`, majority of three replays, `gemma4:e4b-mlx` and
nothing else loaded, built but never installed.
`origin/proto/reference-matching`, `docs/proposals/reference-matching-proto.md`.

| arm | correct | wins | losses | net | flips |
|---|---|---|---|---|---|
| vocabulary off (empty `terms:`) | 76 | — | — | — | 0 |
| today | 84 | 27 | 19 | +8 | 8 |
| today + tuned rejection filter | 104 | 32 | 4 | +28 | 2 |
| **control: veto every proposal blindly** | **103** | **27** | **0** | **+27** | 0 |

Wins and losses are against the vocabulary-off arm. The control sets the
tolerance to 0.01 so every proposal is rejected whatever the audio says. It is
the acoustic proposal path switched off with the `heard:` tables left running.

Head to head the tuned filter beats the blind one 8 wins to 7 losses. The
tolerance curve is flat — 102 to 104 everywhere from 0.01 to 1.00 — so the score
tracks how much is removed, not how well it is chosen.

By class:

| class | clips | off | today | tuned filter | veto everything |
|---|---|---|---|---|---|
| about a term | 68 | 20 | 37 | 50 | 47 |
| controls | 73 | 56 | 47 | 54 | 56 |

The controls line is the clearest. The pass turns 9 controls wrong and wins none
of them. Vetoing everything gives all 9 back. The tuned filter gives 7 back and
keeps 2 wrong.

**Almost every clip in the 8-versus-7 is `Praisy`** — the term this speaker
pronounces as "praise". The measurement guesses on those, and guesses about half
right.

## The open item, resolved: the `Mathieu` veto

The prototype logged:

```
reference: "Mathieu" -> "Matthieu" vetoed — 2.874 from the nearest recording,
the term's own spread is 3.053 over 10
```

That proposal is correct — round 7's table has `07T15-21-29` in group A at
2.874, `Matthieu` really was said — and 2.874 is below the spread.

**The rule does not differ from its description. The tolerance in force was not
1.00.** `ReferenceMatch.verdict` rejects on `distance > tolerance * spread`, and
the two numbers it logs are the two it compared. At 1.00 this proposal is kept.
The line can only come from a run below 0.94.

The sweep confirms it: the published table runs 0.01, 0.90, 0.95, 0.98, 1.00,
1.02, 1.05, 1.10, and the four arms at or below 0.98 all reject this proposal.
So does the log — every veto in the 16:45–17:00 run of 2026-08-09 was checked,
and the smallest `distance / spread` ratio vetoed is 0.834.

**So it is not a false veto and not a bug.** It is the price of a lower
tolerance: below about 0.94 the filter starts eating correct proposals, and
`07T15-21-29` is one of the first. Which is also why the 0.90 arm scores 30 wins
against 1.00's 32. Note for anyone who returns to this: `ReferenceMatch.swift`'s
own comment argues 1.0 is "the wrong default", because one bad auto-mined
recording — `Vercel/09-brazil.wav`, `Tasmeen/06-that'smeanssend.wav` — widens the
cloud for every proposal. That is an argument for pruning the archive, not for
lowering the constant.

## PR 1 — switch the acoustic path off, and measure it

**Changes.** No product code. `acoustic: false` in a scratch `vocabulary.yaml`,
terms and `pronunciations:` left in place, run as a fourth arm.

**Why.** It is the control arm expressed as config. Nobody had scored it. If it
reproduces 103, the acoustic pass is a config line away from being switched off
and the rest of this plan changes shape.

**Size.** A config copy and one run. Half a day of machine time.

**Verified by** `reference-ablation.py --runs 3` over the 141 labelled clips
against the off, today and veto-everything arms. `acoustic: false` should land on
the control arm's numbers: 103 correct, 27 wins, 0 losses, controls back to 56.

**Falsified if** it does not match the control arm. The two are supposed to be
the same thing by two routes — the veto drops proposals before `autoApplies`, and
`acoustic: false` stops them existing — so a gap means one of them does something
extra. Find out which before going further.

## PR 2 — confirm it on live dictation

**Changes.** None. Dictation and a log.

**Why.** Every number above describes replays. The same clip live and replayed
scores from the same distribution, but nothing about the *rules* path has been
checked live since it became load-bearing.

**HUMAN.** Dictate the standing regression sentences on a build whose stamp
matches the tree, with `acoustic: false` and with today's config, and paste both
transcripts:

1. "in general in our data set" — must not become Redcrawl
2. "you don't need to update the design" — must not become Supabase
3. "the bedrock of civilization" — must not become Redrock
4. "Let's praise Praisy's work"
5. "deployed on Vercel against the Versailles Castle", one sentence
6. "Matthieu's work"
7. "Let's praise Matthieu's work" — the `'s` must survive
8. "Let's praise Antonio's work" — the control, not a vocabulary term

**Verified by** 1–3 coming out as ordinary English under `acoustic: false`, and
4–6 still getting their names from the rules.

**Falsified if** a name the rules are supposed to deliver stops arriving. Then
the rules cover less than the replay says and the acoustic path is doing
something the ablation did not attribute to it.

## PR 3 — land the harnesses on `main`

**Changes.** Ports `vocab-ablation.py` and `vocab-losses.py` from
`origin/experiment/does-vocabulary-pay` and `reference-ablation.py` from
`origin/proto/reference-matching` into `scripts/`. Arms are
`name=CONFIG_DIR[,VAR=VALUE]`, every pair reported against every other, wins and
losses separately, split by class, majority of `--runs N` with a flip count.
Documents the three off arms from part 1.

**Size.** About 450 lines of Python. No Swift, no behaviour change.

**Verified by** reproducing the published baseline: vocabulary off 76/141, today
84/141, 27 wins and 19 losses, 5 clips flipping.

**Falsified if** the off arm is not near 76, or wins and losses swing further
than the flip count explains. Then the archive or the case set has moved and
nothing downstream can be trusted.

## PR 4 — a correction keeps the audio

**This is the highest-value item in the plan, and it is about recordings rather
than text.** Recordings are the only asset that improves with use, whatever ends
up deciding. Today `voice/samples/` grows by hand and by mining; every correction
the speaker makes is a labelled recording of a term in their own voice, being
thrown away.

**Changes.** `ConfigWriter.addReplacement` writes a text rule to `config.yaml`
today. Add: append an observation to `voice/observations.jsonl`, cut the
corrected span into `voice/samples/<Term>/`, and record the source clip in the
observation so a later hold-out works. Promote the rendering into
`vocabulary.yaml` with `from: correction` and a `seen:` count. Ship a per-term
cap and a rule for dropping a rendering seen once and never again. `--forget
<term>` must remove all three.

**Size.** Moderate. Touches `ConfigWriter`, `VoiceStore` and the correction
panel.

**Verified by** simulating a correction and checking the three files; exceeding
the cap and checking the oldest unconfirmed entry is what goes; `--forget`
leaving `--check-config` clean.

**Falsified if** live dictation cannot produce a usable cut — no clip file, no
word timings, or a span that does not line up. Check that first, on one live
correction, before building the rest.

## PR 5 — mining that keeps the recordings you need

**Changes.** Three changes to `scripts/mine-pronunciations.py`, ported from
`origin/spike/exemplars-round-2`: read word times from `trace.jsonl` instead of
running the app, so mining an already-traced archive needs no build; `--every`
keeps the occurrences the decoder got **right**, which the pronunciation table
does not want and the recordings very much do; count a possessive as the name,
which alone recovers `Redcrawl's`, `Arexvy's`, `Matthieu's` and eight more. Also
move the word dump above the pass's early guards so clips where nothing fired
still contribute.

**Size.** About 100 lines of Python.

**Verified by** re-mining the archive and reaching the recorded 122 recordings
over 11 terms, with the same per-term split.

**Falsified if** mining still needs a build, or if the recovered count of correct
occurrences is near zero — that would mean the word timings do not survive the
trace. Note that 456 of 2616 wavs have no trace entry.

## PR 6 — the term that is an English word

**This is the problem that is left, and it is unsolved.** After the acoustic path
is off, the damage that remains is a term whose rendering is an ordinary word.
`Praisy` is "praise" in this mouth. Sound cannot separate them, the rules fire on
the spelling, and the judge scores 0 of 8 on exactly this class.

**Start with a measurement, not a design.** Two questions, in order:

1. How many terms are in this class, for this speaker and in general? The
   empirical confusables method in part 1 §6 answers it — run the spotter for
   each term across the archive and see which ordinary words it fires on.
2. What does the pass cost on those terms alone, once the acoustic path is off?
   If it is one term, the question is whether one term justifies any machinery.

**Do not reach for the judge again without reading the dead ends below.** Ten
framings, two routers, two menu shapes and a score block have all been measured
on this class and none moved it.

## PR 7 — the possessive the decoder drops

**Unscoped and unmeasured. Do not start it with a design.**

When the decoder spells a term correctly, nothing is proposed, no slot opens and
the judge is never asked. "Let's praise Matthieu's work" came out as "Let's
praise Matthieu work" with **no vocabulary log lines at all**. Span variants
cannot help, because they are readings of a substitution that was never offered.

What is measured is one transcript and one empty log. Nobody has checked whether
the `'s` is audible in the recording. Start there, then count the cases across
the archive. Only then choose between opening a possessive slot inside the pass
and treating it as ordinary dictation grammar outside it — the second is a larger
stage and needs its own eval set.

## Dead ends — do not retry these

Each was measured. One line each so nobody spends a day rediscovering it.

- **Reference matching as a rejection filter.** AUC 0.815 is real signal, and it
  is not enough: vetoing every proposal blindly scores 103 against the tuned
  filter's 104, head to head 8 wins against 7 losses, and the tolerance curve is
  flat from 0.01 to 1.00. `origin/proto/reference-matching`.
- **Rewording the judge prompt.** Ten framings, 35 to 42 on 53 tuned cases, where
  five wordings of a single sentence already span 38 to 42. Round 1, on `main`.
- **Deleting the term list from the prompt.** Wins 4 of the collision class and
  loses 8 other cases — the list is the only thing that tells the judge `Praisy`
  is a spelling at all.
- **Routing a case to code or to the judge on `Replacements.isRealWord`.** 12 of
  53 misrouted, and close to inverted: the 2 sent to code are the 2 code gets
  wrong, and 10 sent to the judge would have been settled by argmax. Best arm
  32/53 against 41/53. Round 2, on `main`.
- **The blank / cloze menu.** 37/53 against the sentence form's 41/53, and
  sorting the candidate letters — which changes no word of the question — moves it
  to 31/53. Over all 77 spans it does not remove overwrites, it moves them off the
  eight clips being watched. Round 3, `origin/spike/judge-blanks`.
- **The acoustic score block as evidence for the judge.** Argmax 28/57 against the
  constant's 34/57; no gap bucket predicts correctness. Round 4, on `main`.
- **Rejecting on the raw acoustic score, bonus removed.** AUC 0.318. Round 5,
  `origin/spike/raw-score-separation`.
- **Blending the reference distance with the acoustic score.** Rank-average 0.597
  against the distance alone at 0.812 — what you get from averaging a good
  predictor with an inverted one. Round 6.
- **A bigger judge.** `gemma4:12b` 17/28 against e4b's 24/28.
- **A bigger CTC model.** The 0.6B export returns NaN; the hybrid 110m has no CTC
  head. Not a null result — unanswerable on this machine.
- **A cross-encoder reranker as the picker.** top-3 28/28, top-1 19/28 against
  chance 8.1. Rerankers rule out; they do not pick.
- **A fitted λ in the prompt in place of the prose scale.** The same number scores
  38 or 42 depending on the sentence around it.

## Still open, deliberately not scheduled

- **`Vocabulary.spotterFloor` from -5.0 to -4.25.** In-sample on 47 spotter
  proposals it keeps 39 of 39 right and cuts 28 of 92 wrong. It is a loudness
  gate, not a rejection rule: it separates "something is here" from "nothing is
  here" at 0.999 and cannot tell a loud wrong proposal from a loud right one —
  the two best-scoring proposals in the set are a correct `Vercel` over
  "Versailles" at -2.28 and a wrong `Vercel` over "universal" at -2.51, in the
  same clip. It also gates `spottedAnything`, so raising it can silence a clip.
  Moot if PR 1 removes the path.
- **A stronger representation than MFCC + DTW** — one vector per recording from a
  speech encoder, compared by cosine. Rounds 6 and 7 both recommend it. Cost is
  not the reason to want it: the dynamic program measured at about 1 ms per
  proposal. Only worth revisiting if a use for the distance survives PR 6.
- **"Too close, ask the user"** on a reranker's margins. Its own proposal.

---

# Part 3 — Cleanup this work owes

**`decide_above` never fires. Delete it.** It drops a rescorer proposal when the
decoded word beats the de-boosted term by more than 3.0 nats
(`Vocabulary.swift:637-639`). Over the 57 scored spans in the cache the largest
gap is **2.72**, and 40 of 57 are under 1. It is also described to the judge in
`verify_names.md` as "a gap over about 4 means the sound can decide", which is a
scale that does not exist in this data. Removing it removes a config key, a
`--check-config` line and a paragraph of prompt.

**`--no-vocab` is misleading and `calibrate.py` depends on it.** Either make it
switch the whole pass off — acoustic, rules and the judge's trigger — or rename it
`--no-acoustic` and fix `scripts/calibrate.py:130-133`, which calls its output
"what the recogniser heard". Anything calibrated with it read a transcript the
rules had already corrected.

**`docs/transcription.md:273` says the judge runs on about one dictation in
twenty. It is about two in five.** Counting the first trace entry per clip, of
the 190 live dictations whose pipeline had a `vocabulary` stage at all, the judge
was asked on 77 — 41%. The 4% figure you get by dividing by all 1923 live clips
is wrong, because most of them predate the stage. Fix the sentence and name the
source, or drop the number.

**The gate baselines everyone quotes describe a case set that no longer
exists.** Re-recorded on the 141 labelled clips: `before-after.py --runs 3` is 22
fixed / 38 broken / 18 regressed / 63 already right, against the documented 20 /
26 / 11 / 70; `menu-recall.py --runs 3` is recall 112/141 and picked 86/141,
against 102/127 and 90/127. Recall holds as a rate, picked falls from 70.9% to
61.0%, regressions rise from 8.7% to 12.8%. Block 3 is harder than the set the
floors were set on. `origin/spike/ctc-06b`.

**The span variants from PR #66 need re-measuring once PR 1 lands.** The
possessive variant demonstrably produces bad sentences today — "She deserves
Praisy's finishing that so fast" over "praise for finishing", and "They deserve
Praisy's shipping" over "praise for shipping". `max_per_term: 2` was chosen on
the tight end of a plateau measured on the old 37-clip set, one run each. If the
acoustic path goes, most of the variant machinery goes with it; if it stays, redo
the sweep on 141 clips with `--runs 3`.

**Nine spike branches are unmerged.** For each, whether its finding survives on
`main`:

| branch | finding on `main`? |
|---|---|
| `spike/judge-blanks` | **No.** Round 3 and `tests/judge-failures.txt` exist only there. |
| `spike/gap-informative` | Yes. Merged as PR #73; round 4 is in `judge-framings.md`. Branch can go. |
| `spike/ctc-06b` | **No.** The NaN result, `ctc-06b-report.md` and the re-recorded gate baselines exist only there. |
| `spike/raw-score-separation` | **No.** The AUC 0.318 result, `PARROTFLOW_CBW` and the spotter-floor sweep exist only there. |
| `spike/reference-matching` | **No.** Round 6, `scripts/reference-matching.py` and the per-proposal distance table exist only there. |
| `spike/exemplars-round-2` | **No.** Round 7, the 48 scripted clips, the mining changes and the 122-recording corpus exist only there. The most valuable unmerged branch. |
| `experiment/does-vocabulary-pay` | **No.** The ablation, `vocab-ablation.py`, `vocab-losses.py` and the 19-loss list exist only there. |
| `proto/reference-matching` | **No.** The prototype and the control arm that settled this plan's direction. |
| `spike/onset-pilot` | **No.** Code only — `PARROTFLOW_LOGPROB_DUMP`. Already re-ported into `spike/ctc-06b`, so nothing is lost if that one survives. |

Eight of the nine carry something that exists nowhere else. Land the findings —
as documents, harnesses and this plan's PRs — before deleting any branch.
