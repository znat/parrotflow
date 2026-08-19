# Distribution and install flow

How ParrotFlow gets onto someone else's Mac.

Releases are automated. The app installs by `curl`, and a coding agent can
drive the whole setup. The app is not notarized, so Homebrew, a
double-clickable `.dmg`, and a link that opens for someone who was sent it do
not work yet.

## Signing releases anyway

Even without a Developer ID, release builds are signed with a **stable
self-signed certificate** (`scripts/release-certificate.sh`). This does nothing
for Gatekeeper. It is about the second problem below: TCC keys Microphone and
Accessibility grants to the signing certificate, so signing every release with
the same one is what stops an upgrade silently costing users both permissions.

The certificate is therefore a durable asset, not a build artefact. Regenerating
it breaks every existing install. It lives outside the repo and its `.p12` is a
repository secret.

It also does a second job, once `install.sh` pins it. `codesign --verify` proves
a signature matches the bundle it covers and says nothing about who produced it:
a self-signed certificate is free to make, can carry any common name — including
this one — and passes that check. So the installer compares the SHA-256 of the
leaf certificate against a pinned value, which is what turns "this archive is
internally consistent" into "this archive is ours". A swapped release fails
before anything is copied into `/Applications`.

Pinning inside a script is usually how a project strands itself on a key it
later has to rotate. It is safe here for the reason the file already relies on:
`install.sh` is read from `main` on every run, so the pin travels in the same
commit as the new certificate. And it fails in the right direction anyway — a
release signed with a different certificate is one TCC would refuse the user's
existing grants to, so refusing it in the installer converts a silent loss of
Microphone and Accessibility into a stop with a reason.

The fingerprint is derivable from the certificate itself, which is what makes
rotating it a one-line change rather than an archaeology exercise:

```sh
openssl x509 -in ~/.parrotflow-release/cert.pem -outform DER | shasum -a 256
codesign -d --extract-certificates=/tmp/c ParrotFlow.app && shasum -a 256 /tmp/c0
```

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
Launch — no Dock icon, a 🦜 appears in the menu bar
        │
        ▼
  ├─ Microphone       [Grant]   ← system prompt, required
  ├─ Accessibility    [Grant]   ← System Settings, required to type text
  └─ Speech model     [1.2 GB, downloading… 34%]
        │
        ▼
"Hold Right ⌘ and talk"  ← the one thing they need to know
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

The app checks GitHub hourly and offers the release itself. The panel shows the
release notes as Markdown — see `UpdatePanel` and `ReleaseNotes` — and takes
three answers: install and restart, skip this version, or later. Installing runs
the same three checks `install.sh` runs, in the same order: the published
SHA-256, the code signature, and the pinned leaf certificate. Nothing is
replaced until all three agree. See `UpdateInstaller`.

Re-running the install line still upgrades in place, and it is still the way in
when the app cannot install over itself.

A dev build cannot. The archive holds `ParrotFlow.app` signed as
`com.parrotflow.app`; a dev bundle is `ParrotFlowDev.app` signed as
`com.parrotflow.app.dev`. Moving one over the other would not update the dev
build — it would leave the released app under the dev build's name, reading the
other config directory, writing the other log, and listening to the other key.
So the dev build says a release exists and offers the install command instead of
the button. A dev build is updated by building it.

[Sparkle](https://sparkle-project.org) is what most apps use for this, and the
window everyone recognises is Sparkle's. It was not adopted: it brings an
appcast XML feed to publish on every release and an EdDSA key to sign with, and
it replaces the pinned-certificate check that already ties the update path to
`install.sh`.

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

The failure mode of this arrangement is silence. release-please reads the
*subject line* and nothing else, so a commit written as prose has no type, no
bump and no changelog entry — and nothing anywhere reports that it was skipped.
The workflow runs green in 24 seconds and no release exists. That is how this
repository reached fifteen commits and zero tags with the pipeline fully wired
and working exactly as configured. `.githooks/commit-msg`, installed by
`make hooks`, is the only thing that makes the omission visible, and it has to
be visible at commit time because afterwards nothing looks wrong.

`workflow_dispatch` re-runs release-please by hand. It recomputes the release PR
from the commits since the last tag; it cannot conjure a release out of commits
that carry no type.

Adding notarization later is an extra step in that workflow, not a redesign:
sign with Developer ID instead, submit, staple, upload. The rest stays.

## Cost

| Item | Cost |
| --- | --- |
| Apple Developer Program (Developer ID + notarization) | $99/year |
| Notarization submissions | Free, unlimited |
| GitHub Releases hosting | Free |
| Self-signed release certificate | Free |

The $99 buys notarization, and notarization is what Homebrew, a
double-clickable `.dmg`, and a shareable link need. Curl covers a developer who
is already in a terminal. It does not cover a person who was sent a link.

The self-signed certificate is free and keeps the permission grants across
upgrades.
