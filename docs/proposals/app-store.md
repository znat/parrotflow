# Proposal: what publishing on the Mac App Store would cost

**Status.** The `appstore` variant is built, it bundles its own CPython, and
the licence split is written down in [LICENSING.md](../../LICENSING.md). It
cannot be submitted yet: there is no Xcode target to archive from, none of the
Swift has been compiled, and `make sandbox-probe` has still not been run — so
whether the hotkeys survive the sandbox is still unmeasured. See *Built so far*
and *What is left*.

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

## Built so far

A third variant, `appstore`, beside `dev` and `release`. Same mechanism as the
other two: a separate bundle identifier, `com.parrotflow.app.mas`, and
`AppVariant.channel` reads it off the bundle at runtime. One binary still
serves all three.

| | |
|---|---|
| `config.appstore.yaml` | What a store install is written with. Three `replace:` transforms, two pipeline steps, no `command:`, no `prompt:`, no `models:`. |
| `scripts/check-appstore-config.sh` | The guard on that file. Runs in `make test`, needs no binary and no model. Takes a root argument so it can be tested against a broken copy. |
| `AppVariant.Channel` | `.dev` / `.direct` / `.appStore`. `isDev` is unchanged for every existing caller. |
| `CommandRunner.complaint` | Refuses in the store build and says why, once, in the log and in `--check-config` — rather than letting a stage look like a rule that did not match. |
| `UpdateInstaller` + `AppDelegate` | No hourly GitHub call, no install path, and a manual check says updates come through the store. |
| `scripts/variant.sh` | `HOME_PREFIX`, because the sandbox rewrites the home directory and `~/Library/Logs/ParrotFlow.log` is a different file that also exists and is empty. |
| `scripts/build-app.sh` | Ships the store config, and skips `examples/` and `parsing-requirements.txt` — several hundred kilobytes of scripts this build cannot run, in a bundle Apple reads. |

**What a store install gets.** Local dictation, the vocabulary stage, spoken
corrections, `fillers`, `fillers_fr`, `github_refs` — and, since the
interpreter was bundled, `disfluency`, `dates_en` and `numbers_en`. That is
the README's two headline features back.

**What it does not.** `grammar` needs Ollama. `parse` needs spaCy.
`slack_mentions` is a roster the user edits and this build cannot seed one. And
no `command:` of the user's own, which is the real loss and the one nothing
fixes.

### The interpreter, as built

`scripts/fetch-python.sh` pins CPython 3.13.15 from python-build-standalone by
version and SHA-256, and trims it. Measured, not estimated:

| | |
|---|---|
| download | 24 MB |
| extracted | 66 MB |
| after the trim | 28 MB |
| Mach-O files to sign | **1** |

That last row is why this was easier than the first draft said. This build of
CPython is statically linked — `unicodedata`, `_sre`, `_json`, `_datetime`,
`zlib` and the rest live in the executable, `lib-dynload` holds only `_dbm` and
`_tkinter`, and the trim removes both. There are no `.so` files and no
`libpython` dylib, so library validation has nothing to refuse and
`disable-library-validation` is not needed. The script fails if a future
CPython changes that.

Signed inside-out, with `Resources/entitlements-inherit.plist`:
`com.apple.security.inherit` makes the interpreter a child of the app's
sandbox rather than a sandbox of its own, and it is the only entitlement a
child that inherits may carry.

`BundledPython.swift` is the gate. A `command:` may name one thing: a `.py`
inside `Contents/Resources/examples`, checked after standardising the path so
`..` cannot walk out. No shell, so nothing is resolved against PATH at run
time. `Config.createIfMissing` no longer seeds the scripts into the container
for this build — they run where they were signed, because writing an
executable into the container and then running it is the shape 2.5.2 is about.

`scripts/check-appstore-config.sh` enforces all of it, including that every
shipped script imports only the standard library **at module level**. That
distinction is load-bearing: `disfluency.py` imports spaCy inside
`spacy_or_none()` under `try/except ImportError` and runs four of its five
rules without it, which is the fail-open rule working, not a fault.

## What is left

1. **Run `make sandbox-probe`.** Still first, still unrun. A tap the sandbox
   refuses ends this whether or not the variant builds.
2. **An Xcode target.** `Package.swift` has a bare `executableTarget` and
   SwiftPM cannot produce a signed `.pkg`. Nothing can be submitted until this
   exists.
3. **Store certificates.** `pf_signing_identity` already prefers
   *3rd Party Mac Developer Application* and *Apple Distribution* for this
   variant, and falls back to the self-signed ones so a local sandbox build
   works on a machine that has never enrolled one. That fallback build runs
   and can be measured; it cannot be submitted.
4. **A CLA, before the first outside contribution.** The licence split is
   written down and works today because one human holds the copyright. The DCO
   does **not** grant the right to relicense, so the first patch merged under
   it is GPL-3.0 and cannot go into the store build. Retrofitting a CLA means
   asking every contributor, and removing the code of anyone who says no.
   [LICENSING.md](../../LICENSING.md) has this and the third-party inventory —
   including CharsiuG2P, whose upstream weights state no licence at all.
5. **Verify.** None of the Swift above has been compiled — it was written
   without a macOS toolchain. `make test` is the first thing to run.

---

## What the sandbox costs if the probe passes

These are the things that would have to go or change. They are listed so the
decision is made against the whole bill, not the first item.

**The extension system — but only half of it.** `CommandRunner.swift` pipes a
transcript through `/bin/sh` or `python3`. Guideline 2.5.2 wants an app
self-contained in its bundle and forbids running code it did not ship. That
kills a `command:` transform the *user* writes: a `.py` in their config folder
is code the app shipped without and review never saw. No interpreter
arrangement rescues that one.

It does not obviously kill the shipped transforms, and the difference is worth
a section of its own — see *A Python inside the bundle* below.

`ParsingInstall.swift` goes either way: it fetches spaCy and its models at
runtime, which is downloading code. `data/parsing-requirements.txt` already
says *"Nothing here ships with the app"*, so the `parse` transform is opt-in
today and would simply not exist in a store build. `EspeakInstall.swift` goes
too — it tells the user to `brew install espeak-ng`, and espeak-ng is GPLv3 so
it cannot be bundled instead.

What survives is not nothing, but the README leads with the part that does
not: *PR links and Slack mentions are NOT features — they are extensions
configured in yaml*. A user who cannot write the next one is buying a
different product.

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

## A Python inside the bundle

The shipped transforms may not need the interpreter to be the user's. Checked
against the tree rather than assumed:

| Transform | Imports | Third-party |
|---|---|---|
| `dates` (en, fr, engine) | `re json sys os pathlib datetime importlib` | none |
| `numbers` (en, fr, engine) | `re json sys os pathlib` | none |
| `disfluency` | `re json sys os collections` | none |
| `join` | `re json sys` | none |
| `parse` | spaCy | **yes** — opt-in today, drops out |

About 2,100 lines, pure stdlib, pure text in and text out. A CPython trimmed to
that is 15–40 MB, which is nothing beside the 3 GB the app already uses, and
the 40–60 ms cold start is the cost being paid today.

Executing a binary inside your own bundle is not what the sandbox forbids. The
child inherits the sandbox through `com.apple.security.inherit`, and the
scripts would be signed, reviewed and read-only along with everything else in
`Contents/Resources/`. That is the self-contained story 2.5.2 asks for.

Three things would have to be true, and none of them is free:

1. **`Config.createIfMissing()` has to stop seeding.** It copies every shipped
   `.py` out of the bundle into `transforms/examples/` on every launch and
   chmods it `0755`. Under the sandbox that reads as: write executable code
   into the container, then run it. That is the 2.5.2 shape even though the
   file came from the bundle. The store build has to run them in place, from
   the signed read-only bundle, and give up the refresh-on-launch trick that
   buys one shared copy of a script.
2. **Every `.so` in `lib-dynload` has to carry our Team ID.** Library
   validation under the hardened runtime refuses anything else. Sign them in
   the build; do not reach for `com.apple.security.cs.disable-library-validation`,
   which is a review flag and unnecessary when we control the signing.
3. **No `__pycache__`.** Python writes `.pyc` beside the `.py` on first
   import, which a signed read-only bundle refuses — and would invalidate the
   signature if it did not. Precompile at build time and set
   `PYTHONDONTWRITEBYTECODE=1`.

**The alternative to bundling anything.** Those four transforms are regex and
lookup tables. Porting them to Swift removes the interpreter, the signing
work and the review risk in one move. The cost is the scoring harness: the
case sets and `--eval` are built around the scripts, so either the harness is
ported too or the store build is scored differently from the one people
install — and [AGENTS.md](../../AGENTS.md) makes scoring the rule that is not
negotiable. That is the trade to argue, and it is a real one.

Either way this is second. The probe comes first.

---

## The alternative that is not the App Store

The gap is a person who was sent a link and does not live in a terminal. A
signed `.dmg` behind a real download page closes it. Releases are already
notarized, so Gatekeeper opens it. No sandbox, no relicensing, no second
update path, and the extension system survives.

This is the cheaper answer to the actual problem, and it should be ruled out
before the sandbox is paid for.
