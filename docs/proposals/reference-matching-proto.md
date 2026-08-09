# Reference matching, wired into the real pass

**Throwaway prototype. Branch `proto/reference-matching`, behind
`PARROTFLOW_REFERENCE_MATCH=1`, off by default. Not a design, not a PR.**

**It works.** Over the 141 labelled clips the filter takes losses from 19 to 4
and wins from 27 to 32. Against today's pass it fixes 20 clips and breaks
none. The verdict costs about 1 ms per proposal.

The filter can only remove a proposal. It adds nothing, promotes nothing, and
never touches a decision the pass did not already make.

## The question

Every one of the pass's 19 losses is an *overwrite* — a vocabulary term
written over a word the speaker actually said. An overwrite is a claim about
sound, and nothing in the pass checks it against sound the speaker made. This
prototype checks it: cut the audio under each proposal, measure how far it
sits from this speaker's own recordings of the term in
`voice/samples/<Term>/`, and drop the proposal when it is too far.

## The three arms

141 clips, `--runs 3`, majority of three replays, `gemma4:e4b-mlx` and nothing
else loaded. Measured with `scripts/reference-ablation.py` against
`tests/menu-cases.yaml`, from `.build/`, on a scratch `PARROTFLOW_CONFIG_DIR`.
Nothing was installed.

| arm | correct | wins | losses | net | flips |
|---|---|---|---|---|---|
| vocabulary off | 76 | — | — | — | 0 |
| today | 84 | 27 | 19 | +8 | 8 |
| today + rejection filter | **104** | **32** | **4** | **+28** | 2 |

`wins` and `losses` are against the vocabulary-off arm, which is how
`scripts/vocab-ablation.py` defines them. `correct` is the clips whose
majority transcript matches the label, which the other columns do not show:
the filter is 20 clips ahead of today and 28 ahead of off.

The brief's baseline was 28 wins and 19 losses. This run reproduces 27 and 19.
One win of difference is replay noise — today's arm flipped on 8 clips.

Against today's pass directly:

| | wins | losses |
|---|---|---|
| today → filtered | 20 | 0 |

Split by class, filtered against off:

| class | clips | off correct | today correct | filtered correct |
|---|---|---|---|---|
| about a term | 68 | 20 | 37 | 50 |
| controls | 73 | 56 | 47 | 54 |

The controls are where the pass costs today: it turns 9 of them wrong and wins
none. The filter gives 7 of those 9 back and takes nothing.

## It is not switching the feature off

The obvious failure would be a filter that removes everything and reports the
off arm's score. Three things say it is not.

**The score is higher than either arm it sits between.** Off scores 76 and
today scores 84. Switching the acoustic pass off cannot reach 104.

**One sentence keeps the right term and loses the wrong one.**

```
said      Supabase is where the crawl data lives and Vercel hosts the dashboard.
off       Superbase is where the crawl data lives and Versal hosts the dashboard.
today     Supabase is where the Redcrawl data lives and Vercel hosts the dashboard.
filtered  Supabase is where the crawl data lives and Vercel hosts the dashboard.
```

`Supabase` and `Vercel` survive; `Redcrawl` over "crawl" does not. The same
happens on `07T17-39-40`, where the filter keeps `Vercel` at the end of the
sentence and puts `Versailles Castle` back at the front — today's pass writes
"Vercel Castle".

**PLACEHOLDER-CONTROL**

## The veto breakdown

At the shipped tolerance, over the `on` arm's 252 distinct proposals:

| | |
|---|---|
| proposals measured | 252 |
| proposals vetoed | 97 |
| clips carrying a veto | 51 |
| vetoes on clips the pass was losing | 32 |
| vetoes on clips the pass was winning | 20 |
| vetoes on clips that were neither | 45 |

Twenty vetoes land on win clips and **none of them costs the win**. A win clip
carries several proposals — the term the pass got right and the terms it fired
spuriously in the same sentence — and the veto removes the second kind. That
is the second thing the filter does, and it is why wins go up rather than
merely holding: a menu with fewer wrong readings on it is a menu the judge
gets right more often.

By clip, out of the 51 with a veto: 15 losses undone, 4 clips fixed that were
wrong in both arms, 32 unchanged, 0 broken.

## The four losses that survive

| clip | said | filtered |
|---|---|---|
| `07T16-12-20` | So the acoustic pass found praise. | …found **Praisy**. |
| `07T13-09-46` | The team deserves praise for shipping that fast. | …deserves **Praisy** shipping… |
| `08T16-19-02` | They deserve praise for shipping. | …deserve **Praisy's** shipping. |
| `06T14-04-21` | (long clip, partly recovered) | one term still written |

Three of the four are the same collision. This speaker says `Praisy` as
"praise", and six of the 26 recordings in `voice/samples/Praisy/` are the word
"praise". So the ordinary word and the term are the same sound, and no
measurement of sound can separate them. **Reference matching cannot fix these
and never will.** They need the sentence, which is the judge's job.

## The threshold rule

The rule, in one sentence: **a term's recordings sit some distance from each
other; reject a span that sits more than `tolerance` times that distance from
the nearest of them.**

Concretely, per proposal:

1. cut the span with 0.05 s of padding each side, the same cut
   `scripts/mine-pronunciations.py` makes;
2. `d` = the DTW distance over MFCCs from the span to the nearest recording of
   the term;
3. `spread` = the largest leave-one-out nearest-neighbour distance among that
   term's own recordings — the width of the cloud;
4. reject when `d > tolerance × spread`.

`ReferenceMatch.tolerance` is the one constant, `PARROTFLOW_REFERENCE_TOL`
overrides it, and the measured value is **1.00**.

**Why per term.** Round 7 found the distance scale differs per term —
`Matthieu`'s entire true range sat above `Praisy`'s entire false range — so no
single global number can separate both. Normalising is worth about 0.05 AUC
here: separating the decisive proposal on a loss clip from the decisive
proposal on a win clip scores 0.815 with the normalisation and 0.768 without.

**Why the largest and not some other summary.** Nine ways of turning the
term's spread into one number were swept offline, on the same spans:

| rule | AUC |
|---|---|
| `d / max leave-one-out nearest` (shipped) | 0.815 |
| `d / q3 leave-one-out nearest` | 0.813 |
| `d / mean leave-one-out nearest` | 0.813 |
| `d / median of every pair` | 0.827 |
| `d / q1 of every pair` | 0.825 |
| `d − max leave-one-out nearest` | 0.813 |
| `d / median leave-one-out nearest` | 0.767 |
| `d`, no normalisation | 0.768 |

Everything except the two medians lands within 0.015 of everything else. The
largest leave-one-out distance is kept because it is the one the rule can be
stated in words — "farther than the term's recordings ever are from each
other" — and nothing measurably better was found.

**Why 1.00.** It is the literal reading of the rule, and it is also where the
measurement lands. Four tolerances were run end to end:

| tolerance | correct | wins | losses |
|---|---|---|---|
| 1.00 | 104 | 32 | 4 |
| 1.02 | 99 | 32 | 9 |
| 1.05 | 96 | 32 | 12 |
| 1.10 | 90 | 30 | 16 |

PLACEHOLDER-LOWER

**The minimum.** A term with fewer than **three** usable recordings does not
get to reject anything; the filter abstains. Round 7 scored `Matthieu` at
chance on two recordings, and two recordings give exactly one
exemplar-to-exemplar distance, so there is no spread to compare against. All
eleven terms clear it today: the smallest folder is `Claude` with 6 and the
largest is `Praisy` with 26, 122 recordings in total.

## Latency

The verdict is cheap. Measured from `PARROTFLOW_REFERENCE_DUMP` over 997
proposals in 433 replays.

| | n | median | p90 | max |
|---|---|---|---|---|
| first proposal of a term | 561 | 6.7 ms | 25.6 ms | 64.3 ms |
| every proposal after that | 436 | 1.1 ms | 2.0 ms | 24.0 ms |
| the whole filter, per dictation | 433 | 10.0 ms | 29.0 ms | 64.3 ms |

The first number is a one-off. It reads a term's recordings, computes their
MFCCs and measures every pair — 6 ms for `Arexvy` at 7 recordings, 24 ms for
`Praisy` at 26. In the harness every replay is a fresh process so every replay
pays it. **In the running app it is paid once per launch**, so a real
dictation costs the second row: about 1 ms per proposal, a few milliseconds in
total. Against a pass that already spends about 1.5 s on a warm model call,
this is not measurable.

## How it is wired

The veto sits inside `Vocabulary.apply`, where the audio and the token timings
still line up with the words. For each proposal it takes the span's seconds
from the decoder's own word timings, cuts those samples, and asks
`ReferenceMatch.verdict`.

It is asked **before** `autoApplies`, not after. A proposal the pass writes
without asking anybody is exactly what this exists to catch, and a filter that
only pruned the menu would leave every auto-applied overwrite standing. A
vetoed proposal takes the existing `dropped` path — neither written nor
offered — so no new state was added to the pass.

`ReferenceMatch` is a port of `scripts/reference-matching.py` from
`origin/spike/reference-matching`: 26 mel filters, 512-point FFT through
vDSP, 12 cepstra with c0 dropped, mean and variance normalised, DTW with a
symmetric step pattern and the diagonal weighted 2. **The port is exact.**
`--reference-selftest <Term>` prints every distance between a term's
recordings, and against the numpy original the largest difference over 346
pairs on two terms is 1e-6.

## What would have to change before this is real code

**The recordings were mined from this same corpus.** 49 of the 145 clips in
`tests/menu-cases.yaml` are the source of a recording in `voice/samples/`. The
filter holds out any recording cut from the clip it is judging — that is what
`VoiceStore.Observation.wav` is read for — but it cannot hold out the fact
that the archive was mined from this corpus and describes it well. **The
number to trust is smaller than 104 and nobody knows by how much.** A held-out
corpus is the first thing to measure.

**The constant was picked on the clips it is reported on.** 1.00 is defensible
without the data — it is the rule stated literally — but it was confirmed by
sweeping on the same 141 clips. There is no held-out set here either.

**Live dictation holds nothing out.** `clip` is nil when there is no file, so
a recording mined from the dictation currently being transcribed would be
compared against itself. It cannot happen today, because PR 8 does not write
on a correction yet, but it will the moment it does.

**A term whose rendering is an ordinary word is out of reach.** `Praisy` is
"praise" in this mouth. The filter cannot help, and three of its four
remaining losses are that. Whatever ships needs to know which terms those are
and not pretend otherwise.

**The filter runs on every proposal, including the ones about to be dropped.**
The pass already drops a proposal the audio argues against by `decide_above`.
Asking that one is wasted work. It costs a millisecond, so it did not matter
here.

**The `dropped` log line lies about a vetoed proposal.** It says "audio
prefers what was written by …" with a margin nobody computed. The `reference:`
line above it says the truth. Two log lines for one decision is a prototype
tell.

**No tests, no config, no migration.** `PARROTFLOW_REFERENCE_MATCH` and
`PARROTFLOW_REFERENCE_TOL` are environment variables because this is a
prototype. A real version needs the tolerance in `vocabulary.yaml`, next to
`decide_above`, and it needs the case set that says what happens when
`voice/samples/` is empty.

## How to reproduce

```sh
make app                                   # never `make install`

python3 scripts/reference-ablation.py --runs 3 --out /tmp/arms.json \
  --arm "off=/tmp/cfg-off" \
  --arm "on=/tmp/cfg-on" \
  --arm "filtered=/tmp/cfg-on,PARROTFLOW_REFERENCE_MATCH=1,PARROTFLOW_REFERENCE_TOL=1.00"
```

`cfg-on` is a copy of `~/.config/parrotflow-dev` with `audio.output_dir`
pointed somewhere scratch. `cfg-off` is the same with `terms: {}` in
`vocabulary.yaml`, which is the honest off arm — `--no-vocab` only disables
the acoustic third of a three-part pass.

`PARROTFLOW_REFERENCE_DUMP=<file>` measures every proposal without vetoing
anything, which is how the tolerance was swept.
