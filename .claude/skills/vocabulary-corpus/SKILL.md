---
name: vocabulary-corpus
description: Gather the first vocabulary for ParrotFlow — the names, jargon and acronyms a person actually says — from their codebase and their Slack, and turn it into a `vocabulary.yaml`. Use when setting ParrotFlow up on a new machine or a new project, when dictation keeps mangling the same words, or when someone asks what terms they should add.
---

# Building someone's first vocabulary

The vocabulary is a flat list of words you want written correctly. One entry
covers every way the recogniser mangles a name, including renderings nobody has
seen yet — which is what a `replacements` rule cannot do, because a rule needs
the mistake to have happened first.

The hard part is not finding candidate terms. It is throwing away the ones that
will do damage. Most of this skill is rejection criteria, and they are all
earned from measurements: see the scoreboard in `docs/transcription.md`.

**What you are producing:** a `vocabulary:` block for the user's config, and a
short list of terms that need checking by ear because a machine cannot settle
them.

## Say this before you ask for anything

The user is about to hand over their colleagues' names and their company's
internal vocabulary. Tell them where it goes, in plain words, before they do:

> Everything here stays on your Mac. ParrotFlow transcribes locally with a
> model on your machine, the config file is a text file in your home
> directory, and nothing you paste is sent anywhere. The only network call the
> app makes on its own is a daily check for a new release.

Then keep it true:

- **Do not put names into any tool that leaves the machine.** No web search on
  a colleague's name to check its spelling, no asking a hosted model to tidy
  the list. Work from what the user pastes.
- **Write only to the user's config.** Names belong in
  `~/.config/parrotflow/config.yaml`, not in a scratch file somewhere, and not
  in a commit.
- **Do not repeat the whole roster back in chat** beyond what is needed to
  confirm a decision. A list of everyone someone works with is not something
  to restate for the sake of a tidy summary.

If the user is on a project with `transforms:` that call a hosted API — the
OpenAI scripts in this repo are an example — say so plainly, because that is a
real exception to "nothing leaves the machine" and it is theirs to weigh.

## The shape of a good term

Measured over 505 transcripts and 15 screened candidates, terms sort into four
kinds, and only two are worth adding.

**Compounds the decoder splits.** The best case by a distance.

    RedCrawl   -> "red crawl"     glued: redcrawl   1.00
    LangSmith  -> "Lang Smith"    glued: langsmith  1.00
    Firecrawl  -> "fire crawl"    glued: firecrawl  1.00

Glued back together they match exactly, so no threshold can reach anything
else, and they cannot damage a transcript. Take all of these.

**Distinctive names with nothing near them.** Take these too. Nothing near
them means nothing to argue about.

    Tasmeen    nothing within 0.71 in 234k dictionary words
    Arexvy     nothing within 0.67

**Names that collide with ordinary words.** No threshold works. Use
`floor: off` and a `pronunciations:` list instead.

    Praisy   vs "praise"    0.83   and they sound alike, so no gate saves it
    Sentry   vs "entry"     0.83
    Postgres heard as "posters"   0.75

**Words the decoder already writes correctly.** Reject — pure risk, no gain.

    Supabase, Playwright, Drizzle, Tailwind, GitHub, OpenAI, TypeScript

## Step 0 — look for a `.parrot/` folder first

If the repository has one, somebody has already done this for this project.
`.parrot/vocabulary.yaml` holds the terms their team says out loud, and the
comments hold the ones they screened and threw away, with the reason.

Start there rather than from the manifests. It is still hints: screen every
term against this speaker with step 3 and step 5 below, because the risk a
term carries depends on the accent and the languages of whoever dictates it.
`.claude/skills/parrot-folder/SKILL.md` is the procedure, and
`docs/sharing.md` is what the folder is.

## Step 1 — mine the codebase

Read a **subset**, not the tree. What you want is words the person says out
loud in conversation about this project, which is a much smaller set than the
words in the code.

Look at, in this order:

- `package.json`, `Package.swift`, `pyproject.toml`, `go.mod`, `Cargo.toml` —
  dependency and workspace names.
- `README.md` and the top of `docs/` — product names, service names, the
  domain nouns.
- Directory names one level under `src/`, `packages/`, `apps/`.
- `.env.example` keys, and service names in `docker-compose.yml`.

Record the languages in use as you go — from the manifests and file
extensions. You will need them for the spell-check gate in step 3 and for the
sentences in step 5, and a French speaker's vocabulary must be checked against
French too.

Then apply these, in order:

1. **Drop anything under 5 letters or containing non-letters.** `db`, `ci`,
   `gpt-4o`, `CLAUDE.md`. The vocabulary only accepts 5+ letters.
2. **Drop ordinary words.** `build`, `config`, `content`, `parser`, `types`,
   `scripts`, `format`. These get written correctly and boosting them creates
   chances to overwrite the same word used normally.
3. **Drop what you type but never say.** `ipaddr`, `esbuild`, `postcss`,
   `undici`, `octokit`, `picomatch`, `autoprefixer`. This is the biggest cut
   and the easiest to forget — a lockfile is not a conversation.
4. **Convert slugs to spellings.** This is the trap. The vocabulary writes the
   term verbatim, so the entry has to be the output you want:

       package.json says   you would say         the term should be
       langchain           "LangChain"           LangChain
       tailwindcss         "Tailwind CSS"        Tailwind CSS
       nextjs              "Next JS"             Next.js  (rejected: has a dot)

## Step 2 — the Slack prompt

People's names are the highest-value terms in the whole exercise, and they are
not in any repository. Hand the user this to paste into their Slack assistant. It is deliberately
self-contained — no channel names to fill in, no options to pick. A setup step
that asks the user to configure it is a setup step they abandon.

```
Look at every Slack channel and DM I have posted in or been mentioned in
over the last 30 days. Do not ask me which ones — work it out from my
activity, and cover all of them.

Return four lists as plain text. No commentary, no summary, no preamble.

1. PEOPLE
   Everyone who posted in those conversations or who I addressed by name.
   One per line, as:  Display Name | @handle
   Use the spelling of their name as they write it themselves, accents and
   all. Include people I only mentioned by first name.

2. PRODUCTS AND BRANDS
   Names of tools, vendors, services, internal systems and repositories that
   come up in conversation. One per line. Give the exact capitalisation the
   team uses: "LangChain" not "langchain", "RedCrawl" not "redcrawl".

3. ACRONYMS AND JARGON
   Short forms and in-house terms an outsider would not understand.
   One per line, as:  TERM | what it means

4. RECURRING WORDS
   Any other word that appears often in these conversations and is not
   ordinary English or French — project names, codenames, place names,
   anything I say a lot.

Rules for all four lists:
- Only words people say out loud in meetings and messages. Skip anything
  that appears only inside code blocks, file paths, URLs or log output.
- Skip ordinary words. I want what a dictation tool would get wrong.
- Spelling is the whole point. A name spelled wrong here becomes a name
  spelled wrong in everything I dictate from now on.
```

Two things to tell the user when you hand it over:

- **Names are the point.** A colleague's name is dictated constantly, is
  usually foreign to the recogniser, and has no other fix.
- **Spelling matters more than completeness.** A name spelled the way they
  write it is a term; a name spelled the way Slack's assistant guessed is a
  term that will write the wrong thing forever.
- **The handles are worth keeping.** `Display Name | @handle` feeds the
  `slack_mentions` roster as well as the vocabulary, so one gathering serves
  both. The roster lives in `slack_mentions.py` beside the config.

## Step 3 — reject the collisions

For each surviving candidate, find its nearest ordinary word. That distance
decides one thing: whether the term can be matched by sound at all.

There is no number to pick per term. The app takes two numbers for the whole
file — `offer_below`, how far a spelling may sit from a term and still reach
the judge's menu, and `decide_above`, how hard the audio has to argue before a
reading is dropped. Leave both at their defaults. A near neighbour is no longer
a word that gets overwritten; it is a second line on a menu, and the sentence
picks.

Use `NSSpellChecker` for "is this a word", because that is what
`Replacements.isRealWord` uses. Check only the languages this person dictates
in — a French word list rejects English terms that are perfectly safe for an
English-only speaker:

```swift
// swift spell.swift word1 word2 ...
import AppKit
let checker = NSSpellChecker.shared
for word in CommandLine.arguments.dropFirst() {
    let known = ["en", "fr"].contains { language in
        checker.checkSpelling(
            of: word, startingAt: 0, language: language,
            wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
        ).location == NSNotFound
    }
    print("\(word)\t\(known)")
}
```

**All-caps is a trap.** `NSSpellChecker` accepts any all-caps run as an
acronym — `XQZPT` comes back known. Ask about the lowercase form for anything
capitalised.

For the distance, use plain Levenshtein over the longer length, which is what
FluidAudio's gate computes:

    similarity = 1 - editDistance / max(len(a), len(b))

Then:

- **Nearest ordinary word at 0.85 or above** — no threshold works. None both
  catches the term's mishearings and excludes that word. Ship it as
  `floor: off` with a `pronunciations:` list, and let it put the term on the menu and
  the sentence decide.
- **Otherwise** — plain entry. Nothing to write but the name.
- **Check two-word phrases as well as single words.** This is the hole that
  bites: `Turndown` has no dictionary collision and scores a clean 1.00, but
  "turn down the volume" glues to `turndown` and gets rewritten. Any term
  shaped like a verb-particle pair — `turn down`, `back end`, `set up`,
  `check out`, `log in`, `time out` — is unsafe by construction.

## Step 4 — screen with TTS, but do not trust it

Synthesising each term in a carrying sentence and transcribing it tells you
whether the decoder mangles the word at all. It is fast and it needs no
dictation from the user.

Use **Kokoro**, not macOS `say`. `say` has no pronunciation control — its
`[[inpt PHON]]` escape is read aloud as words — and it mispronounces invented
names. Measured: `Neuroplexorin` failed 6/6 under `say` and passed 12/12 under
Kokoro, because `say` was saying it wrong. Screening with `say` would have
added a term that needs nothing.

Three or four voices, three carrying sentences each. A bare word decodes
differently from one buried in speech, and the buried case is the real one.

**The loop cannot tell you which end failed.** A wrong transcript means either
the recogniser misheard or the voice mispronounced, and those call for
opposite conclusions. Have the user listen before trusting any verdict.

## Step 5 — the only measurement that counts

TTS answers whether the *model* knows a word. It says nothing about whether the
word survives *this speaker*, and accent is most of the problem — the whole
reason a non-native speaker needs this.

So: write three or four sentences per surviving term, hand them to the user,
and have them **read the sentences aloud into ParrotFlow**. Then compare what
came back against what they read.

That settles pronunciation and accent at once, and nothing else does. For a
dozen terms it is a few minutes of reading.

## What to hand back

The contents of `vocabulary.yaml`, which sits beside `config.yaml`:

```yaml
acoustic: true
offer_below: 0.50
decide_above: 3.0

terms:
  RedCrawl:             # "red crawl", glues to 1.00
  LangSmith:
  Tasmeen:              # nothing within 0.71
  Matthieu:
    floor: off          # "Matthew" is 0.75 and sounds the same
    pronunciations:
      - heard: Mathieu
        from: correction
      - heard: Matthew
        from: correction
```

A rendering is matched exactly as a rule *and* searched for by sound under its
term's name, which is what reaches a name no threshold can — `Versailles` is
0.40 from `Vercel`. `heard: [a, b]` is the old spelling of the same list; it
still loads, and `--check-config` says what to write instead.

An empty entry is the normal one. The two numbers at the top are the file's,
not a term's, and they ship untuned — leave them alone unless you have
measured the whole set.

That file carries a "do not edit unless you know what you are doing" header
because it is normally written by the app — from corrections and from
`--learn`. This skill is the other thing that writes it. Say that, rather than
leaving the header looking ignored.

And beside it, three short lists:

- **Rejected, with the reason.** `Praisy` — "praise" at 0.83. `Sentry` —
  "entry" at 0.83. These go in with `floor: off` and a `pronunciations:` list
  of renderings actually seen. `floor: off` turns sound matching off for the
  whole term, renderings included, so those are exact rules and the judge reads
  the sentence. Give the reason, or someone re-adds them next month.
- **Already fine.** The terms the decoder writes correctly. Same reason.
- **Read these aloud.** The step 5 sentences.

## Two things worth saying out loud to the user

**A vocabulary does not replace the replacement table.** Measured over 505
transcripts: the vocabulary caught 3 renderings no rule covered, and every one
it missed was already covered by a rule. It reduces how often you write a rule;
it does not remove the need. Mishearings that land far from the spelling —
`Tasmine` at 0.57, `RXV` at 0.50 — are out of reach of any safe threshold.

**Terms are not free.** Each one is another chance to overwrite a correct word,
and the risk is dominated by *which* terms rather than how many. Nine terms
where three collide with ordinary words is worse than thirty that do not.

## When the team should have it too

Screening a term takes real work, and on a shared project the next person will
repeat it. Offer to publish what survived — and the rejected list, which is the
half that gets repeated — into a `.parrot/` folder in their repository. What
travels and what does not is in `.claude/skills/parrot-folder/SKILL.md`. The
short version: the names travel, one person's corrections and one person's two
numbers do not.
