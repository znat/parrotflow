# An accessibility kit, as its own Swift package

Working name: `AXKit`. The name is not checked against GitHub or the Swift
Package Index yet; pick the final name before the first release.

The goal is a library that reads and drives macOS apps through the
accessibility API, native and Chromium/Electron alike, and that can later be
released on its own, as an alternative to AXorcist. ParrotFlow becomes its
first user. The agent (Python, skills, memories) is out of scope here.

**Status.** The kit is internal. Its API may change in any pull request. It
has no consumers outside this repository, and ParrotFlow does not use it yet.
This page covers the read layer, which is all that has landed.

## Package boundary

- A `.library` product and target `Sources/AXKit/`. Dependencies: AppKit and
  ApplicationServices only. Nothing from ParrotFlow (Yams, MLX, FluidAudio,
  Log, Config) may be imported, or the folder can never be split out.
- An executable product `axkit`, target `AXKitCLI` (`Sources/AXKitCLI/`):
  the command line, text or JSON out.
- Tests: `tests/AXKitTests/`, target `AXKitTests`.
- Everything the kit needs sits under paths that `git subtree split` can take
  in one go.
- ParrotFlow's target does not depend on `AXKit` yet. A later pull request
  adds that dependency, and nothing else in Package.swift changes for it.

## Layers

| Layer | File | What it holds |
|---|---|---|
| Element | `Element.swift` | `AXUIElement` wrapper: typed attributes (role, subrole, title, description, value, frame, visible frame, enabled, focused, children, window, identifier, DOM id and classes), settable check, action list, perform and set, a per-call messaging timeout, bounded searches |
| App | `App.swift` | running app by pid, bundle or name; frontmost and focused app; wake for Electron and Chromium (`AXManualAccessibility`, `AXEnhancedUserInterface`); windows; focused element; hit test at a point, in one app or system-wide; an element found by its frame |
| Walk | `Walk.swift` | a bounded walk (depth, element budget, deadline); find by role, name glob and DOM id; a stable identity key; a Codable snapshot |
| Read | `Read.swift`, `Records.swift` | the lean read for screen context: plain records at two calls per element, and pure functions over them. See [The lean read](#the-lean-read) |
| Window | `Window.swift` | position, size, minimised and full screen, through accessibility |
| Wait | `Wait.swift` | `AXObserver` notifications and bounded "wait until" predicates, instead of polling |
| Errors | `AXKitError.swift` | `AXError` mapped to a Swift error that names the call |

## The command line

```sh
swift build -c release
.build/release/axkit trusted
.build/release/axkit apps
.build/release/axkit dump --app com.apple.finder --depth 6
.build/release/axkit find --app com.apple.finder --role AXButton --json
.build/release/axkit hit 400 300 --app com.apple.finder
.build/release/axkit read --app com.tinyspeck.slackmacgap
```

`trusted` and `apps` need no permission. `dump`, `find` and `hit` need the
Accessibility permission for the terminal that runs them. None of them brings
an app in front or sends it a key. `--wake` does write to the target: it sets
`AXManualAccessibility` and `AXEnhancedUserInterface` on it, so that Chromium
and Electron publish their tree.

## Rules the measurements force

Measured 2026-09-27/28 on a native Controls window, a web page in Chrome, and
live Outlook and Teams.

1. **Walk depth:** Teams trees reach 42 levels. The kit's default is 64, with
   an element budget of 8000 and a 3 s deadline.
2. **Background:** accessibility reads work with the app in the background.
3. **A write is not proof:** `AXUIElementSetAttributeValue` returns success
   when the app ignores the value. A caller reads the value back.

## The lean read

`Read` is what the context readers use. `Walk` stays for skills and the
agent, which need its keys, names and actions.

- `Read.walk(from:options:)` reads a subtree, depth first, into `[Record]`.
  A record holds role, subrole, title, description, value, a numeric value,
  identifier, AXURL, frame, depth, the parent's index, focused and enabled.
  The text attributes stay apart: no merged name, so a placeholder never
  passes for content. Values are cut at 4000 characters.
- Per element: one `AXUIElementCopyMultipleAttributeValues` call for
  everything but the value, then one call for the value. The value is not in
  the first call because a secure text field (`AXSecureTextField`, role or
  subrole) must never be asked for it, and the role is not known before.
  When the subrole cannot be read, the value is not asked for either.
  Skipping the value by role does not work: Outlook's buttons and groups hold
  their text there.
- Limits: 4000 records, depth 64 (Teams goes past 40), 1 s, and a 0.1 s
  messaging timeout on every element it touches. The system default is 6 s.
  The result says what stopped it, how many calls it made, and how many
  elements did not answer.
- It never wakes an app. Chromium and Electron must already publish their
  tree.
- Pure, over records: `visible` (inside every scroll area and window above),
  `visibleText` (a value, or a leaf's title or description, one line per
  record), `headings` (level from the value), `landmarks` (the `AXLandmark*`
  subroles and `AXApplicationLog`; Chromium gives `feed` no subrole).
- Live, bounded: `climb` and `ancestors` (two calls per element up),
  `webArea(around:)` (title and AXURL), `document(of:)` (AXDocument).

Measured 10-09, release build, `axkit read` against `axkit dump` (Walk) on
the same window, 3 runs each:

| App | Elements | `read` | `dump` |
|---|---|---|---|
| Slack | 726 | 69–79 ms, 0.10 ms each, 2 calls each | 239–262 ms, 0.34 ms each |
| Claude | 1208 | 137–193 ms, 0.11 ms each | 437–449 ms |
| Finder | 31 | 12–22 ms | 19–23 ms |

Walk makes 14 to 17 calls per element.

### Key format

`Walk.key` is stored by agent skills and memories. `Walk.keyVersion` (now 1)
names its format. A change to what a key is built from (`key`,
`path(below:role:)`, `plainRoles`, `shortHash`, or the name a node is keyed
by) raises it, and stored keys must be rebuilt.

## Tests

- Pure logic in unit tests: the key hash, the path a key is built from, glob
  matching, rounding, snapshot encoding, error text.
- Anything that touches accessibility needs the grant. Live tests read the
  Finder, check `AXIsProcessTrusted()` and skip without it. The hosted CI
  runner has the grant, so they run there too.

```sh
swift test --filter AXKitTests
```

## Migration in ParrotFlow

The snapshot items and the `key` hash are read by the Python agent and stored
in skills and memories. So a swap must not change them:

1. The kit and its CLI land, with ParrotFlow unchanged.
2. ParrotFlow's walk moves onto the kit. Gate: the snapshots of the recorded
   runs, rebuilt through the kit, are identical item by item (compared by
   key) to what the app recorded. One live run before merging.
3. The action layer lands, then the action ops move onto it, one pull request
   each, same gate.

## Release, later

`git subtree split` of the kit's paths into its own repository, a license,
the final name, semantic versions, and ParrotFlow depending on the released
package by URL.
