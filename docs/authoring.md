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
1. write the cases            tests/<thing>-cases.yaml
2. score what exists now      scripts/check-<thing>.sh        <- the baseline
3. change one thing
4. score again                same command, same set
5. keep it only if the number went up and no category collapsed
```

Steps 1 and 2 are not optional overhead. Tuning by eye fixes the example in
front of you and silently breaks one you are not looking at — which is why
every rewrite in this repo ships with a set, and why the sets keep their
failures in rather than dropping them to make a number look better.

## Recipe: a substitution

For a name that comes out wrong, nothing needs writing — say
`"hey parrot"` and fill in the panel, or:

```sh
$PF --learn "super base" Supabase
```

For a pattern, add it to `transcription.replacements` and check it:

```yaml
replacements:
  Supabase: [super base, superbees]
  "": ['/\b(?:u+m+|erm+)\b/']          # empty target deletes
  '$1 ticket': ['/\bticket number (\d+)\b/']
```

```sh
$PF --replace "we deployed to super base and um it worked"
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

transcription:
  pipelines:
    default:
      - replacements
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

- A relative path is looked for in **the transform's own folder** first, and
  beside `config.yaml` second. The folder is the working directory, so
  `shout.py` opens `volumes.json` by that name and the folder is a thing you
  can copy whole. A bare name that is not a file in either place (`sed`, `tr`)
  is looked up on PATH, so a one-liner with arguments works.
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

## Recipe: a language

`pipelines:` takes a key per language, and a language's own list wins over
`default:`:

```yaml
pipelines:
  default: [replacements, fuzzy, numbers]
  fr:      [replacements, numbers]
```

A key that is neither `default` nor one of your `languages:` is reported by
`--check-config` rather than silently never running. Test one without changing
your machine's setup:

```sh
$PF --pipeline my-test.yaml "on en a vingt et un" --lang fr
```

## Writing the case set

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
- **Keep the residue in, failing.** `examples/transforms/dotted/cases.txt` scores 54/54 and
  carries two more it cannot do. A set that reaches 100% by dropping what it
  cannot do is worse than a number.
- **Write the contract at the top of the file**, in prose: what counts as a
  case for this feature and what is deliberately out of scope. It is the thing
  you will disagree with yourself about in a week.
- **Group by category**, so a regression reads as "all the two-word ones broke"
  rather than an unattributable drop of four points.

The sets that exist: `spelling` (62) and `french` (45) for corrections,
`numbers` (97), `routing` (45), `dotted` (56), `code-identifier` (75),
`grammar` (17), `wake` (25), `split` (14), `generic`, `dates`, `inplace`,
`pipeline`, `replacement`. Each has a runner in `scripts/`.

## Before you call it done

- [ ] `--check-config` is clean, and names every `command:` transform you added
- [ ] the check script for what you touched still passes, and you know its
      number before and after
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
- [configuration.md](configuration.md) — where `transforms:` and `pipelines:`
  sit in the file
- `.claude/skills/prompt-iteration/SKILL.md` — deciding between a prompt, a
  regex and a script by measuring instead of by eye
