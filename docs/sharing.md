# Sharing a vocabulary with a team

Everyone on a team says the same names. Today everyone teaches them again, one
correction at a time, on their own machine. A transform someone wrote lives in
their config folder and nowhere else.

A repository can carry both. Put a `.parrot/` folder in it, commit it, and the
next person pulls the names and the transforms out of it instead of finding
them again.

## The folder

```
<repo>/.parrot/
  README.md          # optional — what this folder is, for a human
  vocabulary.yaml    # the names this team says out loud
  config.yaml        # the transforms it shares, as `transforms:` entries
  transforms/
    slack_mentions/          # the same layout as transforms/<name>/
      slack_mentions.py      # in a config folder — copy it and it works
      cases.yaml
      roster.json
```

Every part is optional. A folder holding one `vocabulary.yaml` is a useful
folder.

## Hints, not settings

**Nothing here is read while you dictate.** The app never opens `.parrot/`.
An agent does — see [the `parrot-folder` skill](#the-skill) — and it screens
what it finds, then writes into `vocabulary.yaml` and `config.yaml` in the
config folder. What runs is still only what is in there.

That indirection is the design, for three reasons.

**The app is not repository-aware.** You dictate into Slack, a browser and an
editor. Which checkout is open in another window says nothing about which
names the sentence contains.

**Terms are not free.** Each one is another chance to overwrite a correct
word, and whether it does depends on the speaker: their accent, and the
languages they dictate in. A term is screened against the ordinary words of
those languages, so the same term is a collision for a French speaker and a
clean name for an English-only one. A term that is safe for the person who
committed it is not therefore safe for you. Screening is per person, and it
is most of what the skill does — see
[the vocabulary skill](../.claude/skills/vocabulary-corpus/SKILL.md).

**A shared transform executes code on your machine.** `command:` runs a
program of someone else's, on every dictation that reaches the stage. That
needs a person to read it and say yes, once, out loud. It is not something a
folder in a repository should be able to arrange by itself.

## What belongs in it

| Belongs | Does not |
|---|---|
| Names, products, acronyms the team says out loud | `offer_below:`, `decide_above:` — the reader's two numbers, not the folder's |
| `kind:` on a term — what the thing is | `voice/` — one speaker's mouth on one microphone |
| Renderings people have seen, as `from: mined` | Renderings from `from: correction` — one person's corrections |
| Transforms, with the `cases.yaml` that scores them | Anything under `transforms/examples/`, which the app owns and refreshes |
| The rejected list, with the reason for each | API keys, endpoints, anything from `models:` |

The last line of the first column matters more than it looks. A term someone
screened and threw away is a finding. Written down, it stops the next person
adding `Sentry` again in a month; left out, it does not.

## `vocabulary.yaml`

The same shape as [the one beside your config](transcription.md#2-a-vocabulary--for-words-the-recogniser-gets-wrong),
minus the two file-level numbers:

```yaml
terms:
  RedCrawl:              # heard "red crawl"; glues back to 1.00
    kind: organization
  Tasmeen:
    kind: person
  Sentry:
    kind: organization
    floor: off           # "entry" is 0.83 away and sounds the same
    pronunciations:
      - heard: entry
        from: mined
        note: seen in #deploys, twice

# Rejected, and why. Do not re-add these without a measurement.
#   Supabase, Playwright, Tailwind  — written correctly already, pure risk
#   Turndown                        — "turn down the volume" glues to it
```

`from: mined` is the honest label for a rendering that arrived in a repository:
somebody saw it, nobody in this room confirmed it. `from: correction` means a
named person fixed their own transcript, so it does not travel — the app reads
it as evidence about a voice it has heard.

A term under five letters, or one carrying a dot or a digit, is still worth
committing. It is dropped from sound matching — see `Config.vocabularyTerms` —
and its renderings still work as exact rules.

## `config.yaml`

A fragment, not a config. Only `transforms:` and `lists:` are read from it, and
the paths are relative to the folder:

```yaml
transforms:
  - name: slack_mentions
    description: turn people's names into Slack mentions
    command: slack_mentions.py
```

An entry here is a proposal. The skill shows it to you, names every `command:`
out loud, and copies the folder into `transforms/<name>/` beside your config
only if you say so. It is a copy, not a link: the transform's folder is its
working directory, and a transform that reads a repository it does not own
stops working the day someone moves the checkout.

## The skill

`.claude/skills/parrot-folder/SKILL.md` does both directions:

- **Import.** Read the folder, screen the terms against this speaker and the
  languages they dictate in, merge what survives into `vocabulary.yaml`, and
  offer the transforms one at a time.
- **Publish.** Take what someone already has, strip the parts that are theirs
  alone, and write the folder into the repository.

Ask for it by name — "pull the parrot folder from this repo", "put my
vocabulary in the repo for the team".

## Checking a folder

```sh
scripts/check-parrot-folder.sh              # every .parrot/ in this tree
scripts/check-parrot-folder.sh path/to/.parrot
```

It reads the folder the way the skill will: the YAML parses, the keys are ones
that travel, no personal settings, no speaker audio, and every `command:`
names a file inside the folder.

The stronger check is the app's own parser, on a config directory of your own:

```sh
mkdir -p /tmp/parrot-check && cp .parrot/vocabulary.yaml /tmp/parrot-check/
printf 'transcription:\n  languages: [en]\n' > /tmp/parrot-check/config.yaml
PARROTFLOW_CONFIG_DIR=/tmp/parrot-check ParrotFlow --check-config
```

That says what survived parsing, which is not what the file says.
