# Rewrites: changing what dictation writes

A **transform** says what changes. A **pipeline step** says when it runs.
Defining a transform does nothing until a step names it, or it is put on the
pill, or it is asked for out loud.

## Pick the cheapest tool

| Body | Costs per dictation | Right when |
|---|---|---|
| `replace:` | nothing | the answer is in the text, and a pattern finds it |
| `command:` | one process start: 30–100 ms for Python, ~5 ms for shell | the rule needs code: a lookup, casing, a branch |
| `prompt:` | ~1.5 s warm, ~6.7 s cold | only judgement will do |

Most requests are tables. Reach for a model last. Measured on this app: the same
model scored 68% asked to rewrite a sentence, and 8/8 asked only to say which
words were a name, with a script doing the rest. Split the job: the model
judges, code writes.

A name the recogniser mangles is not a rewrite. It goes in the vocabulary: see
`spoken-commands.md`.

## The three bodies

```yaml
transforms:
  - name: arrow                          # the id a step names
    description: spoken arrow as the → symbol   # matched against spoken commands
    replace:
      "→": ['/\barrow\b(?!\s+function)/']

  - name: ticket_links
    description: ticket numbers as links
    command: ticket_links.py             # transforms/ticket_links/ticket_links.py

  - name: tidy
    description: tidy dictated prose
    display: Tidying                     # shown while it runs
    prompt: |
      Fix grammar and punctuation. Change nothing else. Return only the text.
```

### `replace:`

A map of output to a list of inputs. Checked in order.

- A plain word matches on word boundaries, case-insensitive.
- `/…/` is a regular expression (ICU), case-insensitive. `$1` puts a capture
  back. Quote patterns with single quotes in YAML.
- An empty output `""` deletes the match.
- `{{name}}` is a word list from `lists:`, expanded longest first. Quote every
  list entry: `on`, `no` and `off` are booleans in YAML.
- `replace: {path: table.yaml}` reads the same map from the transform's folder.

### `command:`

The text comes in on stdin and goes out on stdout. That is the contract.

- A bare file name is looked for in `transforms/<name>/` only. That folder is
  also the working directory, so the script opens its own data by bare name.
- A path with a slash, like `built-in/dates/fr.py`, can name any file under
  `transforms/`. That is how the config reaches the shipped scripts.
- A word that is not a file, like `tr` or `sed`, is looked up on `PATH`.
- The first line (`#!/usr/bin/env python3`) picks the interpreter, and the file
  needs `chmod +x`. A missing execute bit is the most common fault.
  `--check-config` names it.
- Non-zero exit, no output, or more than `timeout_seconds` (default 2) leaves
  the text unchanged. A script that calls a model wants `timeout_seconds: 12`.
- `returns: json` sends `{"text": …, "ctx": {"app", "language", "vars"}, "tokens": […]}`
  on stdin and sets `PARROTFLOW_PROTOCOL=json`. Reply `{"text": "…", "vars": {"count": 1}}`.
  Both keys are optional. `vars` become `<name>.count` for later conditions.
  Values are flat strings, numbers or booleans.
- **Tell the user it runs a program.** `--check-config` lists every one.

`assets/transform/` is a starter: a script that reads plain text or JSON, and a
`cases.yaml`. Copy it to `transforms/<name>/`, rename the script to
`<name>.py`, and `chmod +x` it.

### `prompt:`

- `description:` is what spoken commands are matched against. Write it the way
  someone would ask for it.
- `display:` is what the menu bar says while it runs. Write one for a prompt.
- `failed:` is Markdown shown on the pill when it cannot run, such as how to
  install the model.
- `model:` names an entry in `models:`. See `models.md`.
- `prompt: {path: tidy.md}` reads the prompt from the transform's folder.
- `{{context.text}}`, `{{language}}`, `{{app}}` and any published variable can
  appear in a prompt. A name with no value removes its whole paragraph. See
  `context.md`.
- **In a pipeline, it needs a condition.** It rewrites the user's words with no
  preview, on every dictation it matches, at ~1.5 s each.

Markdown a transform returns (a list, bold, a `[link](url)`) arrives formatted
in Slack, the one app measured so far. Every other app gets plain text.

## When it runs

### In the pipeline: every dictation

```yaml
transcription:
  pipeline:
    - transform: fillers
    - transform: dates_en
    - transform: numbers_en
    - transform: money_en
    - transform: disfluency
    - transform: arrow
      app: /terminal|iterm|ghostty|warp/
```

Conditions on a step:

- `app: /…/` matches the app that was in front when the key went down. The app
  name and its bundle id are matched as one string: `Ghostty com.mitchellh.ghostty`.
  There is no `not_app:`. Exclude with an anchored lookahead:
  `app: /^(?!.*(terminal|ghostty))/`. The `^` is required; `--check-config`
  refuses it without.
- `when:` and `unless:` read the text as it is at that step. Between slashes
  it is a regex. Anything else is an expression: `language == "fr"`,
  `numbers_en.count == 0`, `asr.confidence < 0.7`, `!app.matches("slack")`,
  with `&&`, `||`, `!`, `==`, `<`, `contains()`, `startsWith()`, `matches()`.
  `unless` wins over `when`.
- A bare word in `when:` is an error. Write `/genre/`, not `genre`.
- Every step publishes `<name>.ran`, `.ok`, `.changed`, `.ms`. A skipped step
  publishes only `ran = false`, so ask `x.ran && x.ok`.

Terminal app names, for `app:`: Terminal, iTerm2, Ghostty, Warp, WezTerm,
kitty, Alacritty. Check which ones are in `/Applications` (and
`/System/Applications/Utilities` for Terminal) and ask which one they use.

### On the pill: when the user presses a letter

```yaml
  - name: tidy
    offer: true      # a chip on the pill after each dictation
    key: t           # its letter; V is taken by Vocabulary
```

No preview: it rewrites the words just dictated. Good for anything costly or
occasional. The letter is taken from every app for six seconds, so pick one
that rarely starts a word.

### Out loud

Every transform with a `description:` can be reached by "hey parrot, …". See
`spoken-commands.md`. `say: [tidy up, clean it]` adds words the tap-then-hold
path matches.

## Order

- `sentence_repair` and `vocabulary` are not steps. They always run first, in
  that order. `transcription.sentence_repair.enabled: false` or
  `transcription.vocabulary.enabled: false` is the only way to turn one off.
  `sentence_repair` takes out a full stop or question mark a pause put in the
  middle of a sentence. English only.
- Fillers go above the number steps: "two uh two three" must not become "two uh 23".
- Dates go above numbers in every language: a date is made of number words.
- Money goes below numbers: `numbers_en` writes "20 dollars", then `money_en`
  makes it "$20".
- `disfluency` goes below the number steps.
- `--check-config` refuses a condition that reads a step which runs later.

## Adding French

The French scripts ship in `transforms/built-in/`, but the config does not name
them. Add three transforms and three steps:

```yaml
transforms:
  - name: dates_fr
    description: dates et heures dictées en chiffres
    command: built-in/dates/fr.py
    returns: json
    tests: built-in/dates/cases-fr.yaml
  - name: numbers_fr
    description: nombres dictés en chiffres
    command: built-in/numbers/fr.py
    returns: json
    tests: built-in/numbers/cases-fr.yaml
  - name: money_fr
    description: montants dictés avec le symbole de la devise
    command: built-in/money/fr.py
    returns: json
    tests: built-in/money/cases-fr.yaml
```

```yaml
    - transform: dates_en
    - transform: dates_fr
    - transform: numbers_en
    - transform: numbers_fr
    - transform: money_en
    - transform: money_fr
    - transform: disfluency
```

No language condition is needed. Each script only reads its own words, and the
money scripts refuse a transcript detected as the other language. `tests:` is
what makes `"$PF" --eval dates_fr` find its cases.

**Tell the user how `dates_fr` reads a bare hour.** It writes the next time that
hour comes round: at 15:00, "à dix heures" becomes `22h`, and at noon "à 4h"
becomes `16h`. To write the hour as said, add `--no-wall-clock` at the end of
its `command:` line. English writes 12-hour times and adds no pm.

Check: `"$PF" --replace "on se voit le trois mars à dix heures, ça coûte vingt euros"`.

## Shipped transforms

In the default config: `fillers`, `fillers_fr`, `dates_en`, `numbers_en`,
`money_en`, `disfluency` as steps; `grammar` (a prompt, chip `G`) and
`slack_mentions` (a script, chip `S`) on the pill; `github_refs` and `trace`
defined but not in the pipeline.

- `github_refs`: "PR one two three" becomes a link. Replace `OWNER/REPO` in both
  URLs, then add `- transform: github_refs` below `numbers_en`.
- `slack_mentions`: the user fills `ROSTER` in
  `transforms/slack_mentions/slack_mentions.py`. Not in the pipeline on purpose:
  naming someone is not always a request to ping them.
- `disfluency`: four rules for repeats and false starts, and a fifth for "you
  know" that needs a parser. The app installs the parser itself.
- `join` (a script in `built-in/join/join.py`, with `returns: json`): fits the
  start and end of a clip to the text around the cursor. Needs the `input`
  stage above it. See `context.md`.

## Test it

1. Write `transforms/<name>/cases.yaml`: 20 to 40 real sentences, with many
   that must not change. About half, for a step that runs on every dictation.
   Before writing a pattern, list the ordinary phrases that hold the word and
   make them keep cases: "arrow" is also "arrow function", "arrow keys" and
   "narrow".
2. `"$PF" --eval <name>` before the change, and after. Keep the change only if
   both halves held.
3. `"$PF" --replace "<sentence>" --app "<App>"` runs the whole pipeline once.
4. `--check-config` lists the resolved path of every body. When an edit seems to
   do nothing, check that path first.
