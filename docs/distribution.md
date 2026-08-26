# Distribution and install flow

How ParrotFlow gets onto someone else's Mac.

Releases are automated. The app installs by `curl` or by Homebrew, and a coding
agent can drive the whole setup. Releases are signed with a Developer ID and
notarized by Apple, so Gatekeeper opens them whichever route they arrived by.

## What the signature does

Release builds are signed with a **Developer ID Application** certificate. It
does two jobs, and they are easy to confuse.

The first is Gatekeeper. A notarized Developer ID signature is what lets macOS
open the app whichever route it arrived by — a Homebrew cask, a `.dmg`, a link
someone was sent. Only the curl install ever worked without it, and only
because files fetched with curl carry no quarantine attribute.

The second is permissions. TCC keys Microphone and Accessibility to the signing
certificate, so signing every release with the same one is what stops an
upgrade silently costing users both. Replacing the bundle with one signed by a
different identity loses both grants, and the failure is baffling: the app
stops working and System Settings still shows it ticked.

So the certificate is a durable asset, not a build artefact. Keep the `.p12`
and its password. Losing them costs every existing user their permissions on
the next release.

### The one-time cost of the switch

Releases up to v0.9.0 were signed with a stable self-signed certificate
(`scripts/release-certificate.sh`). That did the second job and nothing at all
for the first. Moving to a Developer ID changes the identity, so it costs
exactly what the paragraph above describes: everyone on an older release grants
Microphone and Accessibility once more.

It also means the updater built into those releases refuses the first notarized
build — the check compiled into it does not recognise the new signature. That
is the right failure. An update that succeeded would swap the identity and
leave the app running with no microphone and no explanation. Those users re-run
the curl line, or install with brew. Say so at the top of the release notes:
the update panel renders them, so it is read before anyone clicks install.

Both costs are smallest the earlier this happens, which is why it happens
before the launch rather than after it.

## How a download is checked

There are two ways in — `scripts/install.sh` and the app updating itself — and
they check the same things in the same order, because a door that checks less
is the door that gets used. `Sources/ParrotFlow/UpdateInstaller.swift` is the
second one.

1. The published SHA-256 matches the archive.
2. `codesign --verify --deep --strict`: the signature covers the bundle.
3. `codesign -R` against a designated requirement: who signed it.
4. `spctl --assess --type execute`: Apple notarized it.

Step 3 is the one worth explaining. A valid signature says nothing about who
produced it — anyone can make a certificate, give it any common name including
this one, and pass step 2. The requirement is

```
anchor apple generic and certificate leaf[subject.OU] = "TEAMID"
```

`anchor apple generic` says the chain ends at Apple's root, which nothing
self-signed can claim. The OU of a Developer ID leaf is the Team ID. Together
they say Apple issued this certificate to us.

Step 4 is separate because a signature can be genuine and the build never
submitted. `spctl` asks the question Gatekeeper asks.

Earlier releases pinned the SHA-256 of the leaf certificate instead. The Team
ID replaced it because a Developer ID expires after five years, and renewing it
produces a new leaf with a new hash. A hash compiled into every installed copy
would reject the release that followed the renewal, for every user at once, and
the only way back would be to ask all of them to re-run the installer. The Team
ID does not change when the certificate does.

It is declared twice — `TEAM_ID` in `scripts/install.sh`, `expectedTeamID` in
`Updates.swift` — and `scripts/check-signing-identity.sh` fails the build if the
two disagree.

## Setting up the credentials

Two secrets, both out of the Apple Developer account.

**The certificate.** Create a Developer ID Application certificate in the
developer portal, download it, and export it from Keychain Access as a `.p12`
with a password.

```sh
security find-identity -vp codesigning   # confirm it is there; the OU is the Team ID

base64 -i DeveloperID.p12 | gh secret set SIGNING_CERT_P12
gh secret set SIGNING_CERT_PASSWORD
```

**The notarization key.** An App Store Connect API key with the Developer role,
rather than an Apple ID and an app-specific password: it can be revoked on its
own, it carries nothing but that role, and it does not stop working when the
account password changes. It downloads once, as `AuthKey_XXXXXXXXXX.p8`.

```sh
base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_KEY
gh secret set NOTARY_KEY_ID       # the XXXXXXXXXX out of the filename
gh secret set NOTARY_ISSUER_ID    # shown above the key list in App Store Connect
```

Then put the Team ID in `scripts/install.sh` and `Updates.swift`, and run
`scripts/check-signing-identity.sh`.

For a release cut by hand, `xcrun notarytool store-credentials parrotflow`
saves an Apple ID and an app-specific password in the keychain once.
`scripts/notarize.sh` uses that profile when no API key is in the environment.

The first local build that uses the Developer ID puts a keychain dialog on
screen — *codesign wants to sign using key ... in your keychain*. Answer
**Always Allow**, not Allow. Until something answers it, `codesign` waits, with
no output and no timeout, and the build looks frozen rather than blocked. It
was measured taking 300 seconds and still waiting; once allowed the same signing
step takes under half a second.

CI never meets this. `release.yml` builds its own keychain and runs
`set-key-partition-list` against it with that keychain's password, which grants
codesign the key up front.

### The entitlement that is easy to get wrong

Notarization requires the hardened runtime, and the hardened runtime blocks
microphone access unless the app declares it. Non-sandboxed apps use
`com.apple.security.device.audio-input`. `com.apple.security.device.microphone`
is the App Sandbox key and does nothing here. Without the right one the app is
refused the mic or killed outright. It lives in `Resources/entitlements.plist`,
and `scripts/codesign.sh` is what passes it.

Accessibility needs no entitlement. It is TCC-only, granted by the user.

## Homebrew

```sh
brew install znat/tap/parrotflow
```

The cask lives in [znat/homebrew-tap](https://github.com/znat/homebrew-tap) and
is written by `scripts/bump-cask.sh` in this repository, so what a `brew
install` gets is reviewed here rather than in a second repo with its own
history. The tap holds no logic.

The cask reads the checksum off the published release rather than computing its
own, so brew cannot end up trusting a number the other two install paths would
refuse. It sets `auto_updates true`, because the app installs its own updates
and brew should not report a self-updated copy as outdated.

curl stays the headline install. It needs nothing installed first. Homebrew is
for people who keep a Brewfile, and for ending the "curl | sh" argument.

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
the same checks `install.sh` runs, in the same order — see "How a download is
checked" above. Nothing is replaced until every one of them agrees. See
`UpdateInstaller`.

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
it replaces the signature check that already ties the update path to
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
with the Developer ID from repository secrets, submits the bundle to Apple and
staples the ticket to it, and attaches `ParrotFlow.zip` and its checksum — which
is what `install.sh` downloads from `releases/latest/download/`. A last job
points the Homebrew cask at the new version.

Notarization is the slow step: Apple usually answers in a couple of minutes,
and `scripts/notarize.sh` waits for the answer rather than stapling a ticket
that does not exist yet.

Missing secrets fail the build rather than warn. An ad-hoc signed release is one
that `install.sh`, the app's updater and Gatekeeper all refuse, so publishing it
would only produce an asset nobody can install.

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

## Cost

| Item | Cost |
| --- | --- |
| Apple Developer Program (Developer ID + notarization) | $99/year |
| Notarization submissions | Free, unlimited |
| GitHub Releases hosting | Free |
| Homebrew tap | Free |

The $99 buys notarization, and notarization is what Homebrew, a
double-clickable `.dmg`, and a shareable link need. Curl covers a developer who
is already in a terminal. It does not cover a person who was sent a link.
