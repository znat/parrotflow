# Distribution and install flow

How ParrotFlow gets onto someone else's Mac. Research notes; not implemented.

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

## Homebrew still needs notarization

Homebrew is the right first channel, but it doesn't dodge code signing.
[Acceptable Casks](https://docs.brew.sh/Acceptable-Casks) requires that a cask
work on the latest macOS **"without requiring System Integrity Protection or
Gatekeeper to be disabled."** An ad-hoc signed app fails that.

Two tiers:

**Your own tap** — `brew tap znat/parrotflow && brew install --cask parrotflow`.
No review, no rules, works today. Users of an unsigned build still hit
Gatekeeper and need `--no-quarantine` or a trip to System Settings.

**Official homebrew-cask** — `brew install --cask parrotflow`. Needs the
Gatekeeper clause satisfied, plus "substantial, independently verifiable public
interest" for a new app. Realistic once it's notarized and has some traction.

So: start with a personal tap, notarize as soon as it's worth it, then submit.

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
brew install --cask parrotflow          (or: open the .dmg, drag to Applications)
        │
        ▼
Launch — no Dock icon, a 🎙 appears in the menu bar
        │
        ▼
Welcome window
  ├─ Microphone       [Grant]   ← system prompt, required
  ├─ Accessibility    [Grant]   ← System Settings, required to type text
  └─ Speech model     [~800 MB, downloading… 34%]
        │
        ▼
"Hold Right ⌥ and talk"  ← the one thing they need to know
```

Notes on getting this right:

- **Don't ask for everything at once.** Microphone on launch is fine — it's
  obvious why. Accessibility is better asked the first time a transcript is
  ready to insert, when the reason is self-evident.
- **Accessibility can't be granted in-app.** The best possible flow is a button
  that deep-links to the right System Settings pane plus a line saying what to
  tick. Detect the grant live rather than making them relaunch.
- **The model download must not block.** Recording should work immediately;
  transcription unlocks when the download finishes. Resumable, cancellable,
  with a real progress figure — a silent 800 MB fetch reads as a hang.
- **Ship a fallback.** If Apple's `SpeechTranscriber` proves good enough, offer
  it as the zero-download default and make Parakeet the opt-in upgrade.
- **First run after install is the only chance.** Someone evaluating a dictation
  app gives it about a minute.

## Updates

Homebrew handles updates for cask users (`brew upgrade`). For `.dmg` users,
[Sparkle](https://sparkle-project.org) is the standard: an appcast XML feed, EdDSA
signatures, in-app update prompts. Worth adding only once there are users to
update; a GitHub Releases link in the menu is enough before that.

## Cost

| Item | Cost |
| --- | --- |
| Apple Developer Program (Developer ID + notarization) | $99/year |
| Notarization submissions | Free, unlimited |
| GitHub Releases hosting | Free |
| Homebrew tap | Free |

The $99 is the only real decision. Without it: permissions break on every
rebuild, users fight Gatekeeper, and official homebrew-cask is out of reach.

## Sources

- [Acceptable Casks](https://docs.brew.sh/Acceptable-Casks) · [Cask Cookbook](https://docs.brew.sh/Cask-Cookbook)
- [Updates to runtime protection in macOS Sequoia](https://developer.apple.com/news/?id=saqachfa)
- [Safely open apps on your Mac](https://support.apple.com/en-us/102445)
- [An Exhaustive Guide to Signing and Notarizing on macOS](https://armaan.cc/blog/signing-and-notarizing-macos)
- [Accessibility permission in sandboxed app](https://developer.apple.com/forums/thread/707680)
- [Guideline 2.4.5 rejection for CGEvent.post](https://developer.apple.com/forums/thread/820594)
- [Notarization: the hardened runtime](https://eclecticlight.co/2021/01/07/notarization-the-hardened-runtime/)
