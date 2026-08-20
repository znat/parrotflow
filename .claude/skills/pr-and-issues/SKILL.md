---
name: pr-and-issues
description: Write a pull request or an issue that reads in twenty seconds. A title that works on its own in the release notes, a short lead, and the evidence folded into expandable details. Use when opening or editing a PR or an issue, when rewriting a title so the changelog reads well, or when a body has grown too long to skim.
---

# Writing a pull request or an issue

A reader gives you twenty seconds. Most readers stop there. Some need the
measurements, the alternatives and the diff walk-through, and they will open
them.

So every PR and every issue has two layers:

1. **The lead.** Plain text, no heading, at the top. Three to six sentences.
   What is wrong or what changed, why it matters, and what happens now.
2. **The details.** Everything else, inside `<details>` blocks with a summary
   that says what is in them.

Nothing important lives only inside a `<details>`. A person who reads the lead
and stops must still know what this is and whether it affects them.

## Titles

The title is the part most people read, and it is the only part that survives
into the release notes. Write it for someone who did not read the diff.

**Pull requests.** Conventional Commits, checked by
`.github/workflows/pr-title.yml`. The type decides the release:

| Type | Means | Release |
|---|---|---|
| `feat:` | a capability that was not there before | minor |
| `fix:` | behaviour that was wrong is now right | patch |
| `perf:` | same behaviour, measurably faster | patch |
| `docs:` `refactor:` `test:` `build:` `ci:` `chore:` | no user-visible change | none |

Add `!` before the colon for a breaking change: `feat!: …`.

After the colon, say what the change does, not what area it touches. The
subject is a changelog line. It has to make sense on its own, next to twenty
other lines, with no branch name and no issue number for context.

    feat: the log shows the caret and the text either side of it
    fix: a dictation the decoder returned nothing for is decoded again

Not this:

    feat: logging improvements          <- improved how?
    fix: fix #158                       <- the changelog cannot open #158
    refactor: AppDelegate               <- a file name is not a change

Rules that catch most bad titles:

- Name the thing that changed for the person using the app, not the symbol you
  edited.
- No branch names, no issue numbers, no "various", no "improvements", no
  "update X".
- If the title needs the body to be understood, it is not finished.
- One line. Under about 72 characters.
- `docs:` and `chore:` are hidden from the changelog. Do not hide real work
  under them to avoid a version bump.

**Issues.** No type prefix. One sentence stating the problem as a fact, in the
words of someone who hit it.

    Switching the input microphone leaves the app recording silence
    The fallback copy can overwrite a clipboard the app does not own

Not `Bug in AudioEngine` and not `Fix the microphone`. State the observed
behaviour. The title is the search result someone will find in six months.

## The lead

Three to six sentences. No heading above it. Answer, in this order:

**For an issue:** what happens, when it happens, what it costs. Add the rate or
the count if you have one. Do not open with the code path — open with what a
person sees.

**For a pull request:** what it changes, what it turns on or off, and what a
reviewer should check. If the change is behind a setting, name the setting and
its default in the lead.

If a table makes the lead shorter, use one. A three-row table of
sequence → today → wanted beats a paragraph.

Leave the lead as plain text. Headings above it push it down the page and cost
it its job.

## The details

Everything long goes in a toggle. On GitHub a `<details>` block needs a blank
line after `</summary>` or the Markdown inside it will not render.

    <details>
    <summary>How the loss was measured — 150 dictations, 5 signals</summary>

    Body here. Markdown works: tables, code blocks, lists.

    </details>

Write the summary line as a claim, not a label. `Evidence` tells the reader
nothing. `Five signals were tested and none separate the broken clips` tells
them whether to open it.

Common blocks, in the order they are usually wanted:

- **Why it happens** — the mechanism, the file, the line.
- **What was measured** — the numbers, the case set, before and after.
- **What was tried and rejected** — the alternative and the reason it lost.
- **What this does not fix** — the known gap, so nobody re-files it.
- **Review notes** — where to start, what is mechanical, what is risky.

Three or four toggles is normal. Ten is a document, not a PR. If you have ten,
the change is too big or the writing is repeating itself.

## Language

Follow `CLAUDE.md`: simplified technical English, in the body and the title.

- Short sentences. One idea per sentence.
- Plain words. "use", not "leverage". "so", not "which is why".
- Lead with the point, then the reason.
- Concrete: names, numbers, file paths, `Transcriber.swift:47`.
- No rhetorical build-up, no em-dash chains, no punchy phrasing.
- Say "this loses about 2% of dictations", not "this can be problematic".

Write for a reader who is smart and in a hurry, and who may not know this part
of the codebase.

## Templates

**Issue:**

    <one sentence of what happens, and when>
    <one or two sentences of what it costs, with a number if you have one>
    <one sentence of what it should do instead>

    <details>
    <summary>Why it happens</summary>

    ...

    </details>

    <details>
    <summary>What the fix would touch</summary>

    ...

    </details>

**Pull request:**

    <type>: <what changed, in plain words>

    <what this changes, and for whom>
    <the setting and its default, if there is one>
    <what a reviewer should check first>

    Closes #NN.

    <details>
    <summary>Why the old behaviour was wrong</summary>
    ...
    </details>

    <details>
    <summary>Measurements — <the headline number></summary>
    ...
    </details>

## Before you post

- Read the title alone. Would it make a useful changelog line?
- Read the lead alone. Does someone know what this is and whether it hits them?
- Is any fact that changes a decision hidden inside a toggle? Move it up.
- Does every `<summary>` say what is inside, not just name a category?
- Blank line after each `</summary>`.
- Link the issue from the PR (`Closes #NN`), and link the PR back if the issue
  stays open for a reason.

Post the body from a file, not from a shell string — a heredoc mangles
backticks and `$`:

    gh pr create --title "fix: ..." --body-file <file>
    gh issue create --title "..." --body-file <file>
    gh pr edit NN --body-file <file>

Write that file under the scratchpad directory, not in the repository.
