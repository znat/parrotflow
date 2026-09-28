# An accessibility kit, as its own Swift package

Working name: `AXKit`. The name is not checked against GitHub or the Swift
Package Index yet; pick the final name before the first release.

The goal is a library that reads and drives macOS apps through the
accessibility API, native and Chromium/Electron alike, and that can later be
released on its own, as an alternative to AXorcist. ParrotFlow becomes its
first user. The agent (Python, skills, memories) is out of scope here.

## Package boundary

- A `.library` product and target `Sources/AXKit/`. Dependencies: AppKit and
  ApplicationServices only. Nothing from ParrotFlow (Yams, MLX, FluidAudio,
  Log, Config) may be imported, or the folder can never be split out.
- An executable `axkit` (`Sources/axkit/`): the CLI, JSON in and out.
- A fixture app `AXKitFixtures` (`Sources/AXKitFixtures/`): the native
  Controls window, moved out of `--panels controls` so the package is
  self-contained. The web page lives under `Fixtures/web-controls/`.
- Tests `Tests/AXKitTests/`.
- Everything the kit needs (README, LICENSE placeholder, fixtures, docs) sits
  under paths that `git subtree split` can take in one go.
- ParrotFlow's target gains a dependency on `AXKit`. Nothing else in
  Package.swift changes.

## Layers

| Layer | What it holds |
|---|---|
| Element | `AXUIElement` wrapper: typed attributes (role, subrole, title, description, value, frame, enabled, focused, children, window, identifier, DOM id and classes), settable check, action list, perform, `AXError` mapped to Swift errors, a per-call messaging timeout |
| App | running app by pid, bundle or name; wake for Electron and Chromium (`AXManualAccessibility`, `AXEnhancedUserInterface`); windows; focused element; hit-test at a point, skipping a given pid (an overlay) |
| Walk | a bounded walk (depth, element budget, deadline); selectors by role, name glob, DOM id, path; a stable identity key; a Codable snapshot |
| Wait | `AXObserver` notifications (value changed, created, focus changed, window created) and bounded "wait until" predicates, instead of polling |
| Controls | typed adapters, one per role family, each op verified (below) |
| Input | keys (unicode text, key codes, modifiers) and mouse clicks; route to the frontmost app or to one pid; guards |
| CLI | `axkit dump`, `find`, `get`, `set`, `press`, `type`, and one verb per control op |

## Rules the measurements force

Measured 2026-09-27/28 on the Controls panel, a web page in Chrome, and live
Outlook and Teams. Each rule is a contract of the kit.

1. **Every write is read back.** `AXUIElementSetAttributeValue` returns
   success when the app ignores the value: checkbox, switch, radio, segment,
   popup and stepper all did. An op returns an outcome `{before, after,
   method, verified}`; unverified is a failure.
2. **Date and time fields take a `CFDate` only.** Strings, ISO strings and
   numbers are refused (-25201). One set writes the whole value, Outlook
   included. Keyboard fallback: click 16 pt from the left edge (lands on the
   first part), type the parts in the field's own order (read from its shown
   text), never focus by `AXFocused` then type (lands on the wrong part).
3. **Popup:** press it, then press the item; setting its value is ignored.
   **Menu bar:** `AXPress` on the leaf item works with every menu closed.
   **Sheet:** press its buttons; `AXCancel`/`AXConfirm` on the sheet fail.
   **Popover:** `AXCancel` works. **Outline:** `AXDisclosing` on the row, not
   `AXExpanded`. **Table:** `AXSelectedRows` on the table. **Slider:**
   `AXValue` as a number, or `AXIncrement`. **Toggles:** `AXPress`, with
   "ensure on/off" built from a read.
4. **Chromium:** a value set reaches the page for text inputs, React
   included; never for contenteditable (the text shows, the app is not told);
   date, time and range inputs ignore it; `<select>` items are not reachable,
   so the keyboard is used. Chromium exposes the DOM id.
5. **Fluent combobox (Teams):** the first match is already highlighted, so a
   bare Return picks it; Down then Return picks the second. Escape reverts a
   typed time. Typing into the date appends; select all first.
6. **Walk depth:** Teams trees reach 42 levels. The base branch caps at 40;
   the kit's default is 64, with the element budget unchanged.
7. **Background:** AX actions work with the app in the background. Keys
   posted to one pid work in Chrome and Teams, and in Outlook once the
   field's window is made main (`AXMain`). Each op declares
   `needsForeground`.
8. **Guards before any key or click:** the screen is not locked, no other
   pid holds secure input, and the target is frontmost when the route needs
   it. Text is typed as unicode, so the keyboard layout does not matter.

## What comes in, from where

| Source | Branch | Taken |
|---|---|---|
| `ScreenTargets.swift`: walk, wake, `kindOf`, `states`, hit-test, perform, container filter, `key` | base | rewritten into Element, App, Walk; the `key` algorithm lifted unchanged |
| `DateField.swift`, the `set_date` op | `feat/component-gestures` | lifted into Controls |
| `ControlsSurface.swift`, `scripts/probe-controls.swift` | `feat/controls-panel` | the window lifted into `AXKitFixtures`; the probe becomes live tests |
| `tests/fixtures/web-controls/`, `probe-web-controls.swift`, `web-controls.sh`, `probe-web-headless.mjs` | `feat/web-controls` | moved under the kit's fixtures |

Only Swift and fixture files are cherry-picked. The Python agent commits stay
on their branches.

## What stays out

Seen-line (OCR) pairing, grounding, Jev, memories, the skills DSL and the
Python channel. The kit returns typed outcomes; ParrotFlow decides what they
mean.

## Tests

- Pure logic in unit tests: the key hash, glob matching, date-order
  inference, selectors, snapshot encoding.
- Anything that touches AX needs the Accessibility grant. Live tests check
  `AXIsProcessTrusted()` and skip otherwise; they run from a trusted terminal
  against `AXKitFixtures` and the web page. The probe matrix of 09-27 is
  their expected table.

## Migration in ParrotFlow

The snapshot items and the `key` hash are read by the Python agent and stored
in skills and memories. So a swap must not change them:

1. Kit, fixtures and CLI land, with ParrotFlow unchanged.
2. ParrotFlow's walk moves onto the kit. Gate: the snapshots of the recorded
   runs, rebuilt through the kit, are identical item by item (compared by
   key) to what the app recorded. One live run before merging.
3. The action ops (press, set date, type) move onto the kit, one PR each,
   same gate.

Each step: CodeRabbit before merging, no push.

## Release, later

`git subtree split` of the kit's paths into its own repository, a license,
the final name, semantic versions, and ParrotFlow depending on the released
package by URL.
