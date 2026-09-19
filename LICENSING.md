# Licensing

ParrotFlow is dual-licensed. The source in this repository is GPL-3.0. The
build on the Mac App Store is not, because it cannot be.

> **Not legal advice.** This file is the engineering account of how the two
> licences are kept apart, written so the code and the build scripts match a
> decision. Have a lawyer read it and the App Store terms before submitting.

## Why there are two

GPL-3.0 and the App Store terms conflict. The App Store imposes limits on what
a person may do with a copy — how many devices, what they may pass on — and
GPLv3 forbids passing those limits on. This is not a theory: it is why VLC was
pulled from the store in 2011.

A copyright holder is not bound by their own licence. The same code can be
offered under the GPL to everyone and under different terms on the store, and
the two builds can come from one tree. That is the only reason this is
possible at all, and it rests entirely on the next section.

## What it rests on: owning the copyright

Dual-licensing works only while one party holds the rights to all of the code.
Today that is true. `git log` shows one human author and one bot.

**The DCO is not enough for this, and that is the thing to know.** A
`Signed-off-by:` line certifies that a contributor had the right to submit
their code under the project's licence. It transfers nothing and grants no
right to relicense. So the moment a third party's patch lands under the DCO
alone, that patch is GPL-3.0 and cannot go into the store build.

The consequences, in order of how much they hurt:

1. A contribution that arrives under the DCO can be merged into the GPL build
   and must then be kept out of the App Store build — which means two diverging
   trees, which is the thing this whole arrangement exists to avoid.
2. Or it is refused, which is a bad answer for an open project.
3. Or the contributor signs a **CLA** granting the right to relicense, and the
   problem does not arise.

If the store build matters, a CLA has to be in place *before* the first
outside contribution, not after. Retrofitting one means going back to every
contributor and asking, and anyone who says no or cannot be reached has to
have their code removed.

## What each build is under

| | Source | Binary |
|---|---|---|
| Direct (curl, Homebrew) | GPL-3.0 | GPL-3.0 |
| Dev | GPL-3.0 | not distributed |
| App Store | GPL-3.0 in this repo | Apple's standard Licensed Application EULA |

The App Store build needs no custom EULA. Apple supplies a standard Licensed
Application End User License Agreement that applies unless a custom one is
submitted, and its terms are the ordinary ones for a paid or free Mac app. A
custom EULA is worth the legal cost only if something specific is needed that
the standard one does not give.

Publishing under Apple's terms does not close the source. The repository stays
GPL-3.0, and anyone may keep building and shipping the direct build from it.

## What ships inside the App Store build

Everything the store build distributes has to allow commercial redistribution.
Checked against what `scripts/build-app.sh` actually puts in the bundle:

| | Licence | |
|---|---|---|
| CPython 3.13 | PSF | Bundled. `scripts/fetch-python.sh` asserts `lib/python3.13/LICENSE.txt` survives the trim — shipping it without that file is a violation. |
| Yams | MIT | |
| FluidAudio | Apache 2.0 | |
| mlx-swift-lm | MIT | |
| swift-transformers | Apache 2.0 | |
| The parrot | CC BY | Md Moniruzzaman, Noun Project. Attribution is in the About panel and the README. |

eSpeak NG is GPL-3.0 and is **not** in this build. The store build cannot run
a program outside its bundle, so it neither ships nor invokes it, and the About
panel drops its credit line — see `AppVariant.credits`.

## The models, which are downloaded and not shipped

These are fetched at run time, so they are not redistributed. Terms still
matter, because the app causes the download and depends on them.

| | Licence |
|---|---|
| Parakeet TDT 0.6B v3 | CC BY 4.0 — commercial use allowed, attribution required and given |
| Silero VAD | MIT |
| mmBERT-small | MIT |
| Qwen3 0.6B Base | Apache 2.0 |
| Qwen3 Embedding 0.6B | Apache 2.0 |

**CharsiuG2P is the one to look at.** The About panel already records the
problem: the code is MIT, the Core ML weights the app fetches are Apache 2.0,
and *the upstream weights state no licence at all*. Nothing is redistributed,
which is the saving grace, but "no stated licence" is a worse position for a
paid product than for a GPL one. Resolve it or drop the pronunciation path from
the store build.
