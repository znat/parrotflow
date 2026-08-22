# Promoting ParrotFlow, the programmable dictation tool

Status: **plan, nothing executed yet.**

The constraint: one maintainer, 5–10 hours a week, full-time job. The plan is
shaped around that. Nothing here needs a sprint. Everything is a weekly
routine plus a small number of one-shot launches.

Where we start (2026-08-22): 3 stars, 0 forks, repo is 3 weeks old, v0.9.0.
The README, docs, and demo gifs are already launch-quality. What is missing is
distribution, not polish.

---

## 1. The position

One sentence, used everywhere, verbatim:

> **ParrotFlow is the dictation app your coding agent can program: pipelines,
> transforms and vocabulary live in one YAML file that the agent — or you —
> reads, edits and tests.**

One substrate, two framings, picked per channel:

- **"Your agent programs it."** For AI-native devs, who are most devs now.
  They never open the YAML: they say "make my dictation turn P one into P1
  and stop mangling our product names", and the agent writes the transform,
  runs its tests, and updates the vocabulary from the repo. No GUI app can
  offer this — an agent cannot click through settings, but it can edit a
  file. This framing leads on X, Reddit, and in every demo.
- **"Configure it like Neovim."** For the dotfiles crowd — smaller, but
  they are the ones who star, share configs, and contribute. This framing
  leads on HN and lobste.rs.

The landscape (August 2026) decides this position. "Local" is table stakes
now: Handy is free, MIT and minimal; VoiceInk is a polished open-source Mac
app; Wispr is the no-config cloud product; Claude Code ships its own
`/voice`. None of them is programmable — by a person or by an agent. A
pipeline of regexes, scripts and scoped prompts in a plain file is a
position ParrotFlow holds alone: for the dotfiles crowd it is espanso
against TextExpander, and for everyone else it is the only dictation app
their agent can actually operate.

Two more consequences:

- **Lead with programmable, not with local.** Local, fast and private are
  said once, as table stakes, then the demo is the pipeline.
- **Against per-tool voice modes** (Claude Code `/voice`, editor plugins):
  ParrotFlow is system-wide — one vocabulary and one pipeline across Claude
  Code, Cursor, Slack, the terminal, everywhere. That is the answer, not
  "better recognition".
- **Agents are a distribution channel of their own.** AI-native devs ask
  their agent what to install. Being the answer to "best dictation app that
  works with Claude Code" means docs an agent can find, cite and execute:
  AGENTS.md, the comparison page, install steps that run unattended. Every
  doc now has two readers.

Do not chase cross-platform now. Devs skew Mac, the story is coherent, and a
port would eat the whole time budget.

## 2. Phase 0 — remove friction (weeks 1–2, ~8h total)

Everything a launch sends traffic to must already work.

1. **Join the Apple Developer Program and notarize releases** ($99/year).
   The app is not notarized today; the curl install works only because curl
   sets no quarantine attribute. A mic + Accessibility + keystroke app that
   is not notarized is the trust objection a security-minded HN commenter
   will raise on launch day, and "signed and notarized" is the one-line
   answer. The full recipe is already in docs/distribution.md
   ("Signing and notarizing"); budget half a day for the hardened-runtime
   entitlements. Also a hard prerequisite for any paid build later.
2. **Homebrew tap — only after notarization.** Casks apply quarantine by
   default, so an unsigned app fails Gatekeeper there. Once notarized:
   `znat/homebrew-tap` with a cask (`auto_updates true`, the app has its own
   updater), wired into release-please. curl stays the headline install;
   brew is for Brewfiles and for ending the "curl | sh" comment thread.
3. **Fresh-Mac install test.** Run `install.sh` on a clean account. Time it,
   note every permission prompt. The first 10 minutes decide the HN comments.
4. **Turn on GitHub Discussions.** Issues stay for bugs; "how do I write this
   transform" needs a home that is not an issue.
5. **Add `.github` community files, including a DCO.** Bug and question issue
   templates, a short CONTRIBUTING.md pointing at AGENTS.md and `make test`,
   and a DCO check on PRs, so every contribution certifies its origin from
   the first external PR on.
6. **Set the repo homepage field** and add a one-page GitHub Pages site later
   only if referrer data says people need one. The README is the landing page
   for now.
7. **Record the hero demo as a 60–90s video** (the gifs already exist; screen
   recording with audio of the actual speech is more convincing than a gif).
   Host on YouTube, link from README. This is the single asset every channel
   reuses.

## 3. Phase 1 — launches (weeks 3–6, one channel per week)

Order matters: small rooms first to catch install bugs, HN when the path is
proven. Each launch is ~2h: post in the morning, answer comments same day.

- **Week 3 — r/macapps and r/LocalLLaMA.** Different angles: r/macapps gets
  "local and programmable, here is the YAML", r/LocalLLaMA gets "Parakeet +
  local Gemma, here is the pipeline and the latency numbers". The crowded
  pitch ("another Wispr alternative") is the one to avoid; the pipeline demo
  is the one nobody else can post. Honest maker posts, numbers included.
  Fix whatever breaks.
- **Week 4 — Show HN.** The one shot that matters. Suggested title:
  *Show HN: ParrotFlow – dictation for macOS you configure like Neovim*.
  First comment (yours): why it exists when Handy and VoiceInk exist — the
  pipeline, the scripted transforms, the tested prompts — plus the latency
  numbers and what is local vs optional-remote. Post Tue–Thu, 8–10am ET.
  Stay in the thread all day; answers from the author are what keep a
  Show HN alive.
- **Week 5 — awesome lists and directories.** PRs to awesome-mac,
  awesome-macos, local-AI and whisper-adjacent lists — and the dotfiles and
  Mac-automation ecosystems (awesome-dotfiles, the espanso, Hammerspoon and
  karabiner-adjacent lists), which is where the actual audience lives.
  Submit to lobste.rs. These are 15-minute tasks that compound; they are
  also the long-tail SEO.
- **Week 6 — newsletters.** Console.dev, TLDR, MacStories tips, Dense
  Discovery. Short pitch email each, link to the video. Console alone has
  moved four figures of stars for tools like this.

Product Hunt: skip unless bored. Its audience is not devs and the prep cost
is high.

**Rule for all of it:** you post under your own name, as the author. Claude
drafts, you review and submit. No sockpuppets, no vote asks, no replying to
Reddit threads pretending to be a user. One astroturfing accusation on HN
costs more than every launch gains.

## 4. Phase 2 — the content flywheel (week 4 onward, forever)

This is where the 5–10h/week goes long-term, and the repo has an unfair
advantage: the measured docs are already written. Each becomes a blog post,
and each post is its own HN/lobste.rs submission. Working titles, all backed
by material already in the tree:

- "Local dictation in under 500ms: where the time goes"
  (docs/architecture.md)
- "Teaching a speech model your jargon with one spoken correction"
  (vocabulary, the Versailles/Vercel demo)
- "Ten framings for an LLM judge, and why nothing won"
  (docs/proposals/judge-framings.md — this one is very HN-shaped)
- "A self-correction prompt scored against 89 real transcripts"
  (examples/transforms/self_correction)
- "I let my coding agent configure my dictation app" (AGENTS.md +
  vocabulary-corpus; also the best short-video demo for X)
- "Why another dictation app when Handy and VoiceInk exist" — the honest
  comparison post: minimal free, polished app, no-config cloud, and
  programmable; where each wins, written straight. Also becomes a
  docs/comparison page, which is what half the search traffic wants.

Cadence: one post every two weeks. A post is 3–4h with Claude drafting from
the source doc and you rewriting in your voice. Host on a personal blog or
GitHub Pages, not Medium.

Short demo clips (20–40s, real dictation into Claude Code) go on X/Mastodon
between posts. The "Versal → Vercel" clip is the hook.

## 5. Phase 3 — convert users to a community (ongoing)

- Answer every issue and discussion within 24h. Early on, response time *is*
  the marketing.
- Label `good-first-issue` honestly; transforms are the natural first
  contribution. Nudge every "here is my transform" discussion toward a PR to
  `examples/transforms/`.
- **The per-repo vocabulary folder** (spec'd separately) is the second
  spread mechanic: a repo that commits it teaches every contributor's
  dictation the project's jargon, and shows every contributor the tool
  exists — the `.editorconfig` effect. It also gives teams shared
  vocabulary through git alone, no service. It does not gate the launch;
  if it lands before the Show HN, it is the demo's second act, and either
  way it gets its own flywheel post ("your repo carries its own dictation
  vocabulary").
- **The transform gallery is the whole bet**, not one bullet among four.
  Shareable config is the community mechanic that GUI apps structurally
  cannot have, and it is what carried espanso and Hammerspoon past
  better-funded competitors. Make sharing frictionless: a transform is one
  folder with its tests, `examples/transforms` is the gallery, and every
  post and demo ends by pointing at it.
- Release monthly minimum, even if small. release-please makes this cheap.
  A moving project gets starred; a quiet one gets bookmarked.

## 6. What Claude does vs what you do

You have 5–10h/week. Claude products stretch it roughly 3x, but the split
must be clean:

**Claude (Claude Code sessions against this repo):**

- Draft every post, pitch email, and Show HN comment in the repo's voice,
  from the source docs.
- Build and maintain the Homebrew tap, community files, and release wiring.
- Triage: a session that reads new issues, reproduces what it can, drafts
  replies, labels — you approve and send.
- Babysit CI and release PRs (`subscribe_pr_activity`).
- A weekly scheduled session (Routine) that pulls GitHub traffic — views,
  clones, referrers, stars — and emails you a digest. GitHub keeps traffic
  data for only 14 days, so weekly collection is not optional.

**You, and only you:**

- Press submit on HN, Reddit, and every public post.
- Answer launch-day comments (people can tell).
- Record your own voice in the demos — it is a dictation app.
- Decide roadmap.

A workable week: 1h triage + release, 3h content (Claude drafted), 1h
launch/outreach task from the current phase, 1h in comments/discussions.
That is 6h; the 10h weeks are launch weeks.

## 7. Milestones and honest measures

Stars are the vanity metric; installs and returning users are the real ones.
Track: release download counts, tap installs, traffic referrers, and
discussions started by people you don't know.

- **~100 stars** — first Reddit posts landed. Expected week 3–4.
- **~1,000 stars** — a Show HN or a post hit the front page. If week 8
  passes without one, the message is wrong, not the product: revisit §1
  with the comment threads as data.
- **A stranger shares a transform or a config** — PR, gist, or blog post.
  This is the signal that matters more than any star count: it means the
  espanso mechanic caught. Everything in Phases 2 and 3 is aimed at making
  this happen and then compounding it.
- **Enough popularity for `homebrew/cask`** — submit, and the install line
  becomes `brew install parrotflow`. That line in a thousand dotfiles repos
  is what winning this niche looks like.

The model is espanso, Hammerspoon, karabiner-elements: tools that won a
durable community of people who version-control their setup, against bigger
and better-funded products. The realistic arc is 12–18 months, carried by
the biweekly posts and the transform gallery, not by launch week.
