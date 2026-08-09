# Vocabulary v3 — the acoustic path does not pay

**Status.** Plan. Replaces `docs/proposals/vocabulary-v2.md`, which was written
around improving the LLM judge. That direction was measured over seven rounds
and rejected.

**The headline.** On the 141 labelled clips, throwing away every proposal the
acoustic pass makes — and keeping the `heard:` replacement tables — scores 103
correct against today's 84. All 27 of today's wins survive it, and all 19 of its
losses go. The acoustic proposal path buys no wins the rules do not already
deliver. **The first thing to do is switch it off and confirm that on live
dictation.** It is nearly a config change: PR 1 measured `acoustic: false` and
it lands on the control arm everywhere except two clips, which it costs. The
switch is not free and the reason is in PR 1's result.

**The second headline: keep the clip bank and develop it.** The blind control
killed the *rejection filter as built*, not the recordings under it. The signal
is real — AUC 0.935 pooled on a label-built set, `Supabase` 1.000, `Redcrawl`
0.966, and 7 of the 8 words the app actually wrote a name over sit farther from
that name than every real utterance of it. What failed is the decision rule.
So the recordings stay, and the work is to build a rule worth the evidence.
Part 1 §7 says why a clip beats another text rule. PR 6 says what to measure.

**The bar, for anything built on the clips.** Beat the blind veto on the
three-arm ablation. Not today's pass — the blind veto. A mechanism that cannot
beat "veto everything" is not earning its complexity, whatever its AUC.

**Read part 1 before writing any code.** It is the state of the world. Each item
is a directive with its evidence attached, so you can check it or falsify it. It
exists so nobody spends two more days re-measuring what is already known.

**Where evidence lives.** Some is on `main`. Most is on spike branches that were
never merged. Every claim names its source. Read an unmerged one with
`git show origin/<branch>:<path>`; do not merge the branch.

## Provenance — nothing here is on `main`

Read this before looking for anything. The most common mistake is to assume this
work landed.

**This plan.** Branch `docs/vocabulary-v3-clip-bank`, branched from
`docs/vocabulary-v3`. **Neither is merged.** `main` still carries the superseded
`docs/proposals/vocabulary-v2.md` and has no `vocabulary-v3.md` at all.

**The evidence.** One line each, and whether the finding exists on `main`:

| branch | what is on it | on `main`? |
|---|---|---|
| `proto/reference-matching` | the working prototype, `ReferenceMatch.swift`, `reference-ablation.py`, and the blind control that settled the plan's direction | no |
| `spike/exemplars-round-2` | round 7 — the 48 scripted clips, the mining changes, the 122-recording corpus and the per-term AUCs | no |
| `spike/reference-matching` | round 6 and `scripts/reference-matching.py`, the offline distance tool PR 6a starts from | no |
| `experiment/does-vocabulary-pay` | the ablation harness, `vocab-ablation.py`, `vocab-losses.py` and the 19-loss list | no |
| `spike/raw-score-separation` | the AUC 0.318 result, `PARROTFLOW_CBW`, the spotter-floor sweep | no |
| `spike/gap-informative` | round 4 | **yes** — merged as PR #73, in `judge-framings.md` |
| `spike/ctc-06b` | the 0.6B NaN result and the re-recorded gate baselines | no |
| `spike/judge-blanks` | round 3 and `tests/judge-failures.txt` | no |
| `spike/onset-pilot` | `PARROTFLOW_LOGPROB_DUMP`, already re-ported into `spike/ctc-06b` | no |

Part 3 says the same thing with what would be lost if a branch were deleted.

**The recordings.** `~/.config/parrotflow-dev/voice/samples/<Term>/` — **122 wav
files across 11 term folders**, outside the repository. They are kept out on
purpose: the archive is somebody's voice saying their colleagues' names.
`scripts/check-no-voice.sh`, which is on `main`, refuses a commit that carries
any of it. If they look missing, they are not in git and never were.

**The frozen reference.** `feat/vocabulary-skills-only`, at
`b6b8575 chore: freeze the vocabulary v2 prototype — reference only`. Read-only.
Do not commit to it.

**One page written before the control.**
`https://usercontent.scratchtml.link/0b489c9zkx45xizz`, expires 2026-08-13.
**Superseded on its central claim** — it presents reference matching as the
answer, which the blind control ruled out for the rule as built. Its diagrams
and its onboarding and corrections design still stand.

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

**Comparing audio to the speaker's own recordings carries real signal. The
filter built on it did not beat a blunt instrument.** Two separate facts, and
they are constantly confused.

The signal: DTW over MFCCs against `voice/samples/<Term>/` separates a
loss-decisive proposal from a win-decisive one at AUC 0.815, and separates "the
term was said" from "the term was not said" at 0.874 on proposals and 0.935 on a
label-built set — `Supabase` 1.000 over 9 A / 62 B, `Redcrawl` 0.966 over 8 A /
63 B. Seven of the 8 words the app really did write a name over sit outside the
entire range of real recordings of that name. Round 7,
`origin/spike/exemplars-round-2`.

The rule: wired in as a rejection filter it scores 104 of 141. **Vetoing every
proposal blindly scores 103.** Head to head the measured filter wins 8 and loses
7, and the tolerance curve is flat from 0.01 to 1.00.
`origin/proto/reference-matching`.

**What that does and does not show.** It shows the tuned filter's advantage over
blind vetoing is noise. It does not show the recordings are useless. The
decision rule is the part that failed, and §7 names the mechanism that makes it
fragile. PR 6 is the work.

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
whatever decides. §7 says why they are a better place to put effort than another
text rule, and where the rule built on them is fragile.

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

**One name is said more than one way, and the language is already on disk.**
This speaker dictates in two languages — `languages: [en, fr]`, line 22 of his
config — and `Matthieu` comes out French or anglicised. Those are two correct
pronunciations of one term, not one truth and one mistake. `trace.jsonl` already
records the language per dictation as `lang`, written by
`Trace.Record.recordLanguage` and declared at `Trace.swift:342`. Over the 2161
traced clips the first entry says `en` on 1952, `fr` on 51, and nothing on 158
written before the field existed. **Carry `lang` into
`voice/observations.jsonl`** beside the `from:`, `seen:` and `mic:` fields
`VoiceStore.Observation` already defines. It costs one field at write time and
it cannot be recovered afterwards.

**Language is a proxy, not the truth.** A speaker can say a French name the
French way inside an English sentence. The variable that decides anything is the
pronunciation variant, and clustering is what finds it (PR 6c). What the tag is
good for is coverage — whether each way a name gets said has clips behind it —
and giving a cluster a label a person recognises.

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

## 7. Why a clip and not another text rule

This is the design argument for keeping the recordings. It is an argument, not a
measurement. Read it as the reason to run PR 6, not as its result.

**A text rule is an instruction. A clip is evidence.** That difference decides
how each one behaves as the vocabulary grows.

**A rule fires unconditionally.** A `heard:` entry rewrites its string in every
dictation from now on, whatever the sound was. It is right on the sentences it
was written for. It is also on duty for every sentence nobody thought of.

**A rule's risk accumulates and cannot be read.** `Praisy: heard: praise` and
`Vercel: heard: versal` look the same on the page. One overwrites an ordinary
English word and the other does not, and the list does not say which. §6 exists
because nobody can read the answer off the list — it has to be measured against
the speaker's archive.

**`heard:` lists only grow.** A correction adds an entry. Nothing removes one.
Today the rules are clean: with the acoustic path vetoed they give 27 wins and 0
losses over 141 clips. That is a fact about 11 terms on one corpus, not a
property of rules. The rules are safe here because the list is short.

**A clip never fires.** It adds nothing and promotes nothing. Adding one moves a
distance slightly. It can make a rejection better or worse; it cannot write a
word into a sentence on its own.

**A clip is auditable by ear. No text rule is.** You can play
`voice/samples/Praisy/14-praise.wav` and hear that it is the word "praise". You
cannot listen to `heard: praise`.

**The catch: the rule as built is maximally sensitive to one bad clip.** State
it exactly, because this is what PR 6 attacks. `ReferenceMatch.verdict` in
`Sources/ParrotFlow/ReferenceMatch.swift` on `origin/proto/reference-matching`
does four things:

1. `distance` — the smallest DTW distance from the span to any usable recording
   of the term. A `min` over recordings.
2. `nearest` — for each recording, the distance to its nearest *other* recording.
   Leave-one-out.
3. `spread` — `nearest.max()`. The largest of those.
4. reject when `distance > tolerance * spread`.

**Step 3 is the weak point.** `spread` is a maximum, so one recording sets it.
A clip that is not the term at all sits far from every real one, becomes the
largest leave-one-out distance, and widens the cloud for every proposal of that
term. **One bad clip disarms the veto for that whole term.** The code's own
comment says so and names two, both mined automatically:
`Vercel/09-brazil.wav` and `Tasmeen/06-that'smeanssend.wav`.

**The query side is far safer, and that asymmetry matters.** `distance` is a
`min`, so a bad clip only counts when it is the nearest thing to the span being
judged. A bad clip is by definition unlike the term, so for a genuine utterance
of the term it rarely wins that `min`. Almost all the exposure is in `spread`.

**A second pronunciation does the same damage with correct data.** This is the
multilingual case and it belongs here, next to the outlier, because the
arithmetic is the same. Trace it through `ReferenceMatch.verdict` and it breaks
in two places:

- **The query side under-covers.** `distance` is a `min` over every usable
  recording. A genuine French `Matthieu` is only near the bank if the French
  pronunciation is *in* the bank. If it is not, the span sits at the
  between-cluster distance from everything and is vetoed. A correct utterance,
  rejected for being said the other way. **This is the multilingual failure that
  bites first**, and no threshold fixes it. Only clips do.
- **The spread inflates while the second cluster is thin.** `nearest[i]` is the
  distance from recording i to its nearest *other* recording, and `spread` is
  the largest of those. With both clusters well populated, every recording has a
  close neighbour inside its own cluster, so `spread` stays a within-cluster
  number. With **one or two** clips of the second pronunciation, those clips'
  nearest neighbour is across the gap, that gap becomes the maximum, and the
  veto is disarmed for the whole term. **A bilingual term poisons its own
  threshold**, and it does it worst exactly when the second pronunciation is new
  — which is when clips arrive one at a time from corrections.

**So compute the spread per cluster, not per term.** That follows from
correctness, not from robustness. Round 7 found the distance scale differs per
term. It differs per pronunciation for the same reason, and one number over both
clusters describes neither.

**This part is arithmetic, not a measurement.** Nobody has measured a bilingual
term's spread. In the prototype log `Matthieu` sits at 3.053 over 10 recordings,
which is unremarkable next to `Claude` at 3.436 over 6 — so either both its
clusters are covered or the effect is smaller than the variation between terms.
PR 6a should measure it.

**This argues for pruning and a robust statistic, not for a lower tolerance.**
Lowering the tolerance to compensate eats correct proposals — see the `Mathieu`
veto in part 2, where the filter starts rejecting true proposals below about
0.94.

**Do not overstate any of it.** Every number about the clip bank rests on
recordings mined from the corpus they are measured on. The hold-out is per clip;
there is no hold-out for the fact that the archive describes this corpus well.
The tolerance was tuned on the clips it is reported on. **The true numbers are
worse than the published ones and nobody knows by how much.** A held-out set is
owed before anything built on the clips ships.

---

# Part 2 — The build order

## What the prototype measured, and what it settled

**This table is the bar.** Every arm below is scored against it, and the arm to
beat is the bottom one, not the second one.

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

**What this does not say.** It does not say the recordings carry nothing. Round
7 measured them separately, without a decision rule on top: AUC 0.935 pooled,
`Supabase` 1.000, `Redcrawl` 0.966, and 7 of the 8 live overwrites farther from
the name than every real utterance of it. The signal is there and the rule threw
it away. PR 6 is the attempt to build a rule worth the evidence, and this table
is what it has to beat.

**Reproduced 2026-08-09 by PR 1**, same build and same command with a fifth arm
added. Off 76, today 85, tuned filter 104, veto 102. Today's arm flipped 3 clips
and the filter 1, so the one-clip differences on today and the veto are replay
noise. The table above stays as the prototype recorded it; PR 1's result block
carries the reproduction and the new arm.

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

### Result, measured 2026-08-09

**The falsifier fired. The gap is two clips wide and it is explained.**
`acoustic: false` does not reproduce the veto arm. It matches on the controls
and on the losses. It gives up two wins.

141 labelled clips, `--runs 3`, majority of three replays, `gemma4:e4b-mlx` and
nothing else loaded, built from `origin/proto/reference-matching` at `ad9f3c0`
and never installed. Wins and losses are against the `off` arm.

| arm | correct | wins | losses | net | flips |
|---|---|---|---|---|---|
| off (empty `terms:`) | 76 | — | — | — | 0 |
| today | 85 | 28 | 19 | +9 | 3 |
| tuned filter (tol 1.00) | 104 | 32 | 4 | +28 | 1 |
| veto everything (tol 0.01) | 102 | 26 | 0 | +26 | 0 |
| **`acoustic: false`** | **100** | **24** | **0** | **+24** | **0** |

The four published arms reproduce: 76 exact, 85 against 84, 104 exact, 102
against 103. Today flipped 3 clips and the filter 1, so a clip either way is
replay noise.

By class:

| class | clips | off | today | tuned filter | veto | `acoustic: false` |
|---|---|---|---|---|---|---|
| about a term | 68 | 20 | 38 | 50 | 46 | 44 |
| controls | 73 | 56 | 47 | 54 | 56 | **56** |

**The controls land where the plan predicted.** 56, all 9 given back, none lost.
The whole gap is on term clips.

Head to head, `veto → acoustic: false`: **0 wins, 2 losses.** Neither arm flipped
on any clip over three replays, so two clips is not replay noise.

**Both clips are the same sentence shape.** `Vercel` stands twice and one of the
two came from a `heard:` rule.

| | |
|---|---|
| said | And then you have a list of possible alternatives for Versailles, such as Vercel. |
| veto | And then you have a list of possible alternatives for Versailles, such as Vercel. |
| `acoustic: false` | And then you have a list of possible alternatives for **Vercel**, such as Vercel. |

| | |
|---|---|
| said | … we are visiting the Versailles castle while our app is being deployed on Vercel. |
| veto | … we are visiting the Versailles castle while our app is being deployed on Vercel. |
| `acoustic: false` | … we are visiting the **Vercel** castle while our app is being deployed on Vercel. |

**Where the two routes diverge, and it is not the veto.** `Vocabulary.wanted`
gates the whole pass on `config.vocabulary.acoustic && !terms.isEmpty`
(`Vocabulary.swift:89`), so `acoustic: false` produces no `Vocabulary.Outcome`
at all. The veto arm still runs the pass. It drops every proposal inside
`ReferenceMatch` and returns an `Outcome` anyway.

That `Outcome` carries one thing the judge needs. `Pipeline.swift:920` passes
`findings?.text` — the transcript as it stood before the rules — into
`VocabularyJudge.ruleParts`, which uses it to work out which occurrence of a
term a `heard:` rule wrote. With `findings` nil and the term standing more than
once, it can offer nothing. Replaying one gap clip under each arm:

```
acoustic: false
  vocabulary judge: "Vercel" stands 2 time(s) and no acoustic pass ran, so
  which one "Versailles" became cannot be told; that reading is not offered
  vocabulary judge: 0 slot(s) from 0 proposal(s)

veto
  vocabulary judge: 2 slot(s) from 2 proposal(s) — "Vercel" (Vercel), "Vercel" (Vercel)
```

So `acoustic: false` switches off the acoustic proposals and, as a side effect,
the judge's ability to revert a rule that fired twice in one sentence.
`Vercel: heard: [Versailles]` is the only rule on this corpus that does.

**What it costs the plan.** Two wins out of 141, both `Versailles`. The headline
survives: the acoustic path still buys no wins the rules do not deliver,
switching it off still gives all 9 damaged controls back, and it still removes
all 19 losses. What changes is that the switch is not free, and the fix is
product code rather than config. `ruleParts` should take the pre-rules
transcript from the `replacements` stage, which always has it, instead of from
the acoustic pass, which may not run. **That is not in this PR.** PR 2 should
watch for it live: sentence 5 of the standing regression list — "deployed on
Vercel against the Versailles Castle" — is exactly this shape.

**Cost.** 2115 transcriptions, 26 minutes of wall clock at 10.7 s/clip. The
"half a day of machine time" above is wrong by an order of magnitude, and a
cheaper screen-then-confirm design was considered and dropped for being slower
than the full run.

**Do not read 102 and 100 as precise.** Every arm here rests on recordings mined
from the corpus it is measured on, and the tolerance was tuned on the clips it
is reported on. Part 1 §7: the true numbers are worse than these by an unknown
margin.

### How to reproduce

Three scratch config directories, copied from `~/.config/parrotflow-dev`. Never
run against the live one.

| dir | `vocabulary.yaml` |
|---|---|
| `cfg-on` | unchanged, `acoustic: true` |
| `cfg-off` | everything from `terms:` down replaced by `terms: {}` |
| `cfg-noacoustic` | the one line `acoustic: true` changed to `acoustic: false`, every term and every `heard:` list left in place |

Each directory holds `config.yaml`, `vocabulary.yaml`, `verify_names.md`,
`transforms/` and `voice/`. The reference-matching arms read
`voice/samples/<Term>/`, so it has to be there. None of it is committed —
`scripts/check-no-voice.sh` on `main` refuses a commit carrying any of it.

Append this to each copy of `config.yaml`, or 2115 replays append to the
speaker's own `trace.jsonl`:

```yaml
audio:
  output_dir: /some/scratch/dir
```

Check each arm parses before starting. `cfg-noacoustic` must print
`vocabulary: acoustic: false, so 11 names are only matched by their
pronunciation rules` (`Config.swift:1830-1831`):

```sh
PARROTFLOW_CONFIG_DIR=$S/cfg-noacoustic \
  .build/ParrotFlowDev.app/Contents/MacOS/ParrotFlow --check-config
```

Then, from a checkout of `origin/proto/reference-matching`:

```sh
make app                                   # never `make install`

python3 scripts/reference-ablation.py --runs 3 --out arms.json \
  --arm "off=$S/cfg-off" \
  --arm "today=$S/cfg-on" \
  --arm "filtered=$S/cfg-on,PARROTFLOW_REFERENCE_MATCH=1,PARROTFLOW_REFERENCE_TOL=1.00" \
  --arm "veto=$S/cfg-on,PARROTFLOW_REFERENCE_MATCH=1,PARROTFLOW_REFERENCE_TOL=0.01" \
  --arm "noacoustic=$S/cfg-noacoustic"
```

`reference-ablation.py` exists only on that branch. PR 3 lands it on `main`.

## PR 2 — confirm it on live dictation

**Changes.** None. Dictation and a log.

**Why.** Every number above describes replays. The same clip live and replayed
scores from the same distribution, but nothing about the *rules* path has been
checked live since it became load-bearing.

**HUMAN.** Dictate the standing regression sentences twice — once with today's
config, once with `acoustic: false` — on a build whose stamp matches the tree.
The runbook below is the whole procedure. Paste both transcripts into the result
block.

**PR 1 changed one expectation.** Sentence 5 is the shape PR 1's gap clips have:
`Vercel` standing twice with one occurrence written by the `heard: Versailles`
rule. Offline, `acoustic: false` gets that sentence wrong. So this pass has a
predicted failure as well as predicted passes, which makes it a stronger test —
it confirms an offline finding live instead of only looking for absence of
damage.

**Verified by** 1–3 coming out as ordinary English under `acoustic: false`,
4, 6 and 7 still getting their names from the rules, and sentence 5 failing
exactly as PR 1 predicts — `Vercel … Vercel Castle` under `acoustic: false`,
correct under today's config.

**Falsified if** a name the rules are supposed to deliver stops arriving, other
than sentence 5's second `Vercel`. Then the rules cover less than the replay
says and the acoustic path is doing something the ablation did not attribute to
it. **Also falsified if sentence 5 comes out right under `acoustic: false`** —
that would mean PR 1's attribution to `Pipeline.swift:920` and
`VocabularyJudge.swift:307-323` is wrong, and the two-clip gap has another
cause.

### The runbook

Sixteen dictations, two arms, about twenty minutes. Nothing here touches product
code. It edits one line of your live `vocabulary.yaml` and puts it back at
step 9.

**Do not accept a correction during the pass.** A correction adds a rule to
`transcription.replacements` in `config.yaml`
(`ConfigWriter.addReplacement:23-28`), the app reloads on the save, and from
that point the two arms are running different rules. The transcripts stop being
comparable. If you correct something by accident, note it and redo both arms.

**1. Check the installed build against the tree first.** PR 2 changes no Swift,
so the code under test is `origin/main`. Often the installed app already matches
and steps 2 and 3 are unnecessary.

```sh
/Applications/ParrotFlowDev.app/Contents/MacOS/ParrotFlow --version
git -C ~/Documents/parrotflow rev-parse --short origin/main
```

The two strings must be equal, and the first must not end in `-dirty`. On
2026-08-09 both printed `78d7ba2`. If they match, go to step 4.

**2. Build a stamped build.** In a scratch worktree, so the stamp is a clean
hash and your working branch is left alone. `.claude/worktrees/` is in
`.gitignore`, so the tree is clean and `build-app.sh` adds no `-dirty`.

```sh
cd ~/Documents/parrotflow
git worktree add .claude/worktrees/pr2-build origin/main
cd .claude/worktrees/pr2-build
make app          # prints "==> Build stamp: <hash>"
```

**3. Install it and re-check the stamp.** `make install` stops the running app,
copies the bundle to `/Applications` and relaunches it.

```sh
cd ~/Documents/parrotflow/.claude/worktrees/pr2-build
make install
/Applications/ParrotFlowDev.app/Contents/MacOS/ParrotFlow --version
grep "build: " ~/Library/Logs/ParrotFlow-Dev.log | tail -1
```

`--version` and the log's launch line must both give the hash `make app`
printed. Part 1 §2: a stale `/Applications` bundle once produced a whole round
of wrong conclusions. Never launch the binary with no flag — a bare run starts a
second instance that takes your dictation.

**4. Back up the live vocabulary before touching it.**

```sh
cd ~/.config/parrotflow-dev
cp vocabulary.yaml vocabulary.yaml.bak-before-pr2-live
```

The `.bak-before-<thing>` name is the convention already in that directory.

**5. Arm A is today's config, which is what is live.** Confirm it and confirm
the app agrees:

```sh
grep -n '^acoustic:' ~/.config/parrotflow-dev/vocabulary.yaml
/Applications/ParrotFlowDev.app/Contents/MacOS/ParrotFlow --check-config | grep vocabulary
```

`grep` must print `32:acoustic: true`. `--check-config` must print these three
lines, wrapped here to fit:

```
  · vocabulary: 11 terms in vocabulary.yaml, 11 matched by sound, 37 by rule
  · vocabulary: offered at similarity 0.5 and up, dropped when the audio argues
    against it by more than 3.0 nats — Arexvy, Claude, Matthieu, Mirza, Ollama,
    Praisy, Redcrawl, Redrock, Supabase, Tasmeen, Vercel
  · vocabulary: 37 pronunciation(s) searched for by sound as well as matched exactly
```

**6. Dictate the eight sentences into a scratch file.**

```sh
mkdir -p ~/pr2 && touch ~/pr2/today.txt && open -a TextEdit ~/pr2/today.txt
```

Hold Right ⌘ — the dev build's push-to-talk key, `AppVariant.defaultHotkey` —
say one sentence, release. One sentence per line, in the order of the table in
*What each sentence is for* below. Say them normally. Do not correct anything.

**7. Copy the log lines out now, before the second arm.** The log truncates to
zero at 1 MB (`Log.swift:44-45`), which is about fifteen minutes of activity. Do
not plan to grep it after all sixteen dictations.

```sh
grep -E "transcribed:|vocabulary judge:|vocabulary rewrote" \
  ~/Library/Logs/ParrotFlow-Dev.log | tail -40 > ~/pr2/today.log
```

`transcribed:` is the final text, after the pipeline and just before it is
inserted (`AppDelegate.swift:2009`). The `vocabulary judge:` lines are what
`Pipeline.swift:934` and `VocabularyJudge.swift:320-328` write.

**8. Arm B — switch the acoustic path off, and dictate the same eight.**

```sh
cd ~/.config/parrotflow-dev
sed -i '' 's/^acoustic: true$/acoustic: false/' vocabulary.yaml
grep -n '^acoustic:' vocabulary.yaml        # must print 32:acoustic: false
/Applications/ParrotFlowDev.app/Contents/MacOS/ParrotFlow --check-config | grep vocabulary
```

No restart. `AppDelegate.watchConfig` watches `vocabulary.yaml` and reloads on
save. `--check-config` must now print:

```
  · vocabulary: 11 terms in vocabulary.yaml, 11 matched by sound, 37 by rule
  · vocabulary: `acoustic: false`, so 11 names are only matched by their
    pronunciation rules
```

The "offered at similarity" line and the "37 pronunciation(s) searched for by
sound" line are gone. The first line does not change: it counts terms in the
file, not what runs. If you still see "offered at similarity", the edit did not
land — stop.

Then dictate the same eight sentences and copy the lines out again:

```sh
touch ~/pr2/noacoustic.txt && open -a TextEdit ~/pr2/noacoustic.txt
# dictate, then:
grep -E "transcribed:|vocabulary judge:|vocabulary rewrote" \
  ~/Library/Logs/ParrotFlow-Dev.log | tail -40 > ~/pr2/noacoustic.log
```

**9. Put the vocabulary back, and check that it went back.**

```sh
cp ~/.config/parrotflow-dev/vocabulary.yaml.bak-before-pr2-live \
   ~/.config/parrotflow-dev/vocabulary.yaml
grep -n '^acoustic:' ~/.config/parrotflow-dev/vocabulary.yaml   # 32:acoustic: true
/Applications/ParrotFlowDev.app/Contents/MacOS/ParrotFlow --check-config | grep "offered at similarity"
```

The last command must print a line. If it prints nothing you are still on
`acoustic: false`.

**10. Fill in the result block**, then remove the build worktree if you made
one: `git worktree remove .claude/worktrees/pr2-build`.

Nothing from `~/pr2/` gets committed except the sixteen transcripts of the eight
scripted sentences. No `.wav`, no `voice/`, no copy of `config.yaml` or
`vocabulary.yaml`.

### What each sentence is for

`acoustic: false` keeps every term and every `heard:` list. It only stops the
audio search proposing names. So a name can still arrive by rule, and an
ordinary word can no longer be overwritten by the spotter.

| # | Say | Under `acoustic: false` | Under today's config | Diagnostic for |
|---|---|---|---|---|
| 1 | in general in our data set | plain English, no `Redcrawl` | may write `Redcrawl` | the controls given back |
| 2 | you don't need to update the design | plain English, no `Supabase` | may write `Supabase` | the controls given back |
| 3 | the bedrock of civilization | plain English, no `Redrock` | may write `Redrock` | the controls given back |
| 4 | Let's praise Praisy's work | `Praisy's` | `Praisy's` | a rule delivering the hardest term |
| 5 | deployed on Vercel against the Versailles Castle | **`Vercel … Vercel Castle`, the predicted failure** | `Vercel … Versailles Castle` | both arms — the only row where they must differ |
| 6 | Matthieu's work | `Matthieu's` | `Matthieu's` | a rule delivering a name alone |
| 7 | Let's praise Matthieu's work | `Matthieu's`, `'s` intact | same | the possessive, and "praise" left alone |
| 8 | Let's praise Antonio's work | `Antonio's`, no term written | same | neither arm — it catches damage from elsewhere |

Say sentence 5 as one sentence. Sentences 7 and 8 both contain "praise", the
word this speaker's `Praisy` sounds like, so both also check that it stays an
ordinary word.

Rows 1–3 are the collision cases. None of them can be written by a rule:
`Redcrawl`'s renderings are "red crawl" and four spellings of it, `Supabase`'s
are "super base", "superbees" and "superbase", and `Redrock`'s is "red rock",
which does not match inside "bedrock". Only the audio search can put a name
there, so `acoustic: false` must leave all three alone. Under today's config
they are three of the 9 controls the pass damages.

Rows 4, 6 and 7 are the rules-still-deliver cases. The name has to arrive from
the `heard:` list with no audio search behind it.

**Row 5 is the predicted failure, and it comes from PR 1.** The
`heard: Versailles` rule fires, so `Vercel` then stands twice in one sentence.
`Vocabulary.wanted` gated the pass off (`Vocabulary.swift:89`), so there is no
`Outcome`, so `Pipeline.swift:920` hands `ruleParts` a nil `before` and the
judge cannot tell which occurrence the rule wrote. It offers nothing and the
castle stays `Vercel`. The log line to look for:

```
vocabulary judge: "Vercel" stands 2 time(s) and no acoustic pass ran, so which
one "Versailles" became cannot be told; that reading is not offered
vocabulary judge: 0 slot(s) from 0 proposal(s)
```

Under today's config the same sentence should log `2 slot(s) from 2
proposal(s)` and come out with the castle.

### Result — awaiting the human

**Nothing here is measured yet.** Do not fill this in from a replay, from `say`,
or from any text-to-speech. A previous session tried `say` and every CTC frame
came back blank, which invalidated a whole round. These sixteen transcripts can
only come from a person talking into a microphone.

**Run.** Date: _. Build stamp from `--version`: _. Config dir:
`~/.config/parrotflow-dev`. Arm order: today's config first, then
`acoustic: false`.

| # | Under today's config | Under `acoustic: false` | Verdict |
|---|---|---|---|
| 1 | _ | _ | _ |
| 2 | _ | _ | _ |
| 3 | _ | _ | _ |
| 4 | _ | _ | _ |
| 5 | _ | _ | _ |
| 6 | _ | _ | _ |
| 7 | _ | _ | _ |
| 8 | _ | _ | _ |

The `vocabulary judge:` line per sentence per arm, from `~/pr2/*.log`:

```
today            1  …
today            2  …
today            3  …
today            4  …
today            5  …
today            6  …
today            7  …
today            8  …

acoustic: false  1  …
acoustic: false  2  …
acoustic: false  3  …
acoustic: false  4  …
acoustic: false  5  …
acoustic: false  6  …
acoustic: false  7  …
acoustic: false  8  …
```

**Verdict.** _ Did 1–3 come out as ordinary English under `acoustic: false`? Did
4, 6 and 7 still get their names? Did 5 fail the way PR 1 predicts, and only
that way?

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

**Also write the language.** Add `lang` to `VoiceStore.Observation`, from the
same value `Trace.Record.recordLanguage` already records. Part 1 §3 says why:
this speaker dictates in two languages, one name has two pronunciations, and the
tag is free at write time and unrecoverable later. It labels a cluster and says
whether coverage exists for each way a name is said. It decides nothing on its
own.

**Size.** Moderate. Touches `ConfigWriter`, `VoiceStore` and the correction
panel.

**Verified by** simulating a correction and checking the three files, with
`lang` on the new observation; exceeding the cap and checking the oldest
unconfirmed entry is what goes; `--forget` leaving `--check-config` clean.

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

## PR 6 — a clip bank that survives a bad clip

**This is the active line of work on the recordings.** The blind control killed
the rejection filter as built. It did not kill the evidence under it. The
question here is narrow: does a rule that is not decided by its worst clip beat
the blind veto? If it does not, the clip bank stops being a decision mechanism
and stays what PR 4 makes it — an asset that improves with use.

**Read part 1 §7 first.** It states the mechanism this attacks:
`ReferenceMatch.verdict` sets `spread` to `nearest.max()`, so one bad clip
widens the cloud and disarms the veto for the whole term.

**This does not contradict PR 1, and here is how the two settle.** PR 1 switches
the acoustic proposal path off because the path as it stands costs 19 losses and
buys nothing. PR 6b measures a better rule on the same three arms as the
prototype, so the acoustic path is on in that arm — otherwise there is nothing
to filter and no comparison with the 103 bar. Then one of two things happens.
The rule beats 103, and the acoustic path stays on with the new rule instead of
being switched off. Or it does not, PR 1 stands, and the clip bank is an asset
and not a gate.

**One use for the clips does not depend on that, and it is untested.** As the
`heard:` lists grow they will start overwriting ordinary words — §7 says why
that is a matter of time, not of luck. A clip is the only evidence that could
gate a text rule before it fires. Nobody has measured it, because today the
rules are clean on this corpus. Do not schedule it. Know it is the reason the
recordings keep their value even if 6b fails.

Three experiments, in order. 6a and 6c are offline on data already on disk. No
build, no model, no Ollama for either of them.

### 6a — how much does one bad clip cost?

Sizes the problem before anything is designed. Nobody knows this number.

**Changes.** None to the app. `scripts/reference-matching.py` on
`origin/spike/exemplars-round-2` already computes per-term AUC with the per-clip
hold-out. Add a `--poison` arm.

**How.** For each of the 11 terms: record the AUC as it stands, add one clip of
the wrong word to that term's folder, re-measure, and record `spread` before and
after. The archive already holds real bad clips to use —
`Vercel/09-brazil.wav`, `Tasmeen/06-that'smeanssend.wav`. Then repeat with 6b's
robust statistic in place of the maximum.

**Do the same with a correct clip of the other pronunciation.** §7 predicts a
thin second cluster inflates `spread` the same way a bad clip does. Add one
French `Matthieu` to an anglicised bank, measure, then add several and measure
again — the prediction is that the damage peaks at one or two and falls away as
the second cluster fills. Nothing has measured this.

**Size.** Under 100 lines of Python. Offline.

**Verified by** two numbers per term: how far AUC falls, and how far `spread`
rises. The same pair with the robust statistic says how much robustness buys.

**Falsified if** poisoning a term barely moves its AUC. Then `spread` is not the
weak point, §7's argument is wrong, and 6b and 6c are not worth doing.

### 6b — a rule that is not decided by one clip

**Changes.** Two, measured apart and together.

1. **Replace the maximum.** `spread` is `nearest.max()` today. Use the 90th
   percentile of the leave-one-out distances instead, or another robust summary.
   Round 7 swept nine summaries offline and found all but two within 0.015 AUC
   of each other — but that sweep ran on a clean archive, which is exactly what
   6a stops assuming.
2. **Ask for k ≥ 2 near recordings.** `distance` is a `min` over recordings
   today, so one clip decides the query side too. Require the span to be near
   the k nearest instead. Expect little from it: §7 explains why the query side
   is already fairly robust — a bad clip is unlike the term, so it rarely wins
   the `min` for a genuine utterance. Measure it anyway. It is the other half of
   the rule and it is a few lines.
3. **Compute the spread per cluster, not per term.** This one is not robustness,
   it is correctness. §7 shows one number over two pronunciations describes
   neither. Cluster the term's recordings (6c does the clustering), take the
   spread inside the cluster the span is nearest, and compare against that.
   Needs 6c's clustering, so it lands after it even though it is a change to the
   rule.

**Size.** Small in the prototype for 1 and 2. `ReferenceMatch` already computes
everything they need. 3 waits on 6c.

**Verified by** the three-arm ablation, not by AUC. `reference-ablation.py
--runs 3` with arms `off`, `today`, `veto everything`, `new rule`. **The bar is
the blind veto's 103, not today's 84.** Report wins and losses separately, split
by class, with the flip count.

**Falsified if** the new rule does not beat 103 by more than the flip count
explains. Then it still is not earning its complexity and PR 6 stops here. AUC
going up while the ablation does not is the same trap the tuned filter fell
into.

### 6c — find the bad clips without labels

Pruning is the other half of robustness, and it is the dangerous half. Getting
it wrong deletes correct data.

**Changes.** A script that scores every clip in a term's folder for suspicion.
Four signals, all cheap at 8 to 26 clips per term:

- **Leave-one-out self-consistency.** A clip far from every other clip of the
  term is suspect. This is `nearest` read per clip instead of reduced to one
  number, so the rule already computes it.
- **Cluster first. This is the part that must not be got wrong.** A speaker may
  say one name two ways on purpose — `Matthieu` in French, or anglicised. That
  is two real clusters, not one truth and one outlier. Keep any cluster with two
  or more members. Suspect only a far singleton. The clusters are also what 6b's
  per-cluster spread needs, so this is not only a pruning step.
- **Label the clusters with `lang`.** Part 1 §3: the language is already in
  `trace.jsonl` and PR 4 should carry it into every observation. It does not
  decide anything — a French name can be said the French way in an English
  sentence — but it names a cluster in words the speaker recognises and it says
  whether coverage exists for each way the name is said.
- **Provenance.** `from:` and `seen:` are already defined on
  `origin/feat/vocabulary-v2-pr5` — `VoiceStore.Observation.from` and
  `Config.Vocabulary.Pronunciation`, with sources `correction`, `mined`,
  `calibration` and `legacy`. A clip from a confirmed correction outranks one
  mined from a transcript that may itself have been wrong.
  `Vercel/09-brazil.wav` is a mined one.
- **Duration.** `VoiceStore.Observation.span` carries `[start, end]`. A cut much
  shorter or much longer than the term's typical span is usually a bad cut, not
  a bad pronunciation.

**Size.** About 200 lines of Python, plus the recording session for the bimodal
check.

**Verified by** three things, and the last two matter more than the first:

1. the known bad clips are flagged — `Vercel/09-brazil.wav`,
   `Tasmeen/06-that'smeanssend.wav`;
2. **a deliberately bilingual term keeps both clusters.** Build one: read
   `Matthieu` both ways, several of each, and check that nothing in either
   cluster is flagged. A method that fails this deletes correct data;
3. **and that term still vetoes.** Keeping both clusters is only half the job.
   Run the bilingual term through the ablation and check it still rejects a
   wrong proposal — with the per-cluster spread from 6b, it should; with one
   spread over both clusters, §7 says it will not. **A term that keeps all its
   clips and rejects nothing has failed**, and the first criterion alone would
   call that a pass.

**Falsified if** either bilingual check fails, or if flagging is at chance
against 6a's poisoned clips.

**Open, and not decided here: should pruning ever be automatic?** The
alternative is that nothing is ever deleted — the speaker is shown the suspect
clip and confirms by ear. A clip is auditable, which is the one thing a text
rule is not, so asking is cheap and honest. It is also one more interruption.
Decide it once 6c has a false-flag rate, not before.

## PR 7 — ask the speaker for fewer clips

**Design the burden down instead of absorbing it.** Every clip in the bank
today came from a sitting: `parrotflow-recording-script.md`, 48 lines, about
seven minutes, one dictation per line. It is already the short version — most
lines carry two names, which is how it got shorter without collecting less. It
is still a chore, and it is a chore that repeats per speaker and per new term.

**Items 3 and 5 are proposals. Nothing measures them.** 1, 2 and 4 rest on work
already in this plan. Ordered by leverage.

**1. Only ask for terms that actually collide.** A term nothing sounds like
needs no clips: there is nothing for a veto to reject. Part 1 §6's empirical
confusable sweep decides which terms those are — run the spotter for the term
across the speaker's archive and see which ordinary words it fires on. **This is
the same line of work, not a second one.** The sweep is already owed for
onboarding; making it also decide who needs a clip bank costs nothing extra.

Measured hint at the size of the lever: of the 11 terms, round 7 found ordinary
words overwritten by only **5** of them — `Supabase`, `Redcrawl`, `Claude`,
`Arexvy`, `Praisy`. Six terms have never taken a word that was not theirs on
this corpus. **Verified by** running the sweep before the next recording session
and counting how many terms it clears. Absence of evidence is not the same as
the sweep clearing a term, so run the sweep rather than reading the table.

**2. Mine the archive before asking.** Measured, in round 7. The archive is 2616
wavs and most terms are already in it. `scripts/mine-pronunciations.py` with PR
5's changes took the spontaneous corpus from 27 recordings to 59 without a line
being read, and **2 of the 11 terms needed no scripted line at all** — `Praisy`
at 26 recordings and `Vercel` at 16. Ask only for what mining did not find.

**3. A stopping rule instead of a fixed count.** Proposal. "About seven each"
asks for too many where a name is said one way and too few where it is variable.
Instead add clips until the term's own statistic stops moving.

**How to measure it.** Replay the 122 recordings in mining order. For each term,
plot the spread — or whatever robust statistic 6b picks — against clip count,
and plot the term's AUC against clip count on the same axis. Read where each
curve flattens. The stopping rule is then "add clips until the spread moves less
than *x* over *n* clips in a row", with *x* and *n* read off those curves rather
than guessed. It answers "how many do I need" per term, with a number.

**Falsified if** the curves do not flatten, or flatten at a count no lower than
what is asked for today, or — the one that matters — **the spread flattens while
the AUC is still climbing**. A statistic that has stopped moving is worthless as
a stopping signal if separation is still improving. Check that directly, per
term, before building any of it.

**4. Harvest from corrections.** PR 4 already builds the mechanism. Every
correction is a labelled clip of a term in this speaker's voice, in spontaneous
speech, at no cost to the speaker. Over a week it beats any script, and it is
the only source that still works after onboarding is over.

**5. Prompt during use, not in a sitting.** Proposal. One sentence surfaced
occasionally beats a 48-line session, and the cheaper path also gives better
data: round 7 measured read speech flattering the result by about **0.06 AUC**
against spontaneous recordings from another day. **The trade is speed.** A
brand-new term reaches coverage in days instead of in seven minutes, which is
wrong for a name somebody needs today. Keep the script for that case and make it
the exception rather than the default.

**Size.** 1 and 2 are scripts. 3 is an offline measurement plus a rule. 4 is PR
4. 5 is interface work and should not start before 3 says how many clips a term
actually needs.

## PR 8 — the term that is an English word

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

## PR 9 — the possessive the decoder drops

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

- **The rejection filter exactly as built — `distance > tolerance × max`
  leave-one-out spread, one tolerance, tuned on its own clips.** Vetoing every
  proposal blindly scores 103 against its 104, head to head 8 wins against 7
  losses, and the tolerance curve is flat from 0.01 to 1.00.
  `origin/proto/reference-matching`. **This is a dead end for the rule, not for
  the recordings** — the distance separates at AUC 0.935 on a label-built set.
  The successor is PR 6, and it has to beat 103.
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
  proposal. Worth revisiting once PR 6 says whether a rule on the distance beats
  the blind veto — a better representation cannot rescue a rule that does not.
- **"Too close, ask the user"** on a reranker's margins. Its own proposal. The
  same question comes back in PR 6c for a suspect clip, where it is easier: a
  clip can be played back and confirmed by ear.

---

# Part 3 — Cleanup this work owes

**The `general → Redcrawl` verdict was never recorded. Replay that one clip.**
It is the canonical failure — sentence 1 of the standing regression list — and
it deserves a measured answer, not an inference. Offline, round 7 put it at
distance **3.328**, nearer than **0 of 8** real recordings of `Redcrawl`, so the
filter should reject it. End to end, the prototype log carries no verdict for
it. What survives in `~/Library/Logs/ParrotFlow-Dev.log` is two distinct
`crawl → Redcrawl` vetoes — `"crawl"` at 3.177 and `"crawl."` at 3.511, both
against a spread of 3.098 over 8 recordings — and the string `general` does not
appear anywhere in the file. The log truncates at 1 MB
(`Log.swift:44-45`) and the early part of that run is gone, so absence proves
nothing. **Replay the clip with the prototype build, capture the `reference:`
line to a file rather than the log, and record the verdict.**

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
| `spike/exemplars-round-2` | **No.** Round 7, the 48 scripted clips, the mining changes and the 122-recording corpus exist only there. The most valuable unmerged branch, and PR 6a starts from its `scripts/reference-matching.py`. |
| `experiment/does-vocabulary-pay` | **No.** The ablation, `vocab-ablation.py`, `vocab-losses.py` and the 19-loss list exist only there. |
| `proto/reference-matching` | **No.** The prototype and the control arm that settled this plan's direction. PR 6b changes `ReferenceMatch.swift`, which exists only here. |
| `spike/onset-pilot` | **No.** Code only — `PARROTFLOW_LOGPROB_DUMP`. Already re-ported into `spike/ctc-06b`, so nothing is lost if that one survives. |

Eight of the nine carry something that exists nowhere else. Land the findings —
as documents, harnesses and this plan's PRs — before deleting any branch. Two of
them, `exemplars-round-2` and `proto/reference-matching`, are now live
dependencies of PR 6 rather than history.
