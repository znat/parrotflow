# Proposal: a transform can be a pipeline, and there is only one pipeline

**Status.** Part 1 built. Part 2 is still spec, and is the document to argue
with before any code is written. Where Part 1's implementation departed from
the text below it is noted inline as **[built]**.

**Goal.** Two changes, and the second is the one that matters.

1. `transcription.pipelines:` stops being a map keyed by language. There is one
   pipeline, `transcription.pipeline:`, a bare list.
2. A transform may have a **`steps:` body**: a list of other transforms, run in
   order, with the same `when:` / `unless:` conditions a pipeline step has. It
   is a transform like any other — it has a name and a description, the router
   reaches it by voice, and the main pipeline runs it with `- transform: <name>`.

The second one exists because the useful shape is *a model decides, a script
writes*, and today that shape has nowhere to live. A `prompt:` is one call and
one string back. A `command:` is one process. Chaining them means one of them
shells out to the other, which puts the chain inside a script where no
condition can see it and no `--eval` can score half of it.

---

## Decisions already taken

Do not relitigate these; they were argued and measured.

| | |
|---|---|
| The model never writes the final value | Measured twice. A prompt asked to write Slack handles invents handles (`@priya`, commit `9acb274`), and a prompt asked only to mark names still tags people the speaker never named. The member that writes a handle is a script reading a table. |
| A group is a `Pipeline` | The type already exists: ordered steps, conditions, per-stage variables, derived `ran`/`ok`/`changed`/`ms`, a validator. A second execution model for the same idea would be two things to learn and two things to get wrong. |
| Members are transforms, not stages | `steps:` may name only entries of `transforms:`. Not `vocabulary`, `numbers`, `context` or `input` — see *What is refused*. |
| One level | A group may not name a group. |
| A group is self-contained | Its conditions read the seeds and its own members. Nothing from the pipeline around it. |
| Language keys go | `when: language == "fr"` says the same thing, in the same vocabulary as every other condition, and reads on the line it affects. |

---

## Part 1 — one pipeline

**Built.** Three departures from the text below, marked **[built]** where they
belong.

### The change

```yaml
transcription:
  pipeline:
    - vocabulary
    - numbers
    - transform: dotted
      app: /term|ghostty|iterm|warp/
```

`transcription.pipelines:` and its language keys are gone. `Pipeline.resolved(config:language:)` goes with them.

The bare-list shape is not new. `--pipeline` fixtures already spell it this way
— `tests/pipelines/apps.yaml` opens with `pipeline:` and a list — and
`PipelineCommand` converts it to `["default": pipeline]` on the way in. After
this the fixture format and the config format are the same shape, and that
conversion is deleted.

**[built]** `Pipeline.forText` was kept and cut down to
`Pipeline.language(of:config:)`, which returns the detected language and no
pipeline. Three callers still need the language: `Replacements.apply`,
`Pipeline.runCollectingScope` and `PipelineCommand`.

**[built]** The `["default": pipeline]` line is gone, but `PipelineCommand`
still builds its own steps. The two paths disagree about one entry shape: a
step writing both `stage: transform` and `transform: <name>` sets `namesBoth`,
which the config path drops and reports and the fixture path runs. Three
fixtures use that spelling — `vars-conditions`, `vars-shipped`,
`vars-skipped` — so sharing the builder would refuse them. The disagreement
predates this change and is left as it was.

### What is not lost

`languages:` stays. Language detection stays: it seeds `language` into the
scope, and `numbers` still resolves its own grammar with its own guard. The
only thing that stops depending on the detected language is **which list of
steps runs**.

A per-language difference becomes a condition:

```yaml
    - transform: hesitation
      when: language == "fr" && text.matches("\\b(genre|du coup)\\b")
```

### Migration

A config carrying `pipelines:` is read for one release, and `--check-config`
refuses it:

- `pipelines:` with only `default:` — the steps are taken, and the message says
  to delete the `pipelines:`/`default:` lines and dedent.
- `pipelines:` with any language key — refused, exit non-zero, and the message
  names the key and says to write `when: language == "<key>"` on the steps that
  differ.

The second one is refused rather than merged because a `fr:` list that silently
becomes the `default:` list is a behaviour change nothing on screen would show.
The app also logs it once at launch, since `--check-config` is not something
everybody runs.

**[built]** The first one is a warning, not a refusal. `--check-config` exits 0
and prints it as a notice, because the `default:` steps do run and nothing about
the dictation changed. The app logs it at launch the same way — `applyConfig`
already writes every `problems()` and every `notices()` line. The refusals are
`problems()` entries, so they exit 1 and go to the log with no new plumbing.

**[built]** "Refused" is a verdict on the config, not on the steps. The first
build let `pipeline` stay nil when a language key was present, so the app fell
back to `Pipeline.everything` — which is the automatic stages only. A config
naming fourteen stages then ran one, in both languages, with nothing on screen
saying so. That is a worse outcome than the silent merge this section was
written to avoid, so the two were split: `--check-config` still refuses and
exits non-zero, and the app keeps running one of the lists. `default:` if it is
there, otherwise the first of `languages:` with a key, and `--check-config`
names which. The rule the split holds to is that the app never ends up with
fewer stages than the config asked for without saying so.

**[built]** A `pipelines:` that is present but is not a map — a bare list,
which is what half a migration produces — throws `ConfigError.invalidValue`, as
`pipeline:` does for the same mistake. An earlier build read the decode failure
as an empty map, which accepted the config and dropped every step it named.
`scripts/check-pipeline-config.sh` holds both of these down.

---

## Part 2 — `steps:`, a fourth body

### The schema

```yaml
transforms:
  - name: handles
    description: use Slack handles for the people I name
    display: Adding handles
    confirm: true
    steps:
      - handles_match                     # short form: a transform name
      - transform: handles_read           # long form: a name and its conditions
        when: handles_match.count == 0
        publish: names
      - handles_apply
```

A `steps:` entry is written either way, exactly as a pipeline step is:

| | |
|---|---|
| `- <name>` | a transform, unconditionally |
| `- transform: <name>` | the same, with `when:` / `unless:` / `publish:` beside it |

`when:` and `unless:` are the existing keys with the existing meaning and the
existing two forms — `/a pattern/` against the text as it stands at that point,
or an expression over the variables. Same code, same validator.

**`app:` is not allowed on a member.** A group is reachable by voice, where
`app:` gates nothing (see *An instruction inside a dictation* in
[pipelines.md](../pipelines.md)). Put the `app:` on the step in the main
pipeline that names the group, where it means what it says.

### `publish:` — an answer, not a rewrite

A pipeline carries text. A member that *answers a question about* the text
rather than rewriting it has nowhere to put its answer, and this is the whole
reason the marker prototype had to smuggle the model's answer back through
`[[ ]]` in the sentence.

`publish: <key>` says: the output goes to `<member>.<key>`, and the carried
text is left alone.

```yaml
      - transform: handles_read
        publish: names          # the reply is a value; the message is untouched
```

It applies to any body whose only output is a string — `prompt:`, a plain
`command:`, `replace:`. It is **refused on a member declaring `returns: json`**,
which already says what it publishes and already says whether it touched the
text by returning a `text` key or not. One way to do a thing.

This is the key that makes *the model judges, code decides* spellable in the
config instead of hidden in a script. It also makes the invariant visible: in a
group where every `prompt:` member carries a `publish:`, no model wrote the
text.

### Variables, and the namespace boundary

Inside the group, a member publishes under its own name and a later member reads
it by bare name — `handles_match.count`, exactly as in a pipeline. Nothing new.

Outside, the group publishes:

| | |
|---|---|
| `<group>.ran`, `.ok`, `.changed`, `.ms` | derived by the outer loop, as for any stage |
| `<group>.<member>.<key>` | everything its members published |

`<group>.ok` is false when any member that ran reported `ok: false`. A group is
one capability; a failed part means the capability did not do its job. The text
still comes through — a failing member returns what it was handed, and the
members after it run on that. Fail open, as everywhere else here.

**A group reads nothing from the pipeline around it.** Its members' conditions
see the seeds — `text`, `app`, `bundle_id`, `language`, `instruction`,
`lists.*`, `asr.*` — and each other, and that is all. `--check-config` refuses
an outer namespace inside `steps:`.

The reason is that the same group runs in two places. In the pipeline, `input`
may have run above it; reached by voice, nothing has. A group that works in one
and throws in the other is a capability nobody can reuse, and no load-time check
could tell the two apart. Refusing is the only answer that holds on both paths.

Implementation note: `CommandRunner.Context.encode` splits a scope path at the
**first** dot, so `handles.handles_match.count` would nest as
`vars["handles"]["handles_match.count"]`. Either split fully or accept the flat
second level — decide it, do not discover it.

### The instruction reaches every body

Today the spoken instruction reaches a `prompt:` and nothing else, and the
handles feature is unbuildable because of it: the instruction is the input that
decides the answer, and the member that decides is a script.

The fix is one seed. `Pipeline.runCollectingScope` sets `instruction` in the
scope — empty on the pipeline path, as `{{instruction}}` already is — and three
things follow with no further plumbing:

- `{{instruction}}` in a prompt: unchanged, it is already a scope lookup.
- `ctx.instruction` for a `returns: json` script: free. `Context.encode` puts
  bare scope names at the top level of `ctx`.
- `when: instruction != ""` in a condition.

`instruction` joins `Scope.reserved`, or `--check-config` refuses the condition.

A `replace:` table still gets nothing. There is nowhere in a substitution table
to put an instruction, and inventing one is not on the table.

### Reached by voice

A group has a `description:`, so the router finds it like any other transform,
and `AppDelegate.perform()` gains a fourth case: build the `Pipeline` from
`steps:`, seed `instruction`, run it over the target text.

One carve-out is needed. `Pipeline.skipReason` skips a `transform` stage when
the text carries a wake phrase or an inline instruction, because a transform
that rewrote the sentence first could eat the phrase. On the voice path the
phrase has already been split off by `runInline`, so that guard must not fire
inside a group run. It belongs to the entry point, not to the stage — pass it
in rather than deriving it from the text.

`display:`, `offer:`, `key:` and `confirm:` are the group's. A member's
`display:` still updates the menu bar as the run passes through it, which
`Pipeline.run` already does per step. A member's `offer:`/`key:`/`confirm:` are
ignored when it runs as a member; they still apply when that member is asked
for by name.

**`timeout_seconds:` stays per member.** The group has none. A single number
over a group holding a `tr` one-liner and a model call is either too small for
one or too big for the other, which is the argument `timeout_seconds` was put
on the transform for in the first place.

### What is refused, at `--check-config`

| | |
|---|---|
| a member that does not exist | as a pipeline step naming no transform is |
| a member that is itself a group | one level. A cycle detector is more machinery than this needs, and a cycle fails as a hang on a live dictation |
| a fixed stage in `steps:` | `vocabulary` has an ordering rule stated over one flat list; `context` and `input` are about the hotkey press. Nesting either makes the check wrong or makes it a graph walk |
| `steps: []` | unlike `pipeline: []`, there is no "and I mean it" reading for a capability that does nothing |
| `steps:` beside `prompt:`, `replace:` or `command:` | one body, as today |
| `app:` on a member | see above |
| `publish:` on a `returns: json` member | see above |
| a condition reading an outer namespace | see above |
| a group named like a reserved word | as for any transform |

`--check-config` prints a group as its members, in order, with each member's
body kind beside it — and says which members write text. A group where a
`prompt:` writes the text is legal and is sometimes right; it should not be
possible to have one without knowing.

### Scoring

`--eval <group>` runs the whole group over `cases.yaml`. `--eval <member>` runs
one member, because a member is an ordinary transform with its own folder and
its own set. That is what says whether the prompt or the code is at fault, and
it is what `EvalCases.intermediate:` — `field:`/`produce:`/`resolve:`, built for
exactly this on the Slack mentions set — was a workaround for. It is superseded.
Removing it is a separate change.

One gap has to close for any of this to be scorable: **`instruction:` must be
readable per case**, not only once for the whole file. In the handles set the
instruction varies per case by construction, and a set with one instruction for
all of them measures nothing. A case-level `instruction:` overrides the
file-level one.

---

## The worked example

The one that drove this. Four names in a Slack message, and how many get tagged
depends on how you asked.

| How you ask | `instruction` | Who gets a handle |
|---|---|---|
| "…by the way parrot, use handles for Alex and James" | those words | Alex and James |
| "hey parrot, use slack handles", with text selected | those words | everyone in the roster who is in the text |
| the chip on the pill, or the hotkey | empty | the same — everyone |
| the main pipeline | — | **it is not in the pipeline.** See below |

So there are two defaults, and which one applies is decided by whether the
instruction names anybody. That is one function of one string, which is why it
belongs in the first member and not in the config.

```yaml
transforms:
  - name: handles
    description: use Slack handles for the people I name
    display: Adding handles
    offer: true
    key: h
    steps:
      - handles_match                     # the instruction, by rule
      - transform: handles_read           # only when the rule could not tell
        when: handles_match.mode == "unsure"
        publish: names
      - handles_apply                     # the only member that writes text

  - name: handles_match
    command: match.py
    returns: json          # reads ctx.instruction; publishes mode, names, count

  - name: handles_read
    description: which people an instruction is asking for
    prompt: |
      The instruction asks for some people by name. List them, one per line.
      Write nothing else. Write no handles.

  - name: handles_apply
    command: apply.py
    returns: json          # reads ctx.vars; writes handles from roster.json
```

### `mode`, and why the condition is not `count == 0`

`handles_match` reads `ctx.instruction` and returns one of three answers:

| `mode` | when | `names` |
|---|---|---|
| `all` | the instruction is empty, or says "everyone" / "tout le monde" | every roster name in the text |
| `named` | it names roster people | those |
| `unsure` | it names people and none of them resolve | empty — the model decides |

`unsure` is the whole reason `mode` exists. `count == 0` cannot tell "there is
nobody to tag and I am certain" from "I could not work out who you meant", and
those want opposite things. Two cases make it concrete:

- "use a handle for Patrick", and Patrick is not in the roster. Nobody is
  tagged, and tagging everyone would be the worst possible reading of it.
- "use handles for everyone except Mark". A rule that scans for roster names
  finds Mark and tags exactly the person you excluded. So an exclusion word —
  `except`, `but not`, `sauf`, `à part` — forces `unsure` whatever else matched.

Pronouns ("use her handle"), positional reference ("the first two") and a
mangled name ("Tasneem" for Tasmin) land in `unsure` the same way.

`handles_apply` reads both `ctx.vars.handles_match.names` and
`ctx.vars.handles_read.names`. The condition guarantees at most one is filled.

### An empty instruction is a value, not an absence

This is the amendment the pill path forces. `instruction: ""` means "you asked
by pressing a key, so tag everybody". A non-empty instruction that resolves to
nobody means something else entirely. Both the runtime seed and the case-set
format have to keep them apart:

- `Pipeline` seeds `instruction` as the empty string on every path that has
  none, never as absent. Absent throws in a condition, which is right for
  `input.appending` and wrong here.
- In a case set, a case with `instruction: ""` means empty. A case with no
  `instruction:` key inherits the file-level one. The two must not collapse, or
  half the set is unwritable.

### Why it is not in the main pipeline

A pipeline stage runs on every transcript, with no preview, before anybody has
seen the words. "Tag everyone by default" on that path is a message that pings
four people because you happened to say their names. The existing
`slack_mentions` is in no pipeline for exactly this reason, and it was measured:
a table triggered from inside the sentence turned "I should mention here that…"
into "I should @here that…".

Asking is what makes the broad default safe. The instruction, the chip and the
hotkey are all deliberate acts. The pipeline is not.

Two of the three asking paths show you the result first — `confirm:` covers the
selection path. The chip and the inline instruction give no preview, which is
the documented rule for both and not this transform's to change. What all three
produce is text in your composer; ParrotFlow never sends a message.

**Why it is shaped like this.** Measured this session, 33 cases plus 13 held
out:

- Rules alone: 33/33, 12/13 held out, both gates at zero, 33 ms. On a plainly
  phrased instruction — which is nearly all of them — nothing is left to judge.
  A name is string matching and a handle is a table lookup.
- A prompt alone: 6 wrong-person hits in 33, and 4 after a rewrite. On ordinary
  sentences it tags people the speaker did not name.
- Rules alone on instructions that need language — "use her handle", "everyone
  except Mark", "Tasneem" for Tasmin: 1/8. A prompt gets 5/8.

So the model runs only where the rules could not tell, it returns names and
never handles, and `apply.py` is the only thing that can write an `@`. The
condition `when: handles_match.mode == "unsure"` is the whole design in one
line, and it is in the config where it can be read.

**Two things those numbers do not cover.** Both are the case set's job before
anything ships.

- Every case in that set carries an instruction that names people. The `all`
  mode — an empty instruction, and "use handles for everyone" — is measured on
  two cases and needs its own bucket, including the one that must not fire:
  a message with four names where you pressed the chip and meant all four.
- The `unsure` gate is measured on 8 cases and the model gets 5. The rules get
  the other 33 with both safety gates at zero. **Ship the group without
  `handles_read` first**, and add it as a second step once its own set is
  clean. That is a one-line change to `steps:`, which is the argument for this
  shape rather than a script that chains its own model.

**It costs the router something.** The group has a `description:`, so it joins
the catalogue every spoken instruction is matched against, and every
description added is another way for an idle sentence to find a tool.
`tests/routing-cases.yaml` has to be rerun — it already carries one failure of
exactly this class, "I sent her an email yesterday" reaching `email`.

`code_identifiers` is the second candidate, and it is already this shape with
the seam hidden: the script chains its own model behind its own rules under a
`--model` flag. As a group the chain is three lines of config and each half is
scorable on its own.

---

## Open questions

Each has a recommended default. Take the default unless there is a reason.

| | Default |
|---|---|
| Key name: `steps:` or `pipeline:` on the transform | **`steps:`**. "Pipeline" names the whole thing; "steps" names the list. `transcription.pipeline:` holds one list of steps and a transform holds another. |
| `publish:` as its own key, or folded into `returns:` | **Fold it.** `returns: json` means the body describes itself; `returns: names` means the reply is a plain string filed as `<member>.names`; absent means the reply is the new text. One key, three readings, and `returns:` already refuses anything that is not `json` or `text`. Written as `publish:` throughout this document because it was not yet decided. |
| `<group>.ok` when a member is skipped by its `when:` | **Skipped is not failed.** `ok` reads false only for a member that ran and reported `ok: false`. |
| Can the main pipeline read `<group>.<member>.count` | **Yes.** It costs nothing and the alternative is a group that has to re-publish its own members' facts. |
| Does a member see the group's name anywhere | **No.** A transform should not behave differently for being inside a group; that is what makes `--eval <member>` mean anything. |
| Two members naming the same transform | **Allowed, the later run wins**, as two pipeline steps naming one transform already do. |

---

## Out of scope, but adjacent

- **Removing `EvalCases.intermediate:`.** Superseded here, deleted separately.
- **Groups inside groups.** Refused now. If it is ever wanted, it wants a cycle
  check and a depth limit, and neither is worth building before something needs
  it.
- **A group that returns a value rather than text.** `publish:` gives a
  *member* one. A whole transform that publishes instead of rewriting is a
  different thing and is not needed yet.
- **Deciding by itself who deserves a ping.** Out of scope for handles, and
  measured as such before: it needs a roster with per-name notes and it is the
  version that sends messages nobody asked for. Here the speaker says the names.
