---
name: parrot-folder
description: Share ParrotFlow vocabulary and transforms across a team through a `.parrot/` folder in a repository. Use to pull a repo's names and transforms into someone's config, to screen what it offers against this speaker, or to publish the vocabulary and transforms they already have back into the repo for their team.
---

# The `.parrot/` folder

A repository can carry the names its team says out loud, and the transforms
they wrote. The folder is `.parrot/` at the root of the repo. The layout and
the rules are in `docs/sharing.md`; this skill is the procedure.

```
<repo>/.parrot/
  vocabulary.yaml    # the names
  config.yaml        # `transforms:` entries, paths relative to this folder
  transforms/<name>/ # one folder each, the same layout as a config folder
```

**The folder is hints, not settings.** The app never reads it. You do, you
screen it against the person in front of you, and you write the result into
`~/.config/parrotflow/vocabulary.yaml` and `config.yaml`. Two things make that
indirection worth its cost, and they are the two things to keep in mind the
whole way through:

- **A term is a risk, and the risk is personal.** Each term is another chance
  to overwrite a correct word. Whether it does depends on this speaker's accent
  and which languages they dictate in. Somebody else's screening does not
  transfer.
- **A shared transform runs someone else's program on this machine.** Read it,
  and say what it does out loud, before it is ever in a pipeline.

## Say this before you touch anything

> That folder is a few text files in a git repository. Everything I write from it
> goes into your config on this Mac, and nothing goes the other way unless you
> ask me to publish. A shared transform is a program — I will show you what
> each one runs before anything runs it.

Then keep it true. Do not paste a colleague's name into a web search or a
hosted model to check its spelling. Work from the folder and from what the
user tells you.

---

# Importing a folder

## Step 1 — find it, and say where it came from

```sh
ls .parrot/                                   # the repo you are in
git -C <repo> log -1 --format='%h %s' -- .parrot   # what you are importing
```

Record the short commit. Every entry you write carries it, which is the only
way to answer "is my copy behind" later.

## Step 2 — read it out, do not merge it yet

List what the folder offers, in three groups: terms, transforms, and the
rejected list its comments carry. Keep the list short — names and one line
each. Do not restate a whole roster of colleagues for the sake of a tidy
summary.

Four things do not travel. Drop each one and say so — the folder is still
worth importing without them, and a silent drop is how one machine's tuning
ends up on everyone's:

| Found | Why it stays behind |
|---|---|
| `offer_below:` or `decide_above:` | The reader's two numbers. They are measured over a whole set on one machine. |
| a `pronunciations:` entry `from: correction` | One person fixing their own transcript. It is evidence about their voice. |
| any `.wav`, or a `voice/` directory | Speaker audio. It never belongs in a repository — see `scripts/check-no-voice.sh`. |
| a `models:` block, an endpoint, a key | Not shareable, and a key in a repo is an incident. |

`scripts/check-parrot-folder.sh <path>` finds all four and checks the
transform paths. Run it rather than reading for them. It exits 1 on any of
them, which is the folder's author being told, not you being stopped: import
what is left, and offer to fix the folder.

## Step 3 — screen every term against this speaker

This is the work. The criteria are in
`.claude/skills/vocabulary-corpus/SKILL.md` — steps 1, 3 and 5 — and they
apply unchanged. The short form:

1. **Drop what the decoder already writes correctly.** Pure risk, no gain. The
   author's decoder is not this one and their list will contain some.
2. **Drop what nobody here says out loud.** A term is worth its risk only if
   this person dictates it. Ask about anything you cannot judge from the repo.
3. **Find each term's nearest ordinary word**, in *this speaker's* languages
   — read `transcription.languages` from their config, do not assume `en`. A
   French speaker needs the French check; an English-only speaker does not, and
   a French word list would reject terms that are safe for them.
   0.85 or above means `floor: off` and a `pronunciations:` list, whatever the
   folder says.
4. **Re-check the two-word trap.** Any term shaped like a verb-particle pair —
   `turn down`, `back end`, `log in` — is unsafe by construction, and glues.
5. **Keep the folder's rejected list.** If it says `Sentry` was rejected for
   "entry" at 0.83, that finding stands. Do not re-derive it and do not
   silently overrule it.

Terms that survive go in. Terms that do not go in your report, with the reason,
and — if the folder does not already say so — offer to push the reason back
into the folder's rejected list so the next person does not repeat the work.

## Step 4 — merge into `vocabulary.yaml`

The file sits beside `config.yaml` and carries a "do not edit unless you know
what you are doing" header, because it is normally written by the app — from
corrections and from `--learn`. Say that you are the other thing that writes
it, rather than editing under a header you are ignoring.

Rules for the merge:

- **A local entry wins.** If the term is already there, leave it. Its `floor:`
  and its `pronunciations:` were measured on this machine.
- **A rendering arrives as `from: mined`.** Nobody in this room confirmed it.
  `correction` and `calibration` are labels this machine's own evidence
  earns.
- **Carry the source in `note:`.** `note: parrotflow/.parrot @ 3a8a849`. It is
  never parsed, and it is what makes a re-import diffable.
- **Do not copy the two file-level numbers**, ever, even if the folder has
  them. Leave the reader's as they are.
- **`kind:` travels.** What a term names is a fact about the term.

```yaml
terms:
  RedCrawl:
    kind: organization
  Sentry:
    kind: organization
    floor: off
    pronunciations:
      - heard: entry
        from: mined
        note: acme/.parrot @ 3a8a849
```

Then check it with the parser, not by reading:

```sh
ParrotFlow --check-config      # what survived, and what it now searches for
```

## Step 5 — transforms, one at a time

Never bulk-import these.

For each entry in the folder's `config.yaml`:

1. **Read the body.** A `command:` is a program. Say in one sentence what it
   does, what it reads, and whether it reaches the network. If it does reach
   the network, say so as its own sentence: that is a real exception to
   "nothing leaves this Mac".
2. **Copy the folder**, do not link it. `cp -R .parrot/transforms/<name>
   ~/.config/parrotflow/transforms/<name>`. The transform's folder is its
   working directory, so a copy is self-contained; a path into a checkout
   breaks the day someone moves it.
3. **Add the config entry** to `transforms:` in their `config.yaml`, verbatim
   from the fragment. The paths are already relative to the folder.
4. **Score it before it is in a pipeline.** `ParrotFlow --eval <name>` runs the
   `cases.yaml` that came with it. Read both halves: `keep` — the cases where
   input and expect are the same — is the one that decides whether it is
   usable. A transform whose set does not pass on this machine does not go into
   the pipeline; report the number instead.
5. **Take the lists it needs.** A `replace:` table written as `{{handles}}`
   is nothing without the `lists:` entry behind it. Copy only the lists the
   transforms you took actually name, and never overwrite a list the user
   already has under that name — rename the incoming one and say you did.
6. **Enabling is a separate question.** A transform in `transforms:` is
   reachable by voice. A transform in `transcription.pipelines` runs on every
   dictation. Ask before the second one, and cost it: a `prompt:` stage is
   about a second and a half warm.

## What to hand back

- What went in: terms, and transforms with their `--eval` numbers.
- What did not, with the reason for each. This is the half that gets re-added
  next month if you leave it out.
- Anything that needs the user's ear — the step 5 sentences from the
  vocabulary skill, for terms nothing mechanical can settle.
- The commit you imported, so the next run can say what changed.

---

# Publishing a folder

The other direction: someone has a working vocabulary and wants their team to
have it.

## Step 1 — take what travels

From their `vocabulary.yaml`: the terms, `kind:`, `floor: off` where it is
there, and the renderings **not** labelled `from: correction`.

## Step 2 — strip what does not

| Leave out | Why |
|---|---|
| `offer_below:`, `decide_above:` | Measured for one machine over one set. |
| `from: correction` renderings | One person's mouth. Publish the term, not the evidence. |
| `seen:` counts | A count of this person's dictations. |
| `voice/`, any `.wav` | Never in a repository. |
| Terms that are one person's own — a family name, a personal project | Ask term by term. Do not guess what is private. |

A term with every rendering stripped is still worth publishing. The name is the
valuable part; the renderings are how one decoder mangled it.

## Step 3 — write the folder, with the reasons

Include the rejected list as comments in `vocabulary.yaml`. A term someone
screened and threw away is a finding, and it is the part that stops the next
person doing the work again:

```yaml
# Rejected, and why. Do not re-add without a measurement.
#   Supabase, Playwright, Tailwind — written correctly already, pure risk
#   Turndown                       — "turn down the volume" glues to it
```

For a transform, copy the whole folder — the entry point **and** its
`cases.yaml`. A transform published without its case set cannot be scored by
whoever receives it, and an unscoreable rewrite is one nobody can safely
change.

## Step 4 — check it, then commit

```sh
scripts/check-parrot-folder.sh <repo>/.parrot
```

Say what the commit contains before it is pushed: a repository is a wider
audience than a config file, and a colleague's name in it is there for good.

---

# Re-importing

A copy drifts. That is accepted — the alternative is the app reading a
checkout it does not own.

On a second run, compare the folder's current commit against the `note:` lines
already in `vocabulary.yaml`. Report three groups: new terms, terms whose
folder entry changed, and local entries that now differ from the folder's.
The last group is not a conflict to resolve — a local `from: correction`
rendering beats anything a repository says, every time.
