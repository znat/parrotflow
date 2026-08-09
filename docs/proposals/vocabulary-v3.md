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
that name than every real utterance of it. The bank also picks the right name
out of eleven on 92% of the spans where a name was said, and on 2% where none
was. What failed is the decision rule. So the recordings stay, and the work is
to build a rule worth the evidence. Part 1 §7 says why a clip beats another text
rule. PR 6 says what to measure, and PR 6d is the one that asks whether the
clips can replace the rules outright.

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

**One rider, from PR 2's live pass.** "The rules earn the +18" is true of these
141 clips and is not a property of rules. A `heard:` list only holds renderings
somebody has already written down. On one live sentence the decoder produced
`Praise's` for `Praisy`, no rule matched, and with the acoustic path off the
name did not arrive. On that term some of the wins come from the acoustic path
alone. PR 8 is where that lives.

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

**The bank also says *which* term, not only whether the term was said.** That is
a different question and it has its own measurement. For every span, round 7
compared the distance to the recordings of the term in question against the
distance to the nearest recording of any *other* term. Eleven terms, so this is
1-of-11 identification.

| set | group | AUC (matched vs mismatched) | matched is nearer |
|---|---|---|---|
| scripted set | A — the term really was said | 0.832 | 58/63 (92%) |
| scripted set | B — the term was not said | 0.076 | 13/718 (2%) |
| round 7 proposals | A | 0.816 | 29/33 (88%) |
| round 7 proposals | B | 0.453 | 31/66 (47%) |
| round 6, 27 recordings | A | 0.893 | 27/30 (90%) |
| round 6, 27 recordings | B | 0.762 | 37/46 (80%) |

**Read the last column in opposite directions for A and B.** On A a high number
is the result: the name that was said is nearer its own recordings than any
other name's, 92% of the time. On B a *low* number is the result: the name that
was not said is almost never the nearest, 2% of the time. Round 6's B row at 80%
was the warning — with 4 terms and 17 of its 27 recordings being `Praisy`,
"nearest other term" was mostly "nearest of 17 `Praisy` recordings", so the
distance was carrying something generic. Eleven terms fix it.

**Its limit, stated as plainly as its result.** The pool of other terms is the
other ten names plus the 8 ordinary words the pass actually wrote a name over.
The ordinary words of the 48 scripted sentences were never scanned. So this
measures discrimination **among candidate terms** — something has already
singled the span out. It does not measure "is there a name here at all", and it
does **not** show the bank can replace the `heard:` rules. Round 7 names one
more caveat: the mismatched pool is a different size per term, and a bigger pool
is nearer by construction. PR 6d is the experiment that would test the other
question, and nothing in it is measured yet.

**It is not measuring how long the word is.** AUC on span duration alone is
0.535 on the scripted set, which is chance. Holding the length gap between span
and recording to ±0.05s, the distance still separates at 0.879. Round 7.

**The 8 live overwrites, one row each.** These are the failures themselves, not
a proxy for them: each is a word the pass wrote a name over in these very clips,
scored against that name's own recordings.

| the app heard | and wrote | distance | nearer than |
|---|---|---|---|
| `update` | Supabase | 3.135 | 0 of 9 real spans |
| `crawl` | Redcrawl | 3.142 | 0 of 8 |
| `slide` | Claude | 3.194 | **1 of 6** |
| `retry` | Arexvy | 3.328 | 0 of 6 |
| `general` | Redcrawl | 3.328 | 0 of 8 |
| `already` | Arexvy | 3.380 | 0 of 6 |
| `train` | Praisy | 3.520 | 0 of 21 |
| `ready` | Arexvy | 3.575 | 0 of 6 |

`Praisy` has no A span in the scripted clips, so `train` is ranked against the
21 `Praisy` A spans of set 1, whose worst is 3.348. The one exception is
`slide`→`Claude`: `Claude` is the shortest name in the set and has the fewest
recordings, 6. A rule that rejected any span farther than the term's worst
recording would have caught 7 of the 8 and lost nothing.

`update`→`Supabase` and `general`→`Redcrawl` are F1 and F5, the two failures
this line of work started from. **`general`→`Redcrawl` still has no end-to-end
verdict.** 3.328 above is the offline half of the answer; part 3's first cleanup
item asks for the other half.

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

**Where a recording came from changes what it is worth. The split, and what it
does not say.** Round 7 measured set 1 four times, changing only which
recordings the same proposals were scored against:

| recordings compared against | rec | A | B | AUC |
|---|---|---|---|---|
| round 6, `tests/acoustic/` | 27 | 30 | 46 | 0.812 |
| spontaneous only, re-mined | 59 | 32 | 57 | 0.831 |
| scripted only | 63 | 6 | 24 | 0.910 |
| **all** | **122** | **33** | **66** | **0.874** |

**The rows are not the same rows, so 0.910 is not "scripted clips are better".**
A term with no recording in a source cannot be scored from that source at all.
`Praisy` and `Vercel` have no scripted recording, so the scripted row drops all
69 of their proposals — 58 `Praisy` and 11 `Vercel` — including `Praisy`, the
hardest term in the set at 0.869. That alone can explain the gap to 0.831. Do
not quote 0.910 as evidence that a read line is worth more than a mined one.
Nobody has measured that on equal rows.

**What the split does say.** Two things. Adding recordings raises the headline:
27 recordings give 0.812, 122 give 0.874, and nothing is dropped any more.
And the scripted recordings generalise off their own session — those 63 come
from clips the proposal set does not contain, so no span could score against a
copy of itself even in principle, and spontaneous dictation spans still land
nearer read-speech recordings of their own name than of anyone else's, at 0.910
on 6 A / 24 B. This is the number to weigh when deciding how to spend the
speaker's time in PR 5 (mine first, it is free) and PR 7 (ask for fewer clips).
Weigh it against the paragraph above: read speech flatters by about 0.06.

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
worth a lot: `Supabase` separates at 0.991 on two spontaneous ones. And a bad
pair is a shortage of clips, not a verdict on the term: `Matthieu` was 0.556 on
2 recordings in round 6 and is 1.000 on 11. PR 4 carries that number, because it
is the argument for keeping the audio from every correction.

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

**Two measured facts bear on it, and they are in §1 and §3.** The clip bank
picks the right term out of eleven on 92% of spans where a name was said and on
2% where none was, and `Matthieu` went from AUC 0.556 on 2 recordings to 1.000
on 11. Those are measurements about the distance, not about the rule built on
it, and they do not make the argument below a measurement. They are why it is
worth arguing.

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

**PR 2 did, and the line reproduced verbatim.** Arm B produced it word for word
on a live sentence this run never saw, twice over — the decoder wrote two
renderings and two rules fired. This attribution is no longer an inference from
the code, and the five-line `ruleParts` fix is now a defect with a live repro.

**PR 2 also found a second cost, on a different term.** Under `acoustic: false`
one live sentence lost `Praisy` outright, because the decoder wrote a rendering
no `heard:` entry covers and none safely could. So "no wins the rules do not
deliver" holds on this corpus and is not a general property. See PR 2's result
block and PR 8.

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

`reference-ablation.py` exists only on that branch. PR 3 lands it as
`scripts/vocab-ablation.py`, with the same arm syntax.

## PR 2 — confirm it on live dictation

**Changes.** None. Dictation and a log.

**Why.** Every number above describes replays. The same clip live and replayed
scores from the same distribution, but nothing about the *rules* path has been
checked live since it became load-bearing.

**HUMAN.** Dictate the standing regression sentences twice — once with today's
config, once with `acoustic: false` — on a build whose stamp matches the tree.
The runbook below is the whole procedure. Paste both transcripts into the result
block.

**What two arms can settle, and what they cannot.** PR 2 runs today's config and
`acoustic: false`. Neither is the veto arm. PR 1's gap is a difference in
correct clips between **veto** and `acoustic: false`, so no comparison here can
confirm or falsify that gap. What PR 2 can establish is what it was written for:
whether `acoustic: false` removes the collision failures live, and whether the
rules still deliver the names they are supposed to.

It can still confirm the *mechanism* PR 1 blamed the gap on, because that
mechanism writes a log line and the line is readable in one arm on its own. It
did — see the result block. The gap and the mechanism are different claims.

**Sentence 5's row was corrected in this PR, and the correction is a reasoning
fix, not a result.** An earlier draft of the table below predicted sentence 5
correct under today's config and wrong under `acoustic: false`, and used the
difference between the two as the test. That was wrong on its face. The
correct-under-today half was a claim about the **veto** arm, which PR 2 does not
run. PR 1's veto arm gets sentence 5 right because the acoustic pass runs and
`Pipeline.swift:920` hands `ruleParts` a real `before`; today's arm has the same
plumbing, and the judge still has to pick with it. Necessary is not sufficient.
Arm A then measured it: today's config gets sentence 5 **wrong**, with a full
two-slot menu.

**Confirming PR 1's veto-vs-`acoustic: false` gap live needs a third arm, and it
is out of scope here.** The veto arm is `ReferenceMatch.swift` plus
`PARROTFLOW_REFERENCE_MATCH`, and both exist only on
`origin/proto/reference-matching`. Running it live means building and installing
that branch. **PR 2 does not do that**, and the runbook below deliberately does
not mention it. If that gap is worth confirming live, it is its own PR with its
own build step.

**Verified by** 1–3 coming out as ordinary English under `acoustic: false`, and
4, 6 and 7 still getting their names from the rules.

**Falsified if** a name the rules are supposed to deliver stops arriving under
`acoustic: false` — 4, 6 or 7. Then the rules cover less than the replay says,
and the acoustic path is delivering something the ablation did not attribute to
it. **Also falsified if a collision still writes a term under `acoustic:
false`** — 1, 2 or 3. Then something other than the acoustic path is writing it,
and `Vocabulary.wanted` is not the switch PR 1 took it for.

**No result on sentence 5 falsifies anything in PR 2.** Both arms can get it
wrong for different reasons: today the judge picks badly from a full menu, under
`acoustic: false` there is no menu to pick from. Same output, two causes, and
two arms cannot tell them apart. Record what it does and leave the attribution
to the log lines.

**Outcome.** The first half held: 1–3 came out as ordinary English and 6 and 7
got their names. The falsifier fired on sentence 4. See the result block.

### The runbook

**Both arms are run — see the result block.** This is kept as written so the
pass can be redone on a later build. It was followed on 2026-08-09, including
the relaunch before each arm. The result block quotes what the *running process*
logged at each launch, which is the stronger check and the one to prefer if the
two ever disagree.

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
git -C ~/Documents/parrotflow fetch origin --quiet
/Applications/ParrotFlowDev.app/Contents/MacOS/ParrotFlow --version
git -C ~/Documents/parrotflow rev-parse --short origin/main
```

The `fetch` matters: `origin/main` is a local ref and a stale one would make a
stale build look current.

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

**5. Arm A is today's config, which is what is live.** Relaunch the app first,
then confirm.

**Relaunching is not optional, and `--check-config` is not a substitute.**
`--check-config` is a separate process reading the file on disk. It says nothing
about what the *running* app holds. `FileWatcher` delivers on the main queue,
and on a rename — which `sed -i ''` does — it closes the descriptor and reopens
it 0.2 s later before calling back (`Config.swift:3287-3320`). So a sentence
dictated straight after an edit can still run under the old setting, and nothing
in the transcript would say so. A relaunch removes the race and leaves a dated
line in the log that proves which file the running process read.

```sh
mkdir -p ~/pr2
wc -l < ~/Library/Logs/ParrotFlow-Dev.log > ~/pr2/relaunch.mark
pkill -f "ParrotFlowDev.app/Contents/MacOS/ParrotFlow"   # the pattern `make stop` uses
open /Applications/ParrotFlowDev.app
# wait until the parrot is back in the menu bar, then:
tail -n +$(( $(cat ~/pr2/relaunch.mark) + 1 )) ~/Library/Logs/ParrotFlow-Dev.log \
  | grep "build: "
```

That must print exactly one `build:` line, with the stamp from step 1 or 3.
Every line below it in the log was written by a process that read the config as
it stands now.

Then confirm the setting:

```sh
grep -n '^acoustic:' ~/.config/parrotflow-dev/vocabulary.yaml
/Applications/ParrotFlowDev.app/Contents/MacOS/ParrotFlow --check-config \
  | grep -E "offered at similarity|acoustic: false"
```

`grep` on the file must print `32:acoustic: true`. `--check-config` must print
one line, and it must be the "offered at similarity" one — wrapped here to fit:

```
  · vocabulary: offered at similarity 0.5 and up, dropped when the audio argues
    against it by more than 3.0 nats — Arexvy, Claude, Matthieu, Mirza, Ollama,
    Praisy, Redcrawl, Redrock, Supabase, Tasmeen, Vercel
```

Two more lines carry the counts and are worth a glance:

```
  · vocabulary: 11 terms in vocabulary.yaml, 11 matched by sound, 37 by rule
  · vocabulary: 37 pronunciation(s) searched for by sound as well as matched exactly
```

**6. Mark the log, then dictate the eight sentences into a scratch file.** The
mark is how you get this arm's lines and nobody else's.

```sh
wc -l < ~/Library/Logs/ParrotFlow-Dev.log > ~/pr2/today.mark
touch ~/pr2/today.txt && open -a TextEdit ~/pr2/today.txt
```

Hold Right ⌘ — the dev build's push-to-talk key, `AppVariant.defaultHotkey` —
say one sentence, release. One sentence per line, in the order of the table in
*What each sentence is for* below. Say them normally. Do not correct anything.

**7. Copy the log lines out now, before the second arm.** The log truncates to
zero at 1 MB (`Log.swift:44-45`), which is about fifteen minutes of activity. Do
not plan to grep it after all sixteen dictations.

```sh
tail -n +$(( $(cat ~/pr2/today.mark) + 1 )) ~/Library/Logs/ParrotFlow-Dev.log \
  | grep -E "transcribed:|vocabulary judge:|vocabulary rewrote" > ~/pr2/today.log
wc -l < ~/pr2/today.log
```

Expect at least 8 lines, one `transcribed:` per sentence. If the file is short
or empty, check whether the log truncated during the arm:

```sh
[ "$(wc -l < ~/Library/Logs/ParrotFlow-Dev.log)" -lt "$(cat ~/pr2/today.mark)" ] \
  && echo "the log truncated — redo this arm"
```

`transcribed:` is the final text, after the pipeline and just before it is
inserted (`AppDelegate.swift:2009`). The `vocabulary judge:` lines are what
`Pipeline.swift:934` and `VocabularyJudge.swift:320-328` write.

**8. Arm B — switch the acoustic path off, and dictate the same eight.**

Edit the file, then relaunch exactly as in step 5. The app does watch
`vocabulary.yaml` (`AppDelegate.watchConfig`), so a restart is not needed to
pick the change up — it is needed to *know* the change has been picked up before
the first sentence.

```sh
cd ~/.config/parrotflow-dev
sed -i '' 's/^acoustic: true$/acoustic: false/' vocabulary.yaml
grep -n '^acoustic:' vocabulary.yaml        # must print 32:acoustic: false

wc -l < ~/Library/Logs/ParrotFlow-Dev.log > ~/pr2/relaunch.mark
pkill -f "ParrotFlowDev.app/Contents/MacOS/ParrotFlow"
open /Applications/ParrotFlowDev.app
# wait for the menu bar, then:
tail -n +$(( $(cat ~/pr2/relaunch.mark) + 1 )) ~/Library/Logs/ParrotFlow-Dev.log \
  | grep "build: "
/Applications/ParrotFlowDev.app/Contents/MacOS/ParrotFlow --check-config \
  | grep -E "offered at similarity|acoustic: false"
```

One fresh `build:` line, same stamp as before. Then the `--check-config` grep
must print one line, and it must be the other one:

```
  · vocabulary: `acoustic: false`, so 11 names are only matched by their
    pronunciation rules
```

If "offered at similarity" is still there, the edit did not land — stop. The
"37 pronunciation(s) searched for by sound" line also disappears; it is gated on
`acoustic` too (`Config.swift:1840`). The `11 terms … 11 matched by sound, 37 by
rule` line does **not** change. It counts what is in the file, not what runs.

Then mark the log again, dictate the same eight sentences, and copy the lines
out with the same two commands:

```sh
wc -l < ~/Library/Logs/ParrotFlow-Dev.log > ~/pr2/noacoustic.mark
touch ~/pr2/noacoustic.txt && open -a TextEdit ~/pr2/noacoustic.txt
# dictate the eight, then:
tail -n +$(( $(cat ~/pr2/noacoustic.mark) + 1 )) ~/Library/Logs/ParrotFlow-Dev.log \
  | grep -E "transcribed:|vocabulary judge:|vocabulary rewrote" > ~/pr2/noacoustic.log
wc -l < ~/pr2/noacoustic.log
```

**9. Put the vocabulary back, and check that it went back.**

```sh
cp ~/.config/parrotflow-dev/vocabulary.yaml.bak-before-pr2-live \
   ~/.config/parrotflow-dev/vocabulary.yaml
grep -n '^acoustic:' ~/.config/parrotflow-dev/vocabulary.yaml   # 32:acoustic: true
/Applications/ParrotFlowDev.app/Contents/MacOS/ParrotFlow --check-config | grep "offered at similarity"
```

The last command must print a line. If it prints nothing you are still on
`acoustic: false`. Relaunch once more so the app you go back to work with is
reading the restored file, not the edited one:

```sh
pkill -f "ParrotFlowDev.app/Contents/MacOS/ParrotFlow"
open /Applications/ParrotFlowDev.app
```

**10. Fill in the result block**, then remove the build worktree if you made
one: `git worktree remove .claude/worktrees/pr2-build`.

Nothing from `~/pr2/` gets committed except the sixteen transcripts of the eight
scripted sentences. No `.wav`, no `voice/`, no copy of `config.yaml` or
`vocabulary.yaml`.

### What each sentence is for

`acoustic: false` keeps every term and every `heard:` list. It only stops the
audio search proposing names. So a name can still arrive by rule, and an
ordinary word can no longer be overwritten by the spotter.

**This table was written before the run and is kept as it was, except sentence
5.** It is the pre-registration, and it is worth more unedited than tidied. Only
row 5 is changed, because it was wrong by reasoning rather than by result — the
paragraph below the table says how. The measured transcripts are in the result
block, and the four cells this table got wrong are listed after it.

| # | Say | Under `acoustic: false` | Under today's config | Diagnostic for |
|---|---|---|---|---|
| 1 | in general in our data set | plain English, no `Redcrawl` | may write `Redcrawl` | the controls given back |
| 2 | you don't need to update the design | plain English, no `Supabase` | may write `Supabase` | the controls given back |
| 3 | the bedrock of civilization | plain English, no `Redrock` | may write `Redrock` | the controls given back |
| 4 | Let's praise Praisy's work | `Praisy's` | `Praisy's` | a rule delivering the hardest term |
| 5 | deployed on Vercel against the Versailles Castle | `Vercel … Vercel Castle` | `Vercel … Vercel Castle` — **corrected**, see below | neither arm |
| 6 | Matthieu's work | `Matthieu's` | `Matthieu's` | a rule delivering a name alone |
| 7 | Let's praise Matthieu's work | `Matthieu's`, `'s` intact | same | the possessive, and "praise" left alone |
| 8 | Let's praise Antonio's work | `Antonio's`, no term written | same | neither arm — it catches damage from elsewhere |

Say sentence 5 as one sentence. Sentences 7 and 8 both contain "praise", the
word this speaker's `Praisy` sounds like, so both also check that it stays an
ordinary word.

**Four of the sixteen cells were wrong, and three are in the same column.** The
other twelve held — with the caveat that rows 1–3's "may write" cells hold
whatever happens and are not really predictions.

- **Row 4, `acoustic: false`.** Predicted `Praisy's`. Measured `Praise's`. This
  is the falsifier, not a miss — see the result block.
- **Row 5, today's config.** Corrected in this PR, and wrong by reasoning rather
  than by result: it claimed a veto-arm outcome for an arm PR 2 does not run.
  Arm A then measured it wrong as well.
- **Rows 6 and 7, today's config.** Predicted `Matthieu's` in both. Measured
  `Matthieu` in both — the possessive is eaten by the acoustic substitution.
  Row 7 also predicted "praise" left alone and got `Praisy`, so that cell is
  wrong twice over. The plan had filed the possessive as PR 9, a decoder fault.
  This is a second, different fault with the same symptom, and PR 9 now carries
  both.

Three of the four sit in the "under today's config" column, and all three are
the same mistake: the column was filled in from what the plan wanted the pass to
do, not from what its code does. The `acoustic: false` column was reasoned from
`Vocabulary.wanted` and the rule tables, and it went 7 of 8.

Rows 1–3 are the collision cases. None of them can be written by a rule:
`Redcrawl`'s renderings are "red crawl" and four spellings of it, `Supabase`'s
are "super base", "superbees" and "superbase", and `Redrock`'s is "red rock",
which does not match inside "bedrock". Only the audio search can put a name
there, so `acoustic: false` must leave all three alone. Under today's config
they are three of the 9 controls the pass damages.

Rows 4, 6 and 7 are the rules-still-deliver cases. The name has to arrive from
the `heard:` list with no audio search behind it. **Row 4 is the one that
broke** — the rules did not deliver `Praisy`. See the result block.

**Row 5 fails under both arms, and the two failures have different causes.** The
`heard: Versailles` rule fires, so `Vercel` stands twice in one sentence.

Under `acoustic: false`, `Vocabulary.wanted` gates the pass off
(`Vocabulary.swift:89`), so there is no `Outcome`, so `Pipeline.swift:920` hands
`ruleParts` a nil `before` and the judge cannot tell which occurrence the rule
wrote. It offers nothing and the castle stays `Vercel`. The log line to look
for:

```
vocabulary judge: "Vercel" stands 2 time(s) and no acoustic pass ran, so which
one "Versailles" became cannot be told; that reading is not offered
vocabulary judge: 0 slot(s) from 0 proposal(s)
```

Under today's config the pass runs, `before` is real, and the sentence logs `2
slot(s) from 2 proposal(s)`. **That is the menu, not the answer.** The judge
then picks, and it can pick `Vercel` twice. The earlier draft of this section
read the two-slot menu as a correct outcome; it is only the precondition for
one.

So row 5 is a diagnostic for **neither** arm. The two arms produce the same
sentence for two unrelated reasons, and no comparison between them separates the
two. What tells them apart is the log, and only the log.

### Result, measured 2026-08-09

**3 of 8 under today's config, 6 of 8 under `acoustic: false`.** Both arms are
dictated. The headline holds live and the falsifier fired on one sentence.

**Eight sentences dictated once each is not a rate.** It is 16 dictations. Read
the mechanisms below, which the log settles clip by clip, not the two counts.

**If this is ever redone, it can only be redone by a person talking into a
microphone.** Not from a replay, not from `say`, not from any text-to-speech. A
previous session tried `say` and every CTC frame came back blank, which
invalidated a whole round.

**Run.** Date 2026-08-09, config dir `~/.config/parrotflow-dev`. Arm A
20:21:43–20:22:22, arm B 20:34:58–20:35:34, in that order. Each arm started with
a fresh launch, and each launch wrote its own stamp, its own input device and
its own reading of the vocabulary config:

```
20:21:06  build: 78d7ba2
20:21:06  config: vocabulary: offered at similarity 0.5 and up, dropped when the
          audio argues against it by more than 3.0 nats — Arexvy, Claude, …
20:21:06  launched — hotkey=Right ⌘ mode=push-to-talk mic=Granted
          accessibility=Granted input=RØDE VideoMic GO II

20:34:28  build: 78d7ba2
20:34:28  config: vocabulary: `acoustic: false`, so 11 names are only matched by
          their pronunciation rules
20:34:28  launched — hotkey=Right ⌘ mode=push-to-talk mic=Granted
          accessibility=Granted input=RØDE VideoMic GO II
```

Those are the *running process* saying what it read, which is what part 1 §2 asks
for — `--check-config` was also run before arm B, and it is a separate process
reading the file. `78d7ba2` is `origin/main`, so no Swift under test differs from
the tree. The live `vocabulary.yaml` was backed up to
`vocabulary.yaml.bak-before-pr2-armb`, one line changed, and restored afterwards.
**No correction was accepted at any point**, so both arms ran the same
`transcription.replacements` table.

| # | Said | Today's config (arm A) | `acoustic: false` (arm B) |
|---|---|---|---|
| 1 | in general in our data set | `in Redcrawl in our dataset.` ✗ | `In general in our dataset.` ✓ |
| 2 | you don't need to update the design | `You don't need to update the design.` ✓ | `You don't need to update the design.` ✓ |
| 3 | the bedrock of civilization | `the Redrock civilization.` ✗ | `the bedrock of civil civilization.` ✓ on the term |
| 4 | Let's praise Praisy's work | `Let's praise Praisy's work.` ✓ | `Let's praise Praise's work.` ✗ |
| 5 | deployed on Vercel against the Versailles Castle | `Deployed on Vercel against the Vercel Castle.` ✗ | `deployed on Vercel against the Vercel Gastle.` ✗ |
| 6 | Matthieu's work | `Matthieu work.` ✗ | `Matthieu's work.` ✓ |
| 7 | Let's praise Matthieu's work | `Let's Praisy Matthieu work.` ✗ | `Let's praise Matthieu's work.` ✓ |
| 8 | Let's praise Antonio's work | `Let's praise Antonio's work.` ✓ | `Let's praise Antonio's work.` ✓ |

**Two decoder faults are scored as passes, and here is why.** Arm B's sentence 3
is `civil civilization` and its sentence 5 ends in `Gastle`. Neither word is a
vocabulary term, neither has a vocabulary log line against it, and arm B's
sentence 3 logged no vocabulary activity at all. They are the decoder stuttering
and mishearing an ordinary word. This PR measures what the vocabulary pass does,
so both are scored on the term: `bedrock` survived, and `Gastle` is not the
reason sentence 5 is wrong.

#### Arm A — today's config, `acoustic: true`

Every vocabulary line, copied out of `~/Library/Logs/ParrotFlow-Dev.log` at the
time. The log truncates at 1 MB (`Log.swift:44-45`) and the machine is in daily
use, so this is the record.

```
1  vocabulary: "general" -> "Redcrawl" proposed (raw -7.88 vs -8.12, bonus 5.85) (CTC-vs-CTC: 'Redcrawl'=-2.03 > 'general'=-8.12)
   vocabulary: "general" -> "Redcrawl" also offered (span 0.47)
   vocabulary: "dataset" -> "Praisy" heard in the audio (spotter -4.48)
   vocabulary judge: 2 slot(s) from 3 proposal(s)
   pipeline: vocabulary rewrote the transcript
       before: in general in our dataset.
       after:  in Redcrawl in our dataset.

2  vocabulary: "update" -> "Supabase" proposed (raw -5.47 vs -7.18, bonus 2.88) (CTC-vs-CTC: 'Supabase'=-2.59 > 'update'=-7.18)
   vocabulary judge: 1 slot(s) from 1 proposal(s)

3  vocabulary: "bedrock" -> "Redrock" proposed (raw -12.68 vs -12.62, bonus 2.88) (CTC-vs-CTC: 'Redrock'=-9.80 > 'bedrock'=-12.62)
   vocabulary: "bedrock" -> "Redrock" also offered (span 0.86)
   vocabulary: "bedrock" -> "Redrock's" also offered (span 0.70)
   vocabulary: "bedrock of" -> "Redrock" also offered (span 0.59)
   vocabulary: "bedrock of" -> "Redrock's" also offered (span 0.63)
   vocabulary judge: 1 slot(s) from 5 proposal(s)
   pipeline: vocabulary rewrote the transcript
       before: the bedrock of civilization.
       after:  the Redrock civilization.

4  vocabulary: "praise" -> "Praisy" proposed (raw -13.65 vs -14.07, bonus 2.88) (CTC-vs-CTC: 'Praisy'=-10.77 > 'praise'=-14.07)
   vocabulary: "praise" -> "Praisy" also offered (span 0.83)
   vocabulary: "praise" -> "Praisy's" also offered (span 0.66)
   vocabulary judge: 2 slot(s) from 4 proposal(s)

5  vocabulary judge: 2 slot(s) from 2 proposal(s)

6  vocabulary: "Mathieu's" -> "Matthieu" applied (raw -12.53 vs -13.39, bonus 5.49) (CTC-vs-CTC: 'Matthieu'=-7.04 > 'Mathieu's'=-13.39)
   vocabulary judge: 0 slot(s) from 0 proposal(s)

7  vocabulary: "praise" -> "Praisy" proposed (raw -10.12 vs -9.37, bonus 2.88) (CTC-vs-CTC: 'Praisy'=-7.24 > 'praise'=-9.37)
   vocabulary: "Mathieu's" -> "Matthieu" applied (raw -12.08 vs -12.76, bonus 5.49) (CTC-vs-CTC: 'Matthieu'=-6.58 > 'Mathieu's'=-12.76)
   vocabulary: "praise" -> "Praisy" also offered (span 0.83)
   vocabulary: "praise" -> "Praisy's" also offered (span 0.66)
   vocabulary judge: 1 slot(s) from 3 proposal(s)
   pipeline: vocabulary rewrote the transcript
       before: Let's praise Matthieu work.
       after:  Let's Praisy Matthieu work.

8  vocabulary: "praise" -> "Praisy" proposed (raw -10.53 vs -11.21, bonus 2.88) (CTC-vs-CTC: 'Praisy'=-7.65 > 'praise'=-11.21)
   vocabulary: "praise" -> "Praisy" also offered (span 0.83)
   vocabulary: "praise" -> "Praisy's" also offered (span 0.66)
   vocabulary judge: 1 slot(s) from 3 proposal(s)
```

**The judge refused correctly on 2, 4 and 8.** Each had a wrong proposal on the
menu — `Supabase` over "update", `Praisy` over "praise" twice — and each came
out as ordinary English. The judge is not what failed on those three. It failed
on 5 and 7, and it was never asked on 6.

**Part 1's AUC 0.318 finding reproduced live, with the two mechanisms
separated.** Seven proposals carry both raw scores. Six of the seven are wrong —
only sentence 6's `Matthieu` is a name that was actually said.

| # | proposal | raw, term | raw, word | bonus | boosted | raw prefers | correct? |
|---|---|---|---|---|---|---|---|
| 1 | `general` → `Redcrawl` | −7.88 | −8.12 | 5.85 | −2.03 | the term, by 0.24 | no |
| 2 | `update` → `Supabase` | −5.47 | −7.18 | 2.88 | −2.59 | the term, by 1.71 | no |
| 3 | `bedrock` → `Redrock` | −12.68 | −12.62 | 2.88 | −9.80 | **the word, by 0.06** | no |
| 4 | `praise` → `Praisy` | −13.65 | −14.07 | 2.88 | −10.77 | the term, by 0.42 | no |
| 6 | `Mathieu's` → `Matthieu` | −12.53 | −13.39 | 5.49 | −7.04 | the term, by 0.86 | yes |
| 7 | `praise` → `Praisy` | −10.12 | −9.37 | 2.88 | −7.24 | **the word, by 0.75** | no |
| 8 | `praise` → `Praisy` | −10.53 | −11.21 | 2.88 | −7.65 | the term, by 0.68 | no |

Read it as two separate failures.

**The raw score is not evidence.** On 1, 2, 4 and 8 the term beats the word on
the raw number, before any bonus — and on all four the term is wrong. The margin
does not help either: sentence 2's 1.71 is the largest in the table and it is a
wrong proposal, while the only correct proposal sits at 0.86. This is the shape
of AUC 0.318, on live audio, in the direction Part 1 measured.

**On 3 and 7 the bonus alone made the proposal.** The audio prefers what the
decoder wrote — by 0.06 on `bedrock`, by 0.75 on `praise` — and the flat 2.88
for being in the vocabulary flips it. FluidAudio's `shouldReplace` runs on the
boosted number (`VocabularyRescorer+TokenEvaluation.swift:109-113`), so these
two proposals exist only because of the bonus, and both are wrong. Sentence 3 is
the one where the rewrite then landed: the judge took the `bedrock of` →
`Redrock` span variant, which is why `of` is missing from the output as well.

**Sentence 5 has no acoustic proposal line at all.** Its two proposals are both
rule parts. The `replacements` stage substitutes without logging anything
(`Pipeline.swift:780-794` — it returns `count` and `changes` and writes no
`Log.write`), so `Vercel: heard: [Versal, Versailles, Russell]` firing twice is
silent. `ruleParts` then found `Vercel` standing twice, had a real `before` from
the acoustic pass, attributed both, and opened two slots. The judge kept
`Vercel` in both. **Under today's config sentence 5 is a judge failure on a full
menu.**

**Sentence 4 needed a rule as well as the audio.** The judge counted 4 proposals
from 3 acoustic log lines. Acoustic proposals can only be fewer than their log
lines, never more — the rescorer's line is written before the `moved` guard
(`Vocabulary.swift:677-694`), span variants are written after theirs
(`Vocabulary.swift:710-721`), and applied proposals never reach the judge
(`VocabularyJudge.swift:191`). So at least one of the four is a rule part: a
`replacements` rule fired on this sentence, and the only vocabulary term standing
in the output is `Praisy`. Read it as a `Praisy` rendering in the decode that the
`heard:` list fixed. It is an inference from the counts, not a logged
substitution — the `replacements` stage logs nothing — so treat it as strong and
not certain. Hold it against arm B's sentence 4, where the same sentence logged
`vocabulary.count = 0`.

#### Arm B — `acoustic: false`

The launch quoted above is this arm's: the running process read
`acoustic: false` at 20:34:28, thirty seconds before the first sentence.

Sentences 1, 2, 3, 4 and 8 logged one line each and nothing else:

```
pipeline: skipped vocabulary — when vocabulary.count > 0 did not match (vocabulary.count = 0)
```

**That line is itself a measurement, not an absence.** `vocabulary.count` counts
acoustic proposals *and* `replacements` rules whose target is a vocabulary term
(`Pipeline.swift:708-732`). With the acoustic path off it counts rules only. So
`vocabulary.count = 0` says no `heard:` rule fired on that sentence — which is
the whole of the evidence about sentence 4 below.

Sentences 6 and 7 logged `vocabulary judge: 1 slot(s) from 1 proposal(s)` and
both came out right: the `Mathieu` rule fired, the count reached 1, and the judge
was offered the decoded word back and kept the name. Sentence 5 logged this:

```
vocabulary judge: "Vercel" stands 2 time(s) and no acoustic pass ran, so which one "Versailles" became cannot be told; that reading is not offered
vocabulary judge: "Vercel" stands 2 time(s) and no acoustic pass ran, so which one "Versal" became cannot be told; that reading is not offered
vocabulary judge: 0 slot(s) from 0 proposal(s)
```

**The collisions are gone.** 1, 2 and 3 write no term. That is the result PR 2
was for, and it is what the offline `acoustic: false` arm predicted: the
controls come back whole.

**PR 1's attribution is confirmed live, verbatim.** PR 1 derived that log line
from an offline replay of a corpus clip and wrote it into this section as a
prediction. Arm B produced it, word for word, on a sentence PR 1 never saw:

```
PR 1, from replay:   vocabulary judge: "Vercel" stands 2 time(s) and no acoustic
                     pass ran, so which one "Versailles" became cannot be told;
                     that reading is not offered
                     vocabulary judge: 0 slot(s) from 0 proposal(s)

PR 2, arm B, live:   vocabulary judge: "Vercel" stands 2 time(s) and no acoustic
                     pass ran, so which one "Versailles" became cannot be told;
                     that reading is not offered
                     vocabulary judge: "Vercel" stands 2 time(s) and no acoustic
                     pass ran, so which one "Versal" became cannot be told; that
                     reading is not offered
                     vocabulary judge: 0 slot(s) from 0 proposal(s)
```

Live it fires twice, because the decoder wrote two different renderings —
`Versailles` and `Versal` — and both rules produced a `Vercel`. Two rules, two
occurrences, and `ruleParts` can attribute neither without a `before`.

Note what the judge stage running at all proves here. `vocabulary.count` reached
2, so both rules did fire; the `0 slot(s) from 0 proposal(s)` is the attribution
failing, not the rules failing. That is the difference between sentence 5 and
sentence 4, and the log states it without any inference.

**This raises the `ruleParts` fix from an inference to a reproduced defect.** It
is about five lines: take the pre-rules transcript from the `replacements`
stage, which always has it, instead of from `findings?.text`
(`Pipeline.swift:917-920`), which is nil whenever the acoustic pass did not run.
It is still not in this PR. It is now a defect with a live repro rather than a
reading of the code.

**The possessive is confirmed by removal.** Sentences 6 and 7 come out right
here, where arm A gave `Matthieu work.` and `Let's Praisy Matthieu work.` The
same name, the same speaker, the same build, four minutes apart. What changed is
that arm B has no acoustic substitution, so the name arrives from
`Matthieu: heard: [Mathieu, Matthew]` as a text rule, and a text rule matches
`\bMathieu\b` inside `Mathieu's` and leaves the `'s` where it was. PR 9 has the
mechanism and the code.

#### The falsifier fired: `Praisy` on sentence 4

**A name the rules are supposed to deliver did not arrive.** That is PR 2's
falsifier, stated above, and it fired. Arm B's sentence 4 logged
`vocabulary.count = 0` — no rule with a vocabulary term as its target fired on
it — and came out `Let's praise Praise's work.`

The decode that time was `Praise's`. `Praisy`'s `heard:` list holds `Praises`
among fourteen renderings, and `\bPraises\b` does not match `Praise's`, so no
rule could fire. Arm A's sentence 4 is the contrast: a rule did fire there, on
the count argument above, and the sentence came out right. **So the rule table
is not "not delivering `Praisy`" — it covers the renderings that have been
written down, and this decode was not one of them.** With the acoustic path on,
the acoustic proposal is a second route to the same name. With it off there is
only the list.

**What this does not overturn.** Not the headline. 3 of 8 against 6 of 8 live,
and offline PR 1 measured `acoustic: false` at 100 correct with 0 losses against
today's 85 with 19. One sentence does not move that, and this is one clip.

**What it does mean.** Switching the acoustic path off is not free, and PR 1
already knew that — it cost 2 wins offline, on `Versailles`. This is a second
kind of cost, on a different term, and it means the plan's "the rules earn the
+18" needs a rider: **on `Praisy`, some of the wins come from the acoustic path
alone**, because the rule table can only hold renderings somebody has already
seen written down.

**No `heard:` entry can close this one.** The rendering that was missed is
`Praise's` — the ordinary English word plus a possessive. `Praisy: heard:
praise` would rewrite sentence 8's `Let's praise Antonio's work` and every other
ordinary "praise" this speaker ever dictates. Part 1 §7 says exactly this:
`Praisy: heard: praise` and `Vercel: heard: versal` look identical on the page
and are not the same risk. So `Praisy` is the term where only the audio can
separate the name from the word — and round 7 measured it as the hardest term in
the set, AUC 0.869 (§3). **This is PR 8's problem, met live.** It is also the
case PR 6 has to be good at, because a clip bank is the only evidence source
that can tell `Praise's` from `praise` without a rule that fires
unconditionally.

#### Verdict

**Confirmed.** `acoustic: false` removes the collision failures live. Sentences
1, 2 and 3 write no term under it, and the log shows the pass never ran. That is
PR 2's main question and the answer is yes.

**Confirmed, as a bonus.** PR 1's attribution of its two-clip gap to a nil
`before` at `Pipeline.swift:920` reproduces live, verbatim, on a sentence it
never saw.

**Falsified.** "The rules still deliver the names they are supposed to" is false
as stated. `Praisy` did not arrive on sentence 4 under `acoustic: false`,
because the decoder wrote a rendering no `heard:` entry covers and none safely
could.

**Left open.** Sentence 5 under today's config: the judge got a two-slot menu
with both occurrences attributed, and picked `Vercel` twice. That is the judge
failing with everything it needs, and no arm here diagnoses it further. Also
open: how often the `Praisy` case happens. One clip is not a rate, and nothing
in this run measures one.

**What PR 2 could not do.** It could not test PR 1's veto arm. That needs
`ReferenceMatch.swift` and `PARROTFLOW_REFERENCE_MATCH` from
`origin/proto/reference-matching` built and installed, which is out of scope
here and was not done.

## PR 3 — land the harnesses on `main`

**Changes.** Two harnesses in `scripts/`, not three. `vocab-ablation.py` is
`reference-ablation.py` from `origin/proto/reference-matching` with the two-arm
`vocab-ablation.py` from `origin/experiment/does-vocabulary-pay` folded into it
— the second was the first with N fixed at 2, so keeping both would have been
one harness maintained twice. Arms are `name=CONFIG_DIR[,VAR=VALUE]`, every pair
reported against every other, wins and losses separately, split by class,
majority of `--runs N` with a flip count. `vocab-losses.py` stays its own
script: listing the losing clips and classing each as an overwrite or not is a
different job, and it now takes the two arm names because the harness runs any
number.

Two things PR 1 wanted and did not have. `--only FILE` takes a list of wav
names, so a second pass can re-run just the clips that disagreed.
`--check-config` runs under every arm before the first clip, so a config
directory the app would refuse costs a second instead of the rest of the run. The docstrings carry the
three off arms from part 1 and the scratch config recipe, `audio.output_dir`
included.

**Size.** About 450 lines of Python across the two files. No Swift, no
behaviour change.

**Verified by** reproducing the published baseline: vocabulary off 76/141, today
84/141, 27 wins and 19 losses, 5 clips flipping.

**Falsified if** the off arm is not near 76, or wins and losses swing further
than the flip count explains. Then the archive or the case set has moved and
nothing downstream can be trusted.

### Result, measured 2026-08-09

**The falsifier did not fire. The off arm reproduces exactly, in every block.**

141 labelled clips, `--runs 3`, majority of three replays, `gemma4:e4b-mlx` and
nothing else loaded, built from `feat/ablation-harnesses` at `d7252a8` and never
installed. That build is `main` at `78d7ba2` plus this plan and these two
scripts, so no Swift differs from `main`. Wins and losses are against the `off`
arm.

| arm | correct | wins | losses | net | flips |
|---|---|---|---|---|---|
| off (empty `terms:`) | 76 | — | — | — | 0 |
| today | 88 | 29 | 17 | +12 | 2 |

By class:

| class | clips | off | today |
|---|---|---|---|
| about a term | 68 | 20 | 39 |
| controls | 73 | 56 | 49 |

**The off arm is exact in all three blocks.** 76 of 141, 20 of the 68 term
clips, 56 of the 73 controls — the prototype's numbers to the clip — and it
flipped on nothing over three replays. It is the arm with no acoustic pass and
no judge call in it, so that is what it should do. The archive and the case set
have not moved.

**Today's arm is three clips above PR 1 and four above the published table.**
88 against 85 and 84, 29 wins against 28 and 27, 17 losses against 19 and 19.
The same arm flipped 8 clips in the prototype's run, 3 in PR 1's and 2 here, so
a four-clip move is inside the noise those three runs measured between them.
Nothing else moved: the same 141 clips, the same config files, and the
prototype's extra Swift is gated on `PARROTFLOW_REFERENCE_MATCH`, which no arm
here sets.

**Both headline shapes hold.** All 17 losses are overwrites — a term written
over an ordinary word the speaker meant — and none is anything else, which is
what part 1 §1 says of the 19. And the controls take **0 wins and 7 losses**:
the pass still wins nothing on the clips it can only damage. Counted by the
name written, the losses are `Praisy` 7, `Redcrawl` 5, `Supabase` 3, `Vercel`,
`Matthieu` and `Arexvy` 2 each, `Ollama` and `Mirza` 1 each — `Redcrawl`,
`Supabase` and `Ollama` again costing clips and rescuing none.

**Cost.** 846 transcriptions, 9 minutes of wall clock at 3.8 s/clip for two
arms. PR 1's 10.7 s/clip was five arms over the same clips.

**Only the two arms `main` can run were scored.** The reference-matching arms
need `ReferenceMatch.swift`, which exists only on
`origin/proto/reference-matching`. The harness's support for `VAR=VALUE` arms is
ported and unexercised here; PR 1's command line is the test of it, and it ran
against the same code.

### How to reproduce

Two scratch config directories, copied from `~/.config/parrotflow-dev`. Never
run against the live one. The recipe is in the script's docstring; PR 1's
version above adds the third directory.

```sh
make app                                   # never `make install`

python3 scripts/vocab-ablation.py --runs 3 --out arms.json \
  --arm "off=$S/cfg-off" \
  --arm "today=$S/cfg-on"

python3 scripts/vocab-losses.py arms.json --vocabulary $S/cfg-on/vocabulary.yaml
```

## PR 4 — a correction keeps the audio

**This is the highest-value item in the plan, and it is about recordings rather
than text.** Recordings are the only asset that improves with use, whatever ends
up deciding. Today `voice/samples/` grows by hand and by mining; every correction
the speaker makes is a labelled recording of a term in their own voice, being
thrown away.

**The measured reason to believe a bank improves with use: `Matthieu`, 0.556 to
1.000.** Round 6 measured that term at 0.556 on 2 recordings, which is chance,
and concluded two recordings might be worth nothing. Round 7 measured it at
1.000 on 11 — same rows, same hold-out, only the recordings changed. That is the
clearest single number saying a thin bank is a shortage of clips and not a
property of the term, and PR 4 is what makes clips arrive without anyone being
asked. **Two cautions.** The rows are 3 A / 3 B, so 1.000 rests on nine pairwise
comparisons. And the 9 added recordings are 7 scripted lines plus 2 recovered by
re-mining, not 9 corrections — it measures more clips, not clips from
corrections. Round 7, `origin/spike/exemplars-round-2`.

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

### Result, measured 2026-08-09

**The falsifier did not fire. A usable cut is obtainable, and the instrument
that shows it is not the obvious one.**

The falsifier asks for one live correction. No human was available to dictate
and TTS is banned here — a previous round's `say` output was blank at −0.0 on
every CTC frame — so this was measured on the archive instead. Same word times,
same clips, same arithmetic. What it cannot speak to is stated at the end.

**Where the timings are.** `trace.jsonl`, field `asr.words[]`, each
`{word, start, end, confidence}`. Written by `Trace.Collector.recordASR`
(`Trace.swift:113`) out of `ASRResult.tokenTimings`, grouped by
`Trace.words(from:)`. No dump flag is involved.

**They do not survive the pipeline in memory.**
`Transcriber.transcribe(url:config:app:progress:)` returns a `String` and the
`ASRResult` dies with it. `AppDelegate` keeps `lastTranscript` and
`lastRecording` and no timings. So at all three `addReplacement` call sites
there were none in scope, and the file is the only route. That decided the
design — see below.

**Coverage.**

| | count |
|---|---|
| wav files on disk | 2643 |
| distinct clips with a trace line | 2136 |
| first entry carries word timings | 2011 |
| of the 125 without, ones whose `final` is empty | **125 of 125** |
| on disk **and** first-entry timings | 1779 (67%) |
| on disk, no trace line at all | 692 |

Read the third row. **Every dictation that produced text has word times.** "No
words" means nothing was decoded, so there is nothing to correct. The 692
untraced wavs are historical — 269 fall on 2026-08-03, and there is at most one
a day since 2026-08-05. Part 1 §5's "456 of 2616" is the same fact on a smaller
archive.

**The cut.** `[first word start − 0.05s, last word end + 0.05s]`, sliced out of
the PCM. The same 0.05s `scripts/mine-pronunciations.py:149` uses, so a mined
sample and a corrected one are the same kind of object.

**How it was verified, over 120 random content words and 60 real correction
spans** — a rendering listed under `heard:` that the decoder actually wrote, of
the 416 such spans in the archive.

**1. Silence the span in place and re-decode.** The timeline is untouched, so
the only thing that changed is the audio inside the span. The control silences
a same-length span 0.8s away.

| set | word gone after silencing the timed span | after silencing a shifted span |
|---|---|---|
| 120 random words | 89 of 119 (74.8%) | 14 (11.8%) |
| 60 correction spans | **54 of 60 (90.0%)** | 15 (25.0%) |

**2. Splice the span out.** 106 of 119 (89.1%) against 12.6%. Agrees with 1.
Splicing disturbs the decode of the neighbours as well, which is why 1 is the
better instrument.

**3. Energy.** Span RMS over clip RMS is 1.19 median on the correction spans and
1.07 on the random ones. One cut of 60 sits below 0.5×. The cuts are speech.

**Do not use standalone decoding as an acceptance test for a cut.** This is the
finding worth carrying forward, because it is the test everybody reaches for
first. Decoding the cut on its own recovers the word in only 45 of 120 random
spans and 20 of 60 correction spans — and a cut shifted 0.8s recovers it in 3 of
120, so the alignment signal is there and it is the *decoder* that is failing.
`parakeet-tdt-0.6b-v3` does not reliably decode a 0.5s fragment with no context.
Widening the pad to 0.25s changes nothing: 46 of 120. **18 of the 19 correction
cuts that decoded to silence still passed the silence test**, so a rule that
accepted only decodable cuts would have thrown away good audio at about a third
of everything. Score the cut by what removing it does to the sentence, not by
what it says on its own.

**Two failure modes the build now guards.** 2 of 60 correction spans run past
2s, the worst at 6.4s for one word — a word time that swallowed the pause after
it. And where silencing did not remove the word, it is mostly a clip where the
same word is said twice, which is a limit of the measurement rather than of the
cut.

**What this cannot say.** It is the archive, not a live correction. The one
live-specific risk was reachability at correction time, and that is a plumbing
question the code answers rather than an audio one.

### What was built, and one place the plan was wrong

**One route to the audio, not two.** The plan left the choice open. It is the
trace file, joined to the clip by name — `Trace.delivered(clip:in:)`. The
in-memory alternative was rejected on `--learn`: it is a separate process that
never saw the dictation, so it needs the file route whatever the app does, and
building both would be one job with two mechanisms. PR 5 moves mining onto the
same read.

Cost, measured on a 68 MB trace of 14 001 lines: **0.3s** when the clip is
named, which is the panel's path and the one with a person waiting; 1.3s for
`--learn`'s fallback, which has to look at every clip to find the newest one
whose text contains the rendering. `--learn` grew a `--clip` argument so the
panel's path can be scored without a GUI.

**The plan said `config.yaml`. It should be `vocabulary.yaml`, and this is the
one place PR 4 contradicts the plan.** A correction whose target names a
vocabulary term now writes the rendering into that term's `pronunciations:` with
`seen:` and `from: correction`, instead of into `transcription.replacements`.
Nothing about the app's behaviour changes — `Config.vocabularyRules`
(`Config.swift:532`) turns a rendering into the same exact replacement — but two
things do. The entry now records where it came from, which is what §6c's
provenance signal needs. And `--forget` can reach it: a correction written to
`config.yaml` could never be taken back, which made the plan's "`--forget` must
remove all three" impossible to satisfy for anything this PR wrote. A correction
that is not about a term — `teh` → `the` — still goes to `config.yaml` and keeps
no audio.

**`--forget` already removed all three.** `ForgetCommand` on `main` covers
`vocabulary.yaml`, `observations.jsonl` and `samples/`. The work was making sure
a correction writes where `--forget` looks, which the change above does.

**Nothing is deleted silently.** The duration guard, the per-term cap and the
seen-once rule each print what went and why, to the log in the app and to stdout
under `--learn`. The guard's refusal is also written onto the observation as
`skipped:`, so the rate is countable from the file later — the log truncates at
1 MB (Part 1 §5) and a rate you can only read in prose is a rate nobody reads.

**`lang` and the build stamp go on every observation**, mined ones included.
`AppVariant.buildStamp` is reused, not reinvented. `scripts/mine-pronunciations.py`
now reads `lang` per clip out of the trace and stamps rows with what
`--version` prints.

**The numbers, and where each comes from.** The per-term cap is 25, from the
archive's own 8-to-26 clips per term and Part 1 §3's 0.06 AUC same-session
advantage. The duration guard is 2.0s for one word plus 1.0s per extra word,
from the probe's median 0.64s and p90 0.88s. The seen-once rule waits 30 days,
and only ever drops an entry that says `from: correction` — a mined or legacy
entry has `seen: 0`, meaning never counted, so there is no honest date to delete
it on.

### Verified by

`scripts/check-corrections.sh`, 57 cases, in CI. Every case builds a whole
config directory in /tmp behind `PARROTFLOW_CONFIG_DIR` and generates its own
audio — a tone burst, since the cut is frame arithmetic and
`scripts/check-no-voice.sh` refuses a repository carrying the real thing.

| the plan asked for | what was observed |
|---|---|
| simulate a correction, check the three files | `vocabulary.yaml` gets `- heard: praise` / `seen: 1` / `from: correction`; `observations.jsonl` gets one row with `term`, `heard`, `from`, `span [1, 1.5]`, `wav`, `sample`; `samples/Praisy/00-praise.wav` exists and is 0.60s — the 0.50s span plus 0.05s either side |
| with `lang` on the new observation | `"lang":"fr"`, from the dictation's own trace line, and it follows the clip: naming the other of two clips with the same rendering gives `"lang":"en"` |
| and the build stamp | `"build"` equals what `--version` prints |
| exceed the cap, the oldest unconfirmed goes | 25 samples of which the oldest is confirmed by a correction; the 26th arrives, `01-old.wav` goes, `00-old.wav` stays, the term is back at 25, and the reason is printed |
| `--forget` leaves `--check-config` clean | `✓ forgot Praisy` — 2 pronunciations, 1 observation, 1 sample, the folder gone, and `--check-config` exits 0 with no `✗ vocabulary` line |

Also scored, because each one deletes or refuses: a 6.4s span is refused by name
and number and the observation says so; a two-word rendering gets the extra
second and is kept; a rendering absent from the decoder's words is refused; a
correction with no dictation behind it is refused; a rendering at `seen: 1` from
a correction 2020 is dropped while one at `seen: 4` and a mined one are left
alone.

All 15 checks in CI pass, including the ones this touches —
`check-vocabulary-config.sh` 61/61 and `check-no-voice.sh` 5/5.

**Not done: a live correction.** It needs a human at a microphone. The probe
above is the archive's answer to the same question, and the panel's own path is
scored through `--learn --clip`, which takes the same route with the same clip
name the panel passes.

## PR 4a — a revert writes no rule, and keeps the audio

**A live bug on `main`, independent of this stack.** `ConfigWriter.addReplacement`
wrote `corrected: [heard]` into `config.yaml` whatever the direction of the
correction. So taking a term back — the app wrote `Praisy`, the speaker meant
"praise" — wrote `"praise": ["Praisy"]`, which rewrote *every* `Praisy` into
"praise" from then on. One revert disabled the term, in a file `--forget` could
not reach. Reproduced on `main` at c46c701 with `--learn Praisy praise`.

That matters more now than it did, because the whole direction of this work is
to *encourage* reverts. A revert is the most informative correction there is:
it is the speaker saying, unprompted, that the term is wrong here and that the
audio at this span is the ordinary word.

**A revert does three things, and writing a rule is not one of them.**

1. **Confidence in whatever fired goes down.** If the ordinary word is
   registered as a rendering of the term, that exact rule is what wrote it —
   `Config.vocabularyRules` turns every rendering into an exact replacement, so
   it fires on that spelling every time. Its `seen:` goes down by one. Down by
   one and not deleted: a rendering seen nine times and reverted once is still
   how this person says the word, and deleting it would be the same bug
   pointing the other way. It is only removed at zero, and only when
   `from: correction` wrote it.
2. **The pair is recorded** as `collides_with:` under the term — the word, a
   `reverted` count and a `clips` count. Never matched, never substituted. It
   is keyed on the pair, because "praise" argues with `Praisy` and says nothing
   at all about `Supabase`.
3. **The audio is kept as a negative**, in `voice/negatives/<Term>/`, with
   `polarity: negative` on the observation.

**What can and cannot be attributed.** Only two things write a term where it
was not said: an exact rule from `pronunciations:`, and the acoustic pass. The
first is answerable exactly at the correction site, with no new machinery — if
the word the speaker meant is registered as a rendering of the term, that rule
fired. The second leaves nothing in any file to take back, and the command says
so rather than inventing a culprit. The proposal's own numbers — the
`raw -10.12 vs -9.37, bonus 2.88` in the log — are not in scope: `Trace.Delivered`
carries `asr.words`, `lang` and `final`, and the pipeline's stage list is not
decoded there. Reaching them would mean a second read of the trace for a number
nothing acts on.

**`negatives/` is a separate directory, not a flag inside `samples/`.** Every
script in this repository that walks `samples/` would otherwise ingest a
negative as a positive, silently, and every number computed from the store
would rot. `polarity` on the row is explicit for the same reason: the clip's
meaning inverts, and absent has to keep meaning `positive` so the rows written
before it still parse.

**No sample is deleted on a revert.** Nothing in `samples/` caused the
over-fire — the samples feed the acoustic veto, not the rule that fired — and
6a below showed a bad clip cannot be picked out of a bank from one revert.

**Verified by** `scripts/check-reverts.sh`, 67 cases, in CI. It scores: no rule
in either file; the count-down, the drop at zero, the legacy entry that has no
count to take one off, and the case where nothing can be blamed; the clip in
`negatives/` and nothing at all in `samples/`; `collides_with:` written and then
left alone by `--replace`, which runs every deterministic substitution pass; a
rendering that survives the count-down still firing; `--forget` taking all four
back; and a row with no `polarity` reading as a positive.

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
question in 6a to 6c is narrow: does a rule that is not decided by its worst
clip beat the blind veto? 6d asks the wider one — can the bank propose a term on
its own, with no rule in front of it. If both fail, the clip bank stops being a
decision mechanism and stays what PR 4 makes it — an asset that improves with
use.

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

Four experiments, in order. 6a, 6c and 6d's first step are offline on data
already on disk. No build, no model, no Ollama for any of them. 6d asks a
different question from 6a to 6c — those three fix the veto, 6d asks whether the
bank can propose at all — and it is the only one with no measurement behind it.

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

**Verified by** the three-arm ablation, not by AUC. `vocab-ablation.py
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

### 6d — can the bank *propose* a term, with no rule behind it?

**Nothing in this section is measured.** Every other number in part 1 and part 2
has a branch and a table behind it. This one has none. Read it as a design for
an experiment, not as a result.

**The question.** Scan the spans of a sentence against the clip bank and propose
a term when something lands close. Query by example, with no `heard:` rule and
no spotter in front of it. This is the question that keeps coming back, and it
is worth saying why it matters: if it works it retires the text rules, and §7 is
the argument that the text rules are the part whose risk accumulates and cannot
be read.

**The warning, and it is the whole difficulty.** AUC 0.935 and the 92%
identification rate in part 1 §1 were both measured on spans that something had
**already singled out** — a `heard:` rule, the spotter, or a label. Proposing
means scoring every span of every sentence instead. That is a completely
different false-positive budget. **It is the exact arithmetic that killed the
acoustic path**: a separator that is excellent at "is this candidate wrong" can
be useless at "is there a name here at all". Part 1 §1 says it directly — the
ordinary words of the 48 scripted sentences were never scanned, so nothing
measured so far bears on the false-positive rate of a proposer.

**So the first thing 6d measures is that rate, before anything else is built.**
Take the 141 labelled clips, enumerate every word span from the word timings in
`trace.jsonl`, and count how many ordinary words land within an accept distance
of some term. Report it per 1000 words and as the share of clips with at least
one. The labels say where the real names are, so every other hit is a false
positive. If the rate is not small, stop: nothing downstream survives it and the
rest of 6d is not worth writing.

**Changes.** Offline first, in the same script 6a extends
(`scripts/reference-matching.py` on `origin/spike/exemplars-round-2`). No app
change until the false-positive number says there is a point.

**Size.** Under 200 lines of Python for the false-positive sweep. Unknown after
that, and do not scope it before the number. Note the cost: round 7's 122
recordings over 781 span-term pairs took four minutes of a dynamic program.
Scoring every span of every sentence multiplies that by the number of words, so
6d is also the first place the representation ladder in *Still open* would pay.

**Verified by** the plan's standing bar — `vocab-ablation.py --runs 3` with
arms `off`, `today`, `veto everything` and the proposer, beating the blind
veto's 103 by more than the flip count explains. **And beaten as a proposer**,
which means wins and losses against the `off` arm reported separately, never
net. A mechanism that only ever removes proposals is 6b, not 6d.

**Falsified if** the false-positive sweep finds an appreciable rate over
ordinary words, or if the ablation does not beat 103. Either one ends it. Note
that 6d is falsifiable before any code touches the app, which is the reason to
do the sweep first.

**The standing caveat bites harder here than anywhere.** §7: every number about
the clip bank rests on recordings mined from the corpus they are measured on. A
proposer is scored over every word of that same corpus, so it has more surface
for that flaw than any arm so far. Any number 6d produces needs a held-out set
before it means anything.

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

**PR 2 met it live, and it cuts both ways.** Under today's config the judge
correctly refused `Praisy` over "praise" on two sentences and wrongly took it on
a third. Under `acoustic: false` the same term was **not delivered** on the
sentence that needed it: the decoder wrote `Praise's`, no `heard:` entry
matched, and the sentence came out with the ordinary word. So this term loses
under both settings, in opposite directions, and no `heard:` entry can fix it —
`Praisy: heard: praise` would rewrite every ordinary "praise" (§7). Round 7
already ranked it the hardest term in the set at AUC 0.869 (§3). Any answer here
is a piece of evidence about the sound, not a rule, which makes PR 6's clip bank
the only candidate on the table.

**Start with a measurement, not a design.** Two questions, in order:

1. How many terms are in this class, for this speaker and in general? The
   empirical confusables method in part 1 §6 answers it — run the spotter for
   each term across the archive and see which ordinary words it fires on.
2. What does the pass cost on those terms alone, once the acoustic path is off?
   If it is one term, the question is whether one term justifies any machinery.

**Do not reach for the judge again without reading the dead ends below.** Ten
framings, two routers, two menu shapes and a score block have all been measured
on this class and none moved it.

## PR 9 — the possessive, and there are two of them

**Two cases with the same symptom. One is measured with a named mechanism, the
other is one transcript and an empty log.** They produce the same wrong
sentence, which is how this section came to describe only one of them. Do not
fix case A and report case B as done.

### Case A — the substitution eats it. Measured.

PR 2's arm A, sentences 6 and 7:

```
6  vocabulary: "Mathieu's" -> "Matthieu" applied (raw -12.53 vs -13.39, bonus 5.49)
   vocabulary judge: 0 slot(s) from 0 proposal(s)
   transcribed: Matthieu work.

7  vocabulary: "Mathieu's" -> "Matthieu" applied (raw -12.08 vs -12.76, bonus 5.49)
   transcribed: Let's Praisy Matthieu work.
```

**The decoder wrote `Mathieu's`, with the `'s`.** It is right there in the log
line, as the word the rescorer matched. The pass matched the whole token,
possessive included, and wrote the bare term back. The `'s` is lost in the
replacement, not in the decoding.

**Confirmed by removal, in the same session.** Arm B, four minutes later, same
build and same speaker: `Matthieu's work.` and `Let's praise Matthieu's work.`
With the acoustic path off the name arrives from `Matthieu: heard: [Mathieu,
Matthew]` as a text rule. A literal rule compiles to `\bMathieu\b`
(`Config.swift:1320-1325`) and `Replacements.exact` applies it
(`Replacements.swift:88-106`). `\b` sits happily before an apostrophe, so the
rule rewrites the name inside `Mathieu's` and leaves the suffix alone. Take the
substitution away and the possessive survives.

**The mechanism, in one function.** `Vocabulary.inflected`
(`Vocabulary.swift:456-465`) exists to prevent exactly this — its own comment
says so, citing `Mirza's` → `Mirza`. It only fires when the decoded stem is
spelled like the term:

```swift
let stem = String(lower.dropLast(suffix.count))
if stem == term.lowercased() { return term + suffix }
```

`mathieu` is not `matthieu`, so the guard fails and the bare term comes back.
**A substitution only runs because the decoder spelled the name wrong, so this
guard fails on every case it is needed for.** It carries the possessive only
where nothing needed carrying.

Repro, and it costs a minute: copy `inflected` into a file with `import
Foundation`, print it over these five pairs, and run `swift <file>.swift`. No
build, no app, no audio.

```
term=Matthieu  heard=Mathieu's   ->  Matthieu     ← the live case
term=Matthieu  heard=Matthew's   ->  Matthieu
term=Praisy    heard=praise's    ->  Praisy
term=Matthieu  heard=Matthieu's  ->  Matthieu's   ← the only shape it handles
term=Mirza     heard=Mirza's     ->  Mirza's
```

The rest of the path agrees and adds nothing back. `locate` finds the span by
the rescorer's own `originalWord`, which is `Mathieu's`
(`Vocabulary.swift:769`), and `bounded` accepts it because the next character is
a space (`Vocabulary.swift:309-320`) — so the possessive is inside the matched
range. `trailingMarks` restores `.,?!:;` and no apostrophe
(`Vocabulary.swift:477-480`).

**No judge can catch it.** `autoApplies` returned true
(`Vocabulary.swift:509-523`: `Mathieus` is not a real word and the term wins on
raw score), and `VocabularyJudge.acousticParts` drops every applied proposal at
`VocabularyJudge.swift:191`. That is why sentence 6 logs `0 slot(s) from 0
proposal(s)` on a dictation where a name was rewritten.

**What case A needs.** Not a design — the mechanism is named. It needs a test on
`inflected`, and a count of how often the pass writes a name over a possessive
across the archive, so the fix is sized against something. The guard asks
whether the decoded stem equals the term, when what it has already been told is
that the rescorer matched them.

### Case B — the decoder drops it. Unmeasured.

When the decoder spells a term correctly, nothing is proposed, no slot opens and
the judge is never asked. "Let's praise Matthieu's work" came out as "Let's
praise Matthieu work" with **no vocabulary log lines at all**. Span variants
cannot help, because they are readings of a substitution that was never offered.

What is measured is one transcript and one empty log. Nobody has checked whether
the `'s` is audible in the recording. Start there, then count the cases across
the archive. Only then choose between opening a possessive slot inside the pass
and treating it as ordinary dictation grammar outside it — the second is a larger
stage and needs its own eval set.

**Telling them apart is free.** Case A logs `-> "<Term>" applied` on a word that
ends in `'s`. Case B logs nothing at all.

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
- **A representation ladder, with a middle rung.** Untested proposal. The bullet
  above names the top rung only. There are three: DTW over MFCCs, which is what
  runs today; the Parakeet encoder's frames mean-pooled over the span and
  compared by cosine; and a speech embedding trained for the job. The middle
  rung is cheap in compute, because that encoder already runs on every
  dictation. It is not free in plumbing: nothing in the app reads encoder
  states, `CtcModels.downloadAndLoad()` exposes none, and the only frame-level
  dump that exists is the CTC head's per-frame log-probabilities
  (`PARROTFLOW_LOGPROB_DUMP`, on `origin/spike/ctc-06b` and
  `origin/spike/onset-pilot`). Measure the middle
  rung on round 7's own two sets before paying for the top one.
- **Synthetic cold-start seeding.** Untested proposal. A term with no recording
  has no bank at all — `Redcrawl` was in that state until 2026-08-09. Seed it
  with `say` at several voices and rates, and treat those exemplars as weak
  evidence: probably too weak to confirm a term, possibly good enough to reject
  one, which is the half the veto needs. **The warning comes before the idea.**
  A previous session used `say` and every CTC frame of its output came back
  blank, which invalidated a round of scores; PR 2's result block above forbids
  filling itself from `say` for exactly that reason. So this needs its own
  validity check first: does a `say` clip of a term sit inside the distance
  range of that speaker's real recordings of it? If it does not, synthetic
  seeding is dead, and the check costs an afternoon.
- **A logistic-regression calibrator** over the per-proposal features that
  already exist, as the cheap alternative to `decide_above` / `offer_below`.
  Untested proposal. The features are already written by the harnesses — the
  spotter score `spot` and the de-boosted `gap`
  (`origin/spike/raw-score-separation`), the reference `matched` and
  `mismatched` distances, the `held` recording count
  (`origin/spike/exemplars-round-2`), the span duration and the proposal kind.
  One fitted weight vector in place of hand-set nat thresholds, and a fit over a
  few hundred rows is a few lines. It carries the plan's standing problem — it
  would be fitted on the clips it is reported on — so it needs a held-out split
  from the first run. Part 1 §2 applies as well: measure the blind version,
  which here is the constant "keep what the decoder wrote" at 34 of 57 spans.
- **"Too close, ask the user"** on a reranker's margins. Its own proposal. The
  same question comes back in PR 6c for a suspect clip, where it is easier: a
  clip can be played back and confirmed by ear.

---

# Part 3 — Cleanup this work owes

**The `general → Redcrawl` verdict was never recorded. Replay that one clip.**
It is the canonical failure — sentence 1 of the standing regression list — and
it deserves a measured answer, not an inference. Offline, round 7 put it at
distance **3.328**, nearer than **0 of 8** real recordings of `Redcrawl`, so the
filter should reject it. That row and the other seven overwrites are in part 1
§1. End to end, the prototype log carries no verdict for
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
| `experiment/does-vocabulary-pay` | **No.** The ablation, `vocab-ablation.py`, `vocab-losses.py` and the 19-loss list exist only there. PR 3 lands both harnesses. |
| `proto/reference-matching` | **No.** The prototype and the control arm that settled this plan's direction. PR 6b changes `ReferenceMatch.swift`, which exists only here. PR 3 lands `reference-ablation.py`, merged into `vocab-ablation.py`. |
| `spike/onset-pilot` | **No.** Code only — `PARROTFLOW_LOGPROB_DUMP`. Already re-ported into `spike/ctc-06b`, so nothing is lost if that one survives. |

Eight of the nine carry something that exists nowhere else. Land the findings —
as documents, harnesses and this plan's PRs — before deleting any branch. Two of
them, `exemplars-round-2` and `proto/reference-matching`, are now live
dependencies of PR 6 rather than history.
