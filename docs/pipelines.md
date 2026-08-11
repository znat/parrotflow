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
| `context` | What is on screen around the field, published as `context.*`. Never touches the transcript. Terminals only, and off unless you ask for it — see [Context](#context-what-is-on-screen-around-the-field). |
| `vocabulary` | Every substitution the vocabulary pass made, put to the local model one at a time — see [The name judge](#the-name-judge). |
| `transform` | One entry of `transforms:`, named — see below. The only stage that names something outside itself. |

`numbers` rewrites transcripts that were already correct, so run `--numbers` on
a line to see exactly what it would do before leaving it in.

## The name judge

`vocabulary:` decides which of the substitutions the app made are really names.
It is a stage rather than a transform because the evidence it needs — where
each substituted word sits, and what the decoder wrote there — is measured
during transcription and cannot survive being written to a file.

```yaml
- vocabulary
```

With anything to say about it, spell the stage out — a list entry is either a
name or a mapping, and it cannot be both:

```yaml
- stage: vocabulary
  when: vocabulary.count > 0
  fuzzy: true         # optional; default. false matches renderings exactly
  max_slots: 4        # optional; past this many, keep what the pass wrote
  max_per_slot: 2     # optional; readings per place, the decoder's included
  max_per_term: 2     # optional; places in one sentence about the same name
```

`max_per_slot` cannot go above 2. A verdict has two sides, so a place offers
what the decoder wrote and one alternative; a third reading would be built and
never shown. Refused rather than rounded down, because a number that says one
thing and does another teaches nobody anything.

**There is no prompt file, and naming one is an error.** It used to name one
and you owned it. Nobody should own this one: a wording is right or wrong
against a measurement, not a matter of taste, and five wordings of one sentence
in the old prompt scored 38, 39, 40, 41 and 42 on the same cases.

If your pipeline says `- vocabulary: verify_names.md`, delete the filename. The
config will not load until you do. It is refused rather than ignored because a
filename that loads and does nothing is worse: you would edit that file, see
the judge behave exactly as before, and have nothing to tell you why.
`max_readings:` is refused for the same reason — it capped the lettered menu,
which is gone.

It shows the model the sentence the recogniser wrote, the same sentence after
the pass, and a numbered list of what changed. It takes one KEEP or REVERT per
change and puts the reverted words back itself. The model never writes the
transcript, so it cannot tidy the grammar on the way past.

**A place the pass only proposed is shown as a change too.** With
`vocabulary.acoustic: true` the sound-matching pass hands over spans it has not
written, and the text still holds the decoder's word there. The question is the
same either way — does this name belong here — so `after` is the sentence with
every change taken, whether the pass took it or not, and KEEP is what writes it.

A rule in `replacements:` is judged too, so a name a rule wrote for a word you
meant literally can be undone. The app works out which occurrences the rule
wrote by comparing the transcript before and after it. When two rules write the
same term into one sentence that comparison cannot say which is which, and then
neither is offered — the log says so.

**`fuzzy:` widens what a `heard:` rendering matches.** On by default. Two
things, and they are separate mechanisms:

- A word spelled like a rendering but for its apostrophes *is* that rendering.
  `Praises` in the list and `Praise's` in the transcript is a name lost for one
  character, because `\bPraises\b` does not match an apostrophe.
- A word one edit from a rendering, and only when no dictionary knows the word.
  `Versel` opens a place; "praise" does not, even though it is one edit from
  `Praises`.

Neither writes anything. Each opens one more place for the model to decide, so
the risk of the looser match is bounded by the judge rather than by the
threshold. `fuzzy: false` puts matching back to exact and whole-word.

**`max_per_term` is the one to move if nothing is being judged.** One name
reaches the list from five directions — a rule that already rewrote the text,
a fuzzy rendering, the sound-matching pass, the wider spans it builds around a
split name, and the keyword spotter hearing the name somewhere else in the
clip. Nothing else caps the total, so a noisy name can spend every place on its
own and push the count past `max_slots`, at which point the whole sentence is
declined. The cap keeps the two best-evidenced places and says in the log which
it dropped. Raise it when a name really does appear three times in one
sentence.

`when: vocabulary.count > 0` is not optional in practice. Without it the stage
costs a model call on every dictation, including the ones where nothing was
substituted.

**Order matters, and the app refuses the wrong one.** The judge is given spans
measured on the text the decoder produced. Put `replacements` above it — the
judge offers a rule's substitution back, so the rules have to have fired — and
everything that edits text below it. `--check-config` refuses a pipeline that
puts `fuzzy`, `numbers` or a transform in between, because a span that has
moved cannot be told from a span that was always wrong.

When anything goes wrong — the model unreachable, a reply naming no change,
more places than `max_slots` — the transcript ships exactly as it arrived and
the reason is in the log. Every failure lands the same way: what the pass wrote
is what you get.

It publishes `vocabulary.asked` (how many changes were put to the model),
`vocabulary.slots`, `vocabulary.reverted` (the substitutions it undid, as
`term -> word`) and `vocabulary.judged` (the sentence it settled on).

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

### The folder, and `path:`

A transform named `X` owns `transforms/X/` beside the config that declared it.
A relative path is looked for there first and beside `config.yaml` second, and
the folder is the working directory a `command:` runs in — so a script can read
a data file of its own by a bare relative name.

`prompt:` and `replace:` can name a file instead of holding one. `command:`
already is a path:

```yaml
transforms:
  - name: slack
    description: tidy dictated text into a chat message
    prompt: { path: slack.md }          # transforms/slack/slack.md

  - name: dotted
    description: spoken dotted paths as code
    replace: { path: dotted.yaml }      # the same table, in a file

  - name: slack_mentions
    description: turn people's names into Slack mentions
    command: slack_mentions.py          # transforms/slack_mentions/…
    tests: { path: heldout.yaml }       # what --eval scores; default cases.yaml
```

A scalar stays a scalar: an inline `prompt: |` is unchanged, and a three-line
prompt is worse in a file than in the config it belongs to. A prompt file is
read verbatim — no front matter, no templating. A `replace:` file holds the
same mapping the inline table would.

A `path:` naming a file that is not there, or is not readable, takes out **that
transform and nothing else**: it is skipped, `--check-config` says why, and the
rest of the config goes on working.

`--check-config` prints the resolved absolute path of every body. A prompt
present both in the folder and beside `config.yaml` is otherwise invisible, and
"which one is running" is the first question when an edit had no effect.

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

### `offer:` and `key:`, or: getting on the pill

After a dictation the pill names what can be done to the words that just
landed. `Correct` is always first — it is not a transform, it needs no model,
and it cannot fail. After it comes every transform that asked for a place:

```yaml
  - name: grammar
    description: fix grammar and punctuation mistakes
    display: Fixing grammar
    offer: true       # put a chip on the pill
    key: g            # the letter drawn on it
    prompt: |
      Correct grammar, spelling and punctuation. Return only the text.
```

Press the letter on a chip, or click it. A transform runs as it always does, so
it still shows its preview when `confirm:` is on.

**Both are off by default.** The offer is on screen for a few seconds and every
entry costs the others room, so a transform joins it only by asking. Put a
chip on what you reach for without thinking. Leave it off anything you would
only ever ask for out loud — that is what the wake phrase is for.

`key:` is one letter, drawn as a keycap and shown in capitals whatever you
write. More than one character is cut to the first. A transform with `offer:
true` and no `key:` still gets a chip, without a keycap on it — clickable, and
on no key.

The letter is taken from whatever app you are typing into, for the three
seconds the offer is up. Pick one you are unlikely to start a word with right
after dictating. `C` is already `Correct`'s; a second chip asking for it is
drawn but never reached, because the first chip with that letter wins.

`--check-config` prints what is on the pill and the letter each chip carries.
A chip that is missing, or a `key:` that was cut, is otherwise invisible: the
pill fades out over nine seconds and a short offer looks like a normal one.

Only the shipped `grammar` asks for a place. Everything else in
config.example.yaml is left off.

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

A relative path is looked for in the transform's own folder, and nowhere else:
`command: code_identifiers.py` on a transform named `code_identifiers` is
`transforms/code_identifiers/code_identifiers.py`. Writing it out in full names
the same file. **The folder is the working directory**, so a script reads its
neighbours by bare relative name.

One place to look, deliberately. An earlier draft searched the config directory
too, so a script left beside `config.yaml` kept running; two directories that
can disagree turned out to cost more than they bought, because *which* one a
command runs in stops being answerable once the command names files in both. A
program that is in neither the folder nor on `PATH` is a fault `--check-config`
names, and moving the file is the whole fix.
Beside `config.yaml` is tried second, which is where a script written before
folders existed still sits; it runs, and `--check-config` says where to move it.
Writing the path out in full — `command:
transforms/code_identifiers/code_identifiers.py` — names the same file and is
not reported. A bare name that is not a file in either place — `sed`, `python3`
— is left to the shell to find on PATH, so a command can be a one-liner with
its own arguments:

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

`examples/transforms/code_identifiers/code_identifiers.py` is the first one, and it is in the default pipeline.
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

**54/54 on `examples/transforms/dotted/cases.txt`, plus two it cannot do.** Two ordinary words
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

**8/10 and 3/3 on gemma4:e4b**, and the versions in between are written into
config.example.yaml beside each prompt, because what they cost is the useful
part. Four findings, all of them the prompt making things worse before better:

| Wording | What it did |
|---|---|
| "If none was dictated, do not invent one" | invented a greeting anyway — a prohibition read as a topic |
| "Nothing is ever deleted" | answered with a literal `[Signature]` placeholder |
| the greeting rule given examples | put the examples in the output: "Hi Tom," and "À toi," |
| the list rule moved after the short-reply clause | a two-word reply came back as "[No body text]" |

The first is the lesson `examples/transforms/grammar/cases.yaml` already records — a rule
about restraint making the model less restrained. The third is that file's
other lesson running the opposite way: elsewhere here examples beat rules, and
in a prompt whose output is the same shape as its examples they get copied.

What fixed the greeting was turning the prohibition around and saying what the
email starts with when there is no hello. What fixed a dropped `thanks` was
tying the closing word to the signature instead of listing it among the things
not to add. And `slack` says "Add nothing" rather than "No greeting, no
sign-off", because the second wording was read as an instruction to *remove*
one: "hey uh quick one the build is red" came back as "The build is red".

`email` also sets out lists, which is the one place it adds structure rather
than removing it. Three or more things in a row take a colon and a dash each.
The rule has to say that **no number needs to have been spoken** — "three or
more things in a row" on its own left `here is what I need from you the invoice
the signed contract and the shipping address` inline, because the model was
waiting to be told there were three.

**Numbered lists are deliberately absent.** Spoken ordinals — "first we deploy,
second we run the tests" — stay as sentences. The version that forced them to
1. 2. 3. dropped an item on the floor, and prose where a list was wanted is a
better thing to ship than a list missing a line.

The two cases still failing are one shape: a short reply ending in a goodbye
comes back as the goodbye alone — `yes that works for me see you thursday` →
`See you Thursday.`, and `ok pour moi, à jeudi` → `À jeudi,`. The same sentence
with a comma is right. Three framings have bounced off it, so it is recorded
rather than argued with.

**Neither is in the shipped default pipeline.** Every stage a new install gets
is free and needs nothing running; these cost about a second and do nothing at
all without Ollama. Same rule as the `--model` switch on `code_identifiers`,
which ships off for the same reason. config.example.yaml has them wired up.

**Gmail in a browser tab is not an app.** `app:` reads the window that was in
front, which is `Google Chrome com.google.Chrome` — so name your browser in the
pattern if you live in Gmail, and accept that every other tab gets the stage
too. There is no narrower answer available: the condition is a window, not a
URL.

**They cost the router something, and it is measured.** Both join the catalogue
the activation phrase reaches — as every transform with a description now does,
whatever its body — and each description added is another way for an idle
sentence to find a tool. `tests/routing-cases.yaml` was rerun and grew: 41/45 on
three prompts, 50/54 on six, and 50/54 again when the tables and scripts joined
the list. One new failure appeared and it is the expensive class, the one the
negative half of that set exists for:

```
I sent her an email yesterday  ->  email
```

A sentence, not an instruction, sent to a prompt that would rewrite your
selection. Four descriptions were measured against it and all four routed it
identically, so it is recorded there rather than tuned away.

### `slack_mentions`, which you have to ask for

Said out loud — "hey parrot, use Slack mentions" — and deliberately in no
pipeline. A message that names someone is not a message that pings them, and
nothing in a transcript tells the two apart. So it is the one you ask for.

**`confirm` covers one of the two ways of asking, not both.** Said with text
selected, the result is shown before it replaces anything and you see who is
about to be tagged. Said mid-sentence — "by the way parrot, use Slack mentions"
— there is no preview whatever `confirm` says: nothing is being overwritten
there, and a dialog in the middle would give back the round trip that path
exists to remove. That is the rule for every inline transform, not this one —
see *An instruction inside a dictation* below.

What both produce is text in your composer. ParrotFlow never sends a message,
so the last look before anyone is notified is yours.

**The mapping lives in the prompt**, which is the opposite of the rule
everywhere else here, and it was tried the other way round. The tables are
worth reading about because of what they cost, not because they failed:

```yaml
- name: slack_handles
  replace:
    '@marie.dupont': ['/\bmention(?:ne)? marie\b/']
```

A table cannot invent. This prompt's first draft answered "the config file is
here, Sofia already looked at it" with "…@priya already looked at it" — a handle
made up for a name it had never been given, which in Slack is a message sent to
the wrong person — and it took four rewrites and three load-bearing sentences to
reach 6/6. The tables reached **7/7** on the same cases, for free, with nothing
running. On the mapping alone the table wins outright.

**What it lost on was the trigger.** A table has to fire from inside the
sentence, and the only natural word for it is one English already uses as a
verb:

```
"I should mention here that the deadline changed"
  ->  "I should @here that the deadline changed"
"I wanted to mention Marie is off next week"
  ->  "I wanted to @marie.dupont is off next week"
```

Anchoring the marker to the start of an utterance or to a `.` `!` `?` `;` or
comma fixed those — **11/11**, five prose sentences that must not ping and six
deliberate forms that must — at the price of "can you mention marie about the
invoice" doing nothing at all. But a pipeline stage has **no preview**: it runs
on a transcript nobody has seen yet, so `confirm` does not reach it and a false
positive is a message that has already gone.

Asking out loud has no such failure. It fires when you ask and never otherwise,
which is worth a second and a prompt that had to be taught not to guess. The
table is the better mapping; the voice command is the better trigger, and the
trigger is where the expensive mistakes live.

**One thing is still open, and it decides whether any of this is worth having.**
`TextInserter` puts the text on the pasteboard and synthesises ⌘V — in both
insert modes, so everything ParrotFlow writes arrives in Slack by paste. And
Slack's composer does not re-read what arrives by paste: that is the finding
that keeps `backticks` out of the shipped pipeline, tested on a real Slack. If a
pasted `@handle` does not linkify either, this writes something that looks like
a mention and notifies nobody, which is worse than not having it — you would
believe you had told someone. Paste one into a Slack composer without sending
and see whether it turns blue.

### Order matters, and only one set notices

`numbers` runs before `dotted`, because English says "three point one four" for
a decimal and it is `numbers` that consumes that word. Swap the two and `dotted`
gets there first: "three one.four". The `DECIMAL` cases in the set exist to fail
if anyone reorders them.

Transforms are also what the activation phrase reaches: "hey parrot, tidy that
up" routes on the same `description`. **All three bodies**, because what a
transform is made of is not a reason you cannot ask for it out loud — a table
costs nothing and a script costs a process start, and both answer to a
description exactly as a prompt does.

It was prompts only until it became a real bug. The catalogue was built from
`config.prompts`, which drops every `command:` body, so a transform that became
a script left the list silently — and a router shown nine of your ten tools
does not report the tenth missing, it picks the nearest of the nine. Measured:
"use slack handles" reached `slack`, the chat-tidying prompt, which tidied the
sentence and left the name alone. `--check-config` now prints what each
capability is made of, so a program answering your voice is visible rather than
implied.

An entry with **no `description:`** is not in the catalogue — there is nothing
to match spoken words against. It still runs from a pipeline, where the name is
written down rather than said, and `--check-config` names it apart so that is
visible rather than surprising.

The spoken instruction reaches a `prompt:` and nothing else. A script and a
table take text in and give text back; there is nowhere to put "in French" and
no honest way to invent one.

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

Between slashes it is a regular expression, matched case-insensitively.
Anything else is an **expression** — see [Variables](#variables) below.

> A bare word used to mean "this word appears, on word boundaries". It now
> parses as a variable, and `--check-config` refuses it by name rather than
> letting a stage quietly stop running: `when: genre` is told to become
> `when: /genre/`.

A skipped stage says so in the log. A stage that silently does not run looks
exactly like one that ran and found nothing, and only one of those is
answerable by editing a condition.

## Variables

A regex can ask one thing: does the text say this. It cannot ask whether the
stage above already did the job — so a stage had to re-derive that judgement
from the same words, or run when it should not have.

Every stage publishes facts about itself, under its own name, and a condition
can read them:

```yaml
pipelines:
  default:
    - replacements
    - transform: code_identifiers
    - stage: transform
      transform: dotted
      when: code_identifiers.count == 0     # only if nothing else took it
```

Four are derived for every stage, whatever it is and whether or not it knows
any of this exists:

| | |
|---|---|
| `<stage>.ran` | false when a condition skipped it |
| `<stage>.ok` | false when it errored, timed out, or returned nothing |
| `<stage>.changed` | whether the text differs from what went in |
| `<stage>.ms` | how long it took |

They are **derived, never claimed**. A stage cannot forget to report `changed`,
and cannot report it about the wrong string.

Stages add their own on top. The built-in ones publish `replacements.count`,
`replacements.changes` and `replacements.before` — how many rules fired, which
ones, and the sentence the stage was handed — `numbers.language`, which grammar
actually read the numbers and is not the same answer as the pipeline's
language, and, for a prompt stage, `model`. The name judge reads all three of
the `replacements` ones: `changes` says which rules fired and `before` says
*where*, because the rules leave no positions behind. A `command:` transform
publishes whatever it likes; see
[docs/authoring.md](authoring.md#recipe-a-program-that-reports-what-it-did).

Before any stage runs, the scope already holds `text`, `app`, `bundle_id`,
`language`, and what transcription measured — `asr.confidence`, `asr.duration`,
`asr.processing`, `asr.words`. So a stage can stand down on a recording the
recogniser was not sure about:

```yaml
    - stage: transform
      transform: disfluency
      when: asr.confidence < 0.7 && asr.duration > 3.0
```

### The rules

**A stage writes under its own name and nowhere else.** The namespace comes
from the pipeline, not from the stage, so one stage reaching into another's
facts is not guarded against — it is unspellable.

**Everything else carries through.** A stage contributing nothing erases
nothing. Carrying is the pipeline's job, not something each script has to
remember; a `sed` one-liner could never have echoed a namespace back.

**A name is a fact about the stage, not a claim about the text.**
`code_identifiers.count` — how many names it converted — stays true after a
later stage rewrites the sentence. A variable called `has_identifier` would
not. The namespace makes the first reading the natural one.

**The same stage twice writes the same namespace, and the later run wins.** A
condition between the two sees the earlier facts. Keys the second run does not
mention survive it.

**A skipped stage gets `ran: false` and nothing else** — no `ok`, no `changed`.
Inventing them would let `grammar.ok` read true for a stage that never
happened. Ask `grammar.ran && grammar.ok`; `&&` short-circuits, so the second
half is never evaluated on a stage that has no `ok`.

### The expression language

A subset of [CEL](https://cel.dev), which is chosen for the spec rather than
for any library: if the pipeline is ever rewritten in another language, the
configs people have written keep meaning what they meant.

```
paths          text, numbers.count, asr.confidence
literals       "a string", 12, 1.5, true, false
operators      &&  ||  !  ==  !=  <  <=  >  >=
methods        matches(re)  contains(s)  startsWith(s)  endsWith(s)
```

Strings compare and match case-insensitively, and `matches` is ICU — the same
engine `/…/` conditions use, so a pattern moved from one form to the other
behaves identically.

`!` is a real negation, which is why the anchored negative lookahead below is
not needed in an expression:

```yaml
      app: /^(?!.*(term|ghostty))/          # a pattern needs the anchor
      when: '!app.matches("term|ghostty")'  # an expression does not
```

**An unknown name is an error, not false.** Silently reading false is how a
condition stops working without anything saying so. Two of the three cases are
caught at load, by `--check-config`, before a transcript ever reaches them:

- a name nothing defines — `when: genre`, the old bare-word form
- a stage that runs *later* in the pipeline than the condition reading it,
  which no runtime error can catch in time: by then the transcript is already
  halfway through, and "has not run yet" and "reported nothing" are the same
  absence

The third — a variable a script stopped publishing — can only be seen at run
time. The stage is skipped, and the log says why.

`--pipeline … --vars` prints the whole scope, and a skipped stage names the
values that decided it:

```
  ⊘ transform  — skipped, when code_identifiers.count == 0 did not match
                 (code_identifiers.count = 1)
```

## Context: what is on screen around the field

Every other stage sees the sentence and nothing else. `context` is the one that
looks up: it reads the screen behind the field you are dictating into and
publishes it, so a later stage can know what the sentence is answering.

```yaml
pipelines:
  default:
    - replacements
    - context
    - stage: transform
      transform: reply
      when: context.ok && context.chars > 200
```

It publishes five things, on top of the four every stage gets:

| | |
|---|---|
| `context.text` | what was on screen, minus the input box |
| `context.chars` | how much of it there is |
| `context.lines` | how many rows |
| `context.truncated` | whether the cap cut anything off the front |
| `context.declined` | why nothing was read, when nothing was |

**It never changes the transcript.** `context.changed` is false on every run and
means it — the stage returns its input by construction, not by outcome. A stage
that could put the screen into the transcript is a stage that could paste your
terminal into a chat message.

**Terminals only, for now.** A terminal's accessibility value *is* its visible
screen, so the whole context costs one call — the same call the app already
makes to edit a line in place. No other app works that way. A Slack composer
publishes its own contents and nothing above it, so the messages would have to
come from walking the window's children: hundreds of round trips, per app, for a
flat run of text with no author attached. That may still be worth building. It
is not the same feature, and one stage that means "cheap" in one app and
"expensive" in the next is not a stage anybody can budget for. So everything
else is declined out loud.

**The screen is read when the hotkey goes down, not when the stage runs.** The
press is the last moment the pane is known. By the time the pipeline reaches
this stage there has been a transcription and possibly a model call, and focus
may be somewhere else — so a read then answers "what is on screen now" when the
question is "what were you looking at when you decided to say this".

Those are the same screen nearly always. Measured over 17 dictations, a press
reading and a stage reading agreed 15 times, and both differences were under 35
characters of spinner and token counter. The reason to take the earlier one is
not that it is fresher. It is that the pane is certain.

The read costs about 1ms on a small pane and 36–39ms on a long scrollback, so it
runs on a background queue after the recorder has started. It is skipped
entirely unless some pipeline names the stage.

**This does not fix where the text lands.** If you dictate into one pane and
switch to another before the transcript is ready, the ⌘V still goes to the pane
you switched to. That is a real gap and it is not this stage's — the fix is to
put the transcript on the clipboard instead of pasting it somewhere you did not
aim, and it belongs next to the paste. Until then, the context at least
describes the pane you meant.

**Only the hotkey captures.** Any other entry point — `--pipeline`, a scripted
transcription — reaches the stage with nothing to publish and gets
`context.declined: nothing was captured when the hotkey went down`. Use `--peek`
to see a live read on demand.

**The input box is left out.** It holds the sentence being dictated right now,
which the pipeline already has as `text`. A stage handed the same sentence twice
— once as its input, once as "context" — has every reason to read it as a
quotation.

**The last 2000 characters, cut on a row boundary where there is one.** The
tail, because the rows nearest the box are the ones the sentence is answering.
On a boundary, because a half row reads like something somebody said and there
is nothing in the string to say otherwise.

A single row longer than the whole budget has no boundary inside it, and is cut
anyway — 2000 is how much of your screen may leave it at all, not only how much
is worth reading. A wrapped terminal keeps rows near the pane width, so that is
the log line or the pasted blob that did not wrap.

### Why it is not in the default

Every other stage is on the moment it exists — delete `pipelines:` and you get
all of them. `context` is not, and `transform` is the only other exception.

It reads the screen. Turning that on for everybody who never wrote a
`pipelines:` block would be a silent change to what the app looks at, and that
is the one kind of change that has to be asked for by name. Write the line and
you have it.

Worth knowing before you write it: **while the stage is on, the log holds what
was on screen when you dictated.** That is deliberate — the whole point is to
find out what is worth reading off a screen, and that judgement cannot be made
from "1840 chars" — but it is a real consequence and `~/Library/Logs` is a real
file.

### Seeing what it captures

`--pipeline` cannot show you. TCC pins the accessibility grant to the app
bundle, so a binary run from a terminal is attributed to the terminal and gets
nothing; the stage declines every time and `tests/pipelines/context.yaml` scores
that declining rather than a stub.

`--peek` can, because it runs inside the bundle:

```sh
open -na ParrotFlowDev --args --peek 6
# click the window you want, then read the log
```

It prints what the stage would publish, in full, under `as context:`.

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

### Reading variables from a prompt

A prompt names a variable the way a condition does. Anything a stage published
is reachable, as long as that stage runs earlier in the pipeline.

```yaml
pipeline:
  - context
  - transform: rewrite

transforms:
  - name: rewrite
    prompt: |
      Rewrite the dictation as a clear instruction.

      This is on the speaker's screen right now:
      {{context.text}}

      Use it to spell names and paths. Never quote it back.
```

`{{context.text}}`, `{{numbers.count}}`, `{{language}}`, `{{app}}` — the same
names `when:` reads, so there is one vocabulary rather than two.

**A name with nothing behind it takes its paragraph with it.** Most variables
are absent most of the time: `context` only reads terminals, so in Slack that
prompt is just the first line and the last. Substituting an empty string would
leave `This is on the speaker's screen right now:` over a blank, which tells a
model there is a screen and then shows it none — and a small model asked to use
something that is not there will invent it.

The paragraph is the unit because that is what a prompt is written in. A heading
and its content are one thought, and dropping only the line with the placeholder
would keep the promise and remove the thing promised. One empty name takes the
whole paragraph even if another in it resolved.

So **give a placeholder its own paragraph, beside at least one paragraph that
has none.** A prompt where every paragraph holds a placeholder cannot be emptied
— an empty system message is no instruction at all, and the model would be left
with the transcript and whatever it felt like doing to it — so in that one case
the paragraphs stay and the gaps are simply blank. That is the shape the rule
cannot save.

Score a prompt's placeholders without a model:

```sh
$PF --compose 'On screen:\n{{context.text}}\n\nBe brief.' 'context.text=hello'
scripts/check-compose.sh
```

**`{{instruction}}` is one of these names, not a special case.** It holds the
spoken instruction from ["hey parrot, make that a list"](#an-instruction-inside-a-dictation).
In a pipeline there is no spoken instruction, so it is always empty there and
takes its paragraph with it like any other name.

### Two things to know before interpolating a screen

`{{context.text}}` puts up to 2000 characters of your terminal into the system
message. That is the point, and it has two consequences worth stating.

If the screen holds something shaped like an instruction, the model may follow
it. A Claude Code pane is exactly where arbitrary text lives, so this is
prompt injection from your own screen.

And it goes wherever `llm.endpoint` points. On localhost that is the same
machine. Point it at a hosted model and the interpolation is the moment your
screen leaves the machine. The `context` stage alone never sends anything
anywhere; `{{context.text}}` in a prompt is what does.

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
