---
name: parrotflow
description: Customize ParrotFlow, the local dictation app for macOS, and explain what it can do. Changes its hotkey, languages, microphone, sounds, rewrites (replacements, scripts, prompts), spoken commands and models in config.yaml, then checks the change with the app's own binary. Use when someone asks to customize, configure, set up or change ParrotFlow, asks what ParrotFlow can do, or wants their dictation to write something differently.
metadata:
  app_version: 0.15.0 # x-release-please-version
---

# Customizing ParrotFlow

ParrotFlow is a dictation app for the Mac. The user holds a key, speaks, and
the text lands where the cursor is. Everything they can change is in one file,
`config.yaml`. The app reloads it on save, with no restart.

Your job: change that file on request, or explain what is possible. Check every
change with the app's own binary. Then ask the user for one real dictation,
because you cannot press their hotkey.

Paths below are relative to the folder this file is in: `scripts/`,
`references/`, `assets/`.

## 1. Find the app

```sh
bash scripts/pf.sh          # the release app
bash scripts/pf.sh dev      # only if the user says they use ParrotFlowDev
```

It prints `key=value` lines. Below, `$PF` stands for the `binary=` path and
`$CFG` for the `config=` path. Shell variables may not last from one command to
the next, so set them in each command or write the paths out.

- `binary=` is empty: ParrotFlow is not installed. Give the `install=` line and stop.
- `version_match=no`: say this first, before anything else. "This skill was
  written for ParrotFlow `skill_version`. You have `app_version`." If there is
  an `update_app=` line, the app is the older one: suggest updating it first,
  because an old tag may have no skill in it. Otherwise offer the `reinstall=`
  line. Go on only if the user agrees. Then trust `--check-config` over the
  references.
- `other_app=` is set: both the release and the dev app are installed. They
  have separate configs. Work on the release one unless the user says otherwise.

## 2. Read the current state

```sh
"$PF" --check-config        # what the app actually uses
cat "$CFG"                  # what the file says
```

`--check-config` is the truth. It prints what survived parsing, not what the
file says. Read three marks: `✗` is an error, `⚠` is a key that no setting reads
(it does nothing), `·` is a notice.

Which keys exist:

- `schema=yes`: run `"$PF" --schema`. It prints a JSON Schema with every key,
  its type, its default and one line of help. Keys marked `deprecated` are old
  names; do not write them.
- `schema=no`: read the `config_example=` file (the config a new install gets,
  with comments) and `references/settings.md`. Never run `--schema` here.

## 3. Sort the request, then load one reference

| The user wants | Read |
|---|---|
| A different key, language, microphone, sound, colour, log or update setting | `references/settings.md` |
| Dictation to write something differently: a word, a symbol, a format, a rewrite | `references/rewrites.md` |
| To talk to it: "hey parrot", commands, undo, spelling a name | `references/spoken-commands.md` |
| A language model, local or cloud | `references/models.md` |
| Rewrites that read the screen or the text field | `references/context.md` |
| To know why something went wrong | `references/diagnose.md` |
| Names the app keeps getting wrong | `references/spoken-commands.md` (teaching a word) |
| "What can it do?", "help me set it up", or anything vague | `references/catalogue.md`, then step 4 |

`references/cli.md` lists every flag this skill uses. Use no other flag.

## 4. A vague request: give a short tour

This is the default when the request has no clear target.

1. Say what is on now, from `--check-config`: the hotkey and its mode, the
   languages, the pipeline steps, the chips on the pill, and any models.
2. Look at this Mac. Read only:
   ```sh
   command -v ollama; curl -s -m 1 http://localhost:11434/api/tags
   "$PF" --microphones
   ls /Applications | grep -i -E 'iterm|ghostty|warp|wezterm|kitty|alacritty|slack|outlook'
   ```
3. Offer about three suggestions grounded in what you found. One line each:
   what it does, and what it costs per dictation. Examples:
   - French in `languages` but no `dates_fr` step: add French dates, numbers
     and money. Free.
   - Ollama is installed and no `models:` block: connect it, so the `G` chip
     can fix grammar. About 1.5 s, only when pressed.
   - The microphone in use is a headset or AirPods: Bluetooth drops words.
     Or no list is set and Zoom or Teams devices are attached. Pin the wired
     or built-in one first in `audio.microphones`. Free.
   - Slack is installed and the `S` chip's roster is empty: fill it, so names
     become @handles on request. About 30–100 ms, only when pressed.
   - A terminal is installed: a rule that only runs there, such as a spoken
     symbol. Free.
4. Ask which one they want. Change nothing until they pick.

## 5. Make the change

1. **Back up first.** `cp "$CFG" "$CFG.bak-$(date +%Y%m%d-%H%M%S)"`. Say where.
2. **Make the smallest change.** Keep the user's comments and every other
   setting. The app reloads on save, so write the whole new file to a
   temporary path beside it, then `mv` it over `config.yaml`. Never leave a
   half-written file in place.
3. **Use the cheapest tool.** A table first, then a script, then a prompt. See
   `references/rewrites.md`.
4. **Check it.** Run `"$PF" --check-config` again and compare with step 2:
   - the new value appears on its line;
   - there is no new `✗`;
   - no `⚠` names a key you wrote.

   With `schema=no` the app prints no `⚠`, and a misspelt key is ignored in
   silence. The first check is then the one that catches it: `sounds: false`
   under `feedback:` still prints `sound=true`. Also check each key you wrote
   against `config_example=`.
5. **For a rewrite, run it.** Before and after the change:
   ```sh
   "$PF" --replace "<a sentence it must change>" --app "<App name>"
   "$PF" --replace "<a sentence it must leave alone>" --app "<App name>"
   ```
   `--replace` runs the user's whole configured pipeline, except prompts. Put
   the same sentences in the transform's `cases.yaml` and run
   `"$PF" --eval <name>`. For a prompt, see `references/cli.md`.
6. If any check fails, fix it or restore the backup. Never leave a config that
   `--check-config` refuses.

## 6. Report

Say four things, briefly:

- **What changed**: the key, old value to new value, and the backup path.
- **What it costs per dictation**: nothing for a table, 30 to 100 ms for a
  Python script, about 1.5 s for a model call (6.7 s if the model was unloaded).
- **What now runs on their Mac**: a `command:` transform runs a program. Name
  it. A cloud model sends the text it rewrites off the Mac. Say so.
- **One real test**: give the exact sentence to say, and the app to say it in.
  Ask them to dictate it and tell you what came out.

## Hard rules

- **Never edit `transforms/built-in/`.** The app replaces it at every launch.
  To change a shipped transform, copy its folder to `transforms/<name>/` and
  point `command:` at the file there.
- **Never edit the app bundle**, including its `config.example.yaml`.
- **A stage that calls a model needs a condition**: `when:`, `unless:` or
  `app:`. Otherwise it costs a second on every dictation.
- **Fail open.** A stage whose model or program fails must leave the sentence
  unchanged. Prove it for any stage that calls a model: see "Fail open" in
  `references/cli.md`.
- **Ask before reading `trace.jsonl`, `spans.jsonl` or the log.** They hold
  what the user said. Report counts and patterns, not their sentences.
- **Run the binary only with a flag from `references/cli.md`.** Never with no
  flag: that starts a second copy of the app.
- **Never handle secrets.** The user types API keys themselves, with
  `--set-key`. Never write a key into `config.yaml`.
- **Never set `PARROTFLOW_CONFIG_DIR` in a shell profile.** The app reads it too.
