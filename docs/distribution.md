# Distribution and install flow

How ParrotFlow gets onto someone else's Mac.

Implemented: releases are automated, the app installs by `curl`, and a coding
agent can drive the whole setup. Still open: notarization, and everything that
unlocks — Homebrew, a double-clickable `.dmg`, a link that works for someone who
was sent it.

## The Mac App Store is a dead end for this app

Worth settling first, because it constrains everything else.

The App Store requires the App Sandbox, and
[sandboxed apps cannot use the Accessibility APIs](https://developer.apple.com/forums/thread/707680)
that let one app insert text into another. `AXIsProcessTrustedWithOptions` is
not available under the sandbox. Since typing the transcript into whatever app
you're in *is the product*, this isn't a feature to trade away.

Global hotkeys would survive — a `CGEventTap` needs Input Monitoring, which
sandboxed apps can request — but text insertion does not. Clipboard-manager
style apps get
[rejected under Guideline 2.4.5](https://developer.apple.com/forums/thread/820594)
for related reasons.

This is why every app in this category — Wispr Flow, VoiceInk, Handy, Raycast —
ships outside the App Store. Direct download and Homebrew is the path.

## Homebrew is closed to us until we notarize

This was the plan, and it no longer works. Homebrew **removed
`--no-quarantine`** in the 5.0 line, deliberately, on the grounds that it
existed only to bypass a macOS security mechanism. Verified on 6.0.10: the flag
isn't recognised, `brew install` just prints its usage. `HOMEBREW_CASK_OPTS`
went with it.

So a cask now always installs the app quarantined, Gatekeeper always assesses
it, and an app signed with anything short of a Developer ID always fails that
assessment. What Homebrew's maintainers tell users to do instead is run
`xattr -rd com.apple.quarantine /Applications/Whatever.app` by hand.

That is a bad sentence to put in the install instructions for *any* app. For
this one — which then asks for the microphone and for permission to type into
every window — it is disqualifying. "Turn off a security check, then let me
listen to you" is not a trade a reasonable person should accept, and we should
not be the ones asking.

The official repo is further out than it was. [Acceptable Casks](https://docs.brew.sh/Acceptable-Casks)
already required a cask work **"without requiring System Integrity Protection or
Gatekeeper to be disabled"**, and homebrew-cask is dropping casks that fail its
codesigning-and-notarization audit on **1 September 2026**.

So Homebrew is not a first channel any more. It is a thing that unlocks after
notarization, at the same moment everything else does.

## Why curl works, and it isn't a trick

The quarantine attribute is not applied by macOS. It is applied by the
*downloading application*, via `LSFileQuarantineEnabled` — browsers set it, Mail
sets it, Slack sets it. `curl` does not.

Measured:

```
$ curl -o file.zip <url> && xattr -l file.zip
com.apple.provenance                    ← no com.apple.quarantine

$ xattr -l .build/ParrotFlow.app
com.apple.provenance
$ spctl --assess --type execute -vv .build/ParrotFlow.app
rejected                                ← and yet it launches, every day
```

Gatekeeper only assesses quarantined files. No attribute, no assessment — which
is why a locally built app runs without ceremony, and why a curl-fetched one
does too. Same mechanism, and it is the mechanism every `curl | sh` developer
tool has relied on for a decade.

This is not us disabling a security feature. It is us not triggering one, which
is a different thing: nothing is turned off, no state is changed, and a user who
downloads the same zip in a browser still gets the full Gatekeeper treatment.

The honest caveat: it works because Apple has not closed this path, and closing
it would break most of the developer tooling ecosystem. Unlikely, not promised.
Notarization is the only future-proof answer — curl is what lets us ship before
we have it.

## Signing releases anyway

Even without a Developer ID, release builds are signed with a **stable
self-signed certificate** (`scripts/release-certificate.sh`). This does nothing
for Gatekeeper. It is about the second problem below: TCC keys Microphone and
Accessibility grants to the signing certificate, so signing every release with
the same one is what stops an upgrade silently costing users both permissions.

The certificate is therefore a durable asset, not a build artefact. Regenerating
it breaks every existing install. It lives outside the repo and its `.p12` is a
repository secret.

## Gatekeeper without notarization is now genuinely bad

This used to be a shrug — right-click, Open, done. Not since macOS 15:
[Control-click no longer overrides Gatekeeper](https://developer.apple.com/news/?id=saqachfa).
A user who downloads an unsigned build now has to open System Settings →
Privacy & Security, scroll to a message about blocked software, click Open
Anyway, and re-authenticate. Many will conclude the app is broken.

There is a second, subtler cost, and we already ran into it: **ad-hoc signatures
break permissions on every build**. TCC pins high-risk grants to the binary's
cdhash, so a new build silently loses Microphone and Accessibility while System
Settings still shows the app ticked. A Developer ID certificate makes the
designated requirement key on the certificate instead, and the problem vanishes
for users and for us.

That's the real argument for the $99/year Apple Developer Program here — not
polish, but that the permission model doesn't work properly without it.

## Signing and notarizing

Requires a **Developer ID Application** certificate.

```sh
security find-identity -vp codesigning
```

Notarization requires the hardened runtime, and the hardened runtime blocks
microphone access unless you declare it. Non-sandboxed apps use
`com.apple.security.device.audio-input` (`...device.microphone` is the sandbox
one — not us). Without it the app is refused the mic or killed outright.

`Resources/entitlements.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
```

Accessibility needs no entitlement — it's TCC-only, granted by the user.

```sh
# 1. Sign, with hardened runtime and a secure timestamp
codesign --force --options runtime --timestamp \
  --entitlements Resources/entitlements.plist \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  ".build/ParrotFlow.app"

# 2. Archive with ditto, which preserves the bundle's metadata
ditto -c -k --sequesterRsrc --keepParent ".build/ParrotFlow.app" ParrotFlow.zip

# 3. Store credentials once
xcrun notarytool store-credentials "parrotflow" \
  --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"

# 4. Submit and wait
xcrun notarytool submit ParrotFlow.zip --keychain-profile "parrotflow" --wait

# 5. Staple the ticket to the .app, so it works offline
xcrun stapler staple ".build/ParrotFlow.app"
```

Staple the `.app`, then build the `.dmg` from the stapled bundle and staple that
too. Archives themselves aren't signed — their contents are.

Verify what a user's Mac will conclude:

```sh
spctl --assess --type execute -vv ".build/ParrotFlow.app"   # expect: accepted, Notarized Developer ID
```

Worth automating in CI on tag push, with the certificate and the app-specific
password as repository secrets.

## What the user actually goes through

The install matters as much as the app, because a dictation tool asks for two
permissions and a ~1 GB download before it does anything.

```
curl -fsSL .../install.sh | sh          (~3 MB, checksum verified)
        │
        ▼
Launch — no Dock icon, a 🎙 appears in the menu bar
        │
        ▼
  ├─ Microphone       [Grant]   ← system prompt, required
  ├─ Accessibility    [Grant]   ← System Settings, required to type text
  └─ Speech model     [1.2 GB, downloading… 34%]
        │
        ▼
"Hold Right ⌥ and talk"  ← the one thing they need to know
```

There are two of these paths now, and the agent-driven one is the front door:

**[docs/setup.md](setup.md)** is the same sequence written for a coding agent to
execute — install, both permissions, a transcription check that needs no
microphone, languages, then the Ollama model pulled in the background. It exists
because the audience already has an agent in a terminal, and because a setup
that asks two permissions and downloads 11 GB is exactly the kind of thing
people abandon halfway. Something that explains each step as it takes it, and
verifies afterwards, converts better than a numbered list they read alone.

It also solves a problem a GUI cannot: the parts of this setup that are
genuinely conditional — Ollama's version, how much RAM decides `keep_loaded`,
which languages — are judgement calls, and an agent can make them out loud.

Notes on getting this right:

- **Don't ask for everything at once.** Microphone on launch is fine — it's
  obvious why. Accessibility is better asked the first time a transcript is
  ready to insert, when the reason is self-evident.
- **Accessibility can't be granted in-app.** The best possible flow is a button
  that deep-links to the right System Settings pane plus a line saying what to
  tick. Detect the grant live rather than making them relaunch.
- **Accessibility can't be *checked* from a terminal either**, which is less
  obvious and cost us a wrong turn. TCC credits the check to the responsible
  process, and for a binary exec'd from a shell that is the terminal. Measured
  on a Mac where the app held the grant and was using it: launched by macOS it
  reported `Granted`, the same bundle run from a terminal reported `Not
  granted`. So `--check-config` deliberately does not test it — a check that
  says no when the answer is yes is worse than no check. The app tests it at
  launch and logs the result; that log line is the reliable read.
- **The model download must not block.** Recording should work immediately;
  transcription unlocks when the download finishes. Resumable, cancellable,
  with a real progress figure — a silent 1.2 GB fetch reads as a hang.
- **Ship a fallback.** If Apple's `SpeechTranscriber` proves good enough, offer
  it as the zero-download default and make Parakeet the opt-in upgrade.
- **First run after install is the only chance.** Someone evaluating a dictation
  app gives it about a minute.

## Updates

Re-running the install line upgrades in place — it replaces the bundle and
relaunches. That is the whole update story for now, and it is enough while the
audience is people who are comfortable with a curl line.

It is not enough later, because it requires the user to think of it. [Sparkle](https://sparkle-project.org)
is the standard answer: an appcast XML feed, EdDSA signatures, in-app prompts.
Worth adding once there are users to update; a "new version available" item in
the menu bar is a cheap intermediate step.

Note that the upgrade path is exactly where the stable signing certificate earns
its keep. Replacing the bundle with one signed by a different identity loses
both permissions, and the failure is silent and baffling — the app stops working
and System Settings still shows it ticked.

## Releases are automated

`main` uses [Conventional Commits](https://www.conventionalcommits.org).
[release-please](https://github.com/googleapis/release-please) keeps a release PR
open with the computed next version and the changelog; merging it tags the
release. `.github/workflows/release.yml` then builds on a macOS runner, signs
with the certificate from repository secrets, and attaches `ParrotFlow.zip` and
its checksum — which is what `install.sh` downloads from
`releases/latest/download/`.

The version lands in `Info.plist` through release-please's `extra-files`
annotation, so the bundle version and the tag cannot drift apart.

Adding notarization later is an extra step in that workflow, not a redesign:
sign with Developer ID instead, submit, staple, upload. The rest stays.

## Cost

| Item | Cost |
| --- | --- |
| Apple Developer Program (Developer ID + notarization) | $99/year |
| Notarization submissions | Free, unlimited |
| GitHub Releases hosting | Free |
| Self-signed release certificate | Free |

The $99 is still the only real decision, but what it buys has changed. It is no
longer "polish plus a shorter install line" — Homebrew of any kind, a `.dmg`
anyone can double-click, and a link that works when someone's colleague sends it
to them are all on the far side of it. Curl covers the developer who is already
in a terminal. It does not cover the person who was sent a link.

What the self-signed certificate buys for free is the permissions problem:
grants survive upgrades. That was the other half of the argument for $99, and it
is now settled without it.

## Sources

- [Acceptable Casks](https://docs.brew.sh/Acceptable-Casks) · [Cask Cookbook](https://docs.brew.sh/Cask-Cookbook)
- [Removing support for `--no-quarantine` for casks](https://github.com/Homebrew/brew/issues/20755) · [Prepare for deprecation](https://github.com/Homebrew/brew/pull/20929) · [discussion](https://github.com/orgs/Homebrew/discussions/6537)
- [Updates to runtime protection in macOS Sequoia](https://developer.apple.com/news/?id=saqachfa)
- [Safely open apps on your Mac](https://support.apple.com/en-us/102445)
- [An Exhaustive Guide to Signing and Notarizing on macOS](https://armaan.cc/blog/signing-and-notarizing-macos)
- [Accessibility permission in sandboxed app](https://developer.apple.com/forums/thread/707680)
- [Guideline 2.4.5 rejection for CGEvent.post](https://developer.apple.com/forums/thread/820594)
- [Notarization: the hardened runtime](https://eclecticlight.co/2021/01/07/notarization-the-hardened-runtime/)
