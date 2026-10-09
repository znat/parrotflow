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

## Tests

- Pure logic in unit tests: the key hash, the path a key is built from, glob
  matching, rounding, snapshot encoding, error text.
- Anything that touches accessibility needs the grant. Live tests check
  `AXIsProcessTrusted()` and skip otherwise, so they skip in CI.

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
