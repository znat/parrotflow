# The command line

Every flag the app takes, and what it answers. This is how a change to
`config.yaml` gets tested without speaking into a microphone, which makes it
the page to read if you are an agent configuring this for someone.

```sh
PF=/Applications/ParrotFlow.app/Contents/MacOS/ParrotFlow          # released
PF=/Applications/ParrotFlowDev.app/Contents/MacOS/ParrotFlow       # dev build
```

Each flag runs and exits; nothing here launches the menu bar app. **Exit code 0
means it did what it says**, so these compose into scripts — which is what
`scripts/check-*.sh` are.

## Start here

| Command | Answers |
|---|---|
| `--check-config` | Is the config valid, and what will actually run? |
| `--pipeline <file.yaml> "<text>"` | What does this pipeline do to this sentence? |
| `--replace "<text>"` | What do my replacement rules do to this sentence? |
| `--route "<what you'd say>"` | Which transform does this instruction reach? |
| `--eval <transform>` | How does it score against its own case set? |
| `--seed-config` | What does a first launch write, and what did it leave alone? |

Every one of them reads `~/.config/parrotflow/`. Set `PARROTFLOW_CONFIG_DIR` to
point them somewhere else — a whole config directory in `/tmp`, say — which is
how the check scripts score the binary without inheriting whatever this machine
happens to have configured. The app reads it too, so do not export it from your
shell profile.

### `--check-config`

Validates the YAML and prints what the app would use — not what the file says,
what survives it.

```
$ $PF --check-config
config: /Users/you/.config/parrotflow/config.yaml
  ✓ hotkey            Right ⌥  (push-to-talk, polled)
  ✓ sample rate       16000 Hz mono
  ✓ output dir        /Users/you/Recordings/ParrotFlow
  ✓ min duration      0.3s
  · feedback          sound=true overlay=true
  ✓ microphone        Granted
  ✓ input device      MacBook Pro Microphone
```

It also names, every time and whether or not anything is wrong:

- every `command:` transform, because that is config that executes code
- **the resolved absolute path of every transform's body**, so a file present
  both in `transforms/<name>/` and beside `config.yaml` cannot leave you
  guessing which one ran
- a file still at the old location beside `config.yaml`, and where to move it —
  a notice, not a fault: it runs, and nothing is moved for you
- a pipeline step naming a transform that does not exist
- a pipeline key that is neither `default` nor one of your `languages:`
- an `app:` lookahead that is not anchored, which would run the stage
  everywhere it was written to exclude
- a `fuzzy` stage with no `replacements` stage before it

**Accessibility is the one thing it cannot tell you.** macOS credits a
permission check made from a terminal to the terminal, not to ParrotFlow, so
this reports it missing even when it is granted. The app tests it properly at
launch and writes the answer down:

```sh
grep "launched —" ~/Library/Logs/ParrotFlow.log | tail -1
```

## Testing a rewrite

```sh
$PF --pipeline tests/pipelines/apps.yaml "on en a vingt et un" --app Ghostty
$PF --replace "we deployed to super base" [--app <name>]
$PF --numbers "two hundred forty three" [--lang fr]
$PF --normalize "<text>"
$PF --dates "<instruction>" "<text>" [--locale FR] [--lang en,fr]
$PF --inflected <term> <heard>
$PF --verdicts <count> "<reply>"
```

`--inflected` asks what the vocabulary pass would write where a decoded word
stood — `--inflected Matthieu "Mathieu's"` prints `Matthieu's`. It is
`Vocabulary.inflected` and nothing else: no audio, no model, no config. The
question it answers is whether a possessive survives a substitution, and
`scripts/check-possessive.sh` scores it against `tests/possessive-cases.yaml`.

`--verdicts` asks what the name judge reads out of a model's reply —
`--verdicts 2 "1. KEEP` newline `2. REVERT"` prints `KEEP REVERT`. It is
`VocabularyJudge.verdicts` and nothing else. A reply read wrongly puts a name
into somebody's sentence or takes one out, so it has its own set:
`scripts/check-verdicts.sh` against `tests/verdict-cases.yaml`, malformed
replies included.

`--pipeline` takes a YAML file holding a pipeline — its own, not your config —
so a case file states the setup it assumes instead of inheriting this machine's.
`tests/pipelines/` holds the ones the check scripts use.

- `--app <name>` is the app the stage conditions are matched against. An empty
  `--app ""` means "nothing was in front", which is a different question from
  not passing the flag, and is how the fail-closed rule gets tested.
- `--no-prompts` skips the stages that would call the model, so a run stays
  deterministic and fast.
- `--quiet` prints only the result, for scripts.
- `--vars` prints the whole variable scope when the run is done, one line per
  path, before the output line — so `--quiet --vars | tail -1` is still the
  result. It is how a stage whose only contribution is a fact gets scored at
  all, and the first thing to reach for when a condition is not deciding what
  you expected. See [pipelines.md](pipelines.md#variables).
- `--lang en,fr` stands in for the configured `languages:`, so a case file does
  not depend on how this Mac is set up.

```
$ $PF --pipeline tests/pipelines/vars-shipped.yaml \
      "a python function called max retries" --vars
in:   a python function called max retries
  → transform
      a python function called max_retries
      code_identifiers.asked_model = false  code_identifiers.changed = true  code_identifiers.count = 1
  ⊘ transform  — skipped, when code_identifiers.count == 0 did not match (code_identifiers.count = 1)
var   code_identifiers.asked_model = false
var   code_identifiers.changed = true
var   code_identifiers.count = 1
var   code_identifiers.ms = 69.0
var   code_identifiers.ok = true
var   code_identifiers.ran = true
var   dotted.ran = false
var   language = "en"
out:  a python function called max_retries
```

The line under a stage is what *that* stage contributed; the `var` block at the
end is the whole scope. A skipped stage names the values that decided it, which
is the question you actually have.

## Scoring a transform: `--eval`

One sentence tells you a rewrite is wrong. Only a set tells you a change made
it better rather than moved the failure.

```sh
$PF --eval code_identifiers                        # transforms/…/cases.yaml
$PF --eval slack_mentions --cases heldout.yaml     # another set in the folder
$PF --eval grammar --probe restraint --verbose
$PF --eval ~/scratch/my-cases.yaml                 # one-off, outside a folder
```

It resolves the transform from your config and runs **that** — the same code
the app runs, including the part where every way of failing leaves the text
alone. A runner that reimplements the thing it scores drifts from it, and the
number then describes code nobody ships.

```yaml
# The contract, in prose: what counts as a case here and what is deliberately
# out of scope. It is what you will disagree with yourself about in a week.
cases:
  - probe: ambiguity_common        # optional; groups the breakdown
    input:  mark it as resolved
    expect: mark it as resolved
```

`input` and `expect` are the whole requirement. **`expect` left out means "comes
back exactly as it went in"**, and those cases are reported as their own half —
detected, never declared. A rewrite that scores well on `change` and badly on
`keep` is not 80% of the way there; it is one that makes you proof-read every
dictation.

Four optional keys, each earning its place:

| | |
|---|---|
| `probe:` on a case | the breakdown. One broken category hides behind eleven healthy ones for exactly as long as nobody breaks it out |
| `instruction:` | what the speaker said, for a prompt reached by voice. The same prompt scores differently as a pipeline stage, which is given nothing |
| `control:` | a command doing the same job without a model. The only thing that answers "is the model earning its place" — on Slack mentions it scored the same and the model was dropped |
| `intermediate:` | `field:`, `resolve:` and optionally `produce:`, for a two-stage transform. Scores what the model alone returns, separately, so you can tell whether the prompt or the code is at fault |

Where an intermediate gold exists it is **checked against itself before
anything is scored**: resolving it must produce `expect`. A typo in a gold
otherwise scores every candidate against the typo, silently, for as long as the
set exists — so that is a refusal, not a warning.

Latency is reported warm, after a throwaway first call. A cold start is Ollama
reading weights off a disk and has nothing to say about the thing you changed.

`--eval` exits 0 whenever it managed to score, whatever the number: a set worth
having keeps its residue in, failing. It exits 1 when it could not score at all.

Custom gates — "a handle belonging to someone who was not named must be zero" —
do not generalise and stay in a script of your own. See
[authoring.md](authoring.md).

## Testing a spoken instruction

```sh
$PF --route "hey parrot, make that a bullet list"
$PF --prompt <name> "<instruction>" "<text>"
$PF --command "hey parrot, Tasmin spells T A S M E E N" "<last transcript>" \
    [--phrases "hey parrot,by the way parrot"]
$PF --learn <heard> <corrected>
```

`--route` shows which transform an instruction reaches and why — the router
matches your words against each transform's `description`, so this is how you
find out that a description is too vague before a user does.

`--prompt` runs one named transform against text you supply, with the
instruction that would have been spoken. `--command` runs the whole
wake-phrase path: is this a command at all, is it a correction, which words in
the previous transcript does it target.

`--learn` writes a replacement rule from the terminal, the same one the
correction panel would have written.

## Forgetting what a name sounds like

```sh
$PF --forget <term>
```

Everything learnt about how one name comes out, in one go: its pronunciations
in `vocabulary.yaml`, every line naming it in `voice/observations.jsonl`, and
every clip under `voice/samples/<Term>/`. The term itself stays — forgetting is
about the learnt half, and somebody who wants the name gone deletes the name.

It exists because the three files only ever grow. A rendering learnt from one
bad clip goes on shaping the audio search forever, and the only remedy was to
hand-edit a file whose header says not to. Data nobody can correct is data
nobody should be asked to trust.

```
$ ParrotFlow --forget Praisy
✓ forgot Praisy
  14 pronunciation(s) from vocabulary.yaml
  17 observation(s) from voice/observations.jsonl
  17 sample(s) from voice/samples/Praisy/
```

## Proving the microphone and the model work

```sh
$PF --record 3           # record 3s and verify the file it produced
$PF --transcribe a.wav   # transcribe a clip
$PF --watch-modifiers    # print which modifier keys are physically down, live
$PF --audio-recovery     # what the recorder does when the microphone changes
```

`--record` checks the result, not just that it ran: sample rate, channel count,
bit depth, peak level, and whether the file is the right size for its duration.
A silent clip or a short file gets a non-zero exit.

`--watch-modifiers` is the one to reach for if a bare-modifier hotkey seems
dead — it shows whether the key is reaching the app at all, and whether left
and right are distinguishable on your keyboard.

`--audio-recovery` is for the other kind of dead: the microphone changed —
AirPods connected, a headset came out — and dictation has been recording
silence ever since. It moves the input binding inside the process instead of
switching your real input device, so it is safe to run while somebody is
dictating and it never opens the microphone. That is also its limit: it proves
the recorder replaces its engine and that the capture path writes a real signal
afterwards, and it proves nothing about what the hardware then sends. The cases
are in `tests/audio-recovery-cases.yaml`; `scripts/check-audio-recovery.sh` runs
it against a scratch config.

You can make a test clip without a microphone at all — `say` writes exactly the
format the model wants:

```sh
say -o /tmp/t.wav --data-format=LEI16@16000 --channels=1 "testing one two three"
$PF --transcribe /tmp/t.wav
```

## Text insertion, which is the risky path

```sh
$PF --peek 3 [--find <sentinel>]
$PF --edit-test <needle> <replacement> --find <sentinel> [--after 3] [--literal]
$PF --span-test <start> <length> <replacement> --find <sentinel> [--after 3]
```

`--peek` reads the surface the way the app would — the value, the selection, and
then the same thing as `Surface` sees it: the content as one string and the span
as offsets into it. That last block is the one that decides what a write does;
when it and the raw accessibility lines above it disagree, the surface block is
the one that matters.

`--edit-test` performs a real in-place edit after a delay, finding the text by
searching for it. `--span-test` does the same to a character range given
outright, which is how the app itself now works — a caller that knows which
characters it wants changed says so, and nothing searches for anything.

`--find <sentinel>` is **required** for both: without it these write into
whatever happens to be in front, which during a test run is as likely to be a
real window as the scratch one you meant.

## Looking at the floating surfaces

```sh
$PF --panels preview 20   # put one surface on screen and leave it there
$PF --panels sequence 40  # run a whole dictation's worth of states, on a loop
$PF --panel-sheet s.png   # draw every surface into one PNG, light beside dark
```

`--panels` takes `pill`, `notice`, `caution`, `failure`, `thinking`, `offer`,
`vocabulary`, `rule`, `dictation`, `preview` or `sequence`. `--panel-sheet` draws all of
them at once, which is where drift between them shows up.

`offer` is the one state that takes the mouse — hover a chip to light it, click
one to print which was chosen. Every other state lets clicks through, so the
pill is never a hole in your screen while you are dictating.

It is also the one state that fades. It arrives just below full strength and
thins out over nine seconds, the same as in the app, so it leaves on its own.
Put the pointer on it and the fading stops, which is both what the app does and
how you keep it on screen for as long as you want to look at it.

`sequence` is the one that cannot be checked from a still. The pill is a single
panel that changes width and crossfades its contents rather than being replaced
— hot mic, decoding, applied, the offer, gone — and whether that morphs or
jumps is only visible in motion. It loops for as many seconds as you give it.

## Updates

```sh
$PF --update-check [--after-days N]
$PF --update-install [--dry-run]
```

## The check scripts

Every rewrite in this repo has a case set and a script that scores it. They are
the fastest way to know whether a change to a prompt, a pattern or a stop list
made things better or only different.

```sh
scripts/check-pipeline.sh          scripts/check-replacements.sh
scripts/check-dotted.sh            scripts/check-numbers.sh
scripts/check-routing.sh           scripts/check-wake.sh
scripts/check-split.sh             scripts/check-grammar.sh
scripts/check-dates.sh             scripts/check-inplace.sh
scripts/check-default-config.sh    scripts/check-seeded-transform.sh
scripts/check-transform-folders.sh scripts/check-eval.sh
scripts/check-compose.sh           # what a prompt says once the scope is in it
scripts/check-context.sh           # what the context stage publishes for a screen
scripts/check-span.sh              # a composer-shaped page, or Slack, or Outlook
scripts/check-vocabulary-config.sh # what vocabulary.yaml adds up to, old keys included
scripts/check-possessive.sh        # whether a possessive survives a substitution
scripts/check-verdicts.sh          # what the name judge reads out of a reply
scripts/check-judge-prompt.sh      # the judge's prompt is one its parser can read
scripts/check-no-voice.sh          # nothing in git is one person's voice
scripts/check-audio-recovery.sh    # a microphone that changes leaves a usable engine

PF_VIEWPORT=Ghostty scripts/check-inplace.sh   # the same set, in another terminal
$PF --peek 3 --via-copy                        # what Select All + Copy hands back

scripts/validate-prompt.py gemma4:e4b        # spelling + French correction sets
scripts/validate-code-identifiers.py         # the identifier transform
scripts/validate-generic.py                  # free-form instructions
scripts/validate-gate.py                     # what should never be treated as a command
```

Several read their input out of `Config.defaultYAML` or `config.example.yaml`
rather than a fixture, so what gets scored is what a new install actually gets.

See [authoring.md](authoring.md) for the loop these belong to.

## The log

```sh
make logs                                # tail the dev log
VARIANT=release make logs                # tail the shipped app's
tail -f ~/Library/Logs/ParrotFlow.log
```

It records the hotkey, both permission states, every clip written, every stage
that was skipped and why, and the before-and-after of every rewrite a model
made. A stage that silently does not run looks exactly like one that ran and
found nothing — only one of those is answerable by editing a condition, so the
log distinguishes them.

It is for reading over your own shoulder while something goes wrong: prose,
second resolution, and a rolling buffer that throws the oldest away at 1 MB.
Ask a question of more than one dictation and you want the trace instead.

## The trace

```sh
tail -1 ~/Recordings/ParrotFlow/trace.jsonl | jq .
```

One JSON object per line, appended and never rotated, beside the clips it
describes. It holds what the decoder actually returned before anything touched
it — the raw text, its confidence, and **every word with its start, end and
confidence** — plus the speech gate's segment boundaries, then each pipeline
stage with its before, its after and what it cost in seconds, and finally the
text that was delivered. `wav` joins a line to its recording; `source` is
`live` for something you spoke and `cli` for a `--transcribe` re-run, so a
sweep over the archive does not read as a day of dictation.

The decoder computed all of it either way. It used to be dropped one line after
it arrived.

`kind` says which sort of line you are holding.

- **`dictation`** — the shape above.
- **`correction`** — `heard`, `corrected`, and `via` (`panel`, `command` or
  `learn`). Written whenever a rule is taught, which is minutes after the
  transcript it is about and from a different place entirely, so it gets its
  own line rather than a field on one. These are the only human labels in the
  system, and nothing else on disk can reconstruct them.

`v` is the schema version — records written before it existed have no `v` and
should be read as 1.

A note on what is **not** here. `lang` is ParrotFlow's own verdict, the one that
picked the pipeline; Parakeet reports no language of its own, so there is
nothing else to log. `app` carries the name and the bundle id and deliberately
not the window title, which is the highest-yield field available and the one
that leaks document names, client names and ticket subjects. And a correction is
only recorded when ParrotFlow mediates it — reading the field back after the
text has landed would catch more of them and would mean looking at another app's
content after focus has been given away, which is a different thing to be.

Nothing derived is stored: pause gaps, filled pauses, confidence dips and
whether a gate would have fired are all computable from `asr.words` and
`vad.segments`, and baking them in would mean recomputing history every time a
threshold moves.

The questions it answers, which the log cannot:

```sh
cd ~/Recordings/ParrotFlow

# Which words is the model least sure of? Candidates for the replacement
# table, ranked instead of guessed at.
# `[]?` because a dictation that failed before the decoder returned is still
# written down, with a null `asr` — and iterating that aborts jq outright.
jq -r '.asr.words[]? | select(.confidence < 0.5) | .word' trace.jsonl |
  sort | uniq -c | sort -rn | head -20

# A dictation whose ending went missing: did the decoder stop, or the gate?
# Both halves are guarded: `vad` is absent whenever the speech gate is off or
# its detector would not load, and a record can have every word and no segments.
jq -r 'select((.asr.words|length > 0) and (.vad.segments|length > 0)) |
       [.wav, (.vad.segments[-1][1]), (.asr.words[-1].end), .vad.total] | @tsv' trace.jsonl

# What each stage really costs on your own sentences.
jq -r '.stages[]? | select(.seconds) | [.name, .seconds] | @tsv' trace.jsonl |
  awk '{n[$1]++; s[$1]+=$2} END {for (k in n) printf "%-28s %6.3fs  ×%d\n", k, s[k]/n[k], n[k]}' |
  sort -k2 -rn

# Every dictation a prompt stage rewrote, and into what.
jq -r '.stages[]? | select(.before and .before != .after) |
       [.name, .before, .after] | @tsv' trace.jsonl

# Which stage conditions are doing the skipping, by category rather than by
# whichever regex happened to be written into the prose.
jq -r '.stages[]? | select(.skip_reason) | .skip_reason' trace.jsonl |
  sort | uniq -c | sort -rn

# Every rule you have ever taught, and from where.
jq -r 'select(.kind == "correction") | [.via, .heard, .corrected] | @tsv' trace.jsonl
```

`--transcribe` writes a trace line too, which is what makes it worth having:
change a table, re-run the clips, and both sets of numbers sit in one file
joined to the same audio.

```sh
for f in ~/Recordings/ParrotFlow/*.wav; do ParrotFlow --transcribe "$f" >/dev/null; done
```
