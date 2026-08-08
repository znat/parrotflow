# Proposal: vocabulary v2 — propose, don't decide

**Status.** Planned. This document supersedes the scratchtml note
"Vocabulary v2 — spec, plan, and what the measurements showed" (2026-08-08)
and the artifact "Propose, don't decide". It folds in the review of
2026-08-08, which found bugs in the prototype and in the experiments, and it
restructures the build order so each PR can be implemented and verified by an
agent working alone.

**Goal.** The vocabulary pass stops rewriting text on its own. It proposes
readings; a judge decides; nothing overwrites an ordinary word silently. The
judge's machinery lives in the app; the judge's prompt is a file the user owns.

**The prototype.** A working prototype exists on the branch
`feat/vocabulary-skills-only`. It is the reference, not the base. It contains
known bugs, listed in the findings ledger below. Port from it deliberately;
never merge it.

## Decisions already taken

Do not relitigate these; they were argued and settled on 2026-08-08.

| | |
|---|---|
| Judge mechanics | Native, in the app (option A, folded into PR 3). The JSON/nth hand-off is deleted, not ported. |
| Stage name | `vocabulary`. The pipeline entry is `- vocabulary: verify_names.md`. |
| `menu.py` | Retired entirely. The only user-facing artifact is the prompt file. `menu.py` survives on the frozen prototype branch as reference. |
| Rule slots | Path of least resistance: rule substitutions are still found by term search, limitation documented. `replacements` does not learn to publish ranges. |
| Knobs | Optional stage params with defaults (`max_slots: 4`, `max_readings: 16`, `max_per_slot: 3`, `max_per_term: 2`), not env vars. The vocabulary-pass envs the harness already uses (`PARROTFLOW_SPOTTER_FLOOR`, `PARROTFLOW_JUDGE_DUMP`) stay. |
| Freeze | One `wip:` commit on `feat/vocabulary-skills-only`, then the branch is read-only forever. |
| Execution | One PR at a time, in a worktree, by an agent. No stacking. A PR merges only when its gates pass and its Greptile review rounds are fully addressed; the next PR starts only after the merge. |

---

## How to execute this plan

Rules for the agent doing a PR. Follow them exactly.

1. **Work in a worktree, never on the experiment branch.**

   ```
   cd ~/Documents/parrotflow
   git worktree add ../parrotflow-prN main
   cd ../parrotflow-prN
   git switch -c feat/vocabulary-v2-prN
   ```

   `feat/vocabulary-skills-only` is read-only after PR 0 freezes it. Read
   from it with `git show feat/vocabulary-skills-only:<path>`. Do not commit
   to it, rebase it, or delete it. It is the record of the experiments.

2. **One PR per worktree.** Do not start the next PR in the same worktree.
   Each PR branches from current `main` and lands on `main`.

3. **Every code PR ends with the verification protocol in its section.** A
   gate that fails means stop and report, not force. Record the numbers you
   measured in the PR description.

4. **Steps marked HUMAN need Nathan** (live dictation, label corrections).
   Everything else is replayable from the archive and runs without him.

5. **Prose in simplified technical English** — commit messages, PR
   descriptions, comments. See CLAUDE.md.

### Fixed paths and facts

| What | Where |
|---|---|
| Repo | `~/Documents/parrotflow` |
| Prototype branch | `feat/vocabulary-skills-only` (frozen by PR 0) |
| Live config | `~/.config/parrotflow-dev/config.yaml`, `vocabulary.yaml` |
| Installed transforms | `~/.config/parrotflow-dev/transforms/` |
| App log | `~/Library/Logs/ParrotFlow-Dev.log` |
| Clips | `~/Recordings/ParrotFlow Dev/` (+ `trace.jsonl`, append-only) |
| Built app | `.build/ParrotFlowDev.app/Contents/MacOS/ParrotFlow` |
| Installed app | `/Applications/ParrotFlowDev.app/Contents/MacOS/ParrotFlow` |
| Judge model | Ollama, `gemma4:e4b`, temperature 0. Do not benchmark with other models loaded; e4b is the stable reference. |
| Menu cache | `tests/judge-menus.json` (33 menus, 28 reachable) |
| Case set | `tests/menu-cases.yaml` (37 labelled clips) |

### Environment preflight (run before any measurement)

```
test -d ~/"Recordings/ParrotFlow Dev" && echo clips ok
curl -s localhost:11434/api/tags | grep -q gemma4:e4b && echo ollama ok
swift build -c release 2>&1 | tail -1        # expect "Build complete!"
```

### Build, install, and the handshake

Measurements of live behaviour need the installed app to be the code under
test. This failed silently once (finding F5). After PR 0:

```
make install
"$(/Applications/ParrotFlowDev.app/Contents/MacOS/ParrotFlow --version)"  # prints build stamp
git rev-parse --short HEAD   # must match the stamp, and the stamp must not say "dirty" on a release measurement
```

Until PR 0 lands, the only tell is the log format: `proposed (raw … bonus …)`
is the prototype; `(CTC-vs-CTC: …)` alone is v1.

### Baselines and gates (recorded 2026-08-08, replay numbers)

| Measurement | Command | Baseline |
|---|---|---|
| Menu recall | `python3 scripts/menu-recall.py` | recall 30/37 |
| Judge took it | same run | picked 27/37 |
| Before/after | `python3 scripts/before-after.py` | 16 fixed / 10 broken / 2 regressed |
| Judge on cache | `python3 scripts/tune-judge.py` | 24/28 with the sentinel bug; 26/28 with sentinel lines stripped |
| Two-stage (fixed harness) | see PR 2 | 25/28, ceiling 28/28 |

Gates for every PR from PR 3 on: recall must not fall; `before-after.py`
must show no new REGRESSED rows; judge `picked` must not fall below the
baseline recorded for the same cache. A `--harvest` re-run changes the cache;
re-record the baseline in the PR when you re-harvest, and say so.

**Caveat that stands until PR 1:** the same clip scores ~12 nats apart
between live dictation and replay. Every number above describes replays.

---

## Findings ledger — what happened, and where it is fixed

Each finding has an ID. PRs cite them. Do not re-litigate them; they were
measured.

**F1 — one threshold did two jobs (v1).** The per-term floor decided both
what to look at and what to write. Permissive: "in general" became
"in Redcrawl". Safe: 2 of 20 misheard names caught. → PR 4.

**F2 — substitute-first destroys evidence.** Once `praise` became `Praisy`,
no downstream stage knows what was heard. → PR 3 (propose, judge decides).

**F3 — positions must travel with proposals.** Reconstructing them by
searching for the term collided when two proposals shared one; the correct
reading was never on the menu. A running counter is as wrong: it rewrote the
Versailles castle instead of the deployment. → PR 3 (native ranges, no
search, no counter).

**F4 — the vocabulary bonus corrupts every comparison.** The rescorer adds
up to ~5.9 nats to the term's side only. Raw, the audio preferred "general"
over `Redcrawl` by 5.3. An earlier finding "showing the judge scores hurts"
was measured on the boosted number and is wrong; corrected, scores help.
→ PR 3 publishes raw scores and the bonus separately.

**F5 — the 2026-08-08 failures were a stale binary, and the judge was
silently off.** `/Applications/ParrotFlowDev.app` installed at 00:23 did not
contain the prototype (old log format; new strings absent from the binary),
while `.build/` did. The three "brand overweighted" sentences
(update→Supabase, general→Redcrawl, bedrock→Redrock) were produced by v1
logic; the prototype's router and real-word gate were never exercised on
them. Worse: the new `menu.py` reads `vocabulary.proposals`, which the old
binary never publishes, and no longer reads `vocabulary.changes` — so every
substitution shipped unchallenged. A mechanical contract split across a
binary and a config script will skew. → PR 0 (build stamp + handshake);
PR 3 (mechanics move into the binary).

**F6 — the 0.00 sentinel poisons the judge's evidence.** Spotter-only
proposals carry `heardScore: 0`; the score block renders it as a real
measurement: `"his" 0.00 "Praisy" -3.88 — "Praisy" heard 3.9 less clearly`.
10 of 33 cached menus carry this. Measured on gemma4:e4b: shipped block
24/28, sentinel lines stripped 26/28, no block 25/28. The evidence helps once
it stops lying. Zero is a valid best score in nats; it cannot also be the
sentinel. → PR 3 (scores are optional, absent means absent).

**F7 — the two-stage anomaly was the harness.** "Judge scores 23/28 on a
3-option shortlist but 24/28 on the full menu" had two causes, both in
`rerank-judge.py --stage2`: the shortlist was reordered by reranker score
(the decoder's reading must stay first; ordering is worth ~8 points), and the
full stale score block was passed to a menu it no longer described. Also: with
`--framing all --stage2`, the shortlist silently uses the last framing
alphabetically ("terms" — the below-chance one). → PR 2.

*Ablated properly in PR #62* — mxbai-rerank-base-v2, framing `misheard`,
top-3, judged by gemma4:e4b. The two fixes are not worth the same, and the
second only pays in company:

| Shortlist | picked |
|---|---|
| neither fix | 23/28 |
| order only (decoder's reading first) | 24/28 |
| discriminating trim only | 23/28 |
| both, sentinel lines kept | 23/28 |
| both, sentinel lines dropped | 25/28 |

So ordering is the fix. Trimming the block does nothing on its own, and can
strand a sentinel line as the only survivor — on `2026-08-07T17-05-42` it
dropped the two real Supabase lines and kept `"proposal" 0.00 "Praisy" -5.02`,
which costs a case. The +2 is real; the earlier attribution was not. The trim
therefore applies F6's rule too, which is the same effect arriving twice.

**F8 — a larger judge is worse.** `gemma4:12b`: 17/28 (16/28 cleaned
scores, 15/28 none), replies parse cleanly. Same shape as the reranker
result: size is not the lever. The lever that measured: cleaner evidence
(F6, +2) and a clean two-stage (F7, parity with margins). Strike "try a
bigger judge" from the open levers.

**F9 — bugs in the prototype's Swift.** Port around these; do not copy them:
- The `shifts` delta uses `replacementWord.count`, but the rebuilt text
  inserts `inflected()`, which can add `'s`. Positions after an applied
  possessive are off by two.
- Applied proposals hard-code `nth: 0`.
- `text.range(of: originalWord)` and the cursor in `words(from:in:)` match
  substrings — "update" can land inside "updates". Matches need word
  boundaries or real offsets end to end.
- `proposalsJSON` escapes only `\` and `"`; a control character breaks the
  JSON and the judge silently gets zero slots.
- Pronunciation entries inflate `forVocabSize:`, which shifts the cbw for
  every term. The bonus must be computed from the true term count.
- Pronunciations are silently skipped for terms shorter than 5 characters.
- `tests/judge-cases.yaml`: the header legend for `approve` was corrupted to
  read `decline`. The case relabels below it are correct.

**F10 — `nth` does not survive the pipeline.** `replacements`, `context`
and `fuzzy` run between the vocabulary pass and the judge transform. Any
edit shifts occurrence counts; menu.py then drops or misplaces proposals
silently. → PR 3 (the judge stage runs where ranges are valid, and the app
warns when config places it after a text-editing stage).

**F11 — the eval sets flatter recall.** `mine-menu-cases.py` only admits
clips whose final text contains a term, a known rendering, or a word ≥0.55
similar to a term — Versailles-class deep misses (0.40) can never enter.
`said:` is pre-filled with the app's own output, which biases labels toward
whatever the app already does. `mine-pronunciations.py` reads word dumps
that only print when the pass got past its early guards, so mining can only
widen what already fires. → PR 2 (counter-measures), PR 6 (dump moved).

**F12 — two audio paths disagree by ~12 nats** (live vs replay of the same
clip; replay-to-replay is stable). Until reconciled, every measurement
describes replays. → PR 1, blocking for any live claim.

**F12a — F12 was measurement noise, not two audio paths (PR 1,
2026-08-08).** Two things were wrong with F12.

*There is one audio path.* `Transcriber.transcribe` reads the clip from the
same URL whether it was just dictated or replayed off disk, and the branch
at the seam is gate-versus-no-gate, not live-versus-replay. Measured on the
six clips of 2026-08-08 01:01–01:19 that carry both a live and a replay
`trace.jsonl` entry: VAD total, VAD segments, ASR confidence and every token
timing are identical to the last digit. Same audio, same timings.

*Replay-to-replay is not stable.* The CTC scores move between processes on
byte-identical input. Ten replays of one clip, same seam checksum every time:

| Clip | Term score, 10 runs | Spread |
|---|---|---|
| 01-03-24 (4.05s) | -4.49 ×7, -4.91 ×2, **-5.35 ×1** | 0.86 nats |
| 01-19-35 (18.63s) | -1.96 ×6, -2.07 ×1, -1.81 ×1, -6.84 ×2 | 5.03 nats |

The bolded -5.35 is the *live* number F12 was built on for that clip
(`'Supabase'=-5.35 > 'update'=-10.13`, 01:03:29). A replay reproduces it,
exactly, one run in ten. So the live-versus-replay gap is the same
distribution sampled twice.

**Consequences.** Do not read a single score as a measurement — the noise
reaches 5 nats on a long clip, which is larger than most margins this plan
argues about. Anything that ranks on score needs repeated runs, or it needs
to rank on the decision rather than the number. The seam checksum is now
logged on both paths, so audio can be ruled out in one grep before anyone
chases a score again.

**F13 — harness traps already hit once.** Kept verbatim so they are not
reintroduced: a hardcoded `/Applications` path scored a stale binary; the
newest `trace.jsonl` entry is the current run, take the first per clip;
installing a transform without rebuilding the app disabled the judge;
cross-string `String.Index` silently dropped every replacement; the
`heard:` list was disabled to isolate the acoustic path that its own floors
gated; a stray `--help` app instance doubled the logging; chance was not
computed (half the menus had two options — top-3 was nearly free);
non-ASCII tokens crash a naive `ascii_uppercase.index`.

**F14 — reranker spike results (kept).** Rerankers rule out, they do not
pick: mxbai-rerank-base-v2 (0.5B) top-3 28/28 in ~5s for the set; top-1
19/28 (chance 8.1). Instruction polarity must be inverted ("does this
contain a misrecognition?", ranked ascending) or they score below chance —
listed vocabulary in the query makes term overlap the strongest signal.
Wording is worth 8 points inside the winning polarity and does not transfer
between models. The 1.5B model is worse than the 0.5B. Fusion
`total = logit gap + λ·ctc margin` gives 22/28 on a broad λ plateau
(0.1–0.75). Acoustic numbers pasted into the document: 20→16 — a
cross-encoder does not read them.

---

## Build order

Renumbered from the earlier plan. The harness moves ahead of the code PRs:
an agent working alone verifies by running gates, not by being read.

| New | Old | Title |
|---|---|---|
| PR 0 | — | Freeze the prototype; build stamp; this document |
| PR 1 | "Step 1" | One audio path |
| PR 2 | PR 4 | Measurement harness |
| PR 3 | PR 1+2 + feature | Proposals, and the judge as a prompt |
| PR 4 | PR 3 | Two thresholds |
| PR 5 | PR 5 | Pronunciations and `voice/` |
| PR 6 | PR 6 | Span variants |
| PR 7 | PR 7 | Evidence for the judge |
| PR 8 | PR 8 | Learn from corrections |

PR 0 → PR 1 → PR 2 are strictly ordered. PR 3 depends on PR 2. PRs 4–8
depend on PR 3 and land in order.

---

## PR 0 — freeze the prototype; build stamp; this document

**Why.** F5. The prototype is currently *uncommitted* on
`feat/vocabulary-skills-only`; an uncommitted tree cannot be referenced from
a worktree and one `git checkout` can destroy it. And nothing today proves
the installed app is the code under test.

**Do.**
1. On `feat/vocabulary-skills-only`, commit everything (tracked and
   untracked experiment files) as one commit:
   `wip: vocabulary v2 prototype — reference only, do not build on this`.
   This is the last commit that branch ever receives.
2. In a worktree off `main`: add a build stamp. `scripts/build-app.sh`
   embeds `git rev-parse --short HEAD` plus a `-dirty` suffix into the
   bundle (Info.plist key or a generated Swift constant). The app prints it
   under `--version` and writes it as the first log line at startup.
3. Commit this document as `docs/proposals/vocabulary-v2.md`.

**Do not.** Change any behaviour. No vocabulary code in this PR.

**Verify.**
```
git log -1 --oneline feat/vocabulary-skills-only   # the wip commit
git status --porcelain                              # clean, on the PR branch
swift build -c release && make install
/Applications/ParrotFlowDev.app/Contents/MacOS/ParrotFlow --version
# must print the current short hash; "-dirty" only if the tree is dirty
head -5 ~/Library/Logs/ParrotFlow-Dev.log          # after a relaunch: stamp present
```

**Done when** the stamp round-trips and the prototype branch is frozen.

---

## PR 1 — one audio path (blocking)

**Why.** F12. Live and replay disagree by ~12 nats on the same clip. Until
they agree, no measurement describes the product.

**Do.** Log sample count, duration, and a checksum of the samples at the
point `Vocabulary.apply` receives them, on both paths: live through
`gated?.samples` in `Transcriber.swift`, replay through `Self.samples(at:)`.
Replay one archived clip, then compare against its live log line. Suspects,
in order: `closeLongPauses` retiming, then the speech gate. Fix what differs
until the checksums and scores agree on one clip, then spot-check two more.

**HUMAN.** One live dictation is needed to produce a fresh live log line.
Everything else replays.

**Verify.**
```
# replay a clip that has a live twin in the log
.build/ParrotFlowDev.app/Contents/MacOS/ParrotFlow --transcribe <clip.wav>
grep "vocabulary samples:" ~/Library/Logs/ParrotFlow-Dev.log | tail -2
# same count, same duration, same checksum, and spotter scores within noise (<0.5 nats)
```

**Done when** three clips agree live-vs-replay. Record the residual delta in
the PR. **No PR after this one merges on a measurement until this is done.**

---

## PR 2 — measurement harness

**Why.** F7, F11, F13. PRs 3–8 are judgement calls about reach; none should
merge on an argument when a number is available. The harness must itself be
debugged — it produced two believed-then-retracted numbers (F6's +3/24, F7's
23/28).

**Do.** Port from the prototype branch into `scripts/` and `tests/`:
`menu-recall.py`, `mine-menu-cases.py`, `tune-judge.py`, `before-after.py`,
`rerank-judge.py`, `tests/menu-cases.yaml`, `tests/judge-menus.json`. Keep
every F13 fix they already contain. Then fix what the review found:

1. `rerank-judge.py --stage2`: present the shortlist in the app's menu
   order (decoder's reading first), and trim the score block to lines whose
   two spellings still tell two shortlist options apart. (F7; measured
   23→25/28.)
2. `rerank-judge.py`: `--framing all` + `--stage2` must use the *best*
   framing by top-3, or refuse the combination. Today it silently uses the
   last one alphabetically. (F7.)
3. `tune-judge.py`: add `--strip-sentinels` to drop score lines with a 0.00
   heard score, so the F6 effect stays measurable until PR 3 removes the
   sentinel at the source.
4. `mine-menu-cases.py`: add `--random N` to sample clips with no trigger
   filter, and print a warning in the generated header that `said:` is
   pre-filled with the app's output and must be corrected by hand. (F11.)
5. Fix the corrupted `approve` legend line in `tests/judge-cases.yaml` (F9).
6. Report chance in every table that ranks (F13).
7. `menu-recall.py` and `before-after.py`: add `--runs N`, default 1. It
   replays each clip N times, keeps the per-clip majority, and reports how
   many clips changed outcome between runs (F12a).

**Measurement noise.** F12a: replaying the same clip gives scores up to ~5
nats apart, so one replay is not a measurement. Any gate quoted from
`menu-recall.py` or `before-after.py` must come with the flip count from
`--runs 3` when the number is within 2 cases of the baseline it is compared
with. A single-run number inside that band decides nothing.

**HUMAN.** Labels for any newly mined cases.

**Verify.**
```
python3 scripts/menu-recall.py            # runs; recall 30/37, picked 27/37 against the frozen prototype build only —
                                          # against plain main these numbers do not apply; record what you measure
python3 scripts/tune-judge.py             # 24/28 on the committed cache
python3 scripts/tune-judge.py --strip-sentinels    # 26/28
.venv-rerank/bin/python scripts/rerank-judge.py --model mixedbread-ai/mxbai-rerank-base-v2 --framing misheard --stage2 3
                                          # ceiling 28/28, picked 25/28 (was 23 before the fixes)
.venv-rerank/bin/python scripts/rerank-judge.py --framing all --stage2 3   # refuses, or states which framing it shortlists with
```

**Done when** those five numbers reproduce and the scripts live on `main`.
Test-only: no app behaviour changes.

---

## PR 3 — proposals, and the judge as a prompt

**Done, 2026-08-08.** Measured against a scratch config naming the new stage,
`gemma4:e4b`, nothing else loaded: recall 31/37, picked 27/37, no clip flipped
over three runs; `before-after.py --runs 3` 17 fixed / 9 broken / 1 regressed,
no clip flipped; `tune-judge.py` 21/25 on a freshly harvested cache of 31 menus
(chance 7.3/25); `grep -c '" 0\.00' tests/judge-menus.json` is 0.

A harvest is itself a replay. Two harvests of the same binary differ on two
clips — `17-38-44` 3→6 options, `17-39-27` 6→3 — and the other one scored
22/26. Read `menu-recall.py --runs 3` for reach; the cache is for A/B-ing
prompts against a menu that does not move.

The one REGRESSED row is `17-47-45`, and it is a judge error rather than a
mechanism one: the menu held the true sentence and the model took
"instead we want to have a Arexvy." over "a retry.". `retry` and `Arexvy` are
0.46 apart and the audio prefers `retry` by 0.25 nats, so the proposal is
correct at a 0.50 offer floor and the sentence is the only thing that can
refuse it. That floor is PR 4's, and the prompt that reads the sentence is
PR 7's. Recorded here rather than tuned.

Where the build differs from the text below:

- **The judge asks through `LocalLLM.complete`**, which is `/api/generate` with
  a system and a user message. `menu.py` used `/api/chat`, and so do the
  harness scripts. Ollama applies the same chat template either way; the two
  agree on these menus (23/26 through the harness, 28/31 of the recalled menus
  through the app).
- **`restorePunctuation` is gone.** It was a pass over the finished string, and
  a pass that moves characters invalidates every position `apply` has just
  worked out. The trailing marks of a replaced word are carried during the
  rebuild instead, which is the same rule applied in the one place that knows
  where things are.
- **The F10 check is a refusal, not a warning.** It sits in
  `Pipeline.validate()` beside `fuzzy` before `replacements`, which is the same
  class of mistake, so `--check-config` refuses it. `replacements` above
  `vocabulary:` is explicitly allowed — the judge offers a rule's substitution
  back and needs the rules to have fired.
- **A proposal whose span moved is re-anchored, not dropped.** With
  `replacements` above it, a vocabulary rule shifts the text under every span
  measured after it. The stage tries the recorded offset first and falls back
  to the nearest word-boundary occurrence of the same words, per span rather
  than per proposal — two readings of one span (`Praisy` and `Praisy's` over
  "praise") must land on top of each other. Claiming them separately cost three
  cases of recall before it was fixed.
- **`menu.py` was never on `main`,** so retiring it was nothing to delete. The
  prompt moved from `examples/transforms/verify_names/menu.md` to
  `examples/prompts/verify_names.md`; `tune-judge.py` and `rerank-judge.py`
  follow it.
- **A rule only offers back the words it actually rewrote.** `replacements`
  publishes no positions, so the transcript as the acoustic pass returned it is
  used to tell a rule's substitution from a term the decoder had already
  written. Without it, an already-correct term got a slot whose *head* reading
  was the rule's source spelling — a fabricated "what the decoder wrote", in
  the position the model agrees with most readily. This narrows the documented
  limitation rather than removing it: two rules writing one term into one
  sentence still cannot be told apart, and then nothing is offered.
- **Pronunciations are not ported.** Registering a `heard:` rendering as a
  `CustomVocabularyTerm` is PR 5, so the spotter here searches for the terms
  only. That is why `Versailles` still reaches `Vercel` at −5.28 rather than
  −2.28.

**Why.** F2, F3, F5, F6, F9, F10. The spine. Two ideas in one PR because
they share an interface: the pass proposes instead of writing, and the
judge's machinery is a native stage so the proposals never cross a process
boundary. The prototype proved the behaviour; its JSON/nth hand-off to
`menu.py` is where four of its bugs live, and this PR deletes that hand-off
instead of porting it.

**What the user owns afterwards:** one prompt file
(`transforms/verify_names/verify_names.md`), with `{terms}` in it. What the
app owns: everything mechanical.

**Do.**

1. `Vocabulary.apply` returns `Outcome` with `[Proposal]`. A `Proposal`
   carries: `heard`, `term`, its **range in the returned text** (kept
   native — no `nth`, no JSON), `heardScore: Float?`, `termScore: Float?`,
   `bonus: Float?`, `applied: Bool`. Scores are optional; a spotter-only
   hit has no `heardScore`, and absent means absent (F6).
2. The router, ported from the prototype's `autoApplies` with its comments:
   auto-apply a split compound whose glued letters equal the term; otherwise
   the term must win on **raw** score (bonus subtracted; keep token counts
   from `prepare`) and the decoded word must not be a real word
   (`Replacements.isRealWord`, with the acronym and split-compound
   exceptions). Drop when the audio contradicts by more than the proposal
   margin. Everything else is proposed, never written.
3. The acoustic search (spotter detections → word spans), the wider-span
   variants, and the possessive carry: port from the prototype's `apply`,
   fixing F9 as you go — word-boundary matching, `inflected()` length
   accounted for wherever positions shift, no per-spelling counters.
4. A native pipeline stage, `vocabulary:`, configured with a prompt file
   path. It: gathers unapplied proposals plus `replacements` rule
   substitutions (rules found by term search, the documented least-resistance
   limitation — two rules writing one term into one sentence cannot be told
   apart, which is survivable because a rule fires on an exact spelling);
   builds slots and readings (port `slots()` and `readings()` from the
   prototype's `menu.py`: overlap grouping, widest-first ranking, per-slot
   cap, trim to the readings cap, decoder's reading first); fills the prompt
   (`{terms}`; menu and score block in the user message — a proposal without
   scores contributes **no** score line); asks the model (temperature 0, few
   tokens); parses the letter; rebuilds the sentence from segments;
   publishes `asked`, `slots`, `kept_as_decoded`, `judged`, and the
   `PARROTFLOW_JUDGE_DUMP` file in the exact format the harness already
   parses (`SYSTEM `, `MENU X. `, `SCORES ` lines). Fails closed: on any
   error the text ships as decoded and the reason is logged.
5. Knobs are optional stage params with defaults, not env vars:

   ```yaml
   - vocabulary: verify_names.md
     when: vocabulary.count > 0
     max_slots: 4        # optional; skip and log past this many slots
     max_readings: 16    # optional; trim the menu to this
     max_per_slot: 3     # optional; readings per slot, decoder's included
   ```

6. The app warns at config load when `vocabulary:` is placed after a stage
   that edits text (F10). Recommended order: `replacements`, then
   `vocabulary:`, then the rest.
7. Config: the pipeline entry `- vocabulary: verify_names.md` replaces
   `- transform: verify_names`, and the `verify_names` entry leaves the
   `transforms:` list. `command:` transforms stay legal as the escape hatch.
   `vocabulary.proposals` may still be published as a var for logging, but
   nothing mechanical reads it.
8. Migration: install the prompt file; `menu.py` is retired — it is not
   installed, not shipped, and exists only on the frozen prototype branch.

**Do not.** Do not port `occurrence()`, `proposalsJSON`, or menu.py's
`acoustic_slots` position search — they are the deleted interface (the rule
term search from `rule_slots` is the one part that survives, in Swift). Do
not let the stage rescue FluidAudio's own path (`rescorerConfig` opt-outs
stay as the prototype set them).

**Verify.** The live config still names the old transform, so the harness has
to be pointed at a config that names the new stage. `PARROTFLOW_CONFIG_DIR` is
the seam, and the scripts pass the environment through to the app:

```
swift build -c release && scripts/build-app.sh
.build/ParrotFlowDev.app/Contents/MacOS/ParrotFlow --version   # current hash

# a scratch config: the live config.yaml and vocabulary.yaml, with the
# pipeline entry replaced by `- vocabulary: verify_names.md` and the prompt
# file copied in beside it
export PARROTFLOW_CONFIG_DIR=/tmp/pf-scratch

python3 scripts/tune-judge.py --harvest    # re-harvest against this binary
grep -c '" 0\.00' tests/judge-menus.json   # 0 — the sentinel is gone at the source (F6)
python3 scripts/tune-judge.py              # record; the cache changed, so record rather than compare
python3 scripts/menu-recall.py --runs 3    # gate: recall ≥ 30/37, picked ≥ 27/37, report flips
python3 scripts/before-after.py --runs 3   # gate: no new REGRESSED rows
```

**HUMAN.** Re-dictate the standing regression sentences (below) on the new
build, once, and paste the log lines into the PR. This is the first time the
router meets them (F5): the prototype predicts `update→Supabase` arrives as
a near-tie **proposal**, not an auto-apply.

**Done when** the gates hold, the sentinel grep is zero, and a dictation
with the judge unreachable (Ollama stopped) ships the decoded text with a
logged reason.

---

## PR 4 — two thresholds

**Why.** F1. Offering a reading and writing one are different risks.

**Do.** Replace the per-term floor with two file-level numbers:
`offer_below` (~0.50) and `decide_above` (~3.0 nats of raw margin), read in
`Config.swift`. Migrate on read: an old `floor:` maps to `offer_below`, and
`--check-config` warns. Keep the decoder fix that reads numbers before
booleans (Yams decodes `0.85` as a Bool happily) — it is in the prototype's
`Config.swift` diff. Note from F5's sentences: 0.50 may be too permissive
for the spelling path even as a proposal floor; do not tune it in this PR,
expose it and measure in PR 7.

**Verify.**
```
swift build -c release && make install
/Applications/ParrotFlowDev.app/... --check-config   # old floor: warns, file still loads
python3 scripts/menu-recall.py                       # gates hold
python3 scripts/before-after.py                      # no new REGRESSED
```

Plus a config unit: a `vocabulary.yaml` with `floor: 0.85`, `floor: off`,
and no floor at all — all three load, first maps to `offer_below`.

---

## PR 5 — pronunciations and `voice/`

**Why.** The acoustic path reaches what spelling cannot (`Versailles` is
0.40 from `Vercel`; the spotter finds it at −2.28, and searching for the
*sound of the rendering* improved the hit from −5.28 to −2.28, separating
the two Versailles in one sentence by about a nat). A rule cannot tell them
apart at all.

**Do.** The schema and layout: `pronunciations:` replaces `heard:` (an old
`heard:` list reads as `from: legacy`); each entry records `heard`, `seen`,
`from` (correction / mined / calibration). `Vocabulary.prepare` tokenises
each entry and registers it as an extra `CustomVocabularyTerm` carrying the
term's name and the rendering's CTC token ids, `minSimilarity` past 1 so the
rescorer never double-counts it — the spotter ignores `minSimilarity`, which
is the whole trick. Fix two F9 items here: compute the cbw from the **true
term count**, not `context.terms.count` inflated by pronunciation entries;
and log (or lift) the silent `name.count >= 5` skip. New `VoiceStore.swift`
owns `~/.config/parrotflow/voice/` (`observations.jsonl` append-only,
`calibration.yaml`, `samples/`). `--forget <term>` drops a term's
pronunciations, observations and samples in one go. Move
`tests/pronunciations.yaml` and `tests/acoustic/` content into `voice/` —
they are this speaker's voice sitting in a git repo; the harness reads them
from `voice/`. In `mine-pronunciations.py`, move the word dump above the
early guards so clips where nothing fired still contribute (F11).

**Verify.**
```
swift build -c release && make install
# a vocabulary.yaml with an old heard: list loads; log says "N pronunciation(s)"
python3 scripts/menu-recall.py       # gate: recall must not fall; expect it to rise on Versailles-class clips
python3 scripts/before-after.py      # gate: no new REGRESSED
# cbw check: add 10 pronunciations to one term; the logged bonus for an unrelated term must not change
./ParrotFlow --forget Praisy         # entries, observations and samples gone; --check-config clean
```

---

## PR 6 — span variants

**Why.** Names arrive split ("praise he"), possessed ("Mirza's"), and
punctuated ("Versailles."). Every reading built from the shorter span
strands a word.

**Do.** Port the prototype's wider-span generation: span, span+1, span+2
words × term, term+`'s`, each pair tested independently ("praise his" is
0.45 from `Praisy` and 0.59 from `Praisy's`); carry a trailing possessive
through a substitution; trim trailing punctuation from a span before
replacing; rank widest first, possessive as tiebreak. Cap readings per term
at 2–3. Justify the cap by menu readability — the two-stage number that was
going to justify it was F7's artefact; with the harness fixed you may
re-measure, but do not resize the menu on the old number.

**Verify.** Gates as in PR 3, plus these clips end-to-end in
`menu-recall.py` output: the "praise he / praise his" clips must offer the
wide reading; "Mirza's" must keep its possessive; "Versailles." must keep
its full stop.

**Landed (PR #66, 2026-08-08) — mostly by PR 3, which this plan told it to
do.** PR 3's own `Do` list says "the acoustic search, the wider-span
variants, and the possessive carry: port from the prototype's `apply`" and
"widest-first ranking, per-slot cap". So four of the five items here were
already on `main` before PR 6 started, and the three named clips already
behaved. Where each lives:

| Item | Where | Note |
|---|---|---|
| span, span+1, span+2 × term, term+`'s`, tested independently | `Vocabulary.widerSpans` | Same as the prototype, plus PR 3's guard that refuses a possessive at a sentence end |
| possessive carried through a substitution | `Vocabulary.inflected` | `Mirza's` stays `Mirza's` |
| trailing punctuation trimmed before replacing | `Vocabulary.trailingMarks`, and the trim at the end of `acousticSpans` | `Versailles.` keeps its full stop |
| widest first, possessive as tiebreak | `VocabularyJudge.slots` | Identical ranking to `menu.py` line 237 |
| cap readings per term | `Caps.perSlot` bounds one **place**; nothing bounded a **term** | The gap PR #66 filled |

So PR 6 shipped the missing cap, `max_per_term`, applied in
`VocabularyJudge.slots` where the four sources of a reading meet — a rule,
the rescorer, a wider span and the spotter. Justified by readability, not by
F7: `perSlot`'s doc comment now says so out loud, and `readings` admits it
was never measured.

Swept on `menu-recall.py`, one run each, everything else at the shipped
settings:

| `max_per_term` | recall | picked |
|---|---|---|
| 1 | 28/37 | 24/37 |
| **2** | **31/37** | **27/37** |
| 3 | 31/37 | 27/37 |
| 99 (off) | 31/37 | 27/37 |

2 is the tight end of the plateau, which is the end to take for a cap whose
job is headroom. The spotter floor was **not** moved.

Also here: the judge logs its slot count on every run, so the distance to
`max_slots` can be measured rather than reconstructed from the clips that
broke. On the 40 clips: 0 slots ×5, 1 ×17, 2 ×14, 3 ×3, 6 ×1. The one over
the cap is `17-39-40`, which `max_per_term: 2` takes from 6 slots to 5 —
still declined, and the anatomy is in PR #66. Its three surviving spotter
slots are "went to the" → `Matthieu`, "universal" → `Vercel` and "deployed
on" → `Claude`, none of which is a name anybody said. That is PR 7's
evidence problem, not a span one.

---

## PR 7 — evidence for the judge

**Why.** F4, F6, F8. The judge is the weakest link; the one lever that
measured is cleaner evidence. With the sentinel gone at the source (PR 3),
re-measure what the block is worth — the earlier +3/24 was measured on
corrupted blocks, and the review measured full 24/28 vs stripped 26/28 vs
none 25/28 on the old cache.

**Do.** The score block with the difference precomputed (small models are
unreliable at arithmetic on negatives) in the user message; the scale in the
system message. Two measured follow-ups, each an A/B with
`tune-judge.py`:
1. The prose scale ("gap under ~1 … over ~4") versus a fitted λ from F14's
   fusion plateau, once PR 1 makes the margins trustworthy.
2. The pro-term prior sentence in the prompt ("a spelling that looks like a
   garbled version of a vocabulary term usually is one") — it won an earlier
   bake-off scored on menus where the term usually *was* right; F5's three
   sentences are the case it gets wrong. Ablate it against a cache that
   contains those sentences.

**Verify.** `tune-judge.py --harvest` then A/B each change on the fresh
cache; keep a change only when it does not lose a case class (report per-case
diffs, not just the total). Gates as in PR 3.

**Do not** conclude anything from `gemma4:12b` runs; F8 measured it at
17/28. Do not spend the two-stage reranker here yet — with the F7 fixes it
reached parity (25/28 vs 24/28); it becomes interesting only for its margins
("too close, ask the user"), which is a separate proposal.

---

## PR 8 — learn from corrections

**Why.** The table must grow without anyone writing YAML, and the header of
`vocabulary.yaml` already (falsely, today) claims it does.

**Do.** A correction appends to `voice/observations.jsonl`, cuts the span
into `voice/samples/<Term>/`, and promotes the rendering into
`vocabulary.yaml` with `from: correction` and `seen:` counts. Ship a per-term
cap and a rule for dropping entries never confirmed (a pronunciation seen
once and never again is noise; `seen:` makes that decidable). Note
`ConfigWriter.addReplacement` writes text rules to `config.yaml` today; this
PR points corrections at the vocabulary instead.

**Verify.** Gates as in PR 3, plus: simulate a correction (unit level),
check the three files; exceed the cap, check the oldest unconfirmed entry is
the one dropped; `--forget` still removes everything.

---

## Standing regression sentences

Dictate end-to-end after any PR that touches the router, the judge, or the
thresholds. The correct output is the ordinary word every time for the first
three. HUMAN — these need a voice.

1. "in general in our data set" — must not become Redcrawl
2. "you don't need to update the design" — must not become Supabase
3. "the bedrock of civilization" — must not become Redrock
4. "Let's praise Praisy's work"
5. "deployed on Vercel against the Versailles Castle", one sentence
6. "Matthieu's work"

These six belong in `tests/menu-cases.yaml` with their clips as soon as the
clips exist (PR 3's HUMAN step records them).

## Open questions, deliberately not settled here

- A "too close, ask the user" path on the reranker's margins (F14) — worth
  a proposal of its own after PR 7.
