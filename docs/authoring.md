# Writing a transform, and proving it works

How to add a rewrite to ParrotFlow — a substitution, a prompt, or a program of
your own — and how to know you improved it rather than moved the failure.

Written to be followed start to finish, by a person or by an agent. The
reference for what the pieces mean is [pipelines.md](pipelines.md); this is the
procedure.

## The one decision that matters

Before writing a prompt, decide what should be doing the job at all:

| Body | Costs | Right when |
|---|---|---|
| `replace:` | nothing (0.035 s for a whole pipeline) | the answer is already in the text, marked by a pattern you can write |
| `command:` | one process start (~30 ms `python3`, ~5 ms shell) | the rule is real but needs code — casing, a lookup table, anything with a branch |
| `prompt:` | ~1.5 s warm, 6.7 s cold | only judgement will do — which words the speaker meant, what an instruction is asking for |

Getting this wrong is the expensive mistake, and it is usually made in the
direction of the model. Two measurements from this repo:

- Asked to **rewrite** a sentence containing a spoken identifier, the model
  scores 68% and fails expensively — capitalising "python", adding articles,
  translating French names. Asked only to **extract** which words are a name,
  and leaving the casing to a table in a script, the same model gets 8/8 on the
  cases rules cannot see. Split the job: the model judges, code decides.
- Told "Phillip with one l", models answered "Phill" and "Philp". The described
  change is applied by code for that reason; the model's only job is finding
  which word was meant.

`.claude/skills/prompt-iteration/SKILL.md` is the long form of this argument,
including how to build a validation set that can tell you which one you need.

## The loop

```
1. write the cases            transforms/<name>/cases.yaml
2. score what exists now      $PF --eval <name>               <- the baseline
3. change one thing
4. score again                same command, same set
5. keep it only if the number went up and no category collapsed
```

Steps 1 and 2 are not optional overhead. Tuning by eye fixes the example in
front of you and silently breaks one you are not looking at — which is why
every rewrite in this repo ships with a set, and why the sets keep their
failures in rather than dropping them to make a number look better.

`--eval` is that loop in the binary, against your own config, so it is
available to anyone who installed the app and not only to this repository. It
runs the transform your config actually names — not a copy of it — and always
reports the must-not-change half and the per-probe grid separately. The full
format and every optional key is in [cli.md](cli.md#scoring-a-transform---eval).

The sets in this repository that predate it still have bespoke runners in
`scripts/`, and some of them always will: a custom gate — "a handle belonging
to someone who was not named must be zero" — is not something a generic runner
can express, and should not try to.

## Recipe: a substitution

For a name that comes out wrong, nothing needs writing — say
`"hey parrot"` and fill in the panel, or:

```sh
$PF --learn "super base" Supabase
```

For a pattern or a deletion, put it in a transform's `replace:` and check
it:

```yaml
transforms:
  - name: tidy
    description: delete hesitations and shorten ticket numbers
    replace:
      "": ['/\b(?:u+m+|erm+)\b/']          # empty target deletes
      '$1 ticket': ['/\bticket number (\d+)\b/']
```

```sh
$PF --replace "ticket number 42 and um it worked"
scripts/check-replacements.sh
```

## Recipe: a named table, scoped to an app

A table gets a name when it has to run somewhere specific, or twice with
different output. That is the whole reason `transforms:` exists.

```yaml
transforms:
  - name: backticks
    description: wrap dotted paths in backticks, for chat
    replace:
      '`$1`': ['/\b([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)+)/']

pipeline:
  - vocabulary
  - transform: backticks
    app: /slack|discord/
```

```sh
$PF --pipeline my-test.yaml "read config.port" --app Slack     # should wrap
$PF --pipeline my-test.yaml "read config.port" --app Ghostty   # should not
```

Write the pipeline you are testing into its own YAML file rather than editing
your real config: `--pipeline` takes the file, so the test states its own setup
and does not inherit this machine's. `tests/pipelines/` holds the ones the
check scripts use.

A fixture has no `transcription:` level. `pipeline:` and `transforms:` sit at
the top of the file, and the list under `pipeline:` is written exactly as it is
in a config.

**There is no `not_app:`.** Exclusion is a negative lookahead —
`/^(?!.*(term|ghostty))/` — and the `^` anchor is not optional. Unanchored it
matches one character into the name it was meant to exclude, and the stage runs
everywhere. `--check-config` refuses it rather than letting that ship.

## Recipe: a prompt

```yaml
transforms:
  - name: hesitation
    description: strip filler words from dictated speech
    prompt: |
      Remove filler words. Change nothing else.
      Return only the text.
```

```sh
$PF --prompt hesitation "strip the filler" "so like, we should genre ship it"
$PF --route "hey parrot, clean up the ums"      # does the description match?
```

Two things about the `description` that are easy to miss:

- **It is not a comment.** It is what the router matches spoken words against,
  so write it the way someone would say it. `--route` is how you find out it is
  too vague before a user does.
- **The whole instruction reaches the prompt.** One entry therefore covers
  "format those dates ISO" and "format those dates with slashes" — you do not
  need an entry per phrasing.

Then decide whether it belongs in a pipeline at all. A prompt reached by voice
runs when asked. A prompt in a pipeline runs on **every** transcript that
matches its conditions, at ~1.5 s each, and rewrites your words without you
asking — so it wants a `when:` narrow enough to earn it:

```yaml
- transform: hesitation
  when: /\b(genre|du coup|en fait|like|basically)\b/
```

`when:` and `unless:` read the text *as it stands at that point*, after the
stages above — so a cheap stage can make an expensive one unnecessary rather
than merely earlier.

## Recipe: a program

The transcript arrives on **stdin** and comes back on **stdout**. That is the
whole contract.

```yaml
transforms:
  - name: shout
    description: everything in capitals
    command: shout.py
    timeout_seconds: 2
```

```
~/.config/parrotflow/transforms/shout/
  shout.py        # the entry point, named after the transform
  cases.yaml      # the set, right there
  volumes.json    # whatever data it owns
```

- A relative path is looked for in **the transform's own folder**, and nowhere
  else. That folder is the working directory, so `shout.py` opens
  `volumes.json` by that name and the folder is a thing you can copy whole. A
  bare name that is not a file there (`sed`, `tr`) is looked up on PATH, so a
  one-liner with arguments works; anything else is reported by
  `--check-config` rather than left to fail once per transcript.
- The script is run directly, so its **shebang** picks the interpreter, and it
  needs the **execute bit** — a script that is there but not `chmod +x` is the
  likeliest thing to be wrong with a `command:` transform. Both the log and
  `--check-config` name that case as itself rather than as "command not found".
- Non-zero exit, no output, or over `timeout_seconds` leaves the transcript
  exactly as it arrived, and says so in the log. A script you are halfway
  through writing is an ordinary state to be in.
- Two seconds is right for a script and wrong for one that asks a model. A
  command ending in `--model something` wants `timeout_seconds: 12` beside it.

`examples/transforms/code_identifiers/code_identifiers.py` is the shipped one, and the best template: rules
first, model behind a flag, a table of language conventions that is edited
rather than prompted.

**Remember that this makes `config.yaml` execute code.** Nothing else in that
file does. `--check-config` names every `command:` transform out loud, every
time — a config that runs something you have forgotten about, or that arrived
in a config you copied from somewhere, should not be able to stay quiet.

## Recipe: a program that reports what it did

Text in, text out cannot say anything except the text — so a stage that
*looked* and found nothing is indistinguishable from one that ran and changed
nothing, and the stage below has to re-derive the judgement from the same
words. Adding `returns: json` swaps the plumbing for one that carries
variables. See [pipelines.md](pipelines.md#variables) for what a condition can
then do with them.

```yaml
  - name: code_identifiers
    description: spoken names as identifiers
    command: code_identifiers.py
    returns: json
```

**In**, on stdin:

```json
{ "text": "a python function called max retries",
  "ctx": { "app": "Ghostty", "bundle_id": "com.mitchellh.ghostty",
           "language": "en",
           "vars": { "asr": { "confidence": 0.91, "duration": 4.2 },
                     "vocabulary": { "ran": true, "count": 1,
                                       "changed": true, "ms": 0.4 } } },
  "tokens": [ { "at": 2, "len": 6, "text": "python",
                "tag": "Noun", "lemma": "python" } ],
  "aligned": false,
  "trace": { "wav": "…", "source": "live", "lang": "en",
             "asr": { "text": "…", "confidence": 0.91, "words": [] },
             "vad": { "speech": 3.1, "total": 4.2, "segments": [] },
             "stages": [] } }
```

- **`tokens`** is every word of `text`, tagged by macOS `NLTagger` under
  `.nameTypeOrLexicalClass`: `Noun`, `Verb`, `PersonalName`, `PlaceName`,
  `Determiner` and so on, plus the lemma. It answers the one question a script
  cannot answer from a string — whether a capital is the decoder starting a clip
  or the speaker naming somebody. Recomputed per stage against the text that
  stage was handed, so `at` and `len` are always offsets into `text`. It costs
  0.29 ms for a sentence and 0.97 ms for two hundred words, so it is not
  conditional. `--tag "<text>" --lang en` prints the same thing.
- **`trace`** is what the run has gathered so far: the decoder's own text with
  per-word timings and confidences, the speech segments, and the stages that
  already ran with their `before`, `after` and vars. It is absent under
  `--pipeline`, which has no trace collector, so read it defensively.
- **`aligned`** says whether `text` is still the decoder's own, and so whether
  the word offsets in `trace.asr.words` line up with it. It is false as soon as
  any stage rewrites. Check it before using a word offset: acting on a stale one
  fails silently.

**Out**, on stdout — and only what this stage contributes:

```json
{ "text": "a python function called max_retries",
  "vars": { "count": 1 } }
```

- **Both keys are optional.** No `text` means "I looked and left the sentence
  alone", which is not the same as echoing the input back and is not a failure.
  No `vars` means the stage published nothing this time.
- **Never echo the context back.** You cannot erase another stage's variables
  by leaving them out, because carrying them is the pipeline's job. The reply
  is a contribution, not a replacement.
- Values are strings, numbers or booleans. One level, no nesting.
- Print something that is not JSON and the transcript comes through untouched
  with `<stage>.ok` set false, and the log says what was printed. That is a
  script bug rather than a config one, so `--check-config` cannot catch it.

The app sets **`PARROTFLOW_PROTOCOL=json`** in the environment when — and only
when — the transform declares `returns: json`. Read that rather than taking a
flag, so `returns:` stays the single declaration and the script is still
runnable by hand:

```python
structured = os.environ.get("PARROTFLOW_PROTOCOL") == "json"
raw = sys.stdin.read()
text = json.loads(raw)["text"] if structured else raw.rstrip("\n")
...
if structured:
    sys.stdout.write(json.dumps({"text": out, "vars": {"count": n}}))
else:
    sys.stdout.write(out)
```

That branch is worth keeping. Every harness in `scripts/` pipes plain text, and
so will you the first time a stage misbehaves.

> **Upgrading an existing transform.** A transform folder you own —
> `transforms/<name>/` — is never overwritten, so adding `returns: json` to a
> config whose script predates it means the script prints bare text, the app
> cannot read it, and the stage silently stops doing anything. Edit the script
> first, then the config. `--pipeline <fixture> "<text>" --vars` is how you
> check, before it matters. `transforms/examples/` is different: it is
> refreshed on every launch, so the shipped scripts there are always current.

## Recipe: a language

There is one pipeline, and it runs whatever the language. A step that belongs
to one language says so on its own line:

```yaml
languages: [en, fr]
pipeline:
  - vocabulary
  - numbers
  - transform: hesitation
    when: language == "fr"
```

`language` holds one of your `languages:`, detected from the transcript. Read
it like any other variable, so a step can ask for a language and something else
at once — `when: language == "fr" && asr.confidence < 0.7`.

Test it without changing your machine's setup. Detection needs two or more
`languages:` in the fixture, and `--vars` prints what it decided:

```sh
$PF --pipeline my-test.yaml "on en a vingt et un" --vars
```

A skipped step names the values that skipped it, so a step that did not run
tells you which language it saw.

## Writing the case set

It goes in the transform's own folder, called `cases.yaml`, which is where
`--eval <name>` looks:

```yaml
# The contract, in prose — see below.
cases:
  - probe: language-said
    input:  add a python function called max retries
    expect: add a python function called max_retries
  - probe: prose
    input:  we should discuss the retry count tomorrow    # no expect: —
                                                          # it must not change
```

Twenty to forty cases. Fewer and you cannot tell a real change from noise; more
and you stop running it.

- **Use real inputs.** These come out of speech recognition, so the test inputs
  must be mangled the way speech recognition mangles them. A set built from
  tidy sentences measures nothing, because tidy sentences were never the
  problem. `trace.jsonl` beside your recordings is where they are: every
  dictation you have given, with the decoder's own confidence on each word, so
  the ones it struggled with can be pulled out rather than invented — see
  [cli.md](cli.md#the-trace).
- **Include negatives — a lot of them.** Roughly one in five, and closer to
  half for anything that runs on every transcript rather than on demand. Models
  are strongly biased toward producing output, and a confident wrong answer
  beats a refusal on any set without negatives. `examples/transforms/code_identifiers/cases.yaml`
  is 32 of 75 cases that must come back untouched, and that half is the one that
  catches regressions.
- **Keep the residue in, failing.** `examples/transforms/dotted/cases.txt` scores 73/73 and
  carries three more it cannot do. A set that reaches 100% by dropping what it
  cannot do is worse than a number.
- **Write the contract at the top of the file**, in prose: what counts as a
  case for this feature and what is deliberately out of scope. It is the thing
  you will disagree with yourself about in a week.
- **Group by `probe:`**, so a regression reads as "all the two-word ones broke"
  rather than an unattributable drop of four points. `--eval` prints the grid.
- **Run the control.** If the job can be done without a model, `control:` in
  the case file scores that too, on the same cases. It is the only thing that
  answers "is the model earning its place", and twice in this repo the answer
  was no.
- **State the language with `lang:`** on any case that is not in your first
  one. Without it the pipeline detects, and detection is unreliable at the
  length a case is — "C'est vraiment fantastique." comes back `en`. A French
  case scored under English rules passes for the wrong reason.

The sets that exist. A transform's set lives in its folder; the ones belonging
to a built-in stage or to the router have nowhere else to be and stay in
`tests/`:

| Where | Sets |
|---|---|
| `examples/transforms/<name>/` | `code_identifiers` (78), `dotted` (84), `punctuation` (57), `grammar` (17), `email` (26), `repetitions` (60), `self_correction` (89) |
| `tests/` | `spelling` (62), `french` (45), `numbers` (97), `routing` (45), `wake` (25), `split` (14), `generic`, `dates`, `inplace`, `pipeline`, `replacement`, `word-gate` (25) |

Each has a runner in `scripts/`; the transform sets can also be scored with
`--eval`. `examples/transforms/` is copied whole into
`~/.config/parrotflow/transforms/examples/`, refreshed on every launch — one
tree, not files kept in sync by hand. See `Config.exampleTransformsDirectory`.

## Before you call it done

- [ ] `--check-config` is clean, names every `command:` transform you added, and
      the resolved path it prints for each is the one you meant
- [ ] `--eval <name>`, or the check script for what you touched, still passes —
      and you know its number before and after, on both halves
- [ ] any stage costing a model call has a `when:`, an `unless:` or an `app:`
- [ ] failure leaves the transcript alone — kill the model, run it again, see
      the sentence come through untouched
- [ ] a new default in `config.example.yaml` is covered by
      `scripts/check-default-config.sh`, which reads the real file rather than a
      fixture

## See also

- [pipelines.md](pipelines.md) — the reference: stages, conditions, apps, the
  ordering constraints, and what each shipped transform costs
- [cli.md](cli.md) — every flag these recipes use
- [configuration.md](configuration.md) — where `transforms:` and `pipeline:`
  sit in the file
- `.claude/skills/prompt-iteration/SKILL.md` — deciding between a prompt, a
  regex and a script by measuring instead of by eye
