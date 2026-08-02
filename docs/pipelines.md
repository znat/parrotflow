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

  - name: code_identifiers
    description: spoken names as identifiers
    command: code_identifiers.py
```

`prompt:` asks the local model — about a second, and the reason conditions
exist. `replace:` is a substitution table of its own, in the same shape as
`transcription.replacements`, and costs nothing. `command:` runs a program of
yours, which costs a process start — about 30ms for `python3`, 5ms for a shell
script.

### `display:`, or: what the pause is for

A stage that takes a second is a second in which the menu bar says
`Transcribing…`, which stopped being true when the decoder finished. `display:`
is what it should say instead while this transform runs:

```yaml
  - name: grammar
    description: fix grammar and punctuation mistakes
    display: Fixing grammar
    prompt: |
      Correct grammar, spelling and punctuation. Return only the text.
```

The two strings are read by different audiences and are not interchangeable. A
`description:` is matched — it is what the router compares your spoken
instruction against, so it reads like the thing you would ask for. A `display:`
is only ever shown, so it reads like a status: what is happening, not what you
wanted. The ellipsis is appended for you.

Write one for anything with a wait worth explaining — a `prompt:`, or a
`command:` that thinks. Leave it off a `replace:` table: it finishes in
microseconds, and a label that appears and vanishes inside one frame is noise
where there was none. Stages that write no display leave the current message
alone, which is why the menu bar does not flicker through the whole pipeline on
every dictation.

`--check-config` prints every display it found, which is the only way to see
that one is wrong before the second it was meant to explain has passed.

The catch-all is the one transform that cannot have a display written for it,
because it does whatever you just said rather than one fixed thing. So its
label is generated from the instruction: say "hey parrot, sort that list
alphabetically" and the menu bar reads `Sort that list alphabetically…` while
it runs. Long instructions are cut at a word boundary. Reading it mid-wait is
also how you catch the router having heard you wrong, a second before the
preview would have told you.

### `command:`, or: the app stops needing new primitives

The transcript arrives on **stdin** and comes back on **stdout**. That is the
whole contract. A command that exits non-zero, says nothing, or takes longer
than two seconds leaves the transcript exactly as it arrived, and says so in
the log — a script you are halfway through writing is an ordinary state to be
in, and a dictation tool cannot answer it by dropping your words.

The two seconds are `timeout_seconds` on the transform, and they are counted to
the process **exiting**, not to its output ending: a command that closes stdout and keeps working is over time like any
other, and is killed rather than waited for. What a script starts and leaves
behind is its own business — a plain command is `exec`ed, so the process
ParrotFlow holds is your program itself and not a shell wrapping it, but a
script that backgrounds something of its own outlives the timeout.

Two seconds is right for a script and wrong for one that asks a model — Ollama
takes 7–10s when the weights have gone back to disk — so a `command:` that ends
in `--model something` wants `timeout_seconds: 12` beside it. Per transform,
because a `tr` one-liner and a model call live in the same pipeline and want
different answers.

Paths with spaces work, in the directory and in the command: `command: my
scripts/rewrite.py` is one path, not a program and an argument. The whole value
is tried as a file before anything is split, because YAML quoting cannot help
here — the parser removes the quotes long before the app sees them.

The script is run **directly**, so its first line picks the interpreter — the
shebang, `#!/usr/bin/env python3` or `#!/bin/bash` or whatever you write it in.
The app never needs to know the language. What it does need is the execute bit:
a shebang does nothing without one, and a script that is there but not
`chmod +x` is the likeliest thing to be wrong with a `command:` transform. Both
the log and `--check-config` name that case as itself rather than as "command
not found", which would send you looking for a file that is sitting right where
you put it.

A relative path is relative to **the file that named it**: `command:
code_identifiers.py` is the script sitting beside your config.yaml. It runs with
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

### `code_identifiers`, which ships

`examples/code_identifiers.py` is the first one, and it is in the default pipeline.
It turns "a python function called max retries" into "…called max_retries", in
English and French, with the convention taken from the language named in the
sentence — snake_case for python and rust, camelCase for typescript and go,
PascalCase for a class or a type, SCREAMING_SNAKE for a constant, camelCase
when no language was said.

A copy is written to `~/.config/parrotflow/code_identifiers.py` on first launch and
never overwritten afterwards: once it exists it is yours. The stop lists in it
decide where a name ends, which is a judgement about how you speak rather than
a fact, and they are meant to be edited.

It is gated twice, and both gates are in the config where you can see them:
`app:` to editors and terminals, and `when:` to a sentence containing a kind
word, so no process is started on prose. Delete either line to widen it, or the
step to turn it off.

**What it costs, and what it will not do.** Scored on 75 cases, 32 of which
must come back untouched: 90% overall, and one of those 70 is a sentence it
rewrites and should not — "there is a method called cognitive behavioural
therapy for that" is three plausible words behind a kind word and a naming
word, and no surface rule separates it from a name. The other failures are
namings it declines, which leave the transcript exactly as dictated.

**The model is in there, switched off.** Add `--model gemma4:e4b` to the
command and the script asks a local model about the namings its rules cannot
see — a name given with no marker in front of it, "call it max retries",
"rename the variable to retry count", "a getter for the user profile name".
The rules decline all of those by construction; the model gets 8/8 on them
where the rules get 2/8.

```yaml
  - name: code_identifiers
    description: spoken names as identifiers
    command: code_code_identifiers.py --model gemma4:e4b
```

It **extracts** rather than rewrites: the language the sentence names, and the
names themselves, one per line. The convention that language writes in, the
casing, and putting the words back all stay in the script — as a table you can
add a language to without touching the prompt. That table is worth having on
its own: it replaced a `python|rust|ruby|elixir` pattern that read zig, julia,
erlang and c# as camelCase, and the rules alone went from 1/5 to 5/5 on those
with no model involved. That division is the whole reason it works: asked instead to return
the rewritten sentence, the same model scores 68% and fails in the expensive
direction, capitalising "python" to "Python", adding articles, and translating
French names into English.

And it is off by default because the trade is measured rather than assumed.
Over 75 cases it takes the sentences that should change from 87% to **100%**,
and the sentences that must come back untouched from 94% down to **84%** — a
model asked only about what a careful rule refused sees mostly near-misses, so
chaining it behind the rules inverts their caution. Turn it on if you dictate
code all day and would notice a sentence quietly rewritten; leave it off if you
would not. It also costs about a second, and a model that is cold takes longer
than the two seconds ParrotFlow waits, in which case the transcript passes
through untouched.

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

### Writing to people: `email` and `slack`

Two prompts scoped to one kind of window each, and the first stages that ask
the model from a pipeline rather than from the activation phrase:

```yaml
- transform: email
  app: /mail|outlook|thunderbird|superhuman|missive/
- transform: slack
  app: /slack/
```

`grammar` mends a sentence. These two also **lay one out**, which is the part
no substitution can express: dictated prose arrives as a single block with the
greeting run into the first sentence, no paragraph breaks, and the hesitations
still in it. A comma and a newline after "Bonjour Marie" is not a rewrite of
your words, and it is not something a table can be taught.

`email` puts the greeting on its own line with a blank line under it, breaks
the body where the subject changes, and treats a name at the end as a
signature. `slack` does almost none of that — no greeting, no sign-off, one
paragraph — and is explicitly told to emit no markup at all, for the reason
`backticks` is not in the shipped pipeline: Slack's composer does not render
markdown that arrives by paste, so bold or bullets land in the message as
characters.

Both are told twice not to write anything. That is the failure worth spending
tokens on: a model handed a dictated email will gladly return a better one, in
its own voice, and nothing on screen says it happened — a pipeline stage runs
on a transcript nobody has seen yet, so `confirm` does not apply to it.

**6/7 and 3/3 on gemma4:e4b**, and the versions in between are written into
config.example.yaml beside each prompt, because what they cost is the useful
part. Three findings, all of them the prompt making things worse before better:

| Wording | What it did |
|---|---|
| "If none was dictated, do not invent one" | invented a greeting anyway — a prohibition read as a topic |
| "Nothing is ever deleted" | answered with a literal `[Signature]` placeholder |
| the greeting rule given examples | put the examples in the output: "Hi Tom," and "À toi," |

The first is the lesson `tests/grammar-cases.yaml` already records — a rule
about restraint making the model less restrained. The third is that file's
other lesson running the opposite way: elsewhere here examples beat rules, and
in a prompt whose output is the same shape as its examples they get copied.

What fixed the greeting was turning the prohibition around and saying what the
email starts with when there is no hello. What fixed a dropped `thanks` was
tying the closing word to the signature instead of listing it among the things
not to add. And `slack` says "Add nothing" rather than "No greeting, no
sign-off", because the second wording was read as an instruction to *remove*
one: "hey uh quick one the build is red" came back as "The build is red".

The case still failing is `yes that works for me see you thursday`, which comes
back as `See you Thursday.` — two clauses run together with no comma read as
one goodbye. With the comma it is right. It is left failing rather than argued
with.

**Neither is in the shipped default pipeline.** Every stage a new install gets
is free and needs nothing running; these cost about a second and do nothing at
all without Ollama. Same rule as the `--model` switch on `code_identifiers`,
which ships off for the same reason. config.example.yaml has them wired up.

**Gmail in a browser tab is not an app.** `app:` reads the window that was in
front, which is `Google Chrome com.google.Chrome` — so name your browser in the
pattern if you live in Gmail, and accept that every other tab gets the stage
too. There is no narrower answer available: the condition is a window, not a
URL.

**They cost the router something, and it is measured.** Both are prompts, so
both join the catalogue the activation phrase reaches, and every description
added is another way for an idle sentence to find a tool.
`tests/routing-cases.yaml` was rerun and grew: 41/45 on three prompts, 47/52 on
five. One new failure appeared and it is the expensive class, the one the
negative half of that set exists for:

```
I sent her an email yesterday  ->  email
```

A sentence, not an instruction, sent to a prompt that would rewrite your
selection. Four descriptions were measured against it and all four routed it
identically, so it is recorded there rather than tuned away.

### `slack_handles` and `slack_mentions`, which are tables

```yaml
- name: slack_handles
  description: spoken names as Slack handles
  replace:
    '@marie.dupont': ['/\bmention(?:ne)? marie\b/']

- name: slack_mentions
  description: spoken group mentions as @here and @channel
  replace:
    '@here': ['/\bmention(?:ne)? (?:everyone here|here)\b/']
```

Both run from the Slack pipeline, ahead of the `slack` prompt.

**This was a prompt first, and it was the wrong tool.** A name is a lookup, and
the thing a lookup must never do is answer with something that was not in it.
The prompt did exactly that: its first draft turned "the config file is here,
Sofia already looked at it" into "…@priya already looked at it" — a handle
invented for a name it had never been given, which in Slack is a message sent
to the wrong person. It took four rewrites and three load-bearing sentences to
reach 6/6, and it still cost a second per message and a model being up.

A table cannot invent. It substitutes what is in it and leaves everything else,
in microseconds, with nothing running. **7/7 on the same cases, and the two that
mattered — "Sofia" and a bare "Marie" — are not failures it passes but shapes it
has no way to produce.**

**The marker is the safety, and it is what makes a table possible here.** The
prompt was reachable only by voice — "hey parrot, use Slack mentions" — because
a table in a pipeline would have turned every "Marie" into a ping, and a message
that names someone is not a message that pings them. `mention` in front of the
name is the same opt-in, said in the same breath, and it costs no round trip:

```
"mention marie can you look at this"  ->  "@marie.dupont can you look at this"
"mention everyone here"               ->  "@here"
```

That also removes the argument for keeping a mapping inside a prompt, which was
the one place in this file where a lookup was not a table.

**Two tables rather than one**, so the group pings can be deleted without the
handles going with them: `@here` and `@channel` are the two that wake people up.

**They run before the `slack` prompt** because a handle is a token a model
leaves alone, where "mention marie" is a phrase it might tidy away. Measured
rather than assumed — the handles come through the prompt untouched, 3/3.

**Filling it in.** The shape is regular and the contents are your colleagues, so
hand your team's names and handles to Claude Code and ask it to update the
table. That is the maintenance path, the same way `replacements:` is filled from
`--transcribe` output.

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
