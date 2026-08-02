# Pipelines

Everything a finished transcript goes through, in order, per language:

```yaml
transcription:
  pipelines:
    default: [replacements, fuzzy, numbers]
    fr: [replacements, fuzzy, numbers]
```

A language's own list wins over `default`. A key that is neither `default` nor
one of your `languages:` is reported by `--check-config` rather than silently
never running.

Being in a pipeline is the only way a stage runs, which is why a new install is
written with all of them spelled out: turning one off means deleting a line you
can see, not finding a setting you cannot. Delete `pipelines:` entirely and you
get every stage back — a missing section is silence, not a choice. Write
`default: []` and you get none, which is a choice.

## The stages

| Stage | What it does |
|---|---|
| `replacements` | The substitutions in `replacements:` — literal, word-boundary, case-insensitive, or a regex between slashes. |
| `fuzzy` | The same table against renderings you have not taught, so "super bays" reaches Supabase. Only words the spell checker does not know are eligible, which is what keeps "Excel" from becoming "Vercel". Needs `replacements` before it and says so if it does not have one, because on its own it swallows the preceding word. |
| `numbers` | Spoken numbers as digits: "two hundred forty-three" → 243, plus ordinals, decimals, years and spoken digits. English and French, septante/huitante/nonante included, chosen per transcript. A number word on its own stays a word below ten, so "chapter three" and "on est deux" are left alone. |
| `transform` | One entry of `transforms:`, named — see below. The only stage that names something outside itself. |

`numbers` rewrites transcripts that were already correct, so run `--numbers` on
a line to see exactly what it would do before leaving it in.

## Transforms

The three stages above are fixed. A **transform** is one you write, named in
`transforms:` and run with `- transform: <name>`. It has one of three bodies:

```yaml
transforms:
  - name: prose
    description: tidy up dictated prose
    prompt: |
      Fix grammar and punctuation. Return only the text.

  - name: dotted
    description: spoken dotted paths as code
    replace:
      $1.$2: ['/\b(\w+) (?:dot|point) (\w+)\b/']

  - name: identifiers
    description: spoken names as identifiers
    command: identifiers.py
```

`prompt:` asks the local model — about a second, and the reason conditions
exist. `replace:` is a substitution table of its own, in the same shape as
`transcription.replacements`, and costs nothing. `command:` runs a program of
yours, which costs a process start — about 30ms for `python3`, 5ms for a shell
script.

### `command:`, or: the app stops needing new primitives

The transcript arrives on **stdin** and comes back on **stdout**. That is the
whole contract. A command that exits non-zero, says nothing, or takes longer
than two seconds leaves the transcript exactly as it arrived, and says so in
the log — a script you are halfway through writing is an ordinary state to be
in, and a dictation tool cannot answer it by dropping your words.

The script is run **directly**, so its first line picks the interpreter — the
shebang, `#!/usr/bin/env python3` or `#!/bin/bash` or whatever you write it in.
The app never needs to know the language. What it does need is the execute bit:
a shebang does nothing without one, and a script that is there but not
`chmod +x` is the likeliest thing to be wrong with a `command:` transform. Both
the log and `--check-config` name that case as itself rather than as "command
not found", which would send you looking for a file that is sitting right where
you put it.

A relative path is relative to **the file that named it**: `command:
identifiers.py` is the script sitting beside your config.yaml. It runs with
that directory as its working directory, so it can read its neighbours. A bare
name that is not a file there — `sed`, `python3` — is left to the shell to find
on PATH, so a command can be a one-liner with its own arguments:

```yaml
  - name: shout
    description: everything in capitals, for no good reason
    command: tr '[:lower:]' '[:upper:]'
```

This exists because the other two bodies can only do what the app already knows
how to do. `replace:` cannot change the case of what it captured, so spoken
identifiers were going to need a case operator in the substitution engine, and
whatever came next would have needed something else. A command needs nothing
added ever again — which is the point, and the reason it is worth the process
start.

### `identifiers`, which ships

`examples/identifiers.py` is the first one, and it is in the default pipeline.
It turns "a python function called max retries" into "…called max_retries", in
English and French, with the convention taken from the language named in the
sentence — snake_case for python and rust, camelCase for typescript and go,
PascalCase for a class or a type, SCREAMING_SNAKE for a constant, camelCase
when no language was said.

A copy is written to `~/.config/parrotflow/identifiers.py` on first launch and
never overwritten afterwards: once it exists it is yours. The stop lists in it
decide where a name ends, which is a judgement about how you speak rather than
a fact, and they are meant to be edited.

It is gated twice, and both gates are in the config where you can see them:
`app:` to editors and terminals, and `when:` to a sentence containing a kind
word, so no process is started on prose. Delete either line to widen it, or the
step to turn it off.

**What it costs, and what it will not do.** Scored on 70 cases, 32 of which
must come back untouched: 90% overall, and one of those 70 is a sentence it
rewrites and should not — "there is a method called cognitive behavioural
therapy for that" is three plausible words behind a kind word and a naming
word, and no surface rule separates it from a name. The other failures are
namings it declines, which leave the transcript exactly as dictated.

**Why it is not a prompt.** Measured, in `scripts/validate-identifiers.py`. A
prompt that returns the rewritten sentence scores 68% and fails in the
expensive direction — it capitalises "python" to "Python", adds articles, and
translates French names into English. A prompt reduced to the one thing code
cannot do — naming which words are the identifier when nothing announces them,
"call it max retries" — scores 8/8 where the script scores 2/8, and it is kept
in the runner as variant v4 for anyone who wants it. Chaining it behind the
script scores 100% on the sentences that should change and drops the untouched
ones from 94% to 81%, because a permissive model then sees exactly the
sentences a careful rule refused. That is the right trade for someone who
dictates code all day and the wrong one for a default.

**It also means config.yaml executes code.** Nothing else in that file does.
`--check-config` names every command transform out loud, every time, whether or
not anything is wrong with it — a config that runs something you have forgotten
about, or that arrived in a config you copied from somewhere, should not be
able to stay quiet about it.

**Why a table needs a name.** `transcription.replacements` is a single table
applied by a single stage, so it cannot be two tables running in two places
under two conditions. Named ones can:

```yaml
pipelines:
  default:
    - replacements
    - fuzzy
    - numbers
    - transform: dotted
      app: /term|ghostty|iterm|warp/
    - transform: prose
      app: /^(?!.*(term|ghostty|iterm|warp))/
```

Two tables, two conditions, at most one matching. A single `replacements:`
cannot express that: it is one table run by one stage, in one place.

**`dotted` ships.** A new install is written with it already in the default
pipeline, because this is a tool for people who dictate identifiers. Delete the
step and it stops; delete the transform and `--check-config` tells you the step
names nothing.

### The one rewrite that fires on ordinary language

Every other substitution waits for a name you taught it. This one reads "a
word, then dot or point, then a word", and that shape occurs in prose: "voilà le
point sur les tests" would become "voilà le.sur les tests", and "the dot com
era" would become "the.com era". `point` is an everyday French word.

What keeps them apart is two stop lists, one for what may not come *before* and
one for what may not come *after*. In code both sides are identifiers; in prose
at least one side is nearly always a determiner, a preposition, or the head of a
set phrase — `le point de vue`, `un bon point pour`, `a dot product`.

```
\b(?!(?:le|la|les|…|the|a|an)\b)(\w+) (?:dot|point) (?!(?:de|du|…|product)\b)(?=\w)
```

The second word is matched but not consumed, which is what lets a chain work:
`user point profile point name` → `user.profile.name`. Consuming it would leave
the middle token unavailable to the next match.

**54/54 on `tests/dotted-cases.txt`, plus two it cannot do.** Two ordinary words
either side — "réunion point hebdomadaire" — is a shape only a dictionary would
tell from code, and both residual cases are kept in the set, failing, rather
than dropped to make the number look better. They are unlikely in a terminal or
a chat window, which together with the `app:` scoping is the only reason this is
on by default; in `replacements:` it would run everywhere and would not be
defensible.

`scripts/check-dotted.sh` reads the pattern out of `Config.defaultYAML` rather
than from a fixture, so what is scored is what a new install gets.

### `backticks`, defined and not used

A second transform wraps a dotted path for a chat window:

```yaml
- transform: backticks
  app: /slack|discord/
```

It is a separate transform rather than a cleverer pattern because `dotted` does
not consume the word after the dot, so it has nowhere to put a closing backtick
— the first attempt produced ``lis `config.`port``. It requires a letter to
start, so `21.5` is left alone.

**It is not in the shipped pipeline.** Slack's composer converts markdown as you
type it and never re-reads text that arrives by paste, which is every way this
app inserts text — so the backticks land in the message as characters. Tried on
a real Slack, including with *Format messages with markup* enabled, and it did
not render either way. A default that depends on a setting in another
application, and does not work when that setting is on, is not a default: it
puts noise in your messages and gives you nowhere to look.

Add the step if your chat app renders pasted markup. Getting this to work
properly means putting rich text on the clipboard rather than markdown
characters, which is a different feature.

### Order matters, and only one set notices

`numbers` runs before `dotted`, because English says "three point one four" for
a decimal and it is `numbers` that consumes that word. Swap the two and `dotted`
gets there first: "three one.four". The `DECIMAL` cases in the set exist to fail
if anyone reorders them.

Transforms with a `prompt:` body are also what the activation phrase reaches:
"hey parrot, tidy that up" routes on the same `description`. A `replace:`
transform is not routable by voice today — it runs from a pipeline only, and
`--check-config` lists it apart from the catalogue so that is visible rather
than surprising.

`prompts:` is the older name for this section and still reads, `content:`
alongside `prompt:` with it. `- prompt: <name>` still works as a pipeline step.
An entry defined in both sections is taken from `transforms:`.

## Conditions

A stage can carry a condition, which is what makes an expensive one affordable
— it is skipped on the transcripts that do not need it:

```yaml
pipelines:
  fr:
    - replacements
    - stage: fuzzy
      unless: /```/                      # never inside a code fence
    - stage: numbers
      when: /\b(vingt|cent|mille)\b/     # only if a number word is left
```

`when` and `unless` read the text *as it stands at that point*, after the
stages above — so a cheap stage can make an expensive one unnecessary rather
than merely earlier. Both may be set and `unless` wins, because a reason not to
run is a stronger statement than a reason to.

The pattern is written like a replacement source: between slashes it is a
regular expression, otherwise a word matched on word boundaries.
Case-insensitive either way.

A skipped stage says so in the log. A stage that silently does not run looks
exactly like one that ran and found nothing, and only one of those is
answerable by editing a condition.

## Apps

`app:` runs a stage only where you want it — the rewrite that belongs in a
terminal and nowhere near an email:

```yaml
pipelines:
  default:
    - replacements
    - stage: numbers
      app: /term|ghostty|iterm|warp/
    - prompt: prose
      app: /^(?!.*(term|ghostty|iterm|warp))/
```

**There is no `not_app:`.** The pattern is a regular expression like every
other one here, so exclusion is a negative lookahead. One key covers both
directions, at the cost of the anchor in `/^(?!.*…)/` — and forgetting it is
not a silent failure: `--check-config` and `--pipeline` both refuse an
unanchored lookahead, because unanchored it matches one character into the very
name it was meant to exclude, and the stage would run everywhere.

**The app is the one that was in front when the hotkey went down**, not when
the transcript came back. Between the two there is a transcription and possibly
a model call, and the window you dictated into is not reliably still in front.

**Name and bundle identifier are matched as one string** — `Ghostty
com.mitchellh.ghostty` — so a pattern can name either. Match on the identifier
when you want the rule to survive someone renaming an app, on the name when you
want to read it back in six months. It is one string rather than two on
purpose: `/^(?!.*microsoft)/` matches `Code` while failing
`com.microsoft.VSCode`, and "either one matched" would run the stage in the app
it was written to exclude.

**No app means the stage does not run.** On a path with no window to read, a
positive `app:` fails closed — running anyway would put a terminal-only stage
everywhere else, which is the one outcome the condition existed to prevent. The
log says which it was.

To try one without speaking into the right window:

```sh
ParrotFlow --pipeline tests/pipelines/apps.yaml "on en a vingt et un" --app Ghostty
```

An empty `--app ""` means "nothing in front" rather than "no flag given" — the
two are the same question, and saying so lets a caller pass the flag
unconditionally. `scripts/check-pipeline.sh` relies on it.

### What app conditions do not do

**They do not need Accessibility.** The app is read from `NSWorkspace`, not off
the focused element, so gating a stage by app costs no permission that gating
it by text does not.

**They only apply to dictation.** The pipeline runs on a transcript on its way
into a window. A voice command — anything after the activation phrase — is
routed and transformed on a different path that never assembles a pipeline, so
an `app:` there gates nothing. `--replace` likewise passes no app, which means
an app-conditioned stage never runs under it; that is the fail-closed rule
doing its job on a path with no window, not a bug to work around.

**Negation reads differently for text and for apps.** `unless:` excludes on
text; an app is excluded with a negative lookahead inside `app:`. Two idioms
for one idea, and the reason is that an app pattern is matched against one
joined string where a lookahead is exact, while a second key would have been a
second thing to learn for a case the pattern already covers. Worth knowing
before you go looking for `not_app:` — it is not there and will not be.

**A stage is gated, not parameterised.** `app:` decides whether a stage runs.
It cannot hand the stage a different table or a different prompt per app; two
behaviours mean two steps, each with its own condition.

## Prompt transforms

A `prompt:` transform is the reason conditions exist: it calls the local model,
so it costs about a second where every other stage costs nothing. Measured on
one line, 3.2s with the prompt running against 0.035s with it skipped.

```yaml
- transform: hesitation
  when: /\b(genre|du coup|en fait)\b/
```

It is the only stage that rewrites your words without you asking, and nothing
on screen shows it happened — so every rewrite is written to the log with the
text before and after.

If the model is not running, the prompt does not exist, or the call fails, the
transcript comes back exactly as it arrived. A dictation tool can afford to
skip a stage and cannot afford to lose a sentence.

## Why there is no `dates` or `digits` prompt

There used to be both, and `free_form` does their job. On the sixteen cases
they covered in `tests/generic-cases.yaml` they scored 12/16 against the
built-in's 14/16. `digits` was a straight tie, five cases to five. `dates` was
worse — asked to make "the deadline is March 3 2026" ISO it answered
"2026-03-03", dropping the sentence around the date, which is what a prompt
written for one subject does when handed a whole sentence.

`grammar` ships for the opposite reason. It has a validation set of its own and
beats the built-in on it, 5/5 against 4/5, and the case it wins is the one that
matters most here: leaving alone a sentence that was already right.

## An instruction inside a dictation

An activation phrase in the *first* position means the whole utterance is a
command, about your selection or your last dictation. The same phrase in the
*middle* means something else: the rest is an instruction about the words in
front of it, in the same breath.

```
"there is a bug in get username by the way parrot format that name"
 └─ what gets written, once edited ──┘        └─ what to do to it ─┘
```

Two phrases ship, because one cannot be said in both positions: "hey parrot"
opens an utterance and reads as nonsense inside one, and "by the way parrot" is
the reverse. Configure them with `activation_phrases:`.

**Why it exists.** Saying it afterwards means a second dictation, and a
transform that then has to find its target again — reading a selection, or
editing a field in place, which is where the risk is. Here the target is the
same utterance, and nothing has been written yet.

**The mid-sentence match is exact**, where the first-position one is
deliberately fuzzy. That one has to survive a clipped or misheard wake phrase,
because the audio engine is still starting up when you say it. Mid-sentence the
audio is clean, and there is a whole sentence of ordinary words for a loose
match to fire on — "the parrots are loud today" must stay a sentence.
`tests/split-cases.txt` scores this at 14/14, and half of it is sentences that
must *not* split.

**Every failure still writes what you said.** No model, a router that says this
is not an edit, a prompt that returns nothing — the dictated text goes in and
the reason appears for seven seconds. This is the opposite of the rule
everywhere else, where a failed transform leaves the text alone: there the
words are already on screen, and here they exist nowhere else. Losing the
instruction costs a second attempt; losing the sentence costs the sentence.

**No preview**, whatever the transform's `confirm` says. That setting guards
text you selected and are about to have overwritten, and nothing is being
overwritten here — a dialog in the middle would give back the round trip this
removes. The rewrite goes to the log with its before and after.
