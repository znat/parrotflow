# Proposal: projects — a team's vocabulary, picked rather than guessed

**Status.** Planned. Nothing here is built. One superseded first cut sits on
`claude/parrot-folder-vocab-sharing-c6aj9b`; *What is already on the branch*
at the bottom says what survives it.

**Goal.** A repository carries the names its team says out loud, in a
`.parrot/` folder. A person picks which project they are in; the app merges
that project's names into their vocabulary. Nothing is detected, nothing
arrives unasked, and a wrong pick is one keystroke from being right.

---

## Decisions already taken

Do not relitigate these. Each was argued and settled.

| | |
|---|---|
| The folder | `.parrot/` at the root of a repository. `vocabulary.yaml`, later a `config.yaml` fragment and `transforms/`. |
| Who reads it | **The app**, at config load. Not an agent, not a hook. |
| Which folder | The one the person **picked**. No window titles, no `AXDocument`, no `proc_pidinfo`, no editor hook. |
| Why not detection | The app is not repository-aware, and the one field that would make it so — the window title — was refused on privacy grounds in `Trace.swift:62`. Detection returns later as an *optional writer* of the pick, never as its foundation. |
| A project | A **named set of folders**, not a repo. One name can turn on two checkouts. Repo-ness is detected *within* a folder, to find the root and the name. |
| Default | **No project.** The local `vocabulary.yaml` always loads; no shared folder loads until one is picked. |
| The pick | Sticky and global. Held in a state file beside the config, never in `config.yaml` — that file is written by a person. |
| Shown | In the dictating pill, beside the app icon. Nothing shown, and nothing wider, when no project is active. |
| Switched | On the offer, as chips with letters — `hud-placement-and-offer.md` §3 settled that this surface is buttons, not a menu. The full list lives in the menu bar. |
| A switch repairs | Re-run the vocabulary pass on the last dictation; if its text changed, re-run the transforms and replace what landed. |
| Precedence | Local always wins, per term, whole. No key-by-key blending. |
| Transforms | **Phase 2.** A `command:` from a repository is code execution by `git pull`, and it needs its own opt-in. |

---

## Phase 0 — the measurement that gates the design

`Vocabulary.prepare` rebuilds the spotter whenever the term signature changes
(`Vocabulary.swift:103`): tokenizer load, then one `encode` per term. A project
switch changes that signature, and the switch is now **interactive** — someone
presses a letter and waits. Nobody has swept that cost.

Two halves, and only one of them needs a voice:

- **`prepare()` against term count** — 5, 10, 25, 50, 100 terms. No audio: the
  work is tokenising, and a term is a string. This is a command anyone can run,
  and it belongs in `scripts/`.
- **`apply()` against term count** — needs a clip and is therefore **HUMAN**,
  on the author's own recordings. `check-no-voice.sh` keeps audio out of the
  repository, so this number is recorded here in prose rather than in a set.

Record both in this file before Phase 1 is built. They decide two things: how
many terms a project may contribute before it hurts, and whether the switch can
rebuild inline or has to warm ahead.

---

## Phase 1 — projects, merged vocabulary, pick and repair

### The config

```yaml
transcription:
  projects:
    - ~/work/acme                    # a repo: name and .parrot/ found from it
    - name: infra                    # the mapping form, when you want to say more
      folders: [~/work/acme-infra, ~/notes/infra]
```

A scalar stays a scalar and a mapping adds detail — the same shape `prompt:`
already has. Order is the order the chips appear in.

### Resolving a folder

For each folder, in order:

1. Expand the tilde. An absolute path is used as-is; nothing else is searched.
2. Walk up for `.git`, accepting a **file** as well as a directory — a worktree
   and a submodule both write a file. The first hit is the root.
3. `.parrot/` is looked for at that root. Pointing at
   `~/work/acme/services/api` therefore finds `~/work/acme/.parrot/`.
4. No `.git` anywhere above: the folder is used as its own root. A project need
   not be a repository. It contributes whatever `.parrot/` it literally has.
5. The name, when the config does not give one: the repository root's directory
   name. Not the remote — a fork, a mirror and a rename all change it, and the
   name is a label on a pill rather than an identity.

A folder that does not exist, or a root with no `.parrot/`, is a **notice, not
a fault**. Laptops differ, and a checkout you have not cloned yet must not cost
you the rest of your config.

### What a project contributes, and what it cannot

Read from `<root>/.parrot/vocabulary.yaml`:

| Taken | |
|---|---|
| `terms:` | the names |
| `kind:` | what a term names — a fact about the term |
| `floor: off` | the switch, not a threshold |
| `pronunciations:` | each one relabelled `from: mined` on the way in |

| Refused, with one line from `--check-config` | Why |
|---|---|
| `offer_below:`, `decide_above:`, `acoustic:` | one machine's tuning, measured over one set |
| a rendering `from: correction` | one person fixing their own transcript — evidence about their voice |
| any key not listed above | a shared file carries `terms:` and nothing else |

The app **never writes** a `.parrot/` folder. Corrections, `--learn` and the
correction panel keep writing the local `vocabulary.yaml`, exactly as now.

### Merging

Per term, whole. A term named in the local `vocabulary.yaml` shadows the
project's entry completely — no blending of `floor:` from one and
`pronunciations:` from the other, so "where did this come from" has one answer.
Two folders in one project merge in listed order, first wins.

The result is `Config.vocabulary`, so everything downstream —
`vocabularyTerms` (`Config.swift:604`), the rules, the pronunciations — is
unchanged. That is the whole point of merging at load: one file's worth of new
code, and no new path through the pass.

### Re-reading

`AppDelegate.watchTransformFiles` (`AppDelegate.swift:1013`) already builds
`FileWatcher`s from paths the config names, after the load. Each active
project's `vocabulary.yaml` gets one the same way, so a `git pull` re-merges
live. A malformed shared file costs that folder and nothing else: fail open,
the same rule a stage has.

### The pill

- **No project active:** the pill is what it is today. `PillMetrics.panelSize`
  (`PillHUD.swift:807`) is not asked for another pixel.
- **A project active:** its name beside the app icon, in the dictating state
  and in the offer.
- **The switch:** project chips on the offer, letters like every other chip,
  capped by recency at about three. The rest of the list is in the menu bar.
  A pick from the menu bar sets the project and touches no text.

### The repair

The interesting half. On a switch from the offer:

1. **Re-run the vocabulary pass** — `Vocabulary.apply(to:samples:tokenTimings:config:)`
   (`Vocabulary.swift:563`), the same call `Transcriber` makes at
   `Transcriber.swift:365`, with the merged config the new project produces.
2. **If its text is unchanged, stop.** Nothing downstream can move. Say so on
   the pill, with the treatment #176 already built for a transform that
   changed nothing. No transforms run, no model is reached, nothing is
   replaced. This is the common case — you picked the wrong project, and this
   sentence had no names in it.
3. **Otherwise re-run the transforms** over the new text, and replace what
   landed.

#### It lands in the destination, or it is not a repair

Producing better text is half the job. The words are already in somebody's
Slack composer or terminal, and the repair has to reach them there. It is the
same problem an offered transform already solves, and it uses the same path —
this is the strongest reason to put the switch on the offer rather than
anywhere else.

- **Into the field.** `Correction.Landing` (`AppDelegate.swift:3170`) records
  which of the two endings the dictation had: pasted into an element that was
  confirmed focused at the paste, or left on the clipboard with the
  `changeCount` as it was. The replace path hands focus back first, then
  replaces what the app typed rather than pasting after it.
- **In a terminal.** The line cannot be edited in place, so `rewrite_line`
  clears and retypes it — the same route an offered transform takes, and the
  same refusal when the line will not take it.
- **When it will not land**, because the field moved on, the element is gone,
  or the clipboard's `changeCount` says it is no longer ours: the corrected
  text goes to the clipboard and the pill says so. That is an ending the app
  already has, not a new one.
- **Never clobber typing.** The replacement targets what the app wrote. If
  what is there is no longer that sentence, it takes the clipboard ending
  instead of overwriting somebody's edit.
- `noteRewritten` (`AppDelegate.swift:3362`) then keeps `lastTranscript`
  honest, so a command chosen after the repair works on the repaired text.

The pill says which happened, in the words it already uses for a transform
that landed, a transform that changed nothing, and a rewrite that ended on the
clipboard.

**Retention is the one genuinely new thing.** The clip is deleted after every
dictation unless `logging.audio` is on (`Recorder.swift:589`), and the pass
needs `samples` and `tokenTimings`. So the last dictation's raw ASR text,
samples and timings are held **in memory** for the life of the offer and
dropped when it closes. Never written to disk, so `logging.audio: false` still
means exactly what it says — and the docs say that out loud, because "it kept
my audio" is the sentence people care about.

The offer's clock stops while a re-run is in flight, and the pill shows it
working. A rebuild plus a spotter pass plus a judge call is not instant, and a
surface that sits still reads as broken.

### What `--check-config` prints

- every project, its resolved root, whether it is a repository, and whether it
  has a `.parrot/`
- how many terms each contributed, and how many were shadowed by local ones
- every refused key, one line each, naming the file
- which project is active, and that the pick came from the state file

### Trace

One field for the active project on a dictation, and one line when a switch
repaired something — the text before and after. Not the folder path. This is
what makes "did the repair change more than the names" answerable later
instead of arguable.

### Files to touch

| File | What |
|---|---|
| `Sources/ParrotFlow/Project.swift` *(new)* | resolution, repo-root walk, name, and reading a `.parrot/vocabulary.yaml` into the shared shape |
| `Sources/ParrotFlow/Config.swift` | `projects:` under `Transcription` (~1479); merge into `vocabulary` (169, 442); the new lines in `problems()` (2295) and `notices()` (2400) |
| `Sources/ParrotFlow/AppDelegate.swift` | the active project and its state file; watchers beside `watchTransformFiles` (1013); the menu bar list; the offer chips and the repair, around `Correction` (3157) and the replace path |
| `Sources/ParrotFlow/PillHUD.swift` | the project label in the model, and `PillMetrics.panelSize` (807) — unchanged when there is none |
| `Sources/ParrotFlow/Transcriber.swift` | hand the raw text, samples and timings back out for retention (343–380) |
| `Sources/ParrotFlow/Trace.swift` | the active project on a dictation, and a line when a switch repaired |
| `Sources/ParrotFlow/CheckConfigCommand.swift` | the project block described above |
| `config.example.yaml`, `docs/configuration.md`, `docs/sharing.md`, `docs/transcription.md` | the config shape, the merge rules, and what retention means for `logging.audio` |
| `scripts/` | the two check scripts, and the `prepare()` sweep from phase 0 |

### Acceptance

```sh
PF=/Applications/ParrotFlowDev.app/Contents/MacOS/ParrotFlow
$PF --check-config
```

- [ ] no `projects:` in the config leaves `--check-config` output unchanged
- [ ] a project pointing at a subfolder of a repo resolves to the root's `.parrot/`
- [ ] a worktree, whose `.git` is a file, resolves
- [ ] a folder that is not a repository is accepted and contributes its own `.parrot/`
- [ ] a missing folder is a notice, exits 0, and the rest of the config loads
- [ ] a shared file carrying `offer_below:` loads its terms and refuses that key, by name
- [ ] a rendering `from: correction` in a shared file does not become a local one
- [ ] a term in both files takes the local entry whole
- [ ] with no project picked, the merged vocabulary equals the local one exactly
- [ ] the pill is not one pixel wider with no project active
- [ ] a switch whose vocabulary output is unchanged reaches no model and replaces nothing
- [ ] a switch whose output changed replaces the text **in the destination** — the field it was pasted into
- [ ] the same, in a terminal, through `rewrite_line`
- [ ] the same, when the dictation ended on the clipboard and nothing has copied since
- [ ] text edited since the dictation is never overwritten: the repair takes the clipboard ending and says so
- [ ] the clip is still deleted after the offer closes with `logging.audio: false`

Two scripts: one for the merge, whole config directories in `/tmp` through
`PARROTFLOW_CONFIG_DIR`, the way `check-vocabulary-config.sh` already works;
one for resolution, over fixture folders built by the script itself.

---

## Phase 2 — transforms from a project

Needs phase 1. Held back because a `command:` in a repository is code execution
by `git pull`: anyone with commit rights runs a program on every teammate's Mac.

The shape, to be argued when we get there:

- A project's `.parrot/config.yaml` is a fragment. Only `transforms:` and
  `lists:` are read; paths are relative to the folder.
- A shared transform runs only if the **local** config names it. The fragment
  proposes; the person disposes.
- `notices()` names every `command:` from a project out loud, every run, on top
  of the rule it already follows.
- The folder is the working directory, as `transform-folders.md` settled.
- A project that is not active contributes no transforms at all, which is one
  more thing the pick buys.

Open, and worth deciding then: whether an approved transform is pinned by
content hash, so a changed script asks again.

---

## Phase 3 — hints, later

Once a project is picked, the pick is a value. Anything that can set that value
is an optimisation on a working feature:

- a Claude Code hook writing the session's `cwd` for the app to read
- a window title matched against known project names and thrown away
- `AXDocument` on a window that publishes one

Each is optional, each can be wrong, and the pick always wins. That ordering is
the reason to build the pill first.

---

## What is already on the branch

`claude/parrot-folder-vocab-sharing-c6aj9b` holds one commit written before
this was discussed. It assumed the app never reads the folder, which this
proposal reverses. What survives:

- `scripts/check-parrot-folder.sh` — the repo-side lint. Still right, and
  phase 1 needs it.
- The `.parrot/` folder this repository carries, and its format.
- The publish half of `.claude/skills/parrot-folder/SKILL.md` — writing a
  folder from what somebody already has, and what to strip on the way.

What does not: the whole import half of that skill, and the framing throughout
`docs/sharing.md` that the app never opens the folder. Both need rewriting
against this document, or removing until it is built.
