# Proposal: a folder per transform, and one harness for everyone

**Status.** Specified, not built. Decisions below are settled — implement them
rather than reopening them.

**Goal.** A transform is a directory. Everything belonging to it — the prompt
or script, its case set, its data — lives inside, so it can be written, tested
and handed to someone else as one thing. Today the harness that scores a
rewrite lives in this git repo, which means nobody who installed the app has
it.

Two phases. Phase 1 stands on its own and is worth shipping alone; phase 2
needs it.

---

## Decisions already taken

Do not relitigate these; they were argued and settled.

| | |
|---|---|
| One layout, enforced | Folders. There is no flat alternative to fall back to. |
| Folder name | The transform's name, verbatim as `config.yaml` spells it. Underscores, not hyphens. |
| Entry point | `<name>.py` / `<name>.md` / `<name>.yaml` inside the folder — not `main.py` or `transform.py`. It is what people grep for, and a dozen editor tabs reading `transform.py` is miserable. |
| Case set | `cases.yaml` inside the folder. Uniform, and `--eval <name>` finds it by convention. |
| Inline bodies | Stay legal. A three-line prompt in a file is worse than in the config, and forcing it would break every config that exists, including the shipped `slack`. |
| Body kind | Stays explicit in `config.yaml`. **Never infer `command:` from finding a `.py`.** A config must say out loud when it executes code; inference means you cannot tell by reading it. |

---

## Phase 1 — folder resolution

### The layout

```
~/.config/parrotflow/
  config.yaml
  transforms/
    slack/
      slack.md              # the prompt
      cases.yaml
    slack_mentions/
      slack_mentions.py     # the entry point
      cases.yaml
      heldout.yaml
      roster.json           # data the transform owns
    dotted/
      dotted.yaml           # the replace table
      cases.yaml
```

### The rule

A transform named `X` owns `transforms/X/`. That folder is both where its
files are looked for and **the working directory its command runs in**.

The second half is what pays for the extra directory: a script can open
`roster.json` as a bare relative path, so the folder is self-contained. Copy it
to another machine, or paste it into a gist, and it works.

### Resolution order

For a relative body path declared by transform `X`, in the config at
`<configDir>/config.yaml`:

1. `<configDir>/transforms/X/<path>` — the folder. Normal case.
2. `<configDir>/<path>` — the old location. Resolves, runs, and is reported as
   needing to move (see *Back-compat*).
3. `PATH`, if and only if the path has no `/` in it — keeps
   `command: sed`-style one-liners working. This is existing behaviour in
   `CommandRunner.parts(of:base:)`; do not regress it.

An absolute path is used as-is and skips all three.

Both of these must resolve to the same file, because users will write both:

```yaml
command: slack_mentions.py
command: transforms/slack_mentions/slack_mentions.py
```

The first hits rule 1. The second is relative to `<configDir>` and hits rule 2
by spelling out what rule 1 does — so **rule 2 must be tried for any relative
path, not only for bare filenames**, and a path that already starts with
`transforms/X/` must not be reported as needing to move. Detect that case by
comparing resolved absolute paths, not by string-matching the prefix.

### `path:` on a body

`prompt:` and `replace:` gain a mapping form. `command:` already is a path.

```yaml
- name: slack
  description: tidy dictated text into a chat message
  prompt: { path: slack.md }              # transforms/slack/slack.md

- name: dotted
  description: spoken dotted paths as code
  replace: { path: dotted.yaml }

- name: slack_mentions
  description: turn people's names into Slack mentions
  command: slack_mentions.py
  tests: { path: heldout.yaml }           # optional; default is cases.yaml
```

- A scalar stays a scalar: `prompt: |` inline is unchanged.
- A mapping with `path:` reads the file, resolved by the order above.
- A `replace:` file contains the same mapping the inline table would.
- A prompt file is read verbatim. No front-matter, no templating.
- Unreadable or missing file: the transform is **skipped with a reported
  reason**, the way an entry with no body already is. It must not throw and
  cost the rest of the config.
- `namesBoth` validation is unchanged: a mapping form still counts as naming
  that one body.

### Back-compat

Existing configs point at `code_identifiers.py` beside `config.yaml`. Those
keep working, via rule 2. `--check-config` prints one line per such transform:

```
  · transforms: "code_identifiers" found at the old location —
      move it to transforms/code_identifiers/code_identifiers.py
```

A notice, not a fault. It goes through `notices()` and not `problems()` — the
distinction already exists in `Config.swift` for exactly this reason, and
getting it wrong makes the app announce that a working config is broken.

Nobody's setup stops working because they upgraded. No auto-migration; moving
files under someone without asking is worse than a line of output.

### `--check-config` requirements

For every transform, print the **resolved absolute path** of its body. A file
present in both the folder and the old location is otherwise invisible, and
"which one is running" is the first question when something is wrong.

Keep `notices()` naming every `command:` out loud, every run. That is not
negotiable and is not replaced by the path line.

### Seeding

First launch writes folders instead of loose files:

```
transforms/code_identifiers/code_identifiers.py
transforms/code_identifiers/cases.yaml
```

Extend whatever writes `Config.exampleScript` today. Seed the case set with
it — a shipped example that comes with its own set is the whole argument of
`docs/authoring.md`, made concrete.

### Files to touch

| File | What |
|---|---|
| `Sources/ParrotFlow/Config.swift` | `TransformEntry` decoding (~74–110) for the mapping form; `assembled()` (~127–168); add the folder URL to `Transform` beside `directory` (~205–208); `notices()` (~1012) and `problems()` (~965–990) for the new lines; `exampleScript` (~1044) and the seeding around ~1059–1066 |
| `Sources/ParrotFlow/CommandRunner.swift` | `parts(of:base:)` and `complaint(about:base:)` (~174–250) take the folder as `base`. `run` already sets `currentDirectoryURL = base` (~71), so the working-directory half is nearly free |
| `Sources/ParrotFlow/CheckConfigCommand.swift` | the resolved-path line, and the old-location notice |
| `config.example.yaml`, `docs/configuration.md`, `docs/pipelines.md`, `docs/authoring.md` | the layout, the rule, the `path:` form |
| `scripts/check-default-config.sh` | reads the real file; will need the new shape |

**Note:** `Config.swift` had uncommitted changes from another session on
2026-08-04. Check `git status` and coordinate before starting.

### Acceptance

```sh
PF=/Applications/ParrotFlowDev.app/Contents/MacOS/ParrotFlow

$PF --check-config          # names every command, prints resolved paths,
                            # exits 0 on a folder-shaped config
```

- [ ] `command: slack_mentions.py` and
      `command: transforms/slack_mentions/slack_mentions.py` resolve to the
      same file, and neither is reported as needing to move
- [ ] a script in the folder can open a sibling data file by bare relative
      path
- [ ] `command: sed` still works
- [ ] a config with a script at the old location runs, and gets exactly one
      notice, and `--check-config` still exits 0
- [ ] `prompt: { path: ... }` and an inline `prompt: |` both run
- [ ] a `path:` pointing at a missing file skips that one transform, reports
      why, and leaves the rest of the config working
- [ ] every existing `scripts/check-*.sh` still passes

---

## Phase 2 — one harness, in the binary

### Why

Every rewrite in this repo ships with a case set and a bespoke runner in
`scripts/`. Users get neither. A generic runner turns "write a prompt and hope"
into the loop `docs/authoring.md` already prescribes.

### CLI

```sh
ParrotFlow --eval slack_mentions              # transforms/slack_mentions/cases.yaml
ParrotFlow --eval slack_mentions --cases heldout.yaml
ParrotFlow --eval slack_mentions --verbose --probe ambiguity_common
ParrotFlow --eval <path/to/cases.yaml>        # one-off, outside a folder
```

Resolve the transform from the user's real config and run **that**, not a
reimplementation. `scripts/validate-slack-mentions.py` imports the shipped
script for this reason; the note in `docs/authoring.md` about a runner drifting
from the app is worth 31 points of measured error.

### Case file format

```yaml
# Contract prose at the top: what counts as a case here, what is deliberately
# out of scope. It is what you will disagree with yourself about in a week.
cases:
  - probe: ambiguity_common       # optional; groups the breakdown
    input:  mark it as resolved
    expect: mark it as resolved
```

`input` and `expect` are the whole requirement. Everything else is optional.

### Scoring — the non-obvious requirements

These come from building `validate-slack-mentions.py`; each one caught
something real.

1. **Split the halves and report them separately.** Cases where
   `input == expect` are the must-not-change half. Detect it — do not make the
   author declare it. On the Slack mentions set that half was 36 of 76 and it
   is the one that decides whether a transform is usable: a rewrite that scores
   well on `change` and badly on `keep` means proof-reading every dictation.
2. **Break out by probe**, never only an aggregate. One broken category hides
   behind eleven healthy ones.
3. **Report latency per case**, warm. Cold-start timings send you optimising
   the wrong thing.
4. **A no-model control**, when the transform can run without one. On this task
   it scored the same as the model and the model was dropped; on spoken
   identifiers the control won outright. It is the only thing that answers
   "is the model earning its place".
5. **Optional intermediate gold** for two-stage transforms — a second field
   holding what the model alone should return. Scoring it separately says
   whether the prompt or the code is at fault. The gap ran 25 points on this
   task.
6. **Check the gold against itself before scoring anything.** Where an
   intermediate gold exists, resolving it must produce `expect`. A typo in the
   gold otherwise scores every candidate against a typo, silently, forever.

Custom gates — the Slack set counts wrong handles and false `@channel`
separately, and both must be zero — do **not** generalise. Leave them to a
bespoke script. The generic runner does 1–6.

### Acceptance

- [ ] `--eval` on a shipped example gives the same number as the bespoke
      runner in `scripts/`
- [ ] a transform whose body is a `command:` and one whose body is a `prompt:`
      both score
- [ ] the must-not-change half and the per-probe grid are always printed
- [ ] a case file with a bad gold is refused, loudly, before any scoring

---

## Out of scope, but adjacent

**Command transforms cannot be reached by voice.** `Catalogue(prompts:)` in
`Capability.swift` is built from `config.prompts`, which is
`transforms.compactMap(\.asPrompt)`, and `asPrompt` returns nil for a
`.command` body. So "hey parrot, use Slack mentions" silently routes elsewhere
once that transform becomes a script. Fixing it means `Capability.transform`
carrying a `Config.Transform` rather than a `Config.Prompt`, and `run` in
`AppDelegate.swift` dispatching `.command` through `CommandRunner`.

Not part of this proposal, but whoever takes this will read the same code, and
it is a live bug rather than a hypothetical.

**Moving a roster out of a script into a data file** is the obvious
demonstration of the folder idea and is deliberately not required here. If it
is done, use JSON rather than YAML: the seeded scripts depend on nothing
outside the standard library today, and a user script that dies on a missing
PyYAML is a worse failure than a table in a `.py`.
