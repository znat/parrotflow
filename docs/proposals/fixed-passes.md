# Proposal: `interpret` and `vocabulary` leave the pipeline

Status: **proposed, nothing built.** This is a shape to agree on before any
code moves.

**Goal.** `pipeline:` holds only the stages a person can genuinely order. The
two passes that read the decoder's own output become settings blocks and run
at a fixed point. A config can then no longer put them in the wrong place.

---

## 1. Why a list is the wrong home for these two

`Pipeline.swift` says what a stage is, at the top of the file: every stage is
`String -> String`, and the whole point of the list is that the order is data.

Neither of these two is `String -> String`.

| Pass | What else it reads | So it must run |
|---|---|---|
| `interpret` | The decoder's own words and their timings (`[Trace.Word]`). A rewrite above it moves a word and the pause gate lines up against the wrong token. | First. |
| `vocabulary` | Spans measured before the pipeline started. Any edit above it moves them — the bug that put the menu on the wrong `Versailles` (F3, F10). | Above everything that edits text. |

Neither constraint is a choice. Both are already written down in the code as
rules the config must not break:

- `Pipeline.vocabularyOrderProblems()` — one method whose only job is to
  refuse an order.
- `Stage.editsText` — one property, with the comment "only used to say where
  `vocabulary` belongs".
- `Stage.isAutomatic` — `vocabulary` excluded by hand.
- The `interpret` exception inside the order check, plus the paragraph
  explaining it.
- 12 of the 17 fields on `Pipeline.Step` are options only one of these two
  stages reads: `prompt`, `caps`, `nearMisses`, `bySound`, `gate`, `slotGate`,
  `portrait`, `lowercaseRefused`, `slotFloor`, `marks`, `capitals`, `pause`.
- `PipelineEntry.stageKeys` and `misplacedOptions` — a whole mechanism that
  exists to say "`slot_gate:` is an option on the `vocabulary` stage, it does
  nothing here".

None of that would exist if the two passes were not in the list.

The list also decides what gets downloaded. `PipelineCommand` gates a 320 MB
model on `.interpret` being in it, and `warmModels` gates 400 MB on
`gate_sentence:`. A block is a plainer switch for both.

**The rule to adopt.** A pipeline stage rewrites text and may go anywhere. A
pass that reads the decoder's output, or the machine, is fixed and takes a
settings block.

---

## 2. The new shape

`config.example.yaml`, in house comment style:

```yaml
transcription:
  insert_mode: paste
  languages: [en, fr]

  # What you meant, where the decoder wrote what it heard. A pause makes it
  # write a period or a question mark mid-sentence and capitalise the next
  # word; this reads each boundary and takes the mark out again. English only.
  # Runs before everything below — it reads the decoder's own timings, so it
  # cannot be moved.
  interpret:
    enabled: true
    # What a boundary may be written with. The enders in it — `.` and `?` —
    # are where a boundary is looked for; the rest is a reading tried at each
    # one. Left out, the built-in set for the language.
    # marks: [".", ",", "?"]
    # Read a capital with no mark in front of it as a boundary too.
    capitals: true
    # Seconds of silence a bare capital needs first. 0 reads every one.
    # pause: 0.35

  # Names from vocabulary.yaml, matched then settled against the sentence they
  # stand in. No model. Runs after `interpret` and before the pipeline: it is
  # handed spans measured on the transcript as the decoder wrote it, and any
  # edit moves them.
  vocabulary:
    enabled: true
    near_misses: true        # also match a rendering one edit away
    by_sound: true           # also match words that sound like a term
    gate: true               # the two word lists and the slot's part of speech
    slot_gate: true          # the mmBERT slot — false downloads nothing
    portrait: true           # a term's own sentences and its counter-examples
    lowercase_refused: true  # a refused glued span goes back in lowercase
    # slot_floor: {en: 0.20, fr: 0.30}
    # max_per_slot: 3
    # max_per_term: 2

  # What a transcript runs through, in order. Everything here rewrites text
  # and may be moved.
  pipeline:
    - numbers
    - transform: punctuation
    - transform: repetitions
```

### Key by key

| Written today | Written after |
|---|---|
| `- interpret` | `transcription.interpret.enabled: true` |
| `- stage: interpret` + `marks:` `capitals:` `pause:` | the same keys in the block |
| `- vocabulary`, `- stage: vocabulary` | `transcription.vocabulary.enabled: true` |
| `near_misses:` `by_sound:` `gate:` `slot_gate:` `portrait:` `lowercase_refused:` `slot_floor:` `max_per_slot:` `max_per_term:` | the same keys in the block |
| `- vocabulary: <prompt file>`, `review:` | already retired; keep saying so |

Nothing is renamed. Every option keeps the spelling it has, so a config is
migrated by moving lines, not by rewriting them.

---

## 3. What runs when

```
asr → vad → interpret → vocabulary → pipeline (numbers, transforms, …)
```

Both passes keep publishing into the scope, as `asr` and `vad` already do
without being stages. So `when: vocabulary.count > 0` and
`unless: interpret.count == 0` on a transform go on working, and
`--pipeline --vars` prints the same variables. That is what makes the move
lossless.

`context` and `input` stay stages. They do not edit text and nothing above
them can hurt them, so they are ordinary lines in the list.

### On and off

`enabled:` inside the block. The alternative is the repo's scalar-or-map
idiom — `vocabulary: false` to turn it off, a map to configure it, the way
`floor:` and `slot_floor:` already take two shapes. I recommend `enabled:`:
a fixture and a bench want to keep the block and flip one key, and with the
scalar spelling `vocabulary: false` would also delete the terms under it.

---

## 4. The other half: one home per thing

`vocabulary.yaml` already holds six settings above `terms:`. Adding a
`transcription.vocabulary:` block without moving them leaves the pass with two
homes.

Three of the six are live and should move: `sound_below`, `gate_sentence`,
`asks`. The other three are read and ignored already — `acoustic` and
`decide_above` went with the acoustic pass, and nothing outside `Config`
consumes `offer_below`, since `vocabularyTerms` has no caller left. Leave
those where they are, with the notice they already get.

The split is wrong for a second reason. The file header says **DO NOT EDIT
UNLESS YOU REALLY KNOW WHAT YOU ARE DOING** and the struct doc says the app
writes the file, but `ConfigWriter` only ever writes `terms:`. Three
person-chosen switches sit in a file people are told not to touch.

| File | Holds | Written by |
|---|---|---|
| `config.yaml` | every switch and threshold | a person |
| `vocabulary.yaml` | `terms:`, plus the retired keys | the app: the panel, `--learn`, calibrate |

Read the old location as legacy, with a `notices()` line naming each key and
where it goes now. The repo does exactly this for `floor:`, `heard:` and
`review:`.

This is a separable PR and it should come second. It still belongs to this
shape. Without it, "where do I turn the sentence gate off" has two answers.

---

## 5. Conditions

`when:`, `unless:` and `app:` are dropped from both. Nothing in the repo uses
them on these two stages except `scripts/check-pipeline-config.sh`, which
tests the parsing rather than a need — including a config with two
`vocabulary` steps carrying different floors, which is not a thing anybody
runs.

If "no vocabulary in Terminal" is ever wanted, `app:` goes into the block as
one key. It is a smaller change than keeping the machinery for it now.

---

## 6. Fixtures barely move

A fixture already has a `vocabulary:` key. It mirrors `vocabulary.yaml`
today; after this it holds the settings as well as the terms, and the step
options move into it:

```yaml
# before
vocabulary:
  terms: {BetterStack: {…}}
pipeline:
  - {stage: vocabulary, lowercase_refused: false}

# after
vocabulary:
  lowercase_refused: false
  terms: {BetterStack: {…}}
```

`PipelineCommand` gates a 320 MB download on `pipeline.stages.contains(.interpret)`;
that becomes a read of the block.

---

## 7. Migration

`problems()` is a menu bar warning, not a refusal, so nothing here stops an
app that is already installed from working.

| An old config says | What happens |
|---|---|
| `- interpret`, `- vocabulary`, `- stage: vocabulary` | Read, ignored, one notice: it runs anyway, delete the line. |
| the same with options | The options are read into the block for one release, with a notice naming the block. |
| a `pipeline:` that omits one of them | **See below.** |
| no `pipeline:` key at all | **See below.** `everything` runs `interpret` but not `vocabulary`. |
| an option on the wrong stage | Unchanged message, minus the stage half. |

**Two behaviour flips, and they need a decision.**

A hand-written `pipeline:` that leaves `- vocabulary` out means the pass is
off today. A config with no `pipeline:` key at all runs `Pipeline.everything`,
which excludes `vocabulary` too, because `Stage.isAutomatic` excludes it. If
the block defaults to `enabled: true`, both configs turn the pass on at
upgrade.

Recommendation, in two parts:

- A written `pipeline:` and no block: the list decides, for one release, with
  a `--check-config` line saying so.
- No `pipeline:` at all: turn it on. The reason `isAutomatic` excluded it is
  stale — the comment says the stage "names a prompt file", and it has not for
  some time. `config.example.yaml` turns it on, so a new install already gets
  it. Say it once in `--check-config`.

---

## 8. Footprint

| File | What changes |
|---|---|
| `Pipeline.swift` | Two `Stage` cases gone. `editsText`, `isAutomatic` exceptions and `vocabularyOrderProblems()` deleted. 12 `Step` fields deleted. The two pass bodies move out or take settings instead of a `Step`. |
| `Config.swift` | `PipelineEntry` loses the option decoding and `stageKeys`. Two new settings structs. `Vocabulary` gains the six file-level keys and their legacy readers. |
| `Transcriber.swift` | Where the two fixed passes run. |
| `CheckConfigCommand.swift` | Reads the blocks; the "delete the `interpret` step" wording goes. |
| `PipelineCommand.swift` | Fixture blocks; the interpret model gate. |
| `config.example.yaml`, `docs/pipelines.md`, `docs/configuration.md` | The shape above. |
| `tests/pipelines/*.yaml`, `scripts/check-pipeline-config.sh` | Options move up one level. |

---

## 9. Not in this proposal

`respell` (on `feat/respell`) reads the decoder's top-64 and protects the
spans `vocabulary` wrote. It is the same shape and will want the same
treatment. Naming it here so the rule is not re-argued when it lands.
