# Making ParrotFlow the default dictation tool for devs

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

> **ParrotFlow is dictation configured like a dev tool: local speech, one YAML
> file, transforms you can script, and a vocabulary your coding agent can
> build from your repo.**

Two things make this defensible:

- **Local and fast.** Wispr Flow and Aqua Voice are cloud and paid.
  superwhisper and VoiceInk are local but configured through a GUI. Nobody
  else is "a plain YAML file your agent edits".
- **The coding-agent wedge.** Devs now spend hours a day writing prose to
  Claude Code and Cursor. Prompts are long, typing is slow, and the words are
  full of repo jargon a general speech model mangles. ParrotFlow's vocabulary
  plus `AGENTS.md` plus the `vocabulary-corpus` skill answer exactly that.
  Lead with this use case, not with "dictate emails".

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
  "local Wispr Flow alternative", r/LocalLLaMA gets "Parakeet + local Gemma,
  here is the pipeline and the latency numbers". Honest maker posts, numbers
  included. Fix whatever breaks.
- **Week 4 — Show HN.** The one shot that matters. Suggested title:
  *Show HN: ParrotFlow – local dictation for macOS, programmable in one YAML
  file*. First comment (yours): why it exists, the latency numbers, what is
  local vs optional-remote, and the coding-agent vocabulary story. Post
  Tue–Thu, 8–10am ET. Stay in the thread all day; answers from the author
  are what keep a Show HN alive.
- **Week 5 — awesome lists and directories.** PRs to awesome-mac,
  awesome-macos, local-AI and whisper-adjacent lists. Submit to lobste.rs.
  These are 15-minute tasks that compound; they are also the long-tail SEO.
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
- A user-contributed transform gallery is the moat: rules are shareable,
  GUI settings are not.
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
- **Enough popularity for `homebrew/cask`** — submit, and the install line
  becomes `brew install parrotflow`. That line in a thousand dotfiles repos
  is what "default dictation tool for devs" looks like.
- **First external transform PR merged** — the flywheel exists.

The realistic arc to "default" is 12–18 months, and it is carried by the
biweekly posts and the transform gallery, not by launch week.
