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
| `--bug-report` | Everything a bug report needs, in one paste. |

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
  ✓ output dir        /Users/you/.config/parrotflow/recordings
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
- a `pipelines:` key, which is retired: nothing under it is read, so it is
  refused and the built-in default runs until you write `pipeline:`
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

### `--bug-report`

Prints what the bug form asks for: the version, macOS and the chip, the
permission state, the whole `--check-config` output and the last 50 lines of the
log. Every absolute home path is written as `~`, so the report carries no
account name.

```sh
$PF --bug-report            # the report, on stdout
$PF --bug-report --url      # the prefilled issue form, without the report
```

It exits 0 with no config and no log file. A report about an install that does
not work is the one that has to come out.

🦜 → **Report a Bug…** shows the same text in a window, and copies it only after
you have read it — the log can carry what you dictated. The URL it opens fills
in the short fields; the report itself goes on the clipboard, because a log in a
URL overflows what GitHub accepts and gives an error page rather than a form.

## Testing a rewrite

```sh
$PF --pipeline tests/pipelines/apps.yaml "on en a vingt et un" --app Ghostty
$PF --replace "we deployed to super base" [--app <name>]
$PF --normalize "<text>"
$PF --dates "<instruction>" "<text>" [--locale FR] [--lang en,fr]
$PF --inflected <term> <heard>
$PF --word-gate <word> [term] [--in "<sentence>"]
$PF --teaching "<sentence>" <word>
$PF --suggest "<sentence>" [--lang fr]
```

`--inflected` asks what the vocabulary pass would write where a decoded word
stood — `--inflected Matthieu "Mathieu's"` prints `Matthieu's`. It is
`Vocabulary.inflected` and nothing else: no audio, no model, no config. The
question it answers is whether a possessive survives a substitution, and
`scripts/check-possessive.sh` scores it against `tests/possessive-cases.yaml`.

`--word-gate` asks whether a vocabulary term may be written over this word with
nothing reading the sentence — `--word-gate Frederick` prints `open`,
`--word-gate Versal` prints `auto-apply`. Two word lists decide and both have
to say they have never seen the word: `NSSpellChecker`, which has no first
names in it, and the whole-word half of a tokenizer vocabulary
(`data/wordpiece.txt`), which has no rare compounds in it. Both verdicts are
printed, because a word reaches `open` from either side. `open` is the route
label for "this gate does not settle it"; nothing is asked, and a place nothing
settles keeps what arrived. No model runs — it is a set lookup.

Name the term as well and the whole gate answers about that pair —
`--word-gate "Mirza's" Mirza` prints `possessive dropped` and `open`. One
condition is not about a word at all: a `'s` the heard text carries and the
term does not would be taken out of the sentence, so this gate leaves it open.
`scripts/check-word-gate.sh` scores both forms against
`tests/word-gate-cases.yaml`.

Name the sentence too — with the term, which the model tiers are about —
`--word-gate merge Vercel --in "Go back to main and merge."` prints
`slot Verb` and `route decline`. `slot` is what the masked slot wants, from
ten fillers put back and tagged; `route` is where the proposal goes. The slot
only ever declines: a name goes in a `Noun`, `Adjective` or `Pronoun` slot and
never in a `Verb`, `Adverb` or `Preposition` one, and every other proposal
reads `open` — see `SlotGate`. Nothing is downloaded: with no cached slot
model the slot reads `unavailable` and the route is `open`.
`scripts/check-slot-gate.sh` scores the whole route against
`tests/judge-cases.yaml`. It needs the 269 MB model, so it is not in
`make test`.

`--teaching` asks whether a substitution sits inside a spelling lesson —
`--teaching "Hey Barrot Versal Spells V E R C E L" Versal` prints `REVERT`, and
`ASK` for anything else. The word before `spells` is what a lesson is teaching,
so writing the term over it destroys the correction: "Mirza spells mirza"
teaches nothing. The stage reverts those whatever else was proposed about them,
because every model measured answered all four of the archive's cases the wrong
way.

Most lessons never reach it. "hey parrot, Tasmin spells T A S M E E N" is a
[spoken instruction](#testing-a-spoken-instruction) and the vocabulary stage is
skipped for it.
The rule is for the ones where the wake phrase was itself mangled — "Hey
Barrot", "by the way pirate" — so the command was never recognised and the
sentence arrived as ordinary dictation. `scripts/check-spells-rule.sh` scores
it against `tests/spells-cases.yaml` and sweeps all 59 of
`tests/judge-cases.yaml` to check it fires nowhere else.

`--suggest` prints the rows the correction panel would propose for a sentence,
one `heard<tab>kind` per line, and nothing when it proposes nothing. A row is a
word the macOS dictionary does not know; the kind comes from the word tagger and
is a proposal, not a verdict. `scripts/check-suggest.sh` scores it against the
`approve` cases of `tests/judge-cases.yaml` — 12 of the 17 words that genuinely
needed fixing, at 0.6 rows per sentence.

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
- `--warm` waits for the word vectors and the slot model before the run. The
  sentence gate never makes a dictation wait, so in a one-shot run nothing has
  loaded them and the two tests that read the sentence are skipped every time —
  this is the only way to see them from the command line. Off by default: it is
  about 600 MB of downloads, and `make test` must not need one. Only what the
  fixture's own pipeline reads: a fixture with `slot_gate: false` on its
  `vocabulary` step fetches no slot model, and one with no `vocabulary` step
  fetches neither.
- `--lang en,fr` stands in for the configured `languages:`, so a case file does
  not depend on how this Mac is set up.

```
$ $PF --pipeline tests/pipelines/vars-shipped.yaml \
      "a python function called max retries" --vars
in:   a python function called max retries
  → transform
      a python function called max_retries
      code_identifiers.changed = true  code_identifiers.count = 1
  ⊘ transform  — skipped, when code_identifiers.count == 0 did not match (code_identifiers.count = 1)
var   code_identifiers.changed = true
var   code_identifiers.count = 1
var   code_identifiers.ms = 69.0
var   code_identifiers.ok = true
var   code_identifiers.ran = true
var   dotted.ran = false
var   language = "en"
var   vocabulary.changes = ""
var   vocabulary.count = 0
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
$PF --for <term> "<sentence>" [word]
$PF --against <term> "<sentence>" <word>
$PF --correction <wrote> <put> --in "<sentence>" [--dry]
$PF --sound-group <word>
$PF --group-decide <term>:<score>:<floor>... [--plain <score>]
$PF --name-place <heard> <term>
$PF --picked <word> <term> --in "<sentence>" [--dry]
```

`--route` shows which transform an instruction reaches and why — the router
matches your words against each transform's `description`, so this is how you
find out that a description is too vague before a user does.

`--route "…" --keyed` scores the other path: tap-and-hold, where a key said
this was an instruction and there is no router at all. A name anywhere in the
sentence wins, `say:` aliases included; everything else is `ANY`. No model, so
it answers instantly. `scripts/check-keyed.sh` drives it against
`tests/keyed-cases.yaml`, which supplies its own catalogue.

`--prompt` runs one named transform against text you supply, with the
instruction that would have been spoken. `--command` runs the whole
wake-phrase path: is this a command at all, is it a correction, which words in
the previous transcript does it target.

`--learn` adds a pronunciation to `vocabulary.yaml` from the terminal, the
same one the correction panel would have written.

`--for` records a sentence a term belongs in, without touching the
pronunciations. `--against` records the opposite: a sentence where the term
does not belong, with the ordinary word that stands where it would go. Both
are written to `vocabulary-uses.yaml`, which is what a term's portrait is
built from. `--against` writes no pronunciation — a counter-example teaches
nothing about how a word sounds. Three of them under one term and the portrait
stops reading that term against a floor: a new sentence is written when it sits
closer to the sentences the term belongs in than to these.

```
$ ParrotFlow --against Vercel "I love visiting the Versailles Castle." Versailles
✓ Vercel does not belong at "Versailles"
```

`--correction` is what a correction the app watched you make writes, and it
writes it. A term put back over another term is a use of the one you typed,
carrying the spelling it replaced; an ordinary word put back is a counter under
the term that was proposed. Never both. `--dry` prints the rows without
touching the file.

```
$ ParrotFlow --correction Mik Mick --in "Mick is adjusting the piano."
use Mick "Mick" heard Mik
```

`--sound-group` prints the terms that share a word's sound, every word that
opens that group, and whether the word is still a substitution rule — one that
opens a group of two or more is not. `--group-decide` runs the decision rule on
scores you write down: a member is `<term>:<score>:<floor>[:<uses>]`, a floor
of `-` is a member with too few uses to have one, a score of `-` is one that
could not be scored, `:0` is a member nobody has ever confirmed — unknown,
which opens the place rather than losing it — and `--plain` is the score
against the group's pooled counter rows. The last line is the verdict.

```
$ ParrotFlow --group-decide Mik:0.90:0.80 Mick:0.86:- --plain 0.70
Mik         0.900  floor 0.800  stands
Mick        0.860  floor —      stands
plain       0.700
write Mik
```

The same decision with the real portraits behind it is
`--portrait <heard> "<sentence>"`, which prints the group the word opens, each
member's score and floor, plain's score and the verdict. A group of one prints
the same way, so the cold start of a new name is readable: one use, no floor,
no counter row, nothing decided.

`--name-place` says whether the slot test stands aside at a place: `names` when
both sides are names and the slot cannot separate them, `ordinary` when it is
an ordinary word against a term.

`--picked` is what an answer on the pill records, and it records it: `use
<term>` for a word that is already a term, `create <name> <kind>` for a name
that is not one yet — written to `vocabulary.yaml` with no pronunciation, under
the kind the tagger read — and `counter <term>` for an ordinary word. `blocked <a> <b>` instead of any of
them means the sentence names two members of one group, so nothing is written.
`--correction` answers the same way.

`--for` takes `--near <n>`, the word the correction was at. A terminal joins
dictations with no space after the stop, so one field holds the same name
several times and the position is what says which sentence to store.

## Giving a model its API key

```sh
$PF --set-key <model>            # prompts, and does not echo
printf '%s' "$KEY" | $PF --set-key <model>
$PF --set-key <model> --forget
```

A cloud model in `models:` with no `api_key:` line reads the keychain. This is
how the key gets there without the app asking. The key comes from stdin, never
from an argument, so it is not in `ps` and not in your shell history.

Only for a model that actually uses the keychain. One with `file:` or `env:`
already says where to look, and an `ollama` model needs no key at all; both are
refused rather than storing a key nothing will read.

```
$ printf '%s' "$OPENAI_KEY" | ParrotFlow --set-key gpt
stored a key for gpt in the ParrotFlow keychain.

$ ParrotFlow --check-config | grep gpt
      gpt     openai  gpt-5.6-luna  https://api.openai.com/v1  reasoning off  the Keychain
```

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
$PF --microphones        # every microphone attached, and which one wins
$PF --record 3           # record 3s and verify the file it produced
$PF --transcribe a.wav   # transcribe a clip
$PF --watch-modifiers    # print which modifier keys are physically down, live
$PF --watch-taps         # tap, hold or shortcut — which edge each press comes out as
$PF --audio-recovery     # what the recorder does when the microphone changes
```

`--microphones` prints what is attached, with the exact name and UID that
`audio.microphones` matches on, and marks the one the list lands on right now.
It is where the strings in that setting come from — a name typed from memory is
a name that matches nothing. `--microphones --set "Studio Display Microphone,
MacBook Pro Microphone"` writes the list, best first, and `--microphones --set ""`
clears it; the menu bar does the same thing without the typing. See
[configuration.md](configuration.md#audiomicrophones).

`--record` records through that same list, and says which microphone it used.
It checks the result, not just that it ran: sample rate, channel count,
bit depth, peak level, and whether the file is the right size for its duration.
A silent clip or a short file gets a non-zero exit.

It also prints how long it waited for the first sample. `start` returns as soon
as the audio graph is running, which is before the device sends anything, and
anything said in that window is not in the file. Measured cold on this machine:
330 ms, of which 105 ms was after the engine was up.

`--watch-modifiers` is the one to reach for if a bare-modifier hotkey seems
dead — it shows whether the key is reaching the app at all, and whether left
and right are distinguishable on your keyboard.

`--watch-taps` runs the same key through the real monitor and names the edge
each press came out as: `press`/`release` for a hold, `tap` for one shorter
than `press_delay_seconds`, `abort` for a hold that turned out to be a
shortcut. It reads your configured hotkey and delay unless you name another
(`--watch-taps right_option 20`). A tap is a length of time on a physical key,
so no fixture can score it — the case worth checking by hand is that ⌘S prints
nothing at all.

`--audio-recovery` is for the other kind of dead: the microphone changed —
AirPods connected, a headset came out — and since then dictation records
silence, or the hotkey starts nothing at all. It moves the input binding inside
the process instead of switching your real input device, so it is safe to run
while somebody is dictating and it never starts the microphone. That is also its
limit: it proves the recorder rebinds and that the capture path writes a real
signal afterwards, and it proves nothing about what the hardware then sends.
The cases are in `tests/audio-recovery-cases.yaml`;
`scripts/check-audio-recovery.sh` runs it against a scratch config.

Three blocks. `Device changes` moves the binding — device, rate or channel count
— and checks whether the session was rebuilt; the change is delivered through
the CoreAudio device-list listener's own body, so a break between the listener
and the comparison fails it too. `The device the list names` warms a recorder on
whatever CoreAudio calls the input and checks the same microphone comes back out
of AVFoundation, by UID. `Capture after a device change` pushes a 440 Hz tone
through the write path and checks what lands on disk, including what happens to
a buffer in a format the file cannot take.

The `This machine` block is printed, never scored. Its `open` line is the one to
read: it reports `kAudioDevicePropertyDeviceIsRunningSomewhere` after `warmUp`,
which must be `no` — warming up builds the session and must not start it.

You can make a test clip without a microphone at all — `say` writes exactly the
format the model wants:

```sh
say -o /tmp/t.wav --data-format=LEI16@16000 --channels=1 "testing one two three"
$PF --transcribe /tmp/t.wav
```

## What an answer on the pill writes

```sh
$PF --selector "<text>" "<standing>|<other>|<word>|<answer>"...
```

A place none of the gates settle is put to you on the pill, and the words wait
for the answer. This is that write without the surface: where the span is found
again in the text that shipped, and what goes back there.

```
$PF --selector "can you ask Mick to review it." "Mick|mixed bend|3|1"
  can you ask mixed bend to review it.
```

A place is `standing|other|word|answer` — what stands in the text, the reading
nobody took, where the stage saw it counted in words, and then `0` to keep what
stands there, `1` to take the other reading, `2` for "something else", `-` for
a question nobody answered. Several places are several arguments.
`NOTHING FOUND` means no span was still there: the stages after `vocabulary`
may rewrite, and a span that is gone is a question nobody can answer.

A place where several names share the heard word has one row per member, so the
answer can go past `1`. The row after the last reading is always "something
else": it writes what was heard and records nothing.

The word index is what separates two mentions of the same word, and the write
touches nothing between the places — a newline, a double space and a comma
glued to the next word all survive it.

`--ranges` prints where each answered word ended up instead of the text, which
is what the trace records: a place after one the answer made longer has moved.
`--taught` prints what each answer records instead: the word, and `teaches` or
`nothing`.

`scripts/check-selector.sh` scores both halves, 21 cases. The lowercasing of a
refused glued span is `--lowercase-refused`.

## What word does this slot want

```sh
$PF --slot-model                                           # fetch, compile and load mmBERT-small
$PF --slot-probe "<left half>" "<right half>"              # the ten words the slot expects, and the time
$PF --slot-probe --encode "<text>"                         # the tokenizer alone, no model
$PF --slot-gap "<sentence>" <heard> <term> [--lang fr]     # what the slot says about a rewrite
```

The vocabulary pass proposes a rewrite from spelling and sound alone. The slot
reads the sentence instead: mask the word, ask mmBERT-small for the ten words it
expects there, and measure both readings against them with the word vectors.

```
$PF --slot-gap "The old house looked ghostly in the fog." ghostly Ghostty
  expected  grey like deserted good lost beautiful white cool green ugly
  gap       -0.243   refuse
```

`gap` is `cos(term, centre) − cos(heard, centre)`. Below the floor for the
language the rewrite is refused; above it the slot has no opinion. The floor is
`slot_floor:` on the `vocabulary` step, 0.20 in English and 0.30 in French, and
`--lang` picks which one the verdict is read at. The gap itself is
the same number either way. It only ever refuses — a term is
unknown to the tokenizer by construction, so it can never win this comparison.
The ten words are printed because they explain the number: a slot whose ten
words are pronouns cannot tell two names apart, and the gap comes out near zero.
`scripts/check-slot-gap.sh` scores the decisions against
`tests/slot-gap-cases.yaml`; it needs both models, so it is not in `make test`.

`--slot-probe --encode` prints ids and loads no model, which is what
`scripts/check-slot-tokenizer.sh` compares against HuggingFace's own tokenizer.

mmBERT-small and not ModernBERT, which this stage used to read: the two tie on
the English bench, and mmBERT-small covers 1,800 languages where ModernBERT is
English-only. It is not cheaper — the same cache size, and 18 ms per pass
against 11, because its head is five times wider. Multilingual is the whole
reason for the swap.

## Is this sentence mark real

```sh
$PF --sentence-model                                       # fetch the model the readings need
$PF --sentence-probe "<left half>" "<right half>"          # read one boundary
$PF --sentence-probe --bare "<left half>" "<right half>"   # a capital with no mark
$PF --sentence-probe --window "<left half>" "<right half>" # the window alone, no model
$PF --sentence-probe --bench <cases.json> --out <out.json> # a whole file, one loaded process
```

A pause in the middle of a sentence makes the transcriber write a period or a
question mark. The probe builds three readings of the boundary — the mark on
the left half, the comma, and no mark at all — and scores each with
`mlx-community/Qwen3-0.6B-Base-4bit`. The score is the log-probability of the
continuation divided by its token count. The highest wins, and there is no
threshold.

End the left half with `?` to read a question boundary. With no mark there it
is read as a period.

`--bare` reads it as a capital the transcriber wrote with nothing in front of
it. That shape gets a fourth reading, the text exactly as decoded, because
there is no mark to take out and leaving it alone has to be a candidate of its
own rather than what happens when a mark wins.

```
$PF --sentence-probe --bare "…the dot and the word app" "And decide which one is bigger"
  reading   .           -4.9574  7
  reading   as-decoded  -5.3883  6
  reading   ,           -4.2416  7
  reading   join        -4.3177  6
  winner    ,
```

```
$PF --sentence-probe "…the first usage of the LLM with." "The vocabulary is slower"
  prefix    the first usage of the LLM with
  reading   .        -7.2669  5
  reading   ,        -6.5327  5
  reading   join     -4.5571  4
  winner    join
```

The number after the score is how many tokens it was divided by. `retokenised`
on a line means the mark merged into the last token of the prefix, so that
reading is scored from the first token that actually differs — 2 of 972 bench
sequences do this.

`--bench` reads `[{"left": …, "right": …}]` and writes one row of scores per
boundary, with the mark it read and the milliseconds each decision took. A row
may carry `"mark": "?"` where the left half does not end with the mark itself,
and `"mark": ""` for the bare-capital shape.
It loads the model once, so it is the only way to get a latency number;
`--vectors` loads the word vectors as well, so the memory line describes the
process the app runs.

`--window` builds the prefix and the continuations and stops, as JSON. No model
is loaded. `--bare` applies to it as well.

```
$PF --sentence-probe --window "did you see the parrot?" "At the top right"
{
  "mark" : "?",
  "prefix" : "did you see the parrot",
  "readings" : [
    {
      "continuation" : "? At the top right",
      "key" : "?"
    },
    {
      "continuation" : ", at the top right",
      "key" : ","
    },
    {
      "continuation" : " at the top right",
      "key" : "join"
    }
  ]
}
```

`scripts/check-sentence-window.sh` compares that against
tests/sentence-window-cases.json, whose expectations were written by hand from
the rules rather than from a run. It runs in CI.

`scripts/check-sentence-probe.sh` compares the readings against
tests/sentence-boundary-cases.json; it needs the model, so it is not in
`make test`.

`--sentence-model` fetches the Qwen base model the readings are scored with.
The vocabulary slot gate has its own model and its own command, `--slot-model`.

## Which sentence marks a pause put there

```sh
$PF --sentence-join "<text>"            # read every boundary, and join what wins
$PF --sentence-join --case "<text>"     # the lowercasing alone, no model
```

`--sentence-join` is the pass the app runs, on the text you give it. One block
per boundary, then the text it hands on. A boundary is a `.` or a `?` followed
by a word — a capital after a period, a capital or a lowercase word after a
question mark.

```
$PF --sentence-join "…the first usage of the LLM with. The vocabulary is slower"
  language   en
  boundary   with. The -> with the
  reading    .         -7.2669  5
  reading    ,         -6.5327  5
  reading    join      -4.5571  4
  winner     join
  text       …the first usage of the LLM with the vocabulary is slower
```

The mark is removed where `join` wins, and left alone otherwise. Which marks are
scanned, and which are read beside them, is `marks:` on the `interpret` step in
`config.yaml` — the sentence enders in that list are scanned, the rest are
readings. This command reads the built-in set unless a legacy `marks:` is set;
`--pipeline` is what runs the step as the config spells it.
`scripts/check-sentence-join.sh` scores the decisions against
tests/sentence-boundary-cases.json, in both shapes; it needs the model, so it is
run by hand.

`--case` answers only what the capitalised word becomes once the mark is
gone. `NLTagger` and your vocabulary decide that, so no model is loaded and
`scripts/check-sentence-case.sh` runs in CI. See `SentenceJoin`.

## What ParrotFlow makes of an app

```sh
$PF --profile com.openai.codex ChatGPT
$PF --profile com.mitchellh.ghostty Ghostty
```

Prints the four things `AppProfile` decides from an app's identity: whether its
focused element can be believed (`examine`, `screen` or `blind`), where the pill
opens (`ladder` or `window`), whether the visible pane can be read as context,
and which rich pasteboard flavour a paste into it may carry (`plain`, `html` or
`rtf`).

`paste` is `plain` until the app is measured — see
[proposals/formatted-paste.md](proposals/formatted-paste.md) and `--paste-probe`
below. A terminal and a blind app return before the lookup is reached, so
neither can be promoted out of plain by adding a line to a set.

The name is optional and matters only for terminals, which are matched on either
half — one terminal ships under several bundle ids. Blind apps are matched on the
bundle id alone.

`scripts/check-profiles.sh` runs this over `tests/profile-cases.yaml`. It is the
only part of the destination path that can be checked without a screen and a
real app in front, so it runs in CI. It does not check what an app actually does
— that Codex refuses `AXManualAccessibility`, that a ⌘V lands — only that the
classification is what the case file says.

## What kind of word each word is

```sh
$PF --tag "he asked" --lang en
$PF --tag "Sarah a reporté la réunion" --lang fr
```

Prints the tokens a `returns: json` transform is handed as `tokens`: the offset,
the length, the word, its tag and its lemma. The tags come from macOS
`NLTagger` under `.nameTypeOrLexicalClass`, so `Sarah` is a `PersonalName` and
`Postponed` is a `Verb`. That is the one question a stage cannot answer from a
string — whether a capital is the decoder starting a clip or the speaker naming
somebody.

`--lang` matters. `NLTagger` will not guess a language from four words and
returns `Other` for everything without one. In a pipeline the language comes
from the scope; here it falls back to the first configured language.

## Where the input stage cuts a field

```sh
$PF --input-test "the quick brown fox" 4 5 [limit]
```

Takes a field, a caret, how much is selected and a budget. Prints the three
blocks the `input` stage would publish, delimited with `⟪⟫` so their own spaces
are visible. `scripts/check-input.sh` scores it against
`tests/input-cases.txt`. The capture itself needs a real focused field and the
accessibility grant, so it is not faked here — see
[pipelines.md](pipelines.md#input-what-is-already-in-the-field).

## Text insertion, which is the risky path

```sh
$PF --peek 3 [--find <sentinel>]
$PF --edit-test <needle> <replacement> --find <sentinel> [--after 3] [--literal]
$PF --span-test <start> <length> <replacement> --find <sentinel> [--after 3]
$PF --clipboard-test
$PF --span-rule
$PF --paste-probe <plain|markdown|html|rtf|all> [--file <fixture.md>] [--bare] [--show]
```

`--peek` reads the surface the way the app would — the value, the selection, and
then the same thing as `Surface` sees it: the content as one string and the span
as offsets into it. That last block is the one that decides what a write does;
when it and the raw accessibility lines above it disagree, the surface block is
the one that matters.

The `offsets` line says whether the two can disagree at all. An app's value is a
string and its selected range is a number, and nothing guarantees the number
indexes the string — Chromium's does not. Every block boundary appears in the
value as `\n` and is skipped by the offsets, so a caret at the end of a
three-paragraph message reports two characters early:

```
value     96 chars, 3 line(s)
range     location 94, length 0
offsets   asked 62+12, the app answered "es Tuesday m" where the value has "Does Tuesday" — the app's offsets run 2 behind
  span    96+0 — ""
```

`range` is what the app said. `span` is what it meant, measured with
`AXStringForRange` and corrected. When the two differ, everything aimed by
arithmetic on the value — where a rewrite is written, what the `input` stage
reports either side of the caret — was wrong by that much before the
correction.

`--edit-test` performs a real in-place edit after a delay, finding the text by
searching for it. `--span-test` does the same to a character range given
outright, which is how the app itself now works — a caller that knows which
characters it wants changed says so, and nothing searches for anything.

`--find <sentinel>` is **required** for both: without it these write into
whatever happens to be in front, which during a test run is as likely to be a
real window as the scratch one you meant.

`--clipboard-test` needs neither a window nor a sentinel. A paste borrows the
clipboard, so an in-place edit that gets refused arrives at its own fallback
with the count already moved by its own paste — this checks that the fallback
writes anyway, that it still refuses once somebody else has copied, and that the
restore queued behind the paste does not land on the rewrite. Your clipboard is
saved and put back.

`--paste-probe` answers a different question: which pasteboard flavour each app
accepts. A pasteboard item can carry `public.html`, `public.rtf` and plain text
at once and the receiving app picks, and nothing in this repository can say
which. So this puts one fixture on the clipboard and stops. You press ⌘V
yourself, which keeps the test about the flavour and not about the event tap.

It renders through `Markup`, which is what `TextInserter` writes with. One
registry, two callers, so what you score here is what the app will get.

The fixture exercises seven things in one paste — bold, italic, code, bullet,
nested bullet, numbered list, link — and a link counts twice: the words it was
written on, and the URL behind them. `--file` swaps in your own Markdown and
refuses to run without a path, rather than falling back to the fixture and
scoring a document you did not ask for. `--show` prints the Markdown, the plain
text and the HTML.

**Run `all` first.** It puts HTML and RTF on one item, which is the shape a
shipping paste has, so an app that keeps everything under it is finished and
needs no entry. A single flavour is the follow-up, for an app that scored badly,
to find out which one to withhold.

Plain text rides along with every flavour, because a rich flavour alone is not a
shape anything puts on a real clipboard — a clipboard manager reads it as empty,
and a paste that lands as plain looks the same as a paste that did not land.
`--bare` withholds it, to ask whether an app *could* have taken the rich flavour
or only preferred not to.

`--bare` works for `html` and not for `rtf`. Setting `public.rtf` on an item
makes AppKit derive the plain-text types from it, so RTF is never offered alone
and that question cannot be asked of it. The command says which case it is in.

Unlike `--clipboard-test`, this does **not** put your clipboard back. The
payload has to survive for you to paste it.

The matrix it exists to fill is in
[proposals/formatted-paste.md](proposals/formatted-paste.md).

`--span-rule` needs nothing at all. It scores the range a rewrite is turned into
before any app sees it: the smallest range is often one no paste can carry — an
insertion is a caret with nothing selected, a deletion pastes an empty string,
and a trailing space is Slack's to trim — so the span grows until it covers a
real character and neither end of the replacement is whitespace.

## Looking at the floating surfaces

```sh
$PF --panels preview 20   # put one surface on screen and leave it there
$PF --panels sequence 40  # run a whole dictation's worth of states, on a loop
$PF --panel-sheet s.png   # draw every surface into one PNG, light beside dark
```

`--panels` takes `pill`, `notice`, `caution`, `failure`, `thinking`, `offer`,
`confidence`, `learn`, `learn-long`, `selector`, `selector-long`,
`selector-two`, `vocabulary`, `punctuation`, `rule`, `dictation`, `preview`,
`microphone`, `keyboard`, `update`, `setup`, `launch` or `sequence`.
`--panel-sheet` draws all of
them at once, which is where drift between them shows up.

`confidence` is the same offer with `feedback.confidence` on: the sentence
above the chips, each word coloured by how sure the decoder was of it, and the
decoder's score for the whole utterance under it, on bands of its own. It is
the tallest pill there is — four rows when it also warns.

The sheet carries two more: the warning on its own, an amber pill with one
line, which is what `low_confidence` draws with the colours off and what most
people will ever see of this; and the same pill in scarlet after it has held a
Return. Those two have to read as one escalation rather than two moods, which
is a thing you can only see side by side. See
[configuration.md](configuration.md#low_confidence--when-the-words-may-not-be-your-words).

`microphone` is the Bluetooth notice, with a made-up device name. It is the one
surface with something to click besides the offer: *Why* opens the reasons and
resizes the panel, *Got it* dismisses it. The sheet draws it both ways.

`selector` is the pill for a place the vocabulary step could not settle. The
sentence is written once and the two options stand one above the other, with the
prose running through the middle of the stack. Nothing is marked: a click on
either option is the answer. `selector-long` is the same one place in a sentence
the window has to cut at both ends.

`selector-two` is a sentence with two open places, which is two questions. The
pill asks about the first; the answer is written into the words, and the pill
comes back with the second, counted "2 of 2" beside the question. The last
answer prints the sentence it would type.

A real dictation raises the same pill whenever the vocabulary gates leave a
place open — see [transcription.md](transcription.md). What the answer does to
the words is `--selector`, below.

All three wait six seconds before the pill comes up, then read the caret and
hang the panel off it, the way the app aims at the press. Click into a document
during those six seconds. When the app in front gives no caret the preview falls
to its window's bottom edge, and with no window either to a line drawn in the
middle of the screen; the log says which rung answered.

`offer` is the one state that takes the mouse — hover a chip to light it, click
one to print which was chosen. Every other state lets clicks through, so the
pill is never a hole in your screen while you are dictating.

It is also the one state that fades. It stands at full strength for four
seconds and thins out over the next two, the same as in the app, so it leaves
on its own.
Put the pointer on it and the fading stops, which is both what the app does and
how you keep it on screen for as long as you want to look at it.

`setup` is the first-run window, on the one screen the walk ends on. This
process fetches nothing, so it runs on a sample registry whose percentage
climbs — which is the part of that screen a still cannot show. The sheet draws
the same screen in its four states: *Almost ready*, *Ready*, *Something was
switched off*, *Something did not arrive* for each of the two models a
dictation waits on, and the same screen after eSpeak NG was skipped. The title
is the state, so those are the thing to compare. The alert *Done* raises when
eSpeak NG is missing is a sheet on the window and cannot be drawn here.

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
scripts/check-keyed.sh             scripts/check-dates.sh
scripts/check-routing.sh           scripts/check-wake.sh
scripts/check-split.sh             scripts/check-grammar.sh
scripts/check-inplace.sh           examples/transforms/numbers/score.py
scripts/check-default-config.sh    scripts/check-transform-folders.sh
scripts/check-eval.sh              # every case set, scored
scripts/check-compose.sh           # what a prompt says once the scope is in it
scripts/check-context.sh           # what the context stage publishes for a screen
scripts/check-input.sh             # where the input stage cuts a field, and the caret
scripts/check-pipeline-config.sh   # which pipeline a config resolves to, and what is refused
scripts/check-join.sh              # fitting a clip to the text either side of the caret
scripts/check-span.sh              # a composer-shaped page, or Slack, or Outlook
scripts/probe-offsets.sh           # measures whether an app's offsets index its own value
scripts/check-vocabulary-config.sh # what vocabulary.yaml adds up to, old keys included
scripts/check-possessive.sh        # whether a possessive survives a substitution
scripts/check-spells-rule.sh       # a spelling lesson keeps the word it is teaching
scripts/check-suggest.sh           # which words the correction panel proposes
scripts/check-no-voice.sh          # nothing in git is one person's voice
scripts/check-audio-recovery.sh    # a microphone that changes leaves a usable engine
scripts/check-profiles.sh          # which app gets examined, named, or read for context
scripts/check-clipboard.sh         # when a rewrite may go to the clipboard, and stay there
scripts/check-span-rule.sh         # which range a rewrite is written as, before any app sees it
scripts/check-bug-report.sh        # what a bug report carries, and that it carries no home path
scripts/check-slot-tokenizer.sh    # the slot tokenizer against HuggingFace's own
scripts/check-sentence-probe.sh    # the three readings of a boundary (needs the model)
scripts/check-sentence-window.sh   # the window a boundary is read over, against hand-written cases
scripts/check-slot-gate.sh         # where a name proposal is routed (needs the model)
scripts/check-slot-gap.sh          # what the slot says about a rewrite (needs both models)
scripts/check-sentence-case.sh     # the capital after a mark the join removes
scripts/check-invented-tail.sh     # the endings the decoder wrote over silence
scripts/check-sentence-join.sh     # which sentence marks the join removes (needs the model)
scripts/check-selector.sh          # where an open place lands, and what an answer writes

PF_VIEWPORT=Ghostty scripts/check-inplace.sh   # the same set, in another terminal
$PF --peek 3 --via-copy                        # what Select All + Copy hands back

scripts/validate-prompt.py gemma4:e4b        # spelling + French correction sets
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
tail -1 ~/.config/parrotflow/recordings/trace.jsonl | jq .
```

One JSON object per line, appended and never rotated, beside the clips it
describes. It holds what the decoder actually returned before anything touched
it — the raw text, its confidence, and **every word with its start, end and
confidence** — plus the speech gate's segment boundaries and its own cost, one
row per decode arm, then each pipeline stage with its sub-steps, what it
changed and what it cost in seconds, and finally the text that was delivered.

`v: 3` replaced a stage's `before` and `after` with `edits` — what it changed,
in the coordinates of the text it was handed. Applying every stage's edits in
order to `asr.text` gives `final`, which is the one thing that ties the stage
list to the two ends. Older lines are `v: 2` and were never converted: nothing
in 3 is derivable from 2 except the edits themselves. `wav` joins a line to its recording; `source` is
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

A note on what is **not** here. `lang` is ParrotFlow's own verdict, the one a
`when: language == "fr"` step reads; Parakeet reports no language of its own,
so there is nothing else to log. `app` carries the name and the bundle id and deliberately
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
cd ~/.config/parrotflow/recordings

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

# A dictation that vanished whole: the gate heard speech and the decoder wrote
# nothing at all. Distinct from the query above, which needs words to measure a
# short ending against. 59 of 16,288 records over three weeks, and the reason
# `silenceRetryPads` exists — see Transcriber.swift.
jq -r 'select(((.asr.text // "") | length) == 0 and (.vad.segments|length > 0)) |
       [.wav, .vad.speech, .vad.total] | @tsv' trace.jsonl

# How much of a dictation is spoken before the microphone is recording.
# `capture.first_sample` is seconds from the key going down; `capture.engine`
# is the part of it spent getting the audio graph running. Live dictations
# only — a clip replayed from disk was never pressed for.
jq -r 'select(.capture.first_sample) |
       [.wav, .capture.engine, .capture.first_sample] | @tsv' trace.jsonl

# Which arm decoded what you heard, and what the losers cost.
jq -r 'select(.decodes) | .decodes[] | [.arm, .seconds, .reached, .taken] | @tsv' trace.jsonl

# Where a stage's time really goes. `vocabulary` is one number covering an
# exact pass, a near-miss pass, a phoneme pass and two gates.
jq -r '.stages[]? | .name as $s | (.parts // [])[] |
       [$s, .name, .seconds, .note] | @tsv' trace.jsonl | sort -k3 -rn | head

# Every word a stage changed, and to what.
jq -r '.stages[]? | .name as $s | (.edits // [])[] |
       [$s, .was, .now] | @tsv' trace.jsonl

# Press to text, end to end. `capture.at` is the key going down, to the
# millisecond; `at` is when the pipeline finished and only to the second.
# `.stages[]?` and a default: a clip the gate refused has `capture.at` and no
# stages at all, and `add` over nothing is null.
jq -r 'select(.capture.at) |
       [.capture.stopped, .vad.seconds, .asr.processing,
        ([.stages[]?.seconds // 0] | add // 0)] | @tsv' trace.jsonl

# What each stage really costs on your own sentences.
jq -r '.stages[]? | select(.seconds) | [.name, .seconds] | @tsv' trace.jsonl |
  awk '{n[$1]++; s[$1]+=$2} END {for (k in n) printf "%-28s %6.3fs  ×%d\n", k, s[k]/n[k], n[k]}' |
  sort -k2 -rn

# Where the vocabulary stage's time goes. It has two halves that call a model
# and the stage's own `seconds` covers both: `sound_ms` is the sound pass
# asking the G2P model for pronunciations, `gate_ms` is the word lists, the
# slot and the sentence gate deciding. A dictation past a second here is
# almost always one of the two, and this says which.
jq -r '.stages[]? | select(.name == "vocabulary" and .vars.gate_ms) |
       [.seconds, .vars.sound_ms, .vars.gate_ms, .vars.slots] | @tsv' trace.jsonl |
  sort -rn | head -20

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

## The timeline

`trace.jsonl` says what each stage cost. It cannot say what the *decoder* cost,
because only the winning arm is recorded, and it has no zero — `at` is written
when the pipeline ended, to the second. A timeline has both.

On by default, and rotating at 64 MB — `logging.spans: false` turns it off.

One line per dictation in `spans.jsonl`, beside `trace.jsonl`. Each line is a
flat list of spans threaded by `parent`, measured in seconds from `t0` — the
key coming *up* for something you spoke, and the start of the run for a
`--transcribe` replay.

Zero is the key going up, not going down. Holding a key for fifteen seconds is
not work the app did, and drawn to scale it squashes the second that is. What
the press cost — the wait for the engine, the wait for the first sample, how
long you held it — is in `capture` on the `trace.jsonl` line, which is where a
number belongs when it is not a span.

```sh
# what the last dictation spent its time on, longest first
jq -r '.spans[] | [.dur, .kind, .name, .note] | @tsv' spans.jsonl |
  tail -40 | sort -rn | head

# every decode of the same clip, including the arms that lost
jq -r 'select(.source=="live") | .spans[] | select(.kind=="decode") |
       [.name, .dur, .note] | @tsv' spans.jsonl
```

A span is wall-clock time the app spent. Word timings and speech segments are
positions *in the audio* — they look the same and mean nothing alike, so they
stay in `trace.jsonl` and never become spans.

### Reading it

```sh
ParrotFlow --trace-view              # the last live dictation, on stdout
ParrotFlow --trace-view clip.wav     # a particular one
ParrotFlow --trace-view --redacted   # nothing anybody said in it
ParrotFlow --trace-view --perfetto   # a file to drag onto ui.perfetto.dev
```

```
2026-09-07T14:19:23.206Z   Ghostty   0.797s

  gate                            0.037s  ██                              2.50s of speech
  decode pass 1                   0.190s    ██████████                    reached 6.08s
  decode pass 2                   0.292s    ████████████████              500ms pad, reached 8.40s
  decode pass 3                   0.241s    █████████████                 1000ms pad, reached 9.36s
  vocabulary                      0.245s                    █████████████ Gwen -> Qwen, sarah -> Sarah
    sound                         0.243s                    █████████████ 0 of 80 over the floor
  transform punctuation           0.072s                                  ███  dot -> .
```

Three decodes of the same clip inside a fifth of a second, and a phoneme pass
that took more than the decode and matched nothing. Both are invisible in
`trace.jsonl`, which keeps one figure for the winning arm and one for the whole
stage.

A stage that changed the text says what it changed, in words. A side that is
empty renders as `""`, so `um -> ""` is a deletion and `"" -> really` an
insertion. A stage that moved only whitespace says `spacing`, which is what
`join` usually did. Both halves are capped: a run over six words reads as
`7 words`, and the whole note stops at 56 characters, because a row that wraps
is a row nobody reads. The exact character offsets stay in `trace.jsonl`, where
`edits` keeps them — see `--trace-edits`. `--redacted` drops every note, so a
timeline in a bug report carries none of it.

From a terminal it goes to stdout, so it pipes and it **diffs** — two of these
through `diff` answer "did that change make it slower", which no chart does.

Run from a transform, where there is no terminal, it writes a file and opens it.
The file goes to the temporary directory, named after the clip:
`trace-2026-09-07T16-36-41-18F52ACD.txt`. Named, so a second press opens a new
document instead of rewriting one your editor already holds — an editor shows
you the buffer it loaded, so a fixed name means reading the previous dictation
and believing it is this one. Temporary, because this is a view and not a
record: `spans.jsonl` keeps the timeline, and the system clears these out.

Each decode arm is a row of its own because they overlap: they are three decodes
of one clip running at once, and anything that stacked them would be drawing
something that did not happen.

**`--redacted` is what makes one safe to send.** Timings survive redaction
perfectly and text does not, so it drops the transcript, the app name and every
note, and keeps the shape: a timeline with no words in it still shows that the
phoneme pass took 817 ms. `--bug-report` carries a wordless one already.

**`--perfetto`** writes Chrome Trace Event JSON, beside the text one and named
the same way, to drag onto
<https://ui.perfetto.dev>, for a long dictation where you want to zoom.
Perfetto parses it in the browser and uploads nothing — but the page itself
loads from Google, and the file holds what you said unless you passed
`--redacted`. There is no deep link: `?url=` is HTTPS-only, an `https` page
will not fetch from `http://127.0.0.1` whatever the localhost exemption does
elsewhere, and the alternative is putting your dictations on a public host to
look at a chart.

### A chip that opens it

Not shipped, because a chip claims its letter from every dictation for the nine
seconds the offer is up. Paste it into your own config if you want it:

`config.example.yaml` ships this entry with `offer:` and `key:` commented out,
so a fresh install can ask for a trace out loud and gains no chip:

```yaml
transforms:
  - name: trace
    description: open this dictation's trace
    display: Opening the trace
    say: [timeline, timings, why that was slow]
    # offer: true
    # key: t
    done: Trace opened
    command: sh -c 'said=$(cat); app=/Applications/ParrotFlow.app;
      [ -x "$app/Contents/MacOS/ParrotFlow" ] || app=/Applications/ParrotFlowDev.app;
      "$app/Contents/MacOS/ParrotFlow" --trace-view >/dev/null; printf %s "$said"'
```

A full path, because `ParrotFlow` is not on `PATH`, and chosen at run time
because the dev build is at `/Applications/ParrotFlowDev.app/...` and reads its
own `spans.jsonl`. Writing one path literally also makes `--check-config` report
an error on a machine that has only the other build, and that is a check
failure, not a warning.

**Whatever a `command:` transform prints becomes the new transcript.** That is
why `--trace-view` writes everything a person reads to stderr and hands stdin
straight back on stdout: the sentence returns unchanged, so
`finishOfferedTransform` writes nothing to the field and `done:` is what the
pill says. A version before 2026-09-07 printed to stdout instead, and pressing
the chip on one of those replaces the dictation with a file path. This form is
right against either:

```yaml
    command: sh -c 'said=$(cat); "/Applications/ParrotFlow.app/Contents/MacOS/ParrotFlow"
      --trace-view >/dev/null; printf %s "$said"'
```

`t` collides with "the", "this", "that" — so a dictation starting with one of
those, within the offer window, opens a trace. That is the whole cost: the
command only reads, and the window it opens is a text file. A chip that changed anything would want `x` or `z`, which
nothing starts with.

`done:` is what the pill says afterwards. Without it a transform that leaves
the text alone reports "nothing to change" — true about the sentence, and it
reads as a failure for a transform whose whole job is not to touch it.

### Checking the trace itself

```sh
ParrotFlow --trace-edits    # what a stage recorded replays to what it produced
ParrotFlow --trace-spans    # spans survive being closed from many tasks at once
```

Both are in `make test`, as `check-trace-edits`. The first is the one that
matters: a stage stores what it changed rather than both versions of the
sentence, so the corpus is only worth anything if applying the edits in order
to `asr.text` gives `final`. It is checked on written cases and several
thousand fuzzed pairs, because the pairs that break a diff are never the ones
anybody thinks to write down.

### Watching it live

```sh
scripts/watch.py                       # follow live dictations
scripts/watch.py --last 10             # the last 10, then follow
scripts/watch.py --stage disfluency    # only where that stage changed something
scripts/watch.py --all                 # include cli sweeps and evals
```

Tails `trace.jsonl` and prints one block per dictation: the decoder's text, then
each stage as a **word-level diff** with what it cost and what it published. It
calls no model and reads no log — the trace record turns up complete, and a
dictation is one to three seconds end to end, so there is no middle to
reassemble.

Two things it does that are not obvious. It filters on `source: live`, because
the Dev trace holds roughly three `cli` records for every one you spoke and a
check script running in another terminal otherwise floods the output. And it
parses only lines that arrived with a newline: records reach 17.8 KB, which is
past the size where a single append is reliably atomic, so a read can land
mid-record.

`--archive <dir>` points it at another variant's directory.

`--transcribe` writes a trace line too, which is what makes it worth having:
change a table, re-run the clips, and both sets of numbers sit in one file
joined to the same audio.

```sh
for f in ~/.config/parrotflow/recordings/*.wav; do ParrotFlow --transcribe "$f" >/dev/null; done
```
