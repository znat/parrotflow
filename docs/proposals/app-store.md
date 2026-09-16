# Proposal: what publishing on the Mac App Store would cost

**Status.** Not started. One measurement stands between this and a decision,
and `make sandbox-probe` is that measurement. Nothing else here is worth
paying for until it comes back.

**The question.** The App Store would buy discovery and a one-click install
for someone who was sent a link — the gap [distribution.md](../distribution.md)
names at the end, which curl and Homebrew do not cover. What it costs is the
sandbox, and the sandbox is expensive here in a way it is not for most apps.

---

## Measure this first

Every App Store build is sandboxed. The sandbox is what would break the two
input paths this app is built on, and neither has a fallback:

| | Where | Risk |
|---|---|---|
| `RegisterEventHotKey` — the character-key hotkey | `HotKeyManager.swift:109` | Low. Carbon, no permission, works sandboxed. |
| `NSEvent.addGlobalMonitorForEvents` — hold Right ⌘ | `ModifierKey.swift:528` | Medium. Needs Accessibility. Sandboxed apps on the store do hold that grant. |
| `CGEvent.tapCreate` — the offer chips' letters | `OfferKeys.swift:148` | **High.** Needs Input Monitoring, and an event tap is the thing the sandbox is most likely to refuse. |

The third one can end the question on its own. "Hold Right ⌘ and talk" is the
one thing a new user is told, and the offer keys are how a correction is
accepted without reaching for the mouse.

```sh
make sandbox-probe
```

It signs the dev bundle with `Resources/entitlements-sandbox.plist`, checks
the sandbox actually took, installs to `/Applications` and launches. The app
already writes the answers down, so the result is read and not judged:

```sh
grep -E "launched —|offer keys:" ~/Library/Logs/ParrotFlow-Dev.log
```

`launched — hotkey=NONE` is the second row failing. `offer keys: could not
create the tap` is the third row failing. `offer keys: input monitoring is not
granted` after granting it in System Settings is the same answer by a
different route.

The probe costs the dev app its grants and nothing else. `make install` puts
an ordinary dev build back.

**It does not need the Python stripped out first.** A sandboxed build cannot
run `CommandRunner`, so those stages fail — and a stage that fails leaves the
transcript exactly as it arrived, which is the rule in
[AGENTS.md](../../AGENTS.md). The app still launches and the input paths are
still measurable. Rewriting the extension system to answer a question a plist
answers would be paying the largest cost in this document to find out whether
it was needed.

---

## What the sandbox costs if the probe passes

These are the things that would have to go or change. They are listed so the
decision is made against the whole bill, not the first item.

**The extension system.** `CommandRunner.swift` pipes a transcript through
`/bin/sh` or `python3`. The sandbox forbids executing anything outside the
bundle, and guideline 2.5.2 forbids downloading or running code. That takes
`command:` transforms with it, and with them `ParsingInstall.swift` (fetches
spaCy models) and `EspeakInstall.swift` (tells the user to `brew install
espeak-ng` — 129 references across `Sources/`).

This is the product's difference, not a corner feature. The README leads with
it: *PR links and Slack mentions are NOT features — they are extensions
configured in yaml*. A sandboxed ParrotFlow is a smaller, different thing than
this one, and it competes with VoiceInk and MacWhisper on their terms rather
than its own.

**The self-updater.** `UpdateInstaller.swift` downloads a zip and replaces the
bundle. App Store apps cannot update themselves. `Updates.swift` signature
pinning stops applying, and there would be two update paths to keep working.

**Ollama.** An HTTP call to localhost is allowed with
`com.apple.security.network.client`, so this is not blocked. But an app that
needs a second app installed by hand is a review risk and a bad first run.

**Paths.** `Config.swift:3376` reads `homeDirectoryForCurrentUser`. The
sandbox redirects that into a container, so `~/.config/parrotflow/config.yaml`
moves and the `parrotflow` CLI on the PATH can no longer see it. The
HuggingFace downloads in `HubDownload.swift` need the do-not-backup flag.

**The licence.** GPL-3.0 conflicts with the App Store terms — the usage limits
Apple imposes are ones GPLv3 forbids passing on. This is what got VLC pulled.
`git log` shows one human author, so relicensing or dual-licensing is possible
without chasing contributors. The Swift dependencies are permissive: Yams,
FluidAudio, mlx-swift-lm, swift-transformers. espeak-ng is itself GPLv3, which
is a second reason it cannot be bundled.

**Build and signing.** `Package.swift` has a bare `executableTarget`. The
store needs an Xcode app target to archive; SwiftPM alone cannot produce a
signed `.pkg`. New certificates — Mac App Distribution and Mac Installer
Distribution — on top of the Developer ID, which the direct build keeps. The
$99/year already covers both. A different signing identity means every
existing user re-grants Microphone and Accessibility, the same cost
[distribution.md](../distribution.md) describes for the Developer ID switch.

**Entitlements.** `Resources/entitlements.plist` carries
`com.apple.security.device.audio-input` and is correct for the hardened
runtime without the sandbox. Which key a *sandboxed* build reads is not worth
guessing: `Resources/entitlements-sandbox.plist` names both
`audio-input` and `device.microphone`, which costs nothing and cannot be the
thing that fails.

---

## The alternative that is not the App Store

The gap is a person who was sent a link and does not live in a terminal. A
signed `.dmg` behind a real download page closes it. Releases are already
notarized, so Gatekeeper opens it. No sandbox, no relicensing, no second
update path, and the extension system survives.

This is the cheaper answer to the actual problem, and it should be ruled out
before the sandbox is paid for.
