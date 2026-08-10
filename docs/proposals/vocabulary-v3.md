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

**Where this is going, as a direction and not a result.** Part 2 opens with
*The architecture this is heading for*: the spotter generates and decides
nothing, the clip bank decides from positive and negative clips, the `heard:`
map covers a term's first days, the judge is the fallback, and each part is
switched on per term by evidence. PRs 11 to 15 break that into pieces.
**None of them is measured.** Read them as proposals with falsifiers attached.

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

**`heard:` matching is exact, whole-word and case-insensitive. There is no
near-miss in it.** A literal rendering compiles to `\b<escaped source>\b`
(`Config.swift:1320-1325`) and `Replacements.exact` runs it with
`.caseInsensitive` (`Replacements.swift:89-91`). Every route to a rendering the
list does not already hold lives inside the acoustic pass. The rescorer matches
the decoded words against the vocabulary by edit distance, gated by
`offer_below` (`Vocabulary.swift:26`, `Vocabulary.swift:580`), and the BK-tree
behind it cannot return anything more than about three edits away — the code's
own comment says "Versailles" is six edits from `Vercel` and is unreachable that
way (`Vocabulary.swift:784-786`). The spotter is the only thing that reaches
further, and it sits in the same pass.

**So `acoustic: false` removes every inexact route to a term, and that is PR 2's
`Praisy` loss.** `Praisy`'s list holds `Praises`. The decoder wrote `Praise's`.
`\bPraises\b` does not match `Praise's`, so no rule could fire and the name did
not arrive. That half is measured — PR 2's arm B logged `vocabulary.count = 0`
on the sentence. **The other half is not measured.** `Praise's` is one edit from
`Praises`, so the rescorer's edit-distance path could reach it, but arm A
decoded that sentence differently and nobody has put `Praise's` through the
acoustic path. Read it as the mechanism that would reach it, not as a run that
did. PR 2's result block and PR 8.

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

**The clip bank is wired inside the acoustic pass, so `acoustic: false` switches
the veto off as well.** `Transcriber.swift:175` calls `Vocabulary.apply` only
when `Vocabulary.wanted` is true, and `wanted` is
`config.vocabulary.acoustic && !config.vocabularyTerms.isEmpty`
(`Vocabulary.swift:88-90`). The prototype's veto is a local function defined
inside `apply` — `vetoed`, at `Vocabulary.swift:604-637` on
`origin/proto/reference-matching` — and it is called on the rescorer's proposals
(`:663`), on the wider span readings (`:756`) and on the spotter's spans
(`:776`). No `apply`, no veto.

**So PR 1 and PR 6 are mutually exclusive as both are written, and this plan did
not say so.** PR 1 turns the acoustic path off with one config line. PR 6b
measures a better veto, which needs that path running to have anything to veto.
PR 6 says "the acoustic path is on in that arm" and stops there; it never names
the config line that makes the veto unreachable. Anything that keeps the bank as
a gate has to either keep the pass on or move the bank out of `apply`. PR 13 is
the second shape.

**The clip bank has never gated a `heard:` rule substitution, in any arm.**
Rules are applied by the `replacements` stage (`Pipeline.swift:780-794`) from
`Config.vocabularyRules` (`Config.swift:532-538`). That stage runs in the
pipeline, after the acoustic pass has already finished
(`Transcriber.swift:175-216`). The veto runs inside the pass and only on
acoustic proposals. So PR 2's sentence 5 — a rule writing `Vercel` over
`Versailles` — is invisible to the clip bank, with the spotter on and the veto
at its most aggressive. **Every clip-bank number in this plan is a number about
acoustic proposals.** None of them says anything about a rule.

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

**Most of the time the judge is not discriminating. It is answering the same
way.** PR 2's arm A, sentence 5, is the clearest single case: two slots, and it
produced "Vercel … Vercel Castle" — the same answer at both. That is what
"always keep the term" produces. The dead ends list says it three other ways.
"Keep what the decoder wrote" beats argmax on the score block, 34 of 57 spans
against 28. The shipped prompt scores 0 of 8 on the collision class. And
deleting the term list from the prompt wins 4 of that class and loses 8 other
cases, because the list is the only thing telling the judge `Praisy` is a
spelling at all.

**The mechanism is one prompt carrying two instructions.** It is asked to trust
the term list, so a name the decoder mangled gets written. It is asked to
distrust the term list, so an ordinary word does not get a name written over it.
Those are the same question with opposite answers, and the prompt holds no
evidence that separates them. Every framing measured so far picks a side and
pays on the other. That is why the dead ends read as seven rounds of one result.

**In arm B the judge changed nothing at all.** It ran on 2 of the 8 sentences, 6
and 7, and both times said keep the term — which is the default. Five sentences
never reached it: 1, 2, 3, 4 and 8 each logged `vocabulary.count = 0`. Sentence
5 reached it and printed `0 slot(s) from 0 proposal(s)`, which is the
`ruleParts` defect Fix A is for and not a decision. **Eight sentences dictated
once is not a rate.** This says what the judge did on those eight. It does not
say how often the judge decides anything, and nothing in this plan measures
that.

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

**Measured, 6e: the floor is 5, and "must not reject" starts well above three.**
Subsampling every term's bank says two recordings are indefensible for all
eleven — 18% to 40% of two-clip banks throw away over half the term's own
correct spans — and three are not safe either, at 4% to 15%. At five it is 0% to
3.5%. Both statistics need the same five. **Each of the two numbers above is one
draw and neither is the term.** `Matthieu` at 2 recordings has a median AUC of
0.806 over its 55 possible pairs, running 0.605 to 0.935; `Supabase` at 2 runs
0.636 to 0.998. 6e's result block, and its own caveat: subsampling a good bank
is not the same as a new term's first five corrections.

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

**Measured, 6a.** The mechanism is real and it is large. One bad clip injected
into each of the nine clean folders takes the veto from 554 true rejections to
228 across the eleven terms, and widens the tightest banks by about half a unit
— `Supabase` 2.919 to 3.430, `Arexvy` 3.031 to 3.603. **But the two clips named
above are not the clips that set the spread.** `Tasmeen`'s maximum is held by
`01-tasmin.wav` and `Vercel`'s by `13-versal.wav`, both real recordings of the
term. `06-that'smeanssend.wav` is 5th of 8 and `09-brazil.wav` is 8th of 16.
Removing them changes nothing and makes it worse: taking `09-brazil.wav` out
*raises* `Vercel`'s spread, 3.178 to 3.235. A bad clip with company never sets a
maximum. The result block under 6a has the numbers.

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

**This part is arithmetic, not a measurement, and 6a could not measure it.**
Nobody has measured a bilingual term's spread. 6a looked and found no second
pronunciation in the archive to measure: no observation carries `lang`, all
eleven `Matthieu` recordings come from dictations `trace.jsonl` marks `en`, and
splitting them by what the decoder wrote gives one cluster, not two — 3.216
within a group against 3.250 between, AUC 0.513. It needs a recording session,
which is 6c's second verification. In the prototype log `Matthieu` sits at 3.053 over 10 recordings,
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

## How this lands

Nothing in this plan is merged, and the branches form a deep stack:
`docs/vocabulary-v3-clip-bank` (#74) → `test/acoustic-off-arm` (#75) →
`test/live-acoustic-off` (#76) → `docs/clip-bank-evidence` (#77) →
`feat/ablation-harnesses` (#78) → `test/arm-a-result` (#79) →
`docs/missing-prs` (#80) → `test/poison-a-clip` (#82) →
`docs/architecture-from-evidence` → `docs/vocabulary-pipeline`.
`feat/corrections-keep-audio` (#81) is a sibling off #79, not part of the line.

**#74 to #79 can land as a block.** They are documents and Python harnesses.
No Swift differs from `main` on any of them, so none can change what the app
does, and reviewing them one merge at a time buys nothing.

**The two fixes below target `main` directly.** They are Swift, they are five
lines and three lines, and neither depends on the clip bank. Putting them in
the stack would gate them behind six documents.

**A deep stack rebases every time its base moves.** Six rebases per landed
change, and each one is a chance to lose a result block. That is the cost of
adding to it, and the reason to land the block early.

## The architecture this is heading for

**This is a direction, not a measured result.** Nothing below has been built or
scored. It is written down because the PRs after PR 10 only make sense against
it, and because the alternative is five sections that each imply a different
endpoint. Read every claim in it as a proposal. The measured facts are in part
1.

Five parts, each with one job:

- **The spotter generates candidates and decides nothing.** It is a good
  detector and a bad chooser — part 1 §1 and *Still open*. Take the choosing
  away from it. 6d is where this is measured.
- **The clip bank decides**, from the speaker's own recordings, positive and
  negative. PR 6 and PR 11.
- **The `heard:` map covers a term's first days**, then goes quiet. It is the
  only thing that works with no clips at all. PR 14.
- **The judge is the fallback**, for terms the bank cannot cover yet. It is
  retired per term as coverage arrives, not switched off globally. PR 15.
- **Each part is switched on per term, by evidence.** Part 1 §1: three terms
  have never rescued a clip and have cost nine, while `Vercel` is 9 wins to 1.
  Anything global is the wrong shape.

**What this is answering.** Today the same mechanism both proposes a name and
decides whether the name is right, and it is the same mechanism twice: a
comparison between audio and a *spelling*. Part 1 §1 measured that comparison at
AUC 0.318 — worse than chance. Splitting generate from decide lets the decision
use a different kind of evidence, which is what the clip bank is.

**What could kill it.** 6d's false-positive sweep, first. A generator that fires
on ordinary words hands the bank a problem no decider can fix, and part 1 §1
says nothing measured so far bears on that rate.

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
rules are clean on this corpus. It is the reason the recordings keep their value
even if 6b fails. **This paragraph said "do not schedule it". PR 2 changed
that** — sentence 5 is a rule overwriting `Versailles`, live, and part 1 §1 now
records that no arm has ever gated a rule with the bank. PR 13 is the section.

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

### Result, measured 2026-08-09

**The falsifier's condition fired and its conclusion is false. Build 6b and
6c.** Poisoning a term does barely move its AUC — nine of the eleven arms do not
move it at all. That is arithmetic, not evidence. Inside one term `spread` is a
constant, so an AUC over that term's spans cannot see it, whatever it does. The
number that can see it is the rule's own decision, and it collapses: over the
eleven arms one clip takes the veto from **554 true rejections to 228**, and
buys back 8 of its 10 false ones. §7 is right about the mechanism and the
falsifier was written against a statistic that cannot detect it.

**And the two clips §7 names are not the clips that set the spread.** That is
new, and it changes what 6c has to find.

No app, no build, no model. `scripts/reference-matching.py` with a `--poison`
arm, 122 recordings, 170 spans, every distance computed once. It is
deterministic — no decoder, no replay, so a number here is exact for this data.
Nothing under `~/.config/parrotflow-dev/` was written: the arms run on a copy.

**This is in-sample and the plan says so twice already.** The recordings were
mined from the clips they are scored on. The per-clip hold-out is applied
throughout, and it does not cover the corpus-level fit. Read every absolute
number below as better than the truth by an unknown margin. The *deltas* are
what this experiment is for.

#### The baseline reproduces round 7 exactly

`--set scripted --source all`: `Supabase` 1.000, `Redrock` 0.993, `Tasmeen`
0.985, `Redcrawl` 0.966, `Mirza` 0.940, `Arexvy` 0.936, `Ollama` 0.874,
`Matthieu` 0.848, `Claude` 0.844, pooled **0.935** over 63 A and 718 B. The
control is 0.832 on A and 0.076 on B, 58/63 and 13/718. Duration alone is
0.535. Every figure matches the round 7 table to three decimals. The archive is
still 122 recordings over 11 terms.

#### AUC and spread, one bad clip added

`Vercel/09-brazil.wav` injected into the nine folders that have no known bad
clip. `Vercel` and `Tasmeen` run backwards: their own bad clip is removed.
AUC is on the scripted set, except `Praisy` and `Vercel`, which have no scripted
recording and so no A row there — those two are on round 5's proposal set and
are marked.

| term | rec | AUC before | AUC after | spread before | spread after |
|---|---|---|---|---|---|
| arexvy | 7→8 | 0.936 | 0.936 | 3.031 | **3.603** |
| claude | 6→7 | 0.844 | 0.844 | 3.436 | 3.576 |
| matthieu | 11→12 | 0.848 | 0.844 | 3.053 | **3.570** |
| mirza | 15→16 | 0.940 | 0.940 | 3.257 | 3.257 |
| ollama | 7→8 | 0.874 | 0.874 | 3.313 | 3.516 |
| praisy | 26→27 | 0.869 † | 0.869 † | 3.235 | 3.425 |
| redcrawl | 8→9 | 0.966 | 0.966 | 3.098 | 3.338 |
| redrock | 7→8 | 0.993 | 0.993 | 2.999 | **3.438** |
| supabase | 11→12 | 1.000 | 1.000 | 2.919 | **3.430** |
| tasmeen ‡ | 8→7 | 0.985 | 0.987 | 3.268 | 3.268 |
| vercel ‡ | 16→15 | 0.933 † | 0.933 † | 3.178 | 3.235 |

† on the proposal set, 21 A / 37 B for `Praisy` and 6 A / 5 B for `Vercel`.
‡ the bad clip removed, not added.

**AUC does not move and it cannot.** Nine of the eleven arms are identical to
three decimals. `Matthieu` moves 0.004 on 448 A-B pairs and `Tasmeen` 0.002 on
390, which is two pair-flips and one. The reason is in the arithmetic: AUC ranks spans inside one term, and
`spread` is one number for the whole term, so it divides out. The only route
from a bad clip to AUC is the query side — `distance` is a `min`, so a bad clip
lowers it when it happens to be nearest. §7 predicted that route would be small.
Measured, it is between nothing and 0.004.

**Spread moves a lot, on a clean bank.** The four bold rows are the four
tightest banks. `Supabase` widens 0.511, `Arexvy` 0.572, `Redrock` 0.439,
`Matthieu` 0.517. One clip, and the cloud is half a unit wider.

#### The veto, which is what the spread decides

Same arms, scored as `ReferenceMatch.verdict` scores them: reject when
`distance > 1.0 × spread`, abstain under three recordings, hold out any
recording cut from the span's own clip. A count pools both sets — every span the
term is scored against.

| term | veto B before | veto B after | veto A before | veto A after |
|---|---|---|---|---|
| arexvy | 55/66 (83%) | **1/66 (2%)** | 1/6 | 0/6 |
| claude | 18/70 (26%) | 5/70 (7%) | 1/6 | 0/6 |
| matthieu | 50/67 (75%) | **2/67 (3%)** | 2/10 | 0/10 |
| mirza | 36/67 (54%) | 35/67 (52%) | 1/8 | 1/8 |
| ollama | 34/67 (51%) | 10/67 (15%) | 0/7 | 0/7 |
| praisy | 66/108 (61%) | 12/108 (11%) | 1/21 | 0/21 |
| redcrawl | 58/66 (88%) | 25/66 (38%) | 1/8 | 0/8 |
| redrock | 62/65 (95%) | 14/65 (22%) | 1/7 | 0/7 |
| supabase | 62/64 (97%) | **16/64 (25%)** | 0/10 | 0/10 |
| tasmeen ‡ | 42/68 (62%) | 43/68 (63%) | 1/7 | 1/7 |
| vercel ‡ | 71/76 (93%) | 65/76 (86%) | 1/6 | 0/6 |
| **total** | **554** | **228** | **10** | **2** |
| reject everything | 784 | 784 | 96 | 96 |

**B is the rule working and A is the rule costing.** A B span is a name that was
not said, or an ordinary word the app wrote a name over. Dropping it is the
whole point. An A span is the name really being said, and dropping it is a loss.

**One clip disarms the veto.** `Arexvy` goes from catching 83% of the spans it
should catch to 2%. `Matthieu` 75% to 3%. `Supabase`, the term with a perfect
AUC, 97% to 25%. Across the eleven arms 326 of 554 true rejections go, and 8 of
the 10 false ones go with them. Forty true rejections lost for each false one
saved.

**The blind control is in the table.** Rejecting everything takes all 784 B
spans and all 96 A spans. So the clean rule at 554/10 sits well inside it and
the poisoned rule at 228/2 has moved a long way towards doing nothing. This is
an offline count of rejections, not the three-arm ablation. It does not say what
any of this scores on 141 clips. That is 6b's job and 6b's bar is still 103.

#### The two clips §7 names are not the clips that set the spread

This is the surprise, and it was measurable only because the arm was run
backwards.

| term | the clip that holds the leave-one-out maximum | where the named bad clip ranks |
|---|---|---|
| tasmeen | `01-tasmin.wav` at 3.268 | `06-that'smeanssend.wav` is #5 of 8, at 2.462 |
| vercel | `13-versal.wav` at 3.178 | `09-brazil.wav` is #8 of 16, at 3.005 |

Both maxima are held by real recordings of the term. Removing
`Tasmeen/06-that'smeanssend.wav` changes the spread by nothing at all, 3.268 to
3.268, and the veto by one span. Removing `Vercel/09-brazil.wav` makes the
spread **worse**, 3.178 to 3.235, and costs 6 true rejections — the clip was
some other recording's nearest neighbour, so taking it out pushed that
recording's leave-one-out distance up.

**Why:** a bad clip with company is invisible to a maximum. `Tasmeen`'s eight
recordings include `06-that'smeanssend`, `07-thatmeans`, `03-dasmean` and
`04-dasmean`. Those sit near each other, so each has a close neighbour and none
of them is ever the largest leave-one-out distance. The same shape explains
`Mirza`, whose spread does not move when a bad clip is added: `13-mirza's.wav`
already sits at 3.257, farther out than the injected clip.

**Three things follow for 6c.** First, leave-one-out self-consistency is the
first signal in 6c's list and it does not find either named clip. Second, a
pruner that deletes the farthest recording deletes a real one — `01-tasmin.wav`
and `13-versal.wav` are the term. Third, pruning one bad clip out of a group of
bad clips can raise the spread, so 6c must handle groups, not singletons. 6c
already says "suspect only a far singleton"; this says the singleton assumption
is wrong on the two clips it was written for.

#### The robust statistic buys most of it back

The same arms with the 90th percentile of the leave-one-out distances in place
of the maximum. Nothing else changes.

| statistic | veto B clean | veto B poisoned | kept | veto A clean | veto A poisoned |
|---|---|---|---|---|---|
| maximum | 554 | 228 | 41% | 10 | 2 |
| 90th percentile | 649 | 551 | 85% | 17 | 8 |
| reject everything | 784 | 784 | — | 96 | 96 |

**It is better on both a clean bank and a poisoned one.** Clean, it takes 649
true rejections against the maximum's 554, at a cost of 7 more false ones — 17
of 96 rather than 10 of 96. Poisoned, it holds 551 where the maximum holds 228.

Per term, poisoned, the collapses stop being collapses: `Arexvy` 86%→68% rather
than 83%→2%, `Matthieu` 75%→75% rather than 75%→3%, `Supabase` 100%→97% rather
than 97%→25%. `Claude` is the one that still falls hard, 66%→16%, and it is the
term with six recordings — at n=6 the 90th percentile is nearly the maximum.
`Redrock` falls 98%→65%, and it has seven.

**So the robust statistic is worth building, and it does not finish the job.**
Below about eight recordings a high quantile is the maximum again. That is an
argument for PR 4 and PR 5 — more clips per term — as much as for 6b.

#### The second pronunciation arm could not be run. The data is not there.

**Do not read the sweep below as a bilingual result.** The archive holds no
identified second pronunciation of any term, and this is the honest report of
looking for one.

**`lang` is absent and would not have helped.** No observation carries it — PR 4
is what would write it and PR 4 is not built. Joining
`voice/observations.jsonl` to `trace.jsonl` by the source clip recovers the tag
anyway, and all eleven `Matthieu` recordings come from dictations marked `en`.
That includes the one clip where the speaker plainly says the name twice:
`parrotflow-2026-08-09T14-04-44.wav`, decoded "That was Matthew that was
Mathieu's idea, to be fair", which produced `09-matthew.wav` and
`10-mathieu's.wav`.

**Splitting by what the decoder wrote does not give two clusters.** Six
recordings are rendered `matthew`, `matsu` or `match's` and five `mathieu` or
`mathieu's`. Measured, the two groups sit on top of each other: mean distance
within a group 3.216 over 25 pairs, between groups 3.250 over 30, AUC 0.513
against 0.500 for one cluster. So either the speaker says it one way, or MFCC
and DTW cannot tell the two apart on a half-second name. This method cannot
distinguish those, and neither can any number in this plan.

That leaves §7's prediction — that a thin second cluster inflates `spread` and
the damage peaks at one or two clips — **unmeasured**. The sweep runs, but with
groups that are not clusters it only says what adding any clip does:

| bank | rec | AUC | spread | veto B | veto A |
|---|---|---|---|---|---|
| 6 anglicised + 0 | 6 | 0.844 | 3.253 | 36/67 | 2/10 |
| 6 anglicised + 1 | 7 | 0.842 | 3.253 | 37/67 | 2/10 |
| 6 anglicised + 2 | 8 | 0.855 | 3.189 | 43/67 | 2/10 |
| 6 anglicised + 3 | 9 | 0.866 | 3.189 | 43/67 | 2/10 |
| 6 anglicised + 4 | 10 | 0.855 | 3.189 | 39/67 | 2/10 |
| 6 anglicised + 5 | 11 | 0.848 | 3.053 | 50/67 | 2/10 |

Spread falls and the veto strengthens as clips arrive. There is no peak at one
or two. That is what adding *correct* clips does to a maximum, and it is the
mirror of the poison result: a clip near the bank can only shorten somebody's
leave-one-out distance, and a clip far from it sets a new maximum.

**To measure §7's prediction somebody has to record the second pronunciation on
purpose.** 6c's second verification asks for exactly that — read `Matthieu` both
ways, several of each. Until that session happens, "a bilingual term poisons its
own threshold" stays an argument. No `say`-generated clip: TTS output has come
back blank on every CTC frame before and cost a round of results.

#### What is weak about this

**In-sample, and the poison is one clip.** Every arm injects the same recording,
`Vercel/09-brazil.wav`. A different bad clip would move a different amount. The
direction is not in doubt — eight of the nine injected banks widened — but the
size of the move is one clip's worth of evidence per term.

**Rejection counts are not the ablation.** They say what the rule would drop on
these spans. They do not say what the app would write, and the 141-clip score is
the only thing that settles 6b.

**A one-span move means nothing.** `Mirza` 36→35 and `Tasmeen` 42→43 are one
span on a denominator near 67. Read only the large moves: the seven terms that
lost more than 20 true rejections each.

**`Claude`, `Redcrawl` and `Redrock` have no spontaneous recording**, so their
rows are read speech against read speech from one session. Round 7 already flags
that, and the poison deltas inherit it.

#### How to reproduce

```sh
S=$(mktemp -d) && cp -R ~/.config/parrotflow-dev/voice "$S/voice"   # read only

git show origin/spike/exemplars-round-2:scripts/reference-matching.py \
  > scripts/reference-matching.py          # then the --poison arm on top

PARROTFLOW_CONFIG_DIR=$S python3 scripts/reference-matching.py \
  --set scripted --source all              # the baseline that must reproduce

PARROTFLOW_CONFIG_DIR=$S python3 scripts/reference-matching.py \
  --poison --pronunciation --cache "$S/dist.npz"
PARROTFLOW_CONFIG_DIR=$S python3 scripts/reference-matching.py \
  --poison --pronunciation --robust --cache "$S/dist.npz"
```

The first `--poison` run computes every span-to-recording and
recording-to-recording distance and caches them, under ten minutes. Every arm
after that is indexing and returns at once. `--inject` picks a different bad
clip.

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

### 6c — review a term's bank by ear, in groups

**Rewritten after 6a. What changed and why, before the design.** The old 6c hunted
outliers: score each clip for suspicion, suspect a far singleton, delete it. 6a
falsified that. Bad clips arrive in groups and vouch for each other, so
leave-one-out flags real recordings instead — `Tasmeen`'s maximum is held by
`01-tasmin.wav` and `Vercel`'s by `13-versal.wav`, both genuine, while the two
bad clips §7 names rank 5th of 8 and 8th of 16. Removing `Vercel/09-brazil.wav`
made the spread *worse*, 3.178 to 3.235, and cost 6 true rejections.

**What survives from 6a.** The problem is real and large: one bad clip takes the
veto from 554 true rejections to 228. Clustering before judging still matters,
for the reason the old section gave — a second pronunciation is two real
clusters, not one truth and one outlier. The bilingual verification criteria
below are unchanged. What is dropped is ranking by distance from the pack, and
deleting anything.

**This section is a design. Nothing in it is measured.**

**Changes.** A review tool, not a pruner.

- **Rank by provenance and duration, not by distance.** `from: correction`
  outranks `from: mined`; a mined clip is a guess from a decode that may itself
  have been wrong, and `Vercel/09-brazil.wav` is a mined one.
  `VoiceStore.Observation.span` carries `[start, end]`, so a cut much shorter or
  much longer than the term's typical span sorts to the top — that is usually a
  bad cut rather than a bad pronunciation. Both fields exist today: PR 4 writes
  them and `origin/feat/corrections-keep-audio` carries the code.
- **Group the clips and show the groups.** These are half-second clips. Four of
  them is under three seconds, so **play the whole group** and ask one question
  about it. That is the difference between a review that takes a minute and one
  nobody finishes.
- **Let the group's own tightness decide how it is played.** The same
  leave-one-out number, computed inside the group instead of over the term, says
  whether the group is one thing. Tight enough, answer it as a unit. Loose,
  play it clip by clip. **Do not assume a group is homogeneous.** One
  mispronunciation can sit inside a tight group — that is exactly what 6a found
  in `Tasmeen`, where four similar-sounding clips include `06-that'smeanssend`.
- **Never delete.** Mark a group as not counted and leave the files where they
  are. A clip is auditable by ear, so a mistake here is reversible by ear.
  Deletion is not. This also removes the risk 6a measured: taking one clip out
  of a group of bad clips can raise the spread.
- **Label the clusters with `lang`.** Part 1 §3: the language is already in
  `trace.jsonl` and PR 4 carries it into every observation. It decides nothing —
  a French name can be said the French way in an English sentence — but it names
  a group in words the speaker recognises and it says whether coverage exists
  for each way the name is said.

**Size.** About 200 lines of Python, plus playback, plus the recording session
for the bimodal check.

**Verified by** three things, unchanged from the old section except the first,
and the last two still matter more:

1. the known bad clips are surfaced for review — `Vercel/09-brazil.wav`,
   `Tasmeen/06-that'smeanssend.wav`. **Surfaced, not flagged.** 6a showed
   neither is an outlier, so this is a test of the ranking putting them in front
   of a person, not of an automatic verdict;
2. **a deliberately bilingual term keeps both clusters.** Build one: read
   `Matthieu` both ways, several of each, and check that neither group is marked
   not-counted. A method that fails this loses correct data;
3. **and that term still vetoes.** Keeping both clusters is only half the job.
   Run the bilingual term through the ablation and check it still rejects a
   wrong proposal — with the per-cluster spread from 6b, it should; with one
   spread over both clusters, §7 says it will not. **A term that keeps all its
   clips and rejects nothing has failed**, and the first criterion alone would
   call that a pass.

**Falsified if** either bilingual check fails, or if the review surfaces so many
groups that nobody would finish it. Measure the second before building the
playback: count how many groups a term of 8 to 26 clips produces.

**Resolved, and it was open: pruning is never automatic.** The old section left
this to a false-flag rate. 6a supplies the answer instead — the statistic that
would drive an automatic pruner deletes real recordings, and one of its two
deletions made the bank worse. So the speaker confirms by ear, and the tool
never removes a file.

### 6d — the spotter generates, the bank decides

**Nothing in this section is measured.** Every other number in part 1 and part 2
has a branch and a table behind it. This one has none. Read it as a design for
an experiment, not as a result.

**The question.** Propose a term from the audio, with no `heard:` rule behind
it, and let the clip bank say whether the proposal is right. This is the
question that keeps coming back, and it is worth saying why it matters: if it
works it retires the text rules, and §7 is the argument that the text rules are
the part whose risk accumulates and cannot be read.

**Reframed after PR 2, and this is the change.** The original 6d scanned every
span of every sentence against the bank — a generator built out of the bank
itself. There is already a generator. **The spotter is a good detector and a bad
chooser**, and the plan measured both halves: it separates "something is here"
from "nothing is here" at 0.999 (*Still open*, the spotter-floor sweep), and the
acoustic score it and the rescorer share separates right from wrong at AUC 0.318
(part 1 §1). So take the choosing away from it. Keep the spotter as the
generator and put the bank behind it as the decider.

**This is cheaper than scanning every span, and by a lot.** The spotter
over-generates by design — every term scores against every stretch of audio, so
a 19-second clip yields about ninety hits (`Vocabulary.swift:788-789`). Ninety
verdicts at the measured ~1 ms per proposal is under a tenth of a second, and it
is bounded by the spotter's own output rather than by the word count. Scanning
every span is bounded by nothing.

**6d's warning still applies and is now the first measurement.** Every clip-bank
number in this plan was measured on spans something had already flagged. Ninety
hits per clip is the size of the gap between that and a real generator, and the
same gap is what killed the acoustic path. So the sweep below runs first,
against the spotter's hits, before anything is built.

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
Take the 141 labelled clips and score every spotter hit against the bank — every
hit, not only the ones that survive today's three gates, because the gates are
part of what is being replaced. Count how many ordinary words land within an
accept distance of some term. Report it per 1000 words and as the share of clips
with at least one. The labels say where the real names are, so every other hit
is a false positive. If the rate is not small, stop: nothing downstream survives
it and the rest of 6d is not worth writing.

Run the same sweep over every word span from `trace.jsonl` as a second arm. That
is the version with no generator in front of it, and it is the blind control
part 1 §2 asks for: if the bank behind the spotter does no better than the bank
on its own, the spotter is contributing nothing.

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

### 6e — the abstain curve: how many clips is enough?

**This is an experiment, not a result. It replaces two guesses with a number.**

**The question.** A bank with too few clips must not decide. Everything in this
plan that needs that threshold has guessed at it. The prototype abstains below
three recordings because two recordings give exactly one exemplar-to-exemplar
distance and so no spread — that is arithmetic and it stands. Nothing says three
is where the bank becomes *useful*. PR 10 already asks for the number to be a
config key. PR 14 needs it to say when the map stops being the only evidence.

**Correcting the record before it gets quoted.** An earlier draft of PR 14 said
"about three corrections". That number came from two places and neither
supports it: the prototype's abstain floor, which is about having a spread at
all, and `Matthieu` scoring 0.556 at 2 recordings in round 6. One term at one
count is an anecdote. Do not carry the number forward.

**Changes.** None to the app. 6a's harness already computes per-term AUC with
the per-clip hold-out, so this is a subsampling loop on top of it.

**How.** For each term, draw random subsets of its bank at n = 2, 3, 5, 8, 12,
several draws per n, and record per-term AUC against clip count. Keep the
per-clip hold-out throughout. Plot AUC against n per term, and pooled. Read
where the curve leaves chance and where it flattens.

**What the archive can and cannot support.** It spans 6 clips (`Claude`) to 26
(`Praisy`) over 11 terms. So n = 12 exists for four terms and n = 8 for six;
the high end of the curve is thin and the report must say which terms are in
each point rather than pooling silently. `Claude` cannot reach n = 8 at all.

**Size.** Under 100 lines of Python on top of 6a. Offline, no app, no model,
no Ollama. Under an hour of machine time — every distance is already cached by
6a's `--cache`, so the arms are indexing.

**Verified by** a curve per term and a pooled curve, with the number of terms at
each n stated. The output is one threshold with an argument behind it.

**Falsified if** the curves do not flatten, or if per-term curves disagree so
much that no single n describes them. That is a real outcome and not a failure:
part 1 §3 already found the distance scale differs per term, so a per-term
threshold may be the honest answer. It would mean PR 10's config key is the
wrong shape.

**In-sample, like everything else here.** Part 1 §7's closing warning applies:
the recordings were mined from the corpus they are scored on, so the curve is
better than the truth by an unknown margin. It is the *shape* of the curve this
is for, not the height.

### Result, measured 2026-08-10

**Abstain below five recordings, not three. One number covers ten of the eleven
terms, and it is the same number for both statistics.** At n=3 a draw still
throws away over half of a term's own correct spans between 4% and 15% of the
time, depending on the term and the statistic. At n=5 that is 0% to 3.5%. The
worst case is the number to read: an abstain rule exists for the bad draw, not
for the median one. The prototype's floor of 3 was arithmetic —
"two recordings give one distance" — and it is a floor on *computability*, not
on usefulness. Usefulness arrives two clips later.

**The falsifier half fired, and on the statistic that cannot see the
decision.** It fires on the AUC clause: `Praisy` and `Vercel` do not flatten,
they are still climbing at n=12. It does not fire on the clause that matters —
the per-term decision curves agree closely, and one n describes ten of eleven
terms. This is 6a's lesson again. 6a's falsifier was written against an AUC
that cannot see `spread`; 6e's first clause is written against the same AUC. PR
10's config key is the right shape. Its value is 5, not 3.

No app, no build, no model, no Ollama. `scripts/reference-matching.py` with a
`--subsample` arm on top of 6a's, 122 recordings, 170 spans, every distance
already in 6a's `--cache`. Deterministic given the seed: `6e-2026-08-10`, up to
200 distinct subsets per point, every subset enumerated where a bank has fewer
than 200. Nothing under `~/.config/parrotflow-dev/` was written; the arms run on
a copy.

#### Both baselines reproduce

`--set scripted --source all` gives `Supabase` 1.000, `Redrock` 0.993,
`Tasmeen` 0.985, `Redcrawl` 0.966, `Mirza` 0.940, `Arexvy` 0.936, `Ollama`
0.874, `Matthieu` 0.848, `Claude` 0.844, pooled **0.935** over 63 A and 718 B.
The control is 0.832 on A and 0.076 on B, 58/63 and 13/718. Duration alone is
0.535. 6a's `--poison` table reproduces byte for byte as well, including the
554 → 228 true rejections. The archive is still 122 recordings over 11 terms.

#### What the archive supports — the plan had this wrong

6e's own text says "n = 12 exists for four terms and n = 8 for six". Counted:
**n = 8 exists for seven terms and n = 12 for three.**

| n | terms that reach it |
|---|---|
| 2, 3, 4, 5 | all eleven |
| 6 | all eleven — `Claude` has exactly six |
| 8 | seven: `Matthieu` 11, `Mirza` 15, `Praisy` 26, `Redcrawl` 8, `Supabase` 11, `Tasmeen` 8, `Vercel` 16 |
| 12 | three: `Mirza` 15, `Praisy` 26, `Vercel` 16 |

`Claude` cannot reach n = 8, as the plan says.

#### The AUC curve, per term

Median over the draws, with the full range under it. `Praisy` and `Vercel` have
no scripted A row, so they are on the proposal set and marked †. **The 90th
percentile gives the identical table** — see below.

| term | rec | n=2 | n=3 | n=4 | n=5 | n=6 | n=8 | n=12 | full |
|---|---|---|---|---|---|---|---|---|---|
| arexvy | 7 | 0.895 | 0.921 | 0.923 | 0.936 | 0.936 | — | — | 0.936 |
| | | .862–1.000 | .887–1.000 | .897–1.000 | .913–.985 | .921–.985 |  |  | |
| claude | 6 | **0.582** | **0.635** | 0.736 | 0.851 | — | — | — | 0.844 |
| | | .479–.654 | .538–.759 | .610–.885 | .726–.867 |  |  |  | |
| matthieu | 11 | 0.806 | 0.842 | 0.850 | 0.855 | 0.853 | 0.853 | — | 0.848 |
| | | .605–.935 | .594–.940 | .705–.931 | .757–.917 | .804–.897 | .815–.877 |  | |
| mirza | 15 | 0.950 | 0.954 | 0.954 | 0.952 | 0.950 | 0.948 | 0.942 | 0.940 |
| | | .823–1.000 | .821–.996 | .871–.992 | .927–.992 | .927–.990 | .929–.974 | .929–.950 | |
| ollama | 7 | 0.797 | 0.851 | 0.869 | 0.874 | 0.874 | — | — | 0.874 |
| | | .562–.900 | .685–.903 | .697–.903 | .828–.892 | .854–.885 |  |  | |
| praisy † | 26 | 0.736 | 0.761 | 0.770 | 0.789 | 0.798 | 0.804 | 0.827 | 0.869 |
| | | .468–.851 | .476–.874 | .593–.882 | .642–.887 | .650–.887 | .704–.892 | .726–.898 | |
| redcrawl | 8 | 0.955 | 0.966 | 0.964 | 0.962 | 0.963 | — | — | 0.966 |
| | | .736–.998 | .817–1.000 | .867–1.000 | .879–1.000 | .897–1.000 |  |  | |
| redrock | 7 | 0.866 | 0.917 | 0.951 | 0.973 | 0.993 | — | — | 0.993 |
| | | .723–.980 | .779–.980 | .875–.996 | .920–.996 | .958–.996 |  |  | |
| supabase | 11 | 0.946 | 0.962 | 0.973 | 0.978 | 0.989 | 0.996 | — | 1.000 |
| | | .636–.998 | .733–1.000 | .842–1.000 | .880–1.000 | .898–1.000 | .927–1.000 |  | |
| tasmeen | 8 | 0.879 | 0.926 | 0.931 | 0.981 | 0.985 | — | — | 0.985 |
| | | .726–.987 | .756–.995 | .803–.995 | .851–.995 | .869–.992 |  |  | |
| vercel † | 16 | 0.700 | 0.767 | 0.767 | 0.800 | 0.833 | 0.833 | 0.900 | 0.933 |
| | | .467–.933 | .500–.933 | .500–.933 | .600–.933 | .567–.933 | .633–.933 | .733–.933 | |

† on the proposal set, 21 A / 37 B for `Praisy` and 6 A / 5 B for `Vercel`.
`Vercel`'s AUC moves in steps of 1/30, so read its column as coarse.

**Three things in that table.**

**A single draw at n=2 is worth nothing, which is why nobody should have
quoted `Matthieu` 0.556.** `Matthieu` at n=2 has a median of 0.806 and a range
of 0.605 to 0.935. Round 6's 0.556 was one draw of two clips out of the 55
possible. `Supabase` runs .636 to .998 at n=2 and `Claude` .479 to .654.
`Claude`, `Praisy` and `Vercel` all have draws below chance at n=2, and
`Praisy` still does at n=3, where `Vercel`'s worst draw is exactly chance.

**Nine of eleven flatten. `Praisy` and `Vercel` do not.** Both are still
climbing at n=12, and both are the terms scored on the proposal set rather than
the scripted one. Whether that is the term or the set, this experiment cannot
say. `Redcrawl` is flat from n=2, `Mirza` from n=2, and `Mirza` *falls* slightly
as clips arrive, 0.954 at n=3 against 0.940 at 15.

**The median hides everything.** `Arexvy`'s median at n=2 is 0.895 against
0.936 at its full seven. Read only that and n=2 looks nearly free. The range is
what says otherwise, and the veto below says it louder.

#### The decision, which is the number that decides abstain

Two shares, per term and per n, at tolerance 1.00. **Disarmed**: the draw
rejects under 25% of the B spans it should. **Cost**: the draw rejects over 50%
of the A spans — the term really being said, thrown away. Both read off the
rule's own verdict, which is what 6a found an AUC cannot see. Maximum on the
left of each pair, 90th percentile on the right.

**This table and the one above disagree about where abstain sits, and this one
wins.** At n=3 the AUC median is inside 0.016 of the full-bank value for
`Redcrawl`, `Matthieu`, `Mirza` and `Arexvy` — read the AUC alone and three
clips look finished for four of the eleven terms. Those same four banks at n=3
throw away over half of the term's own correct spans in 4% to 7.3% of draws, and
`Mirza` is disarmed in 5% of them. The rule's behaviour is the thing an abstain
key controls, so it is the thing that sets the number.

| term | n=2 | n=3 | n=4 | n=5 | n=6 | n=8 |
|---|---|---|---|---|---|---|
| **disarmed %** | | | | | | |
| arexvy | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | — |
| claude | **60 / 60** | **90 / 55** | **46.7 / 26.7** | **16.7 / 16.7** | 0 / 0 | — |
| matthieu | 12.7 / 12.7 | 7.9 / 1.2 | 1.5 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| mirza | 6.7 / 6.7 | 5 / 2 | 1.5 / 0.5 | 0 / 0 | 0 / 0 | 0 / 0 |
| ollama | **33.3 / 33.3** | **40 / 17.1** | 17.1 / 2.9 | 4.8 / 0 | 0 / 0 | — |
| praisy | **19.5 / 19.5** | 21.5 / 9 | 15 / 6.5 | 8.5 / 0.5 | 10.5 / 0.5 | 6 / 0.5 |
| redcrawl | 3.6 / 3.6 | 1.8 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| redrock | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | — |
| supabase | 5.5 / 5.5 | 2.4 / 1.2 | 1 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| tasmeen | 10.7 / 10.7 | 16.1 / 0 | 5.7 / 0 | 1.8 / 0 | 0 / 0 | 0 / 0 |
| vercel | 7.5 / 7.5 | 4 / 3.5 | 4.5 / 2 | 1.5 / 0 | 0.5 / 0 | 0 / 0 |
| **cost %** | | | | | | |
| arexvy | **28.6 / 28.6** | 5.7 / 5.7 | 0 / 0 | 0 / 0 | 0 / 0 | — |
| claude | **40 / 40** | 10 / 10 | 0 / 0 | 0 / 0 | 0 / 0 | — |
| matthieu | **27.3 / 27.3** | 7.3 / 7.9 | 2 / 2.5 | 0 / 0 | 0 / 0.5 | 0 / 0 |
| mirza | **18.1 / 18.1** | 4 / 4 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| ollama | **33.3 / 33.3** | 11.4 / 14.3 | 2.9 / 5.7 | 0 / 0 | 0 / 0 | — |
| praisy | **30 / 30** | 11 / 15 | 7.5 / 9 | 2.5 / 3 | 0 / 0.5 | 0.5 / 0.5 |
| redcrawl | **28.6 / 28.6** | 5.4 / 7.1 | 0 / 1.4 | 0 / 0 | 0 / 0 | 0 / 0 |
| redrock | **38.1 / 38.1** | 11.4 / 14.3 | 2.9 / 5.7 | 0 / 0 | 0 / 0 | — |
| supabase | **20 / 20** | 3.6 / 9.7 | 1.5 / 4 | 0 / 0.5 | 0 / 0 | 0 / 0 |
| tasmeen | **25 / 25** | 7.1 / 8.9 | 1.4 / 2.9 | 0 / 0 | 0 / 0 | 0 / 0 |
| vercel | **25 / 25** | 8 / 10.5 | 4.5 / 5 | 1.5 / 3.5 | 2 / 2.5 | 0 / 0.5 |

**n=2 is indefensible for every term in the archive.** Between 18% and 40% of
draws throw away over half of the term's own correct spans. That is one bank in
four to one in three, on the tightest terms as much as the loosest — `Supabase`,
which scores AUC 1.000 at eleven clips, is at 20%. Two clips is a coin flip
about which two.

**n=3 is not safe either, and this is what replaces the guess.** The cost share
is 4% to 11% under the maximum and 4% to 15% under the 90th percentile.
`Claude` is disarmed in 90% of its n=3 draws. The prototype abstains here.

**n=5 is where both sides settle.** The worst cost share over eleven terms is
2.5% under the maximum and 3.5% under the 90th percentile. The worst disarm
share is `Claude` at 17% and then `Praisy` at 9% (maximum) or 0.5% (90th
percentile).

**`Claude` is the one term a single n does not cover.** It is only clean at
n=6, which is its whole bank, so 6e cannot say whether 6 is `Claude`'s answer or
just the end of its data. `Claude` is the shortest name in the set, has the
fewest recordings, has the widest bank — spread 3.436 against `Supabase`'s
2.919 — and is the one term the veto never worked well on: 26% of true
rejections at its full bank against `Supabase`'s 97%. 6a already singled it out
for the same reason.

#### Pooled, in 6a's units

Every term's bank cut to n at once, rejections summed, on the maximum. The
cohort is resampled independently per term per draw, so a row is a joint sample
of that cohort's banks. Median over 200 joint draws, range under it. n=2 to 6 is
all eleven terms; the last two rows change the set and say so.

| n | terms | true rejections (B) | false rejections (A) | |
|---|---|---|---|---|
| 2 | 11 | 555 [394–726] of 772 | 26 [9–52] of 77 | |
| 3 | 11 | 507 [349–673] of 784 | 23 [12–39] of 96 | |
| 5 | 11 | 560 [465–684] of 784 | 16 [6–26] of 96 | |
| all | 11 | **554** of 784 | **10** of 96 | ← 6a's row |
| 8 | 7 | 382 [300–460] of 516 | 10 [5–16] of 70 | |
| 12 | 3 | 175 [129–230] of 251 | 5 [2–9] of 35 | |

The eleven-term rows with the 90th percentile: 577 [436–716] at n=3, 624
[529–715] at n=5, 649 at the full bank. The denominator column is the blind
control — reject every span — and every arm here sits inside it.

**The pooled true-rejection count is a trap and the range says why.** Its median
barely moves: 555 at n=2, 554 at the full bank. A reader could conclude two
clips are as good as twenty-six. The range is 394 to 726 at n=2 and a single
number at the full bank. The count is not lower at n=2; it is unknowable at n=2.
This is §2's "watch for a flat response curve" in another shape.

#### The two statistics need the same abstain point

**The AUC table is identical for the maximum and the 90th percentile, to every
digit.** Verified by diffing the two runs. That is not a coincidence and it is
not an experimental result — `spread` enters only the veto, never `distance`, so
no ranking of spans inside a term can depend on it. It is 6a's arithmetic
restated: the statistic is invisible to the AUC.

**At n=2 the two statistics are the same statistic.** Two recordings give one
leave-one-out distance, so the maximum of it and the 90th percentile of it are
that one number. The n=2 rows of both runs are identical throughout, veto counts
included. Anyone tuning a robust summary should know it has no effect at all
until the third clip.

**From n=3 the 90th percentile disarms less and costs slightly more.** It is
uniformly better on the disarm side — `Tasmeen` 16% → 0% at n=3, `Ollama` 40% →
17%, `Matthieu` 8% → 1%. It is a little worse on the cost side — `Supabase` 4% →
10% at n=3, `Praisy` 11% → 15%. Both are the same trade 6a measured: the higher
threshold rejects more, which catches more true rejections and more false ones.

**So the abstain threshold does not differ between them, and that settles one
6b question.** Both need about 5. The 90th percentile does not let the bank
decide sooner. What it buys is a better decision at the same n — 6a's result —
and it does not buy a lower floor. If 6b adopts it, the abstain key stays where
6e puts it.

#### Does one n work for all terms?

**Yes, at n=5, for ten of eleven.** `Claude` is the exception and its own bank
runs out at 6.

**Clip count does not predict which terms need more.** `Arexvy` and `Redrock`
have seven recordings each and are at 0% disarmed from n=2. `Ollama` also has
seven and is at 40% at n=3. `Praisy` has twenty-six and is the second-worst term
at every n.

**The bank's own width predicts it better, and the evidence is thin.** Ranking
terms by the smallest n at which both shares fall under a fixed bar gives
Spearman +0.54 against the full-bank `spread` and −0.24 against the clip count.
**Do not build on those two numbers.** The ranked variable takes three or four
distinct values over eleven terms, so nearly every pair is a tie and one term
moves the coefficient. The honest statement is the one above: one n covers ten
of eleven, so there is almost nothing left to predict. The direction is the
sensible one — `Claude` has the widest bank at 3.436 and needs the most clips,
`Supabase` the tightest at 2.919 and needs the fewest — and `spread` is the
right kind of predictor because it is computable from the clips alone, where a
per-term AUC needs labelled spans a new term does not have.

#### What is weak about this

**It is in-sample in a second way, and this one is specific to 6e.**
Part 1 §7's warning is that the recordings were mined from the corpus they are
scored on. 6e adds another. **Subsampling a bank measures how *that* bank
degrades. It does not measure how a *new* term with n clips behaves.** A
subsample of `Praisy` at n=3 is three clips drawn from twenty-six that are
already known to separate this corpus well — same speaker, same sessions, same
microphone, mined by the same script from the same archive. A new term's first
three clips come from three corrections in three unrelated sentences, on
whatever days they happen, with nothing having checked that they are the term at
all. **A real n=3 bank is worse than an n=3 subsample of a good bank, by an
amount nobody here has measured.** So 5 is a lower bound on the abstain point,
not an estimate of it. Measuring the real thing needs terms whose banks grew one
correction at a time, which is PR 4's data and does not exist yet.

**The thresholds in the decision table are conventions.** 25% for disarmed and
50% for cost. The per-draw rates are in the script's output and can be read
against another pair. The n=2 verdict survives any reasonable choice; the
difference between n=4 and n=5 does not — `Praisy` moves between safe-at-5 and
safe-at-8 under the maximum when a single grid point is added, because it sits
on the bar.

**The A denominator shrinks at small n.** The per-clip hold-out can take a
subsampled bank under the abstain floor, and then that span is judged by nobody.
`Arexvy` judges 4 A spans at n=2 against 6 at its full bank. So the cost share
at n=2 is a share of four or five spans per term, not of six to ten. It is the
noisiest column in the table and it is also the most extreme, which is a reason
to read the direction and not the digits.

**One seed.** `6e-2026-08-10`. Every point below 200 subsets is exhaustive and
so seed-independent; the points at 200 draws are not. Nothing here rests on a
gap of one or two draws.

**Two terms are scored on the proposal set and nine on the scripted set.** They
are not the same measurement, and the two terms that fail to flatten are exactly
the two on the proposal set. 6e cannot separate those.

**Rejection counts are not the ablation.** Same caveat as 6a. These say what the
rule would drop on these spans. They do not say what the app would write.

#### How to reproduce

```sh
S=$(mktemp -d) && cp -R ~/.config/parrotflow-dev/voice "$S/voice"   # read only

PARROTFLOW_CONFIG_DIR=$S python3 scripts/reference-matching.py \
  --set scripted --source all                    # the baseline that must hold

PARROTFLOW_CONFIG_DIR=$S python3 scripts/reference-matching.py \
  --poison --cache "$S/dist.npz"                 # builds the cache, ~5 minutes

PARROTFLOW_CONFIG_DIR=$S python3 scripts/reference-matching.py \
  --subsample --ns 2,3,4,5,6,8,12 --cache "$S/dist.npz" --csv "$S/max.csv"
PARROTFLOW_CONFIG_DIR=$S python3 scripts/reference-matching.py \
  --subsample --robust --ns 2,3,4,5,6,8,12 --cache "$S/dist.npz" --csv "$S/p90.csv"
```

The `--poison` run computes every distance once. The two `--subsample` runs
index that cache and take about two seconds each. `--csv` writes every number
in the tables above, so none of them is transcribed by hand.

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

**Part 1 §1 now states the rule half exactly, and it sharpens the problem.**
`heard:` matching is exact, whole-word and case-insensitive, and every inexact
route to a term lives in the acoustic pass. So `acoustic: false` does not merely
remove a second route to `Praisy` — it removes the *only* route to any rendering
nobody has written down. `Praise's` was one of those. The list can be extended,
but not with "praise", and that is what makes this the residue.

**PR 11 is the first thing that could give this term two sides.** `Praisy` and
"praise" are one sound in this mouth, so a bank of `Praisy` clips answers
nothing on its own. A bank of "praise" clips beside it makes the question a
comparison. Whether that comparison separates anything is unmeasured, and this
term is the one where it is most likely to fail.

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

## PR 10 — ship the filter

**Gated. Do not start this until PR 6b produces a rule that beats the blind
veto's 103, and until that win holds on a held-out set.** Both conditions, not
either. The bar is the blind veto and not today's pass — part 1 §2. The
hold-out is the second condition because part 1 §7 closes by saying every
published number here is in-sample and "the true numbers are worse than the
published ones and nobody knows by how much". PR 4 is what makes a hold-out
possible: it records the source clip of every recording a correction writes, so
a split by clip is available for the first time.

**Why this section exists.** PR 6a to 6d are experiments on the clip bank. None
of them puts `ReferenceMatch` into the product, and the plan had no PR that
did. This one names that work so its cost is visible before 6b starts. It is
not a design for the rule — 6b picks the rule.

**Changes.** Five things the prototype on `origin/proto/reference-matching`
does not have. Each is named in its own
`docs/proposals/reference-matching-proto.md`, under "What would have to change
before this became real code".

1. **Config, not environment.** `PARROTFLOW_REFERENCE_MATCH` and
   `PARROTFLOW_REFERENCE_TOL` are environment variables. The tolerance belongs
   in `vocabulary.yaml` beside `decide_above` and the other knobs, and the
   switch belongs there too. Keep `PARROTFLOW_REFERENCE_DUMP` as an environment
   variable: it measures every proposal without vetoing anything, which is how
   the tolerance was swept, and that is a harness tool rather than a setting.
2. **Defined behaviour on an empty or thin bank.** Nothing says what happens
   when `voice/samples/` is empty. It must mean the filter does nothing, never
   that everything is vetoed. The prototype abstains below three recordings for
   a term, because two recordings give one exemplar-to-exemplar distance and so
   no spread. Make that number a config key and print the abstaining terms in
   `--check-config`, so a speaker can see which of their terms the filter is
   not deciding. **6e measured the value: 5, not 3.** Three is where a spread
   becomes computable; five is where the decision stops depending on which
   clips arrived. Read 6e's result before choosing the default.
3. **One log line per decision.** The prototype writes two. The `dropped:` line
   says "audio prefers what was written by …" with a margin nobody computed,
   and the `reference:` line above it says the truth. The proto doc calls this
   a prototype tell. Fix the `dropped:` path to state the real reason.
4. **Tests.** `ReferenceMatch` has none. `--reference-selftest <Term>` checks
   the MFCC and DTW port against the numpy original to 1e-6 over 346 pairs,
   which is worth keeping, but it is a developer command and not a test.
   `verdict` needs cases for abstain, reject, keep, and an empty bank.
5. **Migration.** A `vocabulary.yaml` written before these keys exist must keep
   working, and enabling the filter must not change a transcript for a speaker
   with no recordings.

**Why.** Everything above is the difference between a branch that measures well
and code somebody else's dictation depends on. It is listed as one PR because
none of it is worth doing until 6b says there is a rule to ship, and all of it
is needed the moment there is.

**Size.** Moderate. Swift in `ReferenceMatch.swift`, `Config.swift` and
`Vocabulary.apply`, plus tests and a `--check-config` line. The signal-processing
port itself is done and exact, so none of the hard arithmetic is in this PR.

**Verified by** four things.

- `vocab-ablation.py --runs 3` with arms `off`, `today`, `veto everything` and
  the shipped rule, on the held-out split, with the shipped rule beating 103 by
  more than the flip count explains. Wins and losses separately, split by class.
- An empty `voice/samples/` giving a transcript identical to today's arm, clip
  for clip over the 141, with the filter switched on.
- `--check-config` naming every term below the abstain threshold.
- One `reference:` line per verdict, and no `dropped:` line contradicting it.

**Falsified if** the in-sample win over 103 does not survive the held-out
split. Then PR 6b measured the corpus and not the rule, and nothing ships.
**Also falsified if** the abstain rule makes the filter inert in practice: if a
fresh speaker's terms mostly sit under three recordings, this ships a config
key that does nothing until PR 4 and PR 7 have run for weeks, and that is a
different PR in a different order. **And treat a per-speaker tolerance as a
warning, not a feature.** A key invites tuning, tuning on the clips you report
on is the trap part 1 §2 is about, and a key with no defensible default should
not be a key.

## PR 11 — negative clips as a data type

**Proposal. Nothing here is measured.** The design rests on one argument and one
measured fact. The argument: a revert is labelled audio of the ordinary word,
in this speaker's voice, at the exact span the system got wrong. The fact: part
1 §1's `Praisy` case, where the term and an ordinary English word are the same
sound, and no measurement of sound alone separates them. A negative clip is the
only thing on the table that turns that into a comparison.

**Today a revert is discarded.** PR 4 keeps the audio when a correction *makes*
a name. When the speaker takes a name back — `Praisy` → "praise" — the app has
a clip of the ordinary word, cut at the span that misfired, and it throws it
away. That is the most informative correction there is.

**Changes.**

- **`voice/negatives/<Term>/`, a separate directory.** Not a flag on a file in
  `samples/`. Four things walk `voice/samples/<Term>/` today and none of them
  reads a flag: `scripts/reference-matching.py`, `scripts/mine-pronunciations.py`,
  `scripts/vocab-ablation.py`'s config recipe, and `VoiceStore.samplesDirectory`
  (`VoiceStore.swift:49`, `:135`, `:150`, `:192`). A negative dropped into
  `samples/` is silently ingested as a positive by every one of them, and the
  failure is invisible: the bank just gets worse. A directory they do not know
  about cannot be misread.
- **`polarity: positive | negative`, explicit on `VoiceStore.Observation`.**
  Absent reads as positive, so every line written before this key exists still
  parses — the same rule `lang`, `mic` and `build` already follow. It has to be
  explicit rather than inferred from the directory, because the *meaning* of the
  clip inverts. For a correction the clip **is** the term. For a revert the clip
  **is not** the term. A reader that guesses from a path is one refactor away
  from guessing wrong.
- **`collides_with:` under the term in `vocabulary.yaml`.** Three fields per
  entry: the `word`, how many times it was `reverted`, and how many `clips` are
  behind it. **It is never matched and never substituted.** It is not a
  rendering and must not become one — putting "praise" in `Praisy`'s
  `pronunciations:` is exactly the rule part 1 §7 says would rewrite every
  ordinary "praise". All it does is name which pair to compare against. **The
  key parses today with no Swift change**: `Config.Term`'s `CodingKeys` are
  `floor`, `heard` and `pronunciations` (`Config.swift:281`), and a keyed
  container ignores what it is not asked for. So the file can carry the data
  before anything reads it.
- **Keyed on a pair, not on a term.** "praise" is a negative for `Praisy` and
  means nothing to `Supabase`. The comparison a decider makes is "nearer my
  `Praisy` clips or my 'praise' clips", and that question only exists for a
  pair. A global pool of negatives answers a different question and answers it
  badly.
- **`--forget <term>` removes all four things**: pronunciations, samples,
  negatives and the `collides_with` entry. `ForgetCommand.swift` already removes
  the first two; this adds the other two. A term that can be taught and not
  fully forgotten is a term whose data outlives the decision to keep it.

**This is also where part 1 §6's confusables sweep lands.** That sweep runs the
spotter for a term across the speaker's archive and reports which ordinary words
it fires on. Today it has nowhere to write its answer. `collides_with:` is the
place: the sweep proposes the pairs, reverts confirm them, and the `reverted`
count says which pairs are real rather than theoretical. That also makes PR 7's
first item readable off the file — a term with no `collides_with:` entry needs
no clip bank.

**Why the counts are on the entry.** `reverted` and `clips` are what say whether
a pair is worth acting on. A pair reverted once with no clips behind it is a
note. A pair reverted eight times with six clips is evidence. Without the
counts, `collides_with:` is a list that only grows, which is the failure mode
§7 describes for `heard:`.

**Size.** Moderate. `VoiceStore`, `Corrections`, `ConfigWriter`,
`ForgetCommand`, and a `--check-config` line naming the pairs. No decider reads
any of it yet — PR 13 is the first thing that would.

**Verified by** a simulated revert writing a clip under `voice/negatives/`, an
observation carrying `polarity: negative`, a `collides_with:` entry with
`reverted: 1`; `--forget` leaving none of the four behind and `--check-config`
exiting clean; and every existing script producing byte-identical output on an
archive that has negatives in it. That last one is the point of the separate
directory and it is the check that would catch a regression.

**Falsified if** reverts are too rare to build a bank from. Count them first, on
the archive: `Trace` records corrections, so the number of reverts per term over
the last months is countable today without writing anything. If a term collects
one negative a month, the bank behind a pair never fills and PR 13's confirm
direction has nothing to stand on.

**One thing this does not fix.** A negative is evidence about a *sound*. It says
nothing about a rule that fires on a spelling with no audio consulted. That is
PR 13.

## PR 12 — a revert never deletes a sample

**Proposal, and it is a policy rather than a mechanism.** The Swift for the
revert path lands separately, on `fix/revert-does-not-write-a-rule`. This
section says what that path may and may not do to the clip bank.

**The temptation is to delete a sample, and it is wrong.** A revert says the app
wrote a name where the speaker meant an ordinary word. The instinct is that some
recording taught it that. Nothing in `samples/` did. Samples feed the veto,
which only ever *removes* proposals — part 1 §7: "a clip never fires. It adds
nothing and promotes nothing." The thing that wrote the name is a rule or an
acoustic proposal, and the log already names which.

**A bad sample can contribute, indirectly, and 6a measured the limit of that.** A
bad clip inflates `spread` and disarms the veto, so it can let a wrong proposal
through. But 6a showed one revert cannot identify which clip: bad clips arrive in
groups and are invisible to the maximum, the two clips §7 names rank 5th of 8 and
8th of 16, and removing one of them made `Vercel`'s spread worse and cost 6 true
rejections. The geometry points at legitimate recordings. **Deleting on a revert
would delete the wrong file, and it would do it silently.**

**Changes.** On a revert, three things and no deletion:

1. **Blame the proposal the log already names.** The `vocabulary:` lines say
   which mechanism wrote the term — a rescorer proposal, a spotter span, or a
   `replacements` rule. Record that against the revert instead of guessing.
2. **Reduce `seen:` on the rendering that fired, when a rule caused it.**
   `ConfigWriter` counts `seen:` up on every correction
   (`origin/feat/corrections-keep-audio`). A revert is the same evidence with
   the sign flipped, and a rendering whose count goes down is one PR 4's
   seen-once prune can reach.
3. **Count the revert on the term.** N reverts on one term triggers a review of
   that term — 6c's review, by ear, over groups. Not an automatic change.

**Why not delete.** Same reason 6c stopped deleting. A clip is auditable by ear,
so a mistake a person makes is reversible; a deletion is not. And an automatic
deletion driven by a signal 6a showed to be wrong is the worst of both.

**Size.** Small, and most of it is in the revert PR already. The `seen:`
decrement is a few lines on top of `ConfigWriter.adding(pronunciation:)`.

**Verified by** a simulated revert leaving every file in `voice/samples/<Term>/`
in place, the rendering's `seen:` down by one, and the revert counted. Then the
count from PR 11's falsifier: how many reverts a term actually collects, which
is what sets N.

**Falsified if** reverts turn out to be dominated by bad samples after all —
that is, if 6c's review of a term with many reverts keeps finding bad clips.
Then the indirect route is the main route and this policy is too cautious. 6a
says it will not, but 6a measured injected clips and not reverts.

## PR 13 — the clip bank as a gate on `heard:` rules

**Proposal. Nothing is measured, and it is probably the highest-value idea
here.** It is the only thing in the plan that addresses the failure part 1 §1
now records: the clip bank has never gated a rule, in any arm, so PR 2's
sentence 5 is invisible to it.

**The shape.** A rule proposes on text. The bank confirms or refuses it on
sound. The rule keeps its job — it is the thing that works with no clips at all
— and it stops being the last word.

**Two directions, and they carry very different risk.**

- **Veto.** The span's audio is far from every recording of the term, so drop
  the term reading. This only ever subtracts. Its worst case is the transcript
  the decoder wrote, which part 1 §2 measures as right 60% of the time on scored
  spans. Safe.
- **Confirm.** The span's audio is as close as a genuine utterance, so drop the
  *original* reading. This adds. Its worst case is a name nobody said, written
  into a sentence, and nothing downstream undoes it. The speaker has to notice.

**Negatives make confirming much safer, and that is why PR 11 comes first.**
Without them, confirming needs an absolute threshold: "near enough to my `Vercel`
clips". Part 1 §3 says the distance scale differs per term, so that threshold is
per term and tuned, which is the trap part 1 §2 is about. With them it is a
comparison — "nearer my `Vercel` clips than my `Versailles` clips" — and a
comparison needs no scale.

**Read this against sentence 5, because it sets the ceiling.** That sentence has
two slots and four readings. **Veto alone takes it from four to two, not to
one.** The `Vercel Castle` span is far from the `Vercel` bank, so its term
reading goes; the correct `Vercel` span is near, so nothing there is removed and
both of its readings stay. Only a confirming version removes `Versal` and
collapses it to one. So the safe half of this PR does not finish the case that
motivated it.

**Changes.** The gate cannot live where the veto lives — part 1 §1: the veto is
inside `Vocabulary.apply`, which `acoustic: false` switches off, and rules are
applied later by the `replacements` stage. So either the bank moves out of
`apply` into something the pipeline can call, or the gate runs as its own stage
after `replacements`. The second is smaller and matches how `replacements`
already publishes `changes` for a later stage to read. Offline first, in 6a's
harness, before any of it.

**Size.** Unknown, and do not scope it before the offline arm. The offline arm
is small: `replacements.changes` says which rules fired and `trace.jsonl` has
the word timings, so the spans are already available.

**Verified by** the plan's standing bar — `vocab-ablation.py --runs 3` with arms
`off`, `today`, `veto everything` and the gate, wins and losses separately, split
by class. **And by the blind control for this mechanism specifically:** the arm
that vetoes every rule-written term. Part 1 §2 exists because a mechanism that
cannot beat its own blind version has not been shown to work, and "veto every
rule" is a one-line arm.

**Falsified if** the veto direction loses more term clips than it wins control
clips. It has an obvious way to fail: `Praisy` is the word "praise" in this
mouth, so a genuine `Praisy` and a genuine "praise" are the same audio, and a
veto there is a coin flip. Measure per term, not pooled. **Also falsified for
the confirm direction if** it writes any name on a control clip. Controls can
only be damaged, so one is enough to stop it.

## PR 14 — the `heard:` map is a bootstrap, and there is no cutover

**Proposal.** It is a scheduling rule, not a mechanism, and it exists to stop
someone building a switch.

**The claim.** The `heard:` map keeps proposing forever. The clip bank starts
gating a term as soon as it has enough clips to be trusted, and abstains before
that. Nothing is ever switched off, and there is no date where behaviour changes.

**Why no cutover.** A term with two clips behaves exactly as it does today: the
map proposes, the bank abstains, the judge is the fallback. A term with twenty
clips gets its proposals checked. Both states are live at once, per term, and a
term moves between them by collecting clips. That is the "switched on per term
by evidence" line in the architecture section, applied to the one part of the
system that works with no evidence at all.

**Why the map cannot retire.** Part 1 §1: `heard:` matching is the only
mechanism that works with zero recordings, and a new term has zero. PR 7's item
2 shows mining reaches most terms in an existing archive, but a name learnt
today has nothing behind it. The map is what covers a term's first days.

**Correct the record.** An earlier draft of this idea said the bank takes over
after "about three corrections". That number is not supported. It came from the
prototype's abstain floor of 3, which is about having a spread to compare
against at all, and from `Matthieu` scoring 0.556 on 2 recordings in round 6 —
one term at one count. **6e ran and the number is 5.** It is a lower bound: a
subsample of a good bank is not a new term's first five corrections, and 6e's
result block says why. `Matthieu` at 2 recordings has a median AUC of 0.806 over
its 55 possible pairs, so 0.556 was one draw and not the term.

**Size.** No code of its own. It is a constraint on PR 10's abstain key and on
whatever PR 13 ships.

**Verified by** the abstain threshold being a config key with the terms below it
named in `--check-config` (PR 10 already asks for that), and by an ablation arm
where every term is under the threshold producing a transcript identical to
today's, clip for clip.

**Falsified if** running both at once costs clips — if a term whose bank is
thin does worse with the bank abstaining than with the bank absent. That would
mean abstaining is not neutral, and neutrality is the whole claim.

## PR 15 — the judge on probation, with a blind control

**This is a measurement, not a redesign. Do not try to improve the judge.** The
dead ends list seven rounds of trying: ten framings, two routers, two menu
shapes, a score block, a bigger model, a reranker and a fitted constant. None
moved the class that matters.

**The arm nobody has run.** `acoustic: false` **with** the `vocabulary:` stage in
the pipeline, and `acoustic: false` **without** it, over the same 141 clips.
Removing the stage is one line out of the pipeline list, and PR 3's harness runs
config directories, so it is two scratch directories and one command.

**Why this and not another framing.** It is the same discipline that killed the
rejection filter. Part 1 §2: measure the version where the mechanism does
nothing. Nobody has measured the judge doing nothing on the arm the plan wants
to ship. Part 1 §1 says the judge costs a median of 1213 ms on live dictation
and scores 0 of 8 on the failure class that is left; if the two arms tie, that
is 1213 ms and a local model for nothing.

**Gate it on Fix A.** Without the pre-rules text, `ruleParts` offers nothing on
any sentence where a term stands more than once — PR 2's arm B logged exactly
that. The judge would be tested with its one remaining job taken away, and the
test would be unfair to it. Land Fix A, then run this.

**Then retire it per term, not globally.** As PR 11 and PR 13 give a term both
sides of its comparison, that term stops needing a menu. A term with no clips
still does. The same per-term shape as everything else here.

**Size.** No product code. Two config directories and one `vocab-ablation.py`
run. Machine time is PR 3's 3.8 s/clip for two arms, so under ten minutes.

**Verified by** `vocab-ablation.py --runs 3` with arms `off`,
`acoustic: false`, and `acoustic: false` with the `vocabulary:` stage removed.
Wins and losses separately, split by class, with the flip count. Part 1 §2: a
single-run difference within 2 cases decides nothing.

**Falsified if** removing the stage costs clips by more than the flip count
explains. Then the judge is doing work on this arm and the question becomes how
much, per term. **Note what a tie would mean**, because it is the likely outcome
and it is worth naming in advance: the stage would be removable, and the plan
would lose its only mechanism for terms the bank cannot cover.

## Two fixes that go straight to `main`

**Both target `main` directly and neither belongs in the stack.** They are
Swift, they are small, and they depend on nothing in the clip bank or in each
other. Both have a live repro in PR 2's result block, from the dictation pass
of 2026-08-09.

**Their relation to PR 9.** Fix B is the change PR 9's case A asks for. PR 9
names the mechanism and asks for a test and a count; Fix B is the code. It does
nothing for PR 9's case B, where the decoder drops the `'s` and no proposal is
made at all. Fix A is not PR 9 at all — it is attribution, not possessives.
They arrived in the same dictation pass and that is all they share.

**Two sentences dictated once show a mechanism. They do not measure a rate.**
Neither fix has a number saying how often its bug costs a clip. Both have a
log line saying exactly why it does.

### Fix A — `ruleParts` takes the pre-rules transcript from `replacements`

**Changes.** `Pipeline.swift:920` passes `findings?.text` into
`VocabularyJudge.ruleParts` as `before`. `findings` is the acoustic pass's
`Vocabulary.Outcome`, and `Vocabulary.wanted` gates that whole pass on
`config.vocabulary.acoustic` (`Vocabulary.swift:88-90`). So under
`acoustic: false` there is no `Outcome`, `before` is nil, and
`VocabularyJudge.swift:307-323` cannot tell which occurrence of a term a
`heard:` rule wrote. With the term standing more than once it offers nothing.

Take the text from the `replacements` stage instead. That stage is handed the
pre-rules transcript as its input and already publishes `count` and `changes`
computed from it (`Pipeline.swift:779-794`). Publish the input text as well,
and read it at `Pipeline.swift:917-920` beside `replacements.changes`, keeping
`findings?.text` as the fallback. About five lines.

**Why.** The judge loses a reading it could have had, and it loses it on the
one path the app now wants to run. The existing comment at
`VocabularyJudge.swift:307-313` explains why the bug is there — it anticipated
a nil `before` on paths that have no audio at all:

> No acoustic pass ran, so there is no earlier text to compare against —
> `--pipeline`, `--replace`, any path with no audio.

Nobody anticipated a path that has audio and no acoustic pass. `acoustic:
false` is that path, and PR 1 is the plan to make it the default.

The live repro is PR 2 arm B, sentence 5, "deployed on Vercel against the
Versailles Castle":

```
vocabulary judge: "Vercel" stands 2 time(s) and no acoustic pass ran, so which one "Versailles" became cannot be told; that reading is not offered
vocabulary judge: "Vercel" stands 2 time(s) and no acoustic pass ran, so which one "Versal" became cannot be told; that reading is not offered
vocabulary judge: 0 slot(s) from 0 proposal(s)
```

`vocabulary.count` reached 2 on that sentence, so both rules did fire. The zero
is the attribution failing, not the rules.

**Size.** About five lines, plus a test on `ruleParts` with a `before` and a
term standing twice.

**Verified by** two things. A test that gives `ruleParts` a real `before` from
`replacements` with the term standing twice, and gets both occurrences
attributed. And `vocab-ablation.py --runs 3` moving the `acoustic: false` arm
from PR 1's 100 to the veto arm's 102 — the two clips PR 1 measured as the gap
are both this shape.

**Falsified if** the `acoustic: false` arm does not close that gap. Then PR 1's
attribution is incomplete and something else costs those two clips. **Also
falsified if** `replacements.before` is not the pre-rules text on some path. A
pipeline with two `replacements` steps publishes the second step's input under
the same name, exactly as `changes` already does, and the judge would then
attribute against a partly-rewritten transcript. Check what the shipped
pipeline runs before making it the source; a `findings?.text` fallback does not
help when the wrong value is present rather than absent. **And watch what the
new slots are used for.** PR 2's arm A measured sentence 5 wrong with a full
two-slot menu, so correct attribution is necessary and not sufficient. If the
extra slots cost more clips in the ablation than they win, the fix is the wrong
shape.

### Fix B — `Vocabulary.inflected` carries the possessive

**Changes.** `Vocabulary.swift:456-465` reads:

```swift
for suffix in ["'s", "\u{2019}s"] where lower.hasSuffix(suffix) {
    let stem = String(lower.dropLast(suffix.count))
    if stem == term.lowercased() { return term + suffix }
}
return term
```

Drop the `stem == term.lowercased()` test. Carry the suffix whenever the
matched token ends in `'s` or `’s` and the stem is not empty. Three lines, plus
a rewrite of the comment above it to say what the guard was defending against.

**Why.** The function exists to carry a possessive across a substitution, and
the guard makes it fire only where nothing needed carrying. A substitution runs
*because* the decoder spelled the name differently, so the stem is almost never
the term. `mathieu` is not `matthieu`, the guard fails, the bare term comes
back, and the `'s` is gone. Verified standalone on 2026-08-09, no build and no
audio:

```
term=Matthieu  heard=Mathieu's   ->  Matthieu     ← the live case
term=Matthieu  heard=Matthew's   ->  Matthieu
term=Praisy    heard=praise's    ->  Praisy
term=Matthieu  heard=Matthieu's  ->  Matthieu's   ← the only shape it handles
term=Mirza     heard=Mirza's     ->  Mirza's
```

The live repro is PR 2 arm A: "Matthieu's work" came out `Matthieu work.`, and
"Let's praise Matthieu's work" came out `Let's Praisy Matthieu work.` Both were
correct under `acoustic: false` four minutes later, because no substitution ran
and the text rule left the suffix alone.

Nothing downstream catches it. `autoApplies` returned true
(`Vocabulary.swift:509-523`) and `VocabularyJudge.acousticParts` drops every
applied proposal (`VocabularyJudge.swift:191`). That is why arm A's sentence 6
logged `0 slot(s) from 0 proposal(s)` on a dictation where a name had just been
rewritten.

**Size.** Three lines and a test.

**Verified by** a unit test over the five pairs above, where the first three
must now keep the `'s` and the last two must still keep it. Then
`vocab-ablation.py --runs 3`: the labels contain possessives, so clips should
move to correct and none should move wrong. PR 9 also asks for a count of how
often the pass writes a name over a token ending in `'s` across the archive.
Do that count with the fix, not after it — it is what sizes the fix and what
the falsifiers below are read against.

**Falsified if** the ablation loses clips. The narrow guard is deliberate: the
comment says "A word that merely ends in the same letters is not a name plus a
suffix", so a looser rule can write a possessive that was never said.
**Specifically falsified by a contraction.** The rescorer matches a whole
token, and `let's`, `it's` and `he's` end in `'s` without being possessives. If
a term is ever proposed over one of those, today's output is `Praisy` and the
fixed output is `Praisy's` — worse, not better. PR 2's arm A sentence 7 shows
the pass overwriting the word right next to a `Let's`, so this is not
hypothetical. Count how often the matched token is a contraction before
shipping; if that count is not zero on the archive, the fix needs an exclusion
and not the loose rule. **Also falsified if** the archive holds tokens ending
in `'s` where the speaker said no possessive. Fix B assumes the decoder heard
the `'s`, because it is in the token the rescorer matched. Where it did not,
the fix carries a decoder error forward instead of dropping it.

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
