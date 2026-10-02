# Spoken commands

## The activation phrase

```yaml
transcription:
  activation_phrases: [hey parrot, by the way parrot]   # default: [hey parrot]
```

- **At the start**, the whole utterance is a command about the selection, or
  the last dictation when nothing is selected: "hey parrot, make that a bullet
  list". The result is shown before it replaces anything.
- **In the middle**, the rest is an instruction about the words before it, in
  the same breath: "there is a bug in get username by the way parrot format
  that name". No preview. If the instruction fails, the sentence is still
  written. "hey parrot" reads oddly mid-sentence, which is why a second phrase
  is worth adding.
- An empty list turns spoken commands off.
- "hey parrot, undo" puts back the last change. So do `cancel`, `revert`, `put
  it back`, `annule`. Matched without a model. It refuses if the text was
  edited since.

## What a command reaches

1. Every transform with a `description:`, whatever its body. A model (the
   **router**) matches what was said against the descriptions. So write a
   description the way someone would ask for it. Check with
   `"$PF" --route "hey parrot, <what they would say>"`.
2. The **catch-all**: an instruction no transform covers, such as "hey parrot,
   use the 24 hour clock", runs as a free prompt. `commands.catch_all: false`
   refuses those instead. A remark that was never an instruction is refused
   either way.
3. Spelling and the correction panel: see below.

Each part can run on its own model. See `models.md`:

```yaml
commands:
  router: gemma       # runs on every "hey parrot": keep it local and fast
  spelling: gpt       # reading "T A S M E E N"; a bigger model helps
  catch_all: gpt      # or false
```

With no `models:` at all, no model is called. "hey parrot" alone still opens the
correction panel, and undo still works.

**Tap, then hold** the hotkey (bare modifiers only) to speak an edit with no
phrase. There is no router there: a transform's name, or a word from its
`say:` list, picks it with no model; anything else goes to the catch-all.
`say:` is how a script or a table is reached this way:

```yaml
  - name: slack_mentions
    say: [slack mentions, mentions]
```

Check with `"$PF" --route "use slack mentions" --keyed`.

## Teaching a word

Names and terms the recogniser gets wrong: see `vocabulary.md`. "hey parrot"
alone opens the correction panel, and "hey parrot, Tasmin spells T A S M E E N"
fills it in. Both are described there.
