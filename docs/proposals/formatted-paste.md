# Proposal: bullets, bold, italic and links that survive the paste

**Status.** Built, and measuring. The delivery path ships: `Markup.swift`
renders, `AppProfile.paste` decides, `TextInserter` writes. The matrix below is
what promotes an app out of plain text, and only Slack is in it so far.

**Goal.** A dictated message arrives in Slack, Outlook or a compose box with
its bullets, its bold, its italics and its links intact.

---

## Two problems, kept apart

| | |
|---|---|
| **Producing the markup** | Speech is flat. Something has to turn "bullet point call the client" into `- Call the client`. That is a pipeline stage with its own case set. |
| **Delivering the markup** | A pasteboard item can carry `public.html`, `public.rtf` and plain text at once. The receiving app picks. Each app picks differently and each loses something different. |

Delivery goes first. It is the half that cannot be reasoned about, and a
production stage is worthless until something can carry its output.

---

## What is built

| | |
|---|---|
| `Markup.swift` | Markdown parsed once, rendered as `plain`, `markdown`, `html` or `rtf`. A `Flavour` registry, not a switch, because two callers read it. |
| `AppProfile.paste` | One entry per app, beside `focus`, `anchor` and `readsPane`. `plain`, `html` or `rtf`. |
| `TextInserter.insert(_:mode:paste:)` | Defaults to `.plain`, so the four in-place-edit callers in `Surface.swift` are unchanged and stay plain — an edit writes into a field's existing text, where markup would be wrong. |
| `--paste-probe` | The measuring tool, rendering through the same `Markup`. |
| `--profile` | Prints the flavour. `scripts/check-profiles.sh` scores it against `tests/profile-cases.yaml` in CI. |
| `--clipboard-test` | Three new checks on the fail-open contract, below. |

RTF goes through AppKit's HTML importer rather than being built by hand: that is
what produces a real `\listtable` and real `HYPERLINK` fields. It also keeps the
two rich flavours the same document, so a difference in the target app is the
target app. Measured at 400ms, no `NSApplication` needed.

### The contract, checked by `--clipboard-test`

```
✓ an unmeasured app gets plain text, verbatim
✓ a transcript with no markup gets plain text, verbatim
✓ a measured app gets the markup and the fallback
```

"Verbatim" is the load-bearing word. Both ways down to plain write the text
itself and not a rendering of it, because stripping markers that were never
there can still move whitespace.

### Where it is deliberately not extensible

`AppProfile.of` returns for a terminal and for a blind app **before** the paste
lookup is reached. Neither can be promoted out of plain by adding a line to a
set. A terminal renders no markup and would show the tags.

---

## The probe

```sh
$PF --paste-probe <plain|markdown|html|rtf|all> [--file <fixture.md>] [--bare] [--show]
```

It puts one fixture on the clipboard in one flavour and stops. You press ⌘V
yourself. Pressing it yourself keeps the test about the flavour and not about
the event tap.

The fixture exercises seven things in one paste: **bold, italic, code, bullet,
nested bullet, numbered list, link**. A link is two scores — the words it was
written on, and the URL behind them.

The flavours:

| | |
|---|---|
| `plain` | Markers stripped, bullets kept as `•`, URL in brackets. The floor. If this is good enough, stop here. |
| `markdown` | The source left as it is. Notion, Linear and Obsidian convert it themselves. Most apps do not. |
| `html` | `public.html`, plus the plain fallback. |
| `rtf` | `public.rtf`, plus the plain fallback. Built from the same HTML through AppKit's importer, so it carries a real `\listtable` and real `HYPERLINK` fields. |
| `all` | HTML and RTF and plain on one item — the shape a shipping paste would have. |

`--bare` withholds the plain fallback. **A rich flavour alone is not a shape
anything puts on a real clipboard.** A clipboard manager reads it as empty, and
a paste that lands as plain looks identical to a paste that did not land. So
the fallback is the default and `--bare` is the follow-up: when a cell renders
as plain, `--bare` says whether the app could have taken the rich flavour or
only preferred not to.

**Your clipboard is not put back.** The payload has to survive for you to paste
it.

---

## Step 1 — `all`, into everything

`all` is the shape a shipping paste has: HTML, RTF and plain on one item. Test
it first. Every app that scores 7/7 here is finished and needs no config at all.

Run the probe **once**, then paste into every app in the list before running it
again. Flavour outside, apps inside — three probe runs, not thirty.

```sh
.build/debug/ParrotFlow --paste-probe all
```

Score each cell per feature, not pass/fail. A cell that keeps everything but
flattens the nesting is a different decision from one that drops the link. A
cell says what was lost; `all 7` means nothing was. A link is two scores — the
words, and the URL behind them.

The five that decide it, plus the safety check:

| App | engine | `all` |
|---|---|---|
| Slack | Electron | |
| Microsoft Outlook | native | |
| Gmail compose (Chrome) | Blink `contenteditable` | |
| Google Docs (Chrome) | its own clipboard layer | |
| Notion | Electron | |
| VS Code or Ghostty | plain text | |

Then the rest, if the first six leave anything open:

| App | engine | `all` |
|---|---|---|
| Microsoft Teams | Electron | |
| Obsidian | Electron | |
| Granola | Electron | |
| Apple Mail | native | |
| Apple Notes | native | |
| Microsoft Word | native | |

The editor row is not a feature check, it is a safety check. An editor and a
terminal understand none of these flavours and must land on the plain fallback.
If either one pastes `<p>Ship the` then rich paste is dangerous everywhere and
the default has to stay plain.

Google Docs is the one to expect trouble from. It does not read the pasteboard
the way the others do — it has its own internal clipboard, and what it accepts
from outside is narrower than what it produces.

## Step 2 — diagnose only what failed

For an app that scored badly, the question is whether it *could* do better with
one flavour alone. That is three more runs, on that app only.

```sh
.build/debug/ParrotFlow --paste-probe html --bare   # HTML alone
.build/debug/ParrotFlow --paste-probe rtf --bare    # RTF alone
.build/debug/ParrotFlow --paste-probe markdown      # does it convert markup itself?
```

| App | `all` picked | `html --bare` | `rtf --bare` | `markdown` |
|---|---|---|---|---|
| | | | | |

An app that does better with HTML alone than with `all` is reaching for RTF when
both are offered. The fix is to withhold RTF for it.

## Measured so far

| App | flavour | result |
|---|---|---|
| Slack | `html` | **all 7** — bold, italic, code span, bullets, a real second level with `◦`, 1/2/3, "Dana" styled as a link. URL not yet confirmed. Slack's WYSIWYG composer was on. **Shipped as `.html`.** |

Record the Slack "format messages with markup" setting alongside its row. It
changes the answer, and without it the numbers do not reproduce.

## What the matrix decides

Two lines in `AppProfile.swift`, one per measured app:

```swift
private static let htmlBundleIDs: Set<String> = ["com.tinyspeck.slackmacgap"]
private static let rtfBundleIDs: Set<String> = []
```

Not a `paste:` block in `config.yaml`. That was proposed and withdrawn: it would
be a second per-app registry sitting beside `AppProfile`, which exists precisely
so an app does not appear in several lists. Its own doc comment says so.

A config override can come later, for an app nobody here has measured. It is not
needed to ship this and is not built.

Two rules that do not depend on the numbers:

- **Default to plain.** An app with no proven row gets `public.utf8-plain-text`
  and nothing else. A wrong flavour does not only lose the bold — in some apps
  it loses the sentence. Fail open. **Built and checked.**
- **Only pay the cost when there is something to format.** A transcript with no
  Markdown markers takes today's path unchanged. `Markup.isPlain` is the gate.
  **Built and checked.**

---

## Known hazards

- `AttributedString(markdown:)` sets `inlinePresentationIntent`, not fonts. RTF
  built straight from the parse comes out unstyled. Going through the HTML
  importer avoids this — measured at 400ms, and it needs no `NSApplication`.
- Slack's composer rewrites what it receives, and its behaviour depends on a
  preference. See above.
- The matrix is measured against app versions, and Slack ships weekly. If it
  drifts, the next harness is: paste, select all, copy back, and inspect the
  returned flavours for bold runs. That is scriptable. Do not build it until
  the manual matrix proves it is needed.
- ⌘⇧V pastes plain in most of these apps. It is the user's escape hatch and it
  belongs in the docs.
