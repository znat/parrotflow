# Setting up ParrotFlow

**These are instructions for a coding agent, not for a person.** Someone has
asked you to set ParrotFlow up on their Mac. Follow this file top to bottom.

Read the whole thing before you start, then work through it. Do not invent extra
steps, and do not skip the checks — most of what goes wrong here is invisible
until you look for it.

## How to talk while you do this

The person watching is a developer, but they know nothing about this app. Many
of them do not speak English as a first language.

- **Use simple, international English.** Short sentences. One idea each.
- Use common words. Say "delete", not "purge". Say "start", not "kick off".
- No idioms. No phrasal verbs where a plain verb exists.
- No jargon they did not use first. Not "TCC", not "ASR", not "quantised".
- Say what you are about to do, do it, say what happened.
- Never say "should work". Check, then say what is true.
- Lines shown as `> quoted text` are for you to say. Use your own words if they
  fit better, but keep them short and keep them simple.

Two things you cannot do, ever:

1. **Grant permissions.** macOS only accepts those from a human, clicking. You
   can open the right window and wait. You cannot click for them.
2. **Test dictation.** It needs a voice. Only they have one.

When you hit either, stop and ask. Then check what they say they did — people
tick the wrong row in System Settings often.

## What you are installing

Three separate downloads, in this order. Say which one you are on, because the
sizes are very different and a silent 10 GB download looks like a hang.

| What | Size | When | Needed for |
| --- | --- | --- | --- |
| The app | 3 MB | Step 3 | everything |
| Parakeet, the speech model | 1.2 GB | Step 5, automatic | dictation |
| Gemma, the language model | 10 GB | Step 9, optional | voice commands |

Dictation works after Step 5. Everything after that is extra.

## If ParrotFlow is already installed

Check first:

```sh
ls -d /Applications/ParrotFlow.app 2>/dev/null
```

If it is there, this is an upgrade or a repair, not a first install. Go to
Step 3 and run the installer anyway — it replaces the app in place. Then go to
Step 7. Read `~/.config/parrotflow/config.yaml` first and only ask about what is
missing. Do not ask questions they have already answered.

---

## Step 1 — Say what is about to happen

Before you run anything. They should be able to stop you here.

> ParrotFlow is dictation that runs on your Mac. You hold a key, you talk, and
> the text appears in the app you are using. Nothing is uploaded. No account, no
> API key, no network call.
>
> Setup takes about five minutes of your time, plus one large download that runs
> in the background.
>
> I will:
> 1. Check your Mac can run it
> 2. Install the app
> 3. Help you through two macOS permission windows
> 4. Prove that transcription works
> 5. Ask you a few questions about how you want it to work
> 6. Start an optional 10 GB download, for commands you say out loud
>
> You will have to click twice in System Settings. I cannot do that part for
> you.
>
> Ready?

Wait for an answer. If they ask what the 10 GB is for: it is only for spoken
commands, like *"hey parrot, Tasmin spells T A S M E E N"* or *"hey parrot, fix
the grammar"*. Dictation does not need it.

## Step 2 — Check the Mac

```sh
sw_vers -productVersion                # need 14 or higher
uname -m                               # need arm64
sysctl -n hw.memsize                   # bytes of RAM — write this down, Step 9 needs it
df -g / | tail -1 | awk '{print $4}'   # GB free — need 15 or more
```

**Remember the RAM number.** It decides a setting in Step 9, and it is easy to
forget to look.

Stop if macOS is older than 14, or if the Mac has an Intel processor. Speech
recognition runs on the Neural Engine, and Intel Macs do not have one. Say this
plainly and stop. There is no way around it.

If free disk space is under 15 GB, say so and ask whether to continue.
Dictation needs about 1.5 GB. The 10 GB model is optional and can be skipped.

## Step 3 — Install the app

```sh
curl -fsSL https://raw.githubusercontent.com/znat/parrotflow/main/scripts/install.sh | sh
```

This downloads about 3 MB, checks it against its published checksum, puts the
app in `/Applications`, and starts it.

> The app is installed. There is a microphone icon in your menu bar now, at the
> top right. Can you see it?

If the download fails, there may be no release published yet — check
`https://github.com/znat/parrotflow/releases`. If `/Applications` cannot be
written to, run the same command again with `PARROTFLOW_DEST=~/Applications`.

## Step 4 — Microphone permission

The app asks for this the first time it starts. The window may already be open.

> macOS is asking if ParrotFlow can use your microphone. Please say yes. Without
> it there is nothing to transcribe.

Then check. Do not take their word for it:

```sh
/Applications/ParrotFlow.app/Contents/MacOS/ParrotFlow --check-config
```

Look for `✓ microphone  Granted`. Anything else: send them to **System Settings
→ Privacy & Security → Microphone**, then check again.

This command also prints the whole config the app is using. Read it. You will
come back to it several times below.

## Step 5 — Prove transcription works, and download Parakeet

This is the step that makes the app real, and it does not need a microphone.

```sh
say -o /tmp/pf-check.wav --data-format=LEI16@16000 --channels=1 "Testing one two three"
/Applications/ParrotFlow.app/Contents/MacOS/ParrotFlow --transcribe /tmp/pf-check.wav
```

`say` is part of macOS. It writes exactly the 16 kHz mono WAV file the speech
model expects.

The first run downloads that model and prints its progress. Tell them before it
starts, because 1.2 GB with no explanation looks like a problem:

> Now I am downloading the speech model. It is called Parakeet, it is about
> 1.2 GB, and it runs on your Mac. This is the part that turns your voice into
> text, so dictation needs it. It takes a few minutes.

A transcript appears at the end. It will be close to "Testing one two three" but
not identical — `Testing 123.` is a normal and correct result. What matters is
that text came back at all.

If this fails, stop and fix it before going further. Nothing after this step can
work if this step does not.

## Step 6 — Accessibility permission, or the clipboard instead

There is a real choice here. Ask it before you open any settings window.

> One more permission, and you have a choice.
>
> **Type the text for me.** ParrotFlow types your words straight into the app
> you are using. This needs the Accessibility permission.
>
> **Copy the text instead.** ParrotFlow copies your words, and you press
> Command-V yourself. This needs no permission.
>
> Typing is what most people want. Which do you prefer?

If they choose the clipboard, set this in `~/.config/parrotflow/config.yaml`,
under `transcription`:

```yaml
transcription:
  insert_mode: clipboard
```

Tell them what that costs, plainly. The cost comes from the permission, not from
the setting — without Accessibility the app cannot read the text they selected,
and reading a selection is exactly what that permission controls:

> Two things will not work without that permission: fixing a word by voice, and
> the voice commands in Step 10. Both of them have to read the text you
> selected. Dictation itself is not affected. You can turn the permission on
> later at any time, and nothing needs to be reinstalled.

Then go to Step 7. If they later change their mind, come back to this step.

If they choose typing — the default — open the window for them:

```sh
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
```

> I opened the settings window. Find ParrotFlow in the list and turn the switch
> on.

**Checking this is not obvious, so do it exactly this way.** `--check-config`
does *not* tell you. macOS credits a check made from a terminal to the terminal,
not to ParrotFlow, so it reports "not granted" for an app that has the
permission. The app tests it properly when it starts and writes the answer in
its log. So restart the app, then read the log:

```sh
pkill -f "ParrotFlow.app/Contents/MacOS/ParrotFlow"; sleep 1
open -a ParrotFlow; sleep 3
grep "launched —" ~/Library/Logs/ParrotFlow.log | tail -1
```

You want `accessibility=Granted` on that line. If it says `NotGranted`, the
switch is off, or they turned on a different app. Ask them to look again,
restart the app, and read the log again.

## Step 7 — The questions that shape the config

Ask these together. They are short. Edit
`~/.config/parrotflow/config.yaml` after each answer — the app reloads the file
when you save it, so no restart is needed.

**1. Languages.**

> Which languages do you dictate in?

Dictation itself understands many languages and needs no setting. This list does
something narrower: it tells ParrotFlow which language a transcript was in, so
it can pick the right correction rules.

**Only `en` and `fr` work today.** Anything else is ignored. If they name
another language, be honest:

> Dictation will work in that language. The speech model understands many
> languages. But the correction rules are only written for English and French so
> far, so I will leave this setting on English.

Most used language first:

```yaml
transcription:
  languages: [en, fr]
```

One entry means no language detection runs at all. That is faster and more
accurate, so use one entry if they only dictate in one language.

**Then write the filler words for those languages.** Do not skip this because
the config looks like it already handles it. A new config has
`replacements: {}` — the filler rule exists only in `config.example.yaml`, so
a fresh install deletes nothing. And the rule in that example is English only:
`um`, `uh`, `erm`, `hmm`. A French speaker keeps every `euh`.

> When people talk, they make sounds like "um" and "euh". I can remove those
> from your text. Do you want that?

Some people want them kept. Ask, do not assume. If they want it, write one rule
per language they named:

```yaml
transcription:
  replacements:
    # English
    "": ['/[,]?\s*\b(?:mm[-‑]?hmm|uh[-‑]?huh|mhm|u+m+|u+h+|erm+|hmm+|mm+)\b[,]?/']
    # French — add these words to the same list
    #          euh+|heu+|hein|bah
```

Merge them into the single `""` entry rather than writing two — it is one map,
and a repeated key is invalid YAML. Check the result with `--check-config`,
which prints every rule and reports a pattern it cannot compile.

**Only add words that are not words in the other language.** Rules are not
language-scoped: every rule runs on every transcript. `euh`, `heu` and `hein`
are safe. Never add `ben`, `genre`, `quoi`, `voilà`, `donc` or `alors` — they
are ordinary French words, and `ben` is an English name. Deleting one of those
damages a sentence that was already correct, which is the one thing a
replacement rule must never do.

**2. The key.**

> The key is the right Option key. You hold it, you talk, you let it go. Is that
> key free on your Mac, or do you use it for something else?

The right Option key is used to type accented characters — `é`, `ü`, `ñ`. If
they need it, change the key:

```yaml
hotkey:
  key: right_command    # or fn, right_control, or a character key plus modifiers
```

`--check-config` prints the key it will use, and says so if another app already
owns it. Every key name is listed in the config file itself.

**3. Numbers.**

> When you say "two hundred and forty three", do you want to see 243 or the
> words?

Off by default. Show them what it would do instead of explaining it, in the
language they dictate in:

```sh
PF=/Applications/ParrotFlow.app/Contents/MacOS/ParrotFlow
$PF --numbers "I need two hundred and forty three of them by nineteen eighty four"
$PF --numbers "il m'en faut deux cent quarante trois avant quatre-vingt-dix-sept jours"
```

Which grammar reads the numbers comes from the `languages` list you just set, so
run this after that edit and it answers the way dictation will. `--lang fr` pins
it if you want to show them one language on purpose.

If they want it: `transcription: numbers: true`.

## Step 8 — Let them try it

The first real dictation. You cannot do this one.

> Your turn. Open any text box — a note, a chat window, this terminal.
>
> Hold the **right Option key**, say a sentence, then let the key go.
>
> Wait about one second. The text appears where your cursor is.

If nothing arrives:

```sh
grep -E "transcribed|speech gate|hotkey" ~/Library/Logs/ParrotFlow.log | tail -5
```

- Nothing in the log at all → the key never fired. Check `--check-config` for a
  registration failure, and ask if another app uses that key.
- `speech gate: no speech detected` → the microphone heard nothing. Wrong input
  device, or they let the key go too early.
- `transcribed: …` but no text appeared → Accessibility. Go back to Step 6.

Once it works, say so and move on. This is the moment they decide whether they
like the app.

## Step 9 — Voice commands (the 10 GB part)

Everything above already works. This step adds one thing: talking to the app
instead of typing at it. Teaching it a name by voice, fixing grammar in text you
selected, turning a paragraph into bullet points.

> The last part, and it is optional. It downloads a 10 GB model called Gemma.
> That model is what understands the commands you say out loud.
>
> Everything else already works without it. The download runs in the background,
> and you can keep using dictation the whole time.
>
> Do you want it?

If they say no: set `llm: enabled: false` in the config, tell them they can
still fix words by hand from the menu bar, and go to Step 11.

**Ollama runs the model. Check it is installed and running.** This one call
answers both questions:

```sh
curl -s --max-time 3 http://localhost:11434/api/version
```

- Returns `{"version":"0.31.1"}` or similar → it is running. Check the version
  below.
- Returns nothing → it is not installed, or not started.

```sh
command -v ollama            # installed?
```

Say what Ollama is before you install it. Do not install software on someone's
machine silently:

> Gemma needs a program called Ollama to run it. Ollama runs language models on
> your own Mac, offline. I will install it now.

```sh
brew install ollama
brew services start ollama
```

If it is installed but not answering, start it. Use `brew services start ollama`
when it came from Homebrew — the path starts with `/opt/homebrew` or
`/usr/local/Cellar`. Otherwise, ask them to open the Ollama app.

**The minimum version is 0.22.0.** Older builds cannot run the `gemma4` e-series
models at all. Compare what `/api/version` returned. If it is older:

- Installed with Homebrew → `brew upgrade ollama`
- The Ollama app → they must update it from the Ollama menu, or download it
  again from ollama.com. You cannot update that one for them.

**Now use the RAM number from Step 2.** The model needs 9.6 GB of memory while
it is loaded. This setting decides whether it stays in memory between commands:

| RAM | `llm.keep_loaded` | Why |
| --- | --- | --- |
| 32 GB or more | `true` | 9.6 GB in memory is affordable. Commands answer in 1–2 seconds. |
| 16 to 32 GB | `false` | Keeping 9.6 GB of 16 would slow down everything else. Commands take 7–10 seconds, because Ollama loads the model again each time. |
| under 16 GB | `false`, and say something | It will work, but the Mac will swap memory to disk. Tell them, and offer `llm: enabled: false` instead. |

Write it into `~/.config/parrotflow/config.yaml`:

```yaml
llm:
  enabled: true
  model: gemma4:e4b
  keep_loaded: true    # or false, from the table above
```

**Then start the download in the background.** Do not wait for it:

```sh
nohup ollama pull gemma4:e4b > /tmp/parrotflow-pull.log 2>&1 &
```

> The download has started in the background. It is 9.6 GB, so it takes from a
> few minutes to half an hour, depending on your connection.
>
> Dictation works right now. Please do not wait for this. The only thing missing
> until it finishes is the commands you say out loud.

Check on it later with:

```sh
tail -2 /tmp/parrotflow-pull.log
ollama list | grep gemma4
```

If the download fails with an error about the model or the manifest, Ollama is
too old, whatever its version string said. Upgrade it and pull again.

## Step 10 — Teach them what they can say

Do this while the download runs. It is the part people miss, and the app is
half as useful without it.

Everything below starts with the **wake phrase**: `hey parrot`. Hold the same
key you hold for dictation, say the wake phrase, then say what you want. The app
knows this is a command and not dictation, so it never types those words into
your document.

Print the real list first, so you describe what is actually installed rather
than what this file assumes:

```sh
/Applications/ParrotFlow.app/Contents/MacOS/ParrotFlow --check-config
```

Read the `capabilities` lines. Then explain, in three parts:

**1. Teach it a name.**

> Say a name it always gets wrong, and spell it:
>
>     "hey parrot, Tasmin spells T A S M E E N"
>
> A panel opens with the correction already filled in. You press Return. From
> then on, that name is written correctly every time.
>
> You can also select the wrong word first and just say "hey parrot". The panel
> opens with what it heard and an empty box for what it should be.

**2. Change text you selected.**

> Select some text, hold the key, and say what you want:
>
>     "hey parrot, fix the grammar"
>     "hey parrot, make that a bullet list"
>     "hey parrot, sort that list alphabetically"
>     "hey parrot, use the 24 hour clock"
>
> A panel shows you the new text before it replaces anything. You can edit it in
> the panel. Command-Return replaces the text, Escape cancels.
>
> If you select nothing, it works on the last thing you dictated. That is useful
> right after you speak, when there is nothing to select yet.

The first two examples come from the prompt list. The last two match no prompt
at all — they are handled by `free_form`, which sends the whole instruction to
the model. This is why the list is not a menu: the user does not have to learn
it. Do not read them a list of commands to memorise.

**3. The tuned ones are already there.**

A new install is written with three transforms — `bullets`, `terse` and
`grammar` — so there is nothing to add and nothing to fetch. They are in the
`capabilities` lines you printed a moment ago. Each exists because it scores
better on its own test set than `free_form` does at that one job; everything
else is free-form's, which is why the list is not a menu.

Point at them rather than offering them:

> Three of those are tuned for one job each: bullet points, shorter text, and
> grammar. Everything else you say goes to the general one. You do not have to
> remember which is which — it works that out.

If they want one of their own, it goes in `transforms:` and it needs a
`description`: that is the text the router matches spoken words against, so an
entry without one can never be picked, and `--check-config` reports it as an
error rather than leaving it to look like the router misbehaving.

```sh
/Applications/ParrotFlow.app/Contents/MacOS/ParrotFlow --check-config
```

The `capabilities` count goes up and the new entry is listed by name. A
`transforms:` entry can also be a substitution table rather than a prompt, and
those run from a pipeline instead of by voice — docs/pipelines.md, not something
to cover in a handover.

**If the Gemma download is still running,** say this now:

> These commands start working the moment the download finishes. Nothing to
> restart.

You can prove routing works without saying anything out loud, once the model is
there:

```sh
PF=/Applications/ParrotFlow.app/Contents/MacOS/ParrotFlow
$PF --command "hey parrot, Tasmin spells T A S M E E N"   # shows the rule it would add
$PF --route "make that a bullet list"                     # shows which prompt it picked
```

## Step 11 — Hand over

Keep this short. Three things they need, and where to look.

> Done. Three things to remember:
>
> **Dictate** — hold the right Option key, talk, let it go.
>
> **Fix a word** — when a name is wrong, select it, hold the key, and say
> "hey parrot". Or say the spelling: "hey parrot, Tasmin spells T A S M E E N".
>
> **Change text** — select it, hold the key, and say what you want. For example
> "hey parrot, fix the grammar". You always see the result before it replaces
> anything.
>
> Your settings are in `~/.config/parrotflow/config.yaml`. Save the file and the
> app reloads it immediately.
>
> The menu bar icon has *Correct a Word…*, *Settings…* and *Permissions…*.

---

## When things go wrong

**Nearly everything is in the log.**

```sh
tail -30 ~/Library/Logs/ParrotFlow.log
```

Every start records the key and both permissions. Every clip records whether
speech was found and what was transcribed.

**The key does nothing.** Another app may own the same combination. Registration
failures appear in `--check-config` and in the menu bar item. For a single
modifier key like right Option, check that the key physically reaches the app:

```sh
/Applications/ParrotFlow.app/Contents/MacOS/ParrotFlow --watch-modifiers
```

**Permissions look granted but the app disagrees.** This is almost always a
signature problem. macOS ties these grants to the app's signature, and an app
replaced by a different build loses them while System Settings still shows it
ticked. Turning the switch off and on again does not fix it — the dead record is
reused. Reset it properly, then grant it again:

```sh
tccutil reset Accessibility com.parrotflow.app
tccutil reset Microphone com.parrotflow.app
```

Then restart the app and grant the permission from a clean start.

**A voice command does nothing, or says nothing to change.** The app tells you
what text it looked at. Read the log:

```sh
grep -E "router|transform|command|selection" ~/Library/Logs/ParrotFlow.log | tail -10
```

If it worked on the wrong text, the selection was not readable — common in
terminals, where a selection is dropped as soon as focus moves. Copy the text
first, then say the command.

**Voice commands do nothing at all.** Check Ollama is running and has the model:

```sh
curl -s --max-time 3 http://localhost:11434/api/version
ollama list | grep gemma4
```

**A name is still wrong after teaching it.** Check the rule was written:

```sh
grep -A5 replacements ~/.config/parrotflow/config.yaml
```

**Dictation is slow the first time.** The first clip after the app starts loads
the speech model. After that it is fast.

**A command you ran never returns.** The app ignores a flag it does not know and
starts as a menu bar app instead, which never exits. That means the installed
app is older than this file. Press Ctrl-C, run Step 3 again to update it, and
retry.

**Do not** suggest turning off Gatekeeper, running
`xattr -dr com.apple.quarantine`, or `sudo` for anything. Nothing in this setup
needs them. If something looks like it does, something else is wrong. Say so and
stop.
