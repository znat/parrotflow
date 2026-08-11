# Teaching it a word

The part that matters if you dictate library names, CLI tools and your
colleagues' names all day. A rule you teach once is written to your
`config.yaml` and applied to every transcript afterwards.

When a name comes out wrong, select it in whatever app you're in, hold the
hotkey and say **"hey parrot"**. A panel opens with the sentence in it,
editable in place. What it heard sits above the word it became, struck through.

    VOCABULARY  teach me the words I got wrong

                     Tasmin           Mick
     I    work  with Tasmeen and      Mik
     ──   ────  ──── ───────  ───     ───
     space splits a word in two   ⌫ at the start joins it to the word before

     2 words → vocabulary   Cancel esc   Add Tasmeen, Mik to the vocabulary ⌘↩

Every gesture is one a text field already has: type over a word, space to
split one word into two, ⌫ at the start of a word to join it to the word
before, clear a word to drop it. ⌘Z undoes.

A rule is keyed on what you edited, not on a word — so when the decoder splits
a name in two ("red crawl" for Redcrawl), joining the two words teaches
`red crawl => Redcrawl` and leaves the colour alone. The words you did not
touch cost nothing.

Saving writes one rule per changed word to `config.yaml` — comments and your other
settings untouched — and puts the corrected phrase back where it came from,
punctuation and spacing intact.

## Saying the spelling instead

You can skip the panel entirely and just say the correction:

    "hey parrot, Tasmin spells T A S M E E N"
    "hey parrot, Mick is spelled M I K"
    "hey parrot, it's spelled S U P A B A S E not super base"

A local model works out which word was wrong; the panel opens prefilled so you
confirm with one keystroke rather than trusting it blindly.

You do not have to spell it. Describing the change works too, in either
language:

    "hey parrot, Jerome with a G at the beginning"
    "hey parrot, Mathieu ne prend qu'un seul t"
    "hey parrot, Elastic search is one word"
    "hey parrot, Jean Luc avec un trait d'union"

And one breath can carry two corrections, which open as two changed words
in the panel:

    "hey parrot, Tasmin spells T A S M E E N and Mick spells M I K"
    "hey parrot, Nathalie sans le h et Philipe avec deux p"

## Why the model does so little of this

The spelled-out letters are read from the text, not the model — a run of single
letters can only be the target spelling, and relying on the model for that got
the direction backwards on "X spells Y" phrasing in three of seven test cases.
Described changes are applied by code for the same reason: asked to write
"Phillip with one l", the models answered "Phill" and "Philp". The model's only
job is finding which words in your transcript you meant.

The word being corrected is found in your **previous transcript**, not in the
command. The command is dictated too, so the name gets misheard a second time:
saying "Tasmine spells T A S M E E N" can come through as "Das mean spells…",
and a rule for "Das mean" matches nothing you will ever say. Since the target
spelling is already known from the letters, the closest match to it in the last
transcript is the word that needs fixing.

## In Slack, in a browser, in Outlook

These all work the same way and are not told apart: what a correction needs is
the field's text and the characters to change, and a composer, a webview and a
mail body all supply both.

The one that took measuring is Chromium — Slack, the new Outlook, every browser
tab. It accepts a request to move the selection, answers `.success`, and does it
a moment later; asked what it has selected in a contenteditable it says `""`
whatever is highlighted. Read too early, that is indistinguishable from an app
that ignores the request, and it was misread that way for a while. Waiting for
the answer is the whole of the fix.

`scripts/check-span.sh` scores this against a local fixture page that behaves
like a composer, and against Slack or Outlook directly if you focus one.

## What it needs

Ollama running with the model in `llm.model` (`ollama pull gemma4:e4b`), and
the Accessibility permission — reading your selection is exactly what that
permission governs.

ParrotFlow loads that model at launch and asks Ollama to keep it there. Ollama
otherwise drops it after five minutes idle, and reloading is most of what you
wait for: measured 6.7 s cold against 1.5 s warm, so in practice almost every
correction paid for a reload. The cost is the model sitting in memory for as
long as the app runs — 9.6 GB for `gemma4:e4b`. Set `llm.keep_loaded: false` to
have the RAM back and the wait with it. On a 16 GB Mac that is the right
setting; on 32 GB it is not.

Without a model, `"hey parrot"` and `"hey parrot, fix vocabulary"` still open
the panel — those are matched without one.

Change the trigger with `transcription.activation_phrases`.

## How it is scored

`tests/spelling-cases.yaml` holds 62 cases — French, Indian, Chinese, Turkish,
Vietnamese, Korean, Nigerian, Polish, Irish, Arabic names, plus product names
recognition splits, described changes, two-in-a-breath corrections, and
negative cases; `tests/french-cases.yaml` holds 45 more where the dictated
sentence is French. Score a model or a prompt against them with
`scripts/validate-prompt.py gemma4:e4b`.

## Without speaking

*Correct a Word…* in the menu opens the same panel,
`--learn <heard> <corrected>` adds a rule from the terminal, and
`--command "<what you'd say>"` shows how a phrase would be routed. See
[cli.md](cli.md).

## Taking it back

Every substitution says how to undo it, in the toast that confirms it:

    grammar applied · "Hey parrot, undo"

Say that and the text goes back to what it was. It is matched as a literal
phrase, never through the model — the moment you want it is the moment
something went somewhere unexpected, and "Ollama is not running" is not an
acceptable answer then. `cancel`, `revert` and `put it back` work too, as do
`annule` and `annuler`.

It refuses if you have edited the text since. An undo fired against text that
has moved on is not an undo, it is a second unwanted edit, landing exactly where
you had started fixing things by hand.

And it only ever writes to the field it changed, which it remembers rather than
looks for. Two fields holding the same sentence are not unusual — a message and
the reply quoting it, the same text pasted into a second window — so matching
text alone would happily rewrite the wrong one while leaving the substitution
you wanted reversed exactly where it was.

One deep, on purpose. This is not an edit history; it is the answer to "that
went somewhere I did not expect", which is only ever asked about the thing that
just happened.

## In a terminal

Selections are fragile: they get dropped on a keystroke or when focus moves,
often before the transcript comes back. ParrotFlow snapshots the selection the
moment the hotkey goes down, which covers most of it, and falls back to your
clipboard when there is nothing to read. So if a terminal selection does not
come through, copy it first — select, ⌘C, then say the phrase. The panel always
opens either way, with a word you can type into.

## An instruction inside a dictation

The same phrase said mid-sentence means something else: the rest is an
instruction about the words in front of it, in the same breath.

```
"there is a bug in get username by the way parrot format that name"
 └─ what gets written, once edited ──┘        └─ what to do to it ─┘
```

Fully described in [pipelines.md](pipelines.md#an-instruction-inside-a-dictation),
along with why two phrases ship and why this path writes your sentence even when
everything about the instruction fails.

## See also

- [configuration.md](configuration.md#transcriptionreplacements) — the rule
  table a correction writes into
- [pipelines.md](pipelines.md) — the `fuzzy` stage, which catches renderings you
  never taught
- [authoring.md](authoring.md) — changing the prompts behind any of this, with
  the case sets that say whether you made it better
