# Reference matching, wired into the real pass

**Throwaway prototype. Branch `proto/reference-matching`, behind
`PARROTFLOW_REFERENCE_MATCH=1`, off by default. Not a design, not a PR.**

**The damage drops. Reference matching is not what drops it.**

Wiring the filter in takes losses from 19 to 4 and wins from 27 to 32 over the
141 labelled clips. That reads like a result. It is not: **throwing every
acoustic proposal away without measuring anything takes losses to 0 and keeps
27 wins.** Head to head the tuned filter beats the blind one by one clip, which
is noise.

The finding underneath is bigger than the filter. **On this corpus the acoustic
proposal path buys no wins that the `heard:` replacement tables do not already
deliver, and it costs 19 losses.**

## The question

Every one of the pass's 19 losses is an *overwrite* — a vocabulary term
written over a word the speaker actually said. An overwrite is a claim about
sound, and nothing in the pass checks it against sound the speaker made. This
prototype checks it: cut the audio under each proposal, measure how far it
sits from this speaker's own recordings of the term in
`voice/samples/<Term>/`, and drop the proposal when it is too far.

## The arms

141 clips, `--runs 3`, majority of three replays, `gemma4:e4b-mlx` and nothing
else loaded. Measured with `scripts/reference-ablation.py` against
`tests/menu-cases.yaml`, from `.build/`, on a scratch `PARROTFLOW_CONFIG_DIR`.
Nothing was installed.

| arm | correct | wins | losses | net | flips |
|---|---|---|---|---|---|
| vocabulary off | 76 | — | — | — | 0 |
| today | 84 | 27 | 19 | +8 | 8 |
| today + rejection filter | 104 | 32 | 4 | +28 | 2 |
| **control: veto every proposal** | **103** | **27** | **0** | **+27** | 0 |

`wins` and `losses` are against the vocabulary-off arm, the way
`scripts/vocab-ablation.py` defines them. `correct` is how many clips'
majority transcript matches the label.

The brief's baseline was 28 wins and 19 losses. This run reproduces 27 and 19.
One win of difference is replay noise — today's arm flipped on 8 clips.

**The control is the whole story.** It sets the tolerance to 0.01, so every
proposal is rejected whatever the audio says; measured directly, 11 of 11
verdicts on three clips come back `reject`. It is the acoustic proposal path
switched off, with the `heard:` replacement tables left running. It scores 103.
The filter that measures scores 104.

Head to head:

| | wins | losses | net |
|---|---|---|---|
| veto-everything → tuned filter | 8 | 7 | +1 |

**Eight clips saved, seven clips lost.** The measurement is doing something —
it is not random — but what it does is trade one set of clips for another of
the same size.

Split by class:

| class | clips | off | today | filtered | veto-everything |
|---|---|---|---|---|---|
| about a term | 68 | 20 | 37 | 50 | 47 |
| controls | 73 | 56 | 47 | 54 | 56 |

The controls line is the clearest. The pass turns 9 controls wrong and wins
none of them. Vetoing everything gives all 9 back. The filter gives 7 back and
keeps 2 wrong.

## Where the eight and the seven are

Almost all of them are `Praisy`.

The filter keeps these, which vetoing everything loses:

```
said  Let's praise Praisy's work.
veto  Let's praise praise his work.
tuned Let's praise Praisy's work.

said  So the document was a really super base uh for discussion and the Supabase proposal…
veto  So the document was a really Supabase uh for discussion and the Supabase proposal…
tuned So the document was a really super base uh for discussion and the Supabase proposal…
```

The filter loses these, which vetoing everything keeps:

```
said  So let's praise the work that Praisy has done.
veto  So let's praise the work that Praisy has done.
tuned So let's Praisy's work that Praisy has done.

said  The team deserves praise for shipping that fast.
veto  The team deserves praise for shipping that fast.
tuned The team deserves Praisy shipping that fast.
```

This speaker says `Praisy` as "praise", and six of the 26 recordings in
`voice/samples/Praisy/` are the word "praise". **The term and the ordinary
word are the same sound**, so no measurement of sound can tell them apart. The
filter guesses, and it guesses about half right. Three of its four remaining
losses are exactly this.

## Does the measurement carry any signal at all?

Yes, and it is weak. Over the 252 distinct proposals the `on` arm made,
separating the decisive proposal on a loss clip from the decisive proposal on
a win clip scores **AUC 0.815** against a chance of 0.500. (The decisive
proposal is the one whose term appears in the on-transcript and not in the
off-transcript.) Without the per-term normalisation it is 0.768.

0.815 is real. It is also not enough. At the operating point that keeps every
win, the filter removes 97 of 252 proposals — 38% — and the 62% it leaves
still contain four losses.

## The veto breakdown

At tolerance 1.00, over the 252 proposals:

| | |
|---|---|
| proposals measured | 252 |
| proposals vetoed | 97 |
| clips carrying a veto | 51 |
| vetoes on clips the pass was losing | 32 |
| vetoes on clips the pass was winning | 20 |
| vetoes on clips that were neither | 45 |

By clip, of the 51: **15 losses undone, 4 clips fixed that were wrong in both
arms, 32 unchanged, 0 wins killed.** No win clip loses its win, because a win
clip carries several proposals and the veto removes the spurious ones. That is
also true of the blind control, which is the point.

## The threshold rule

The rule, in one sentence: **a term's recordings sit some distance from each
other; reject a span that sits more than `tolerance` times that distance from
the nearest of them.**

Per proposal:

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
single global number can separate both. Normalising is worth about 0.05 AUC.

**Why the largest and not another summary.** Nine ways of reducing the term's
spread to one number were swept offline on the same spans:

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

Everything except the two medians is within 0.015 of everything else. The
largest leave-one-out distance is kept because it is the one the rule can be
stated in words — "farther than the term's recordings ever are from each
other" — and nothing measurably better was found. **A 0.012 AUC difference is
not a reason to change a rule you cannot say out loud.**

**Why 1.00.** It is the literal reading of the rule, and it is where the
measurement lands. Seven tolerances were run end to end:

| tolerance | correct | wins | losses |
|---|---|---|---|
| 0.01 (veto everything) | 103 | 27 | 0 |
| 0.90 | 104 | 30 | 2 |
| 0.95 | 102 | 29 | 3 |
| 0.98 | 103 | 30 | 3 |
| **1.00** | **104** | **32** | **4** |
| 1.02 | 99 | 32 | 9 |
| 1.05 | 96 | 32 | 12 |
| 1.10 | 90 | 30 | 16 |

Everything from 0.01 to 1.00 scores 102–104. The curve is flat across two
orders of magnitude of tolerance and only falls once the filter stops removing
much. **That flatness is the same finding again**: the score does not depend on
how well the filter measures, only on how much it removes.

**The minimum.** A term with fewer than **three** usable recordings does not
get to reject anything; the filter abstains. Round 7 scored `Matthieu` at
chance on two recordings, and two recordings give one exemplar-to-exemplar
distance, so there is no spread. Nothing hits it today: the smallest folder is
`Claude` with 6 and the largest is `Praisy` with 26, 122 in total.

## Latency

The verdict is cheap. Measured from `PARROTFLOW_REFERENCE_DUMP` over 997
proposals in 433 replays.

| | n | median | p90 | max |
|---|---|---|---|---|
| first proposal of a term | 561 | 6.7 ms | 25.6 ms | 64.3 ms |
| every proposal after that | 436 | 1.1 ms | 2.0 ms | 24.0 ms |
| the whole filter, per dictation | 433 | 10.0 ms | 29.0 ms | 64.3 ms |

The first row is a one-off: reading a term's recordings, their MFCCs, and every
distance between them — 6 ms for `Arexvy` at 7 recordings, 24 ms for `Praisy`
at 26. In the harness every replay is a fresh process so every replay pays it.
**In the running app it is paid once per launch**, so a real dictation costs the
second row: about 1 ms per proposal, a few milliseconds in total. Against a
pass that already spends about 1.5 s on a warm model call, this is not
measurable. **Cost is not why this should not ship.**

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
`origin/spike/reference-matching`: 26 mel filters, a 512-point FFT through
vDSP, 12 cepstra with c0 dropped, mean and variance normalised, DTW with a
symmetric step pattern and the diagonal weighted 2. **The port is exact.**
`--reference-selftest <Term>` prints every distance between a term's
recordings; against the numpy original the largest difference over 346 pairs on
two terms is 1e-6.

## What the numbers suggest instead

**Measure turning the acoustic proposal path off and keeping `replacements`.**
That is the control arm, it scores 103 against today's 84, it costs nothing to
run, and nobody had measured it. It is a config change, not a feature. Every
one of today's 27 wins survives it, because they come from the `heard:` tables
rather than from the spotter.

**Then ask what the acoustic path is for.** It buys 5 wins over rules-only and
costs 4 losses, and all of them are `Praisy` — a term whose rendering is an
English word. If that is the only thing it earns, the question is whether one
term justifies the machinery, not whether the machinery can be filtered.

**A term whose rendering is an ordinary word needs a different mechanism.**
Sound cannot separate `Praisy` from "praise" in this mouth, and the judge is
already the only thing that can read the sentence. `docs/proposals/judge-framings.md`
measured that the shipped prompt gets 0 of 8 on exactly these. That is the open
problem, and reference matching does not touch it.

## What would have to change before this became real code

**The recordings were mined from this same corpus.** 49 of the 145 clips in
`tests/menu-cases.yaml` are the source of a recording in `voice/samples/`. The
filter holds out any recording cut from the clip it is judging — that is what
`VoiceStore.Observation.wav` is read for — but it cannot hold out the fact that
the archive was mined from this corpus and describes it well. **The real
numbers are worse than these and nobody knows by how much.**

**The constant was picked on the clips it is reported on.** No held-out set.

**Live dictation holds nothing out.** `clip` is nil when there is no file, so
a recording mined from the dictation being transcribed would be compared
against itself. It cannot happen today because PR 8 does not write on a
correction yet. It will the moment it does.

**The filter runs on proposals the pass is about to drop anyway.** `decide_above`
already drops a proposal the audio argues against. Asking that one is wasted
work. It costs a millisecond, so it did not matter here.

**The `dropped` log line lies about a vetoed proposal.** It says "audio prefers
what was written by …" with a margin nobody computed. The `reference:` line
above it says the truth. Two log lines for one decision is a prototype tell.

**No tests, no config, no migration.** `PARROTFLOW_REFERENCE_MATCH` and
`PARROTFLOW_REFERENCE_TOL` are environment variables because this is a
prototype. A real version would need the tolerance in `vocabulary.yaml` next to
`decide_above`, and a case set for what happens when `voice/samples/` is empty.

## How to reproduce

```sh
make app                                   # never `make install`

python3 scripts/reference-ablation.py --runs 3 --out /tmp/arms.json \
  --arm "off=/tmp/cfg-off" \
  --arm "on=/tmp/cfg-on" \
  --arm "filtered=/tmp/cfg-on,PARROTFLOW_REFERENCE_MATCH=1,PARROTFLOW_REFERENCE_TOL=1.00" \
  --arm "control=/tmp/cfg-on,PARROTFLOW_REFERENCE_MATCH=1,PARROTFLOW_REFERENCE_TOL=0.01"
```

`cfg-on` is a copy of `~/.config/parrotflow-dev` with `audio.output_dir`
pointed somewhere scratch. `cfg-off` is the same with `terms: {}` in
`vocabulary.yaml`, which is the honest off arm — `--no-vocab` only disables the
acoustic third of a three-part pass.

`PARROTFLOW_REFERENCE_DUMP=<file>` measures every proposal without vetoing
anything, which is how the tolerance was swept.

**Run the control arm.** Without it this reads as a win.
