# Reading the screen and the field

Two pipeline stages publish what is around the cursor, for later steps to read.
Neither changes the text. Both are off until a pipeline names them, because
they read the screen. One pass does something with that and is on by default.

## `context`: the screen around the field

```yaml
transcription:
  pipeline:
    - context
    - transform: reply
      when: context.ok && context.chars > 200
```

- Works in terminals (the visible screen) and in Slack (the conversation you
  are typing in). Other apps decline.
- Publishes `context.text` (the last 2000 characters, input box left out),
  `context.chars`, `context.lines`, `context.place` (the Slack channel),
  `context.people`, `context.code`, `context.roster`, `context.declined`.
- Read when the hotkey goes down, not when the stage runs.
- Costs about 1 ms in a terminal and 130–150 ms in Slack, off the main thread.
- **While it is on, the log holds what was on screen.** Tell the user.

## `input`: what is already in the field

```yaml
    - input
    - transform: join
      when: input.ok
```

- Works in every app. Publishes `input.before`, `input.after`, `input.selection`,
  `input.appending`, `input.ok`, `input.declined`. A terminal gives
  `input.text` instead, and the other four are absent. Guard with `input.ok`.
- The shipped `join` script reads it: it fixes the capital and the full stop
  at the start and end of a clip dropped into the middle of a sentence.
  Define it with `command: built-in/join/join.py` and `returns: json`.

## Using them in a prompt

```yaml
  - name: reply
    description: answer what is on screen
    prompt: |
      Rewrite the dictation as a clear instruction.

      This is on the speaker's screen right now:
      {{context.text}}

      Use it to spell names and paths. Never quote it back.
```

- Put each placeholder in its own paragraph. An empty one removes its
  paragraph, so the model is never told about a screen it cannot see.
- **Two risks to tell the user.** Text on screen that looks like an
  instruction may be followed. And with a cloud model, `{{context.text}}` sends
  up to 2000 characters of the screen off the Mac.

## `context_spelling`: on by default

```yaml
transcription:
  context_spelling:
    enabled: true
```

Spells a dictated word the way the screen does: "rewrite line" becomes
`rewrite_line` when the screen shows it. It runs after the last step and needs
no pipeline line. It never waits: until its model is loaded, text goes through
as dictated. `enabled: false` turns it off.

## Testing

`--pipeline` and `--replace` cannot capture a screen: a binary run from a
terminal has no Accessibility grant, so both stages decline every time. Use
`--pipeline` with `--vars` to check the conditions, then ask the user for a real
dictation in the app that matters.
