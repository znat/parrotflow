# Setting up ParrotFlow

**Instructions for a coding agent, not for a person.** Someone asked you to set
ParrotFlow up on their Mac. Read the whole file, then work top to bottom. Do not
invent steps, and do not skip the checks — most of what goes wrong here is
invisible until you look for it.

## How to talk while you do this

They are a developer who knows nothing about this app, often not a native
English speaker. Short sentences, common words, no jargon they did not use
first. Say what you are about to do, do it, say what happened. Never say "should
work" — check, then say what is true. Lines shown as `> quoted text` are for you
to say; shorter words of your own are fine.

Two things you cannot do, ever:

1. **Grant permissions.** macOS only accepts those from a human, clicking.
2. **Test dictation.** It needs a voice. Only they have one.

When you hit either, stop and ask — then check what they say they did. People
tick the wrong row in System Settings often.

## What you are installing

Say which download you are on. A silent 10 GB download looks like a hang.

| What | Size | When | Needed for |
| --- | --- | --- | --- |
| The app | 3 MB | Step 2 | everything |
| Parakeet, the speech model | 1.2 GB | Step 3, automatic | dictation |
| Gemma, the language model | 10 GB | Step 5, optional | voice commands |

Dictation works after Step 3. Everything after is extra.

**Already installed** (`ls -d /Applications/ParrotFlow.app`)? This is an
upgrade. Run Step 2 anyway — it replaces the app in place — then go to Step 4,
read `~/.config/parrotflow/config.yaml` and
`~/.config/parrotflow/vocabulary.yaml`, and ask only about what is missing.

---

## Step 1 — Explain, then check the Mac

They should be able to stop you here.

> ParrotFlow is dictation that runs on your Mac. You hold a key, you talk, and
> the text appears in the app you are using. Nothing is uploaded — no account,
> no API key, no network call.
>
> I will check your Mac, install the app, help you through two permission
> windows, prove transcription works, and ask you a few questions. About five
> minutes. You have to click twice in System Settings yourself. Ready?

If they ask what the 10 GB is for: only spoken commands. Dictation does not need
it.

```sh
sw_vers -productVersion                # need 14 or higher
uname -m                               # need arm64
sysctl -n hw.memsize                   # bytes of RAM — write this down, Step 5 needs it
df -g / | tail -1 | awk '{print $4}'   # GB free — need 15 or more
```

**Remember the RAM number.** It decides a setting in Step 5.

Stop if macOS is older than 14, or if the Mac is Intel. Under 15 GB free: say
so and ask whether to continue.

## Step 2 — Install, and get both permissions

```sh
curl -fsSL https://raw.githubusercontent.com/znat/parrotflow/main/scripts/install.sh | sh
```

Installs to `/Applications` and starts it.

> The app is installed. There is a microphone icon in your menu bar now, top
> right. Can you see it?

Download fails → check `https://github.com/znat/parrotflow/releases` for a
release. `/Applications` not writable → rerun with
`PARROTFLOW_DEST=~/Applications`, and use that path instead of `/Applications`
in every command below.

**Microphone.** The app asks at first launch; the window may already be open.

> macOS is asking if ParrotFlow can use your microphone. Please say yes.

Check it yourself — do not take their word:

```sh
/Applications/ParrotFlow.app/Contents/MacOS/ParrotFlow --check-config
```

Want `✓ microphone  Granted`. Anything else: **System Settings → Privacy &
Security → Microphone**, then check again. This also prints the config the app
is using. Read it; you will come back to it.

**Accessibility, or the clipboard instead.** A real choice. Ask before opening
any settings window.

> **Type the text for me** — ParrotFlow types straight into the app you are
> using. Needs the Accessibility permission.
>
> **Copy the text instead** — ParrotFlow copies, you press Command-V. Needs no
> permission.
>
> Typing is what most people want. Which do you prefer?

Clipboard → set `transcription: insert_mode: clipboard`, then say:

> Two things will not work: fixing a word by voice, and the voice commands in
> Step 5. Both have to read the text you selected. Dictation is not affected,
> and you can turn the permission on later without reinstalling anything.

Typing — the default — open the window:

```sh
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
```

**Check this exactly this way.** `--check-config` does *not* tell you: macOS
credits a check made from a terminal to the terminal, so it reports "not
granted" for an app that has the permission. The app tests it properly at launch
and writes the answer to its log.

```sh
pkill -f "ParrotFlow.app/Contents/MacOS/ParrotFlow"; sleep 1
open -a ParrotFlow; sleep 3
grep "launched —" ~/Library/Logs/ParrotFlow.log | tail -1
```

Want `accessibility=Granted`. `NotGranted` means the switch is off or they
ticked a different app.

## Step 3 — Prove transcription works with no voice

Needs no microphone.

```sh
say -o /tmp/pf-check.wav --data-format=LEI16@16000 --channels=1 "Testing one two three"
/Applications/ParrotFlow.app/Contents/MacOS/ParrotFlow --transcribe /tmp/pf-check.wav
```

The first run downloads that model — tell them first:

> Downloading the speech model now. It is called Parakeet, about 1.2 GB, and it
> runs on your Mac. A few minutes.

`Testing 123.` is a correct result; what matters is that text came back. If this
fails, stop and fix it — nothing after this step can work.

## Step 4 — Configure languages, filler words, hotkey, numbers

Ask together, edit `~/.config/parrotflow/config.yaml` after each answer. The app
reloads on save.

**1. Languages.** **Only `en` and `fr` work today** — if they name another, say
dictation works in it but the correction rules are not written yet, and leave
this on English.

```yaml
transcription:
  languages: [en, fr]     # most used first; one entry skips detection entirely
```

**Then write the filler words for those languages.** Do not skip this because
the config looks like it handles it — the `fillers` transform in
`config.example.yaml` is English only. A French speaker keeps every `euh`.

> When people talk they make sounds like "um" and "euh". Shall I remove those?

```yaml
transforms:
  - name: fillers
    description: delete hesitation sounds
    replace:
      # English; add French euh+|heu+|hein|bah to this same list
      "": ['/[,]?\s*\b(?:mm[-‑]?hmm|uh[-‑]?huh|mhm|u+m+|u+h+|erm+|hmm+|mm+)\b[,]?/']
```

One `""` entry, not two — it is one map, and a repeated key is invalid YAML.

**Only add words that are not words in the other language.** Every rule runs on
every transcript. `euh`, `heu`, `hein` are safe. Never add `ben`, `genre`,
`quoi`, `voilà`, `donc` or `alors` — ordinary French words, and `ben` is an
English name. Deleting one damages a sentence that was already correct.

**2. The key.** Right Command is the default. Right Option also types `é`,
`ü`, `ñ` — steer them away from binding that one if they type accented
characters. Alternatives: `fn`, `right_control`, or a character key plus
modifiers — all listed in the config file.

**3. Numbers.** On by default. Show, do not explain:

```sh
PF=/Applications/ParrotFlow.app/Contents/MacOS/ParrotFlow
$PF --numbers "I need two hundred and forty three of them by nineteen eighty four"
```

The grammar used comes from `languages`, so run this after that edit. It is a
pipeline step, so if they do not want it, delete the `- numbers` line from
`transcription.pipeline:`. There is no `numbers:` setting — a config carrying
one is refused by `--check-config`.

Check every edit with `--check-config`. It prints each rule and reports a
pattern it cannot compile.

## Step 5 — The optional model half

One decision covers everything in this step: do they want the 10 GB part.

> Optional, and last. It downloads a 10 GB model called Gemma, which
> understands the commands you say out loud. Everything else already works
> without it, and the download runs in the background. Do you want it?

**No** → set `llm: enabled: false`, tell them they can still fix words by hand
from the menu bar, and go to **Hand over**.

**Yes** → keep going.

**Or a hosted model instead.** Everything below runs Gemma on their own Mac,
which is the private option and the default. Someone who would rather not
download 10 GB can name a hosted model under `models:` in config.yaml and give
it an API key — the app asks for the key on its next launch and keeps it in the
keychain. That sends what they dictate to somebody else's server, so say so and
let them choose. See [configuration.md](configuration.md).

**Ollama runs the model.** These answer whether it is installed and running:

```sh
curl -s --max-time 3 http://localhost:11434/api/version
command -v ollama
```

Say what it is before installing — do not put software on someone's machine
silently:

> Gemma needs a program called Ollama to run it. Ollama runs language models on
> your own Mac, offline. I will install it now.

```sh
brew install ollama && brew services start ollama
```

Installed but not answering → `brew services start ollama` if the path starts
with `/opt/homebrew` or `/usr/local/Cellar`, otherwise ask them to open the
Ollama app.

**Minimum version 0.22.0** — older builds cannot run `gemma4` e-series models at
all. Homebrew: `brew upgrade ollama`. The Ollama app: they must update it
themselves, you cannot.

**Now use the RAM number from Step 1.** The model needs 9.6 GB while loaded:

| RAM | `llm.keep_loaded` | Why |
| --- | --- | --- |
| 32 GB or more | `true` | 9.6 GB is affordable. Commands answer in 1–2 s. |
| 16 to 32 GB | `false` | Commands take 7–10 s; Ollama reloads each time. |
| under 16 GB | `false`, and say so | Works, but the Mac swaps to disk. Offer `llm: enabled: false` instead. |

```yaml
llm:
  enabled: true
  model: gemma4:e4b
  keep_loaded: true    # or false, from the table above
```

**Start the download in the background. Do not wait for it:**

```sh
nohup ollama pull gemma4:e4b > /tmp/parrotflow-pull.log 2>&1 &
```

> 9.6 GB, so a few minutes to half an hour. Dictation works right now — please
> do not wait for this.

Check later with `tail -2 /tmp/parrotflow-pull.log` and `ollama list | grep
gemma4`. An error about the model or manifest means Ollama is too old, whatever
its version string said.

**Teach them what they can say.** Do this while the download runs.

Everything starts with the wake phrase `hey parrot`: hold the same key, say the
phrase, then say what you want. Those words are never typed into the document.
Print the real list first — the `capabilities` lines from `--check-config` —
rather than reading from this file.

> Say a name it gets wrong, and spell it:
>
>     "hey parrot, Tasmin spells T A S M E E N"
>
> A panel opens with the correction filled in. Press Return, and that name is
> right every time after. You can also select the wrong word and just say "hey
> parrot".
>
> Or select some text and say what you want:
>
>     "hey parrot, fix the grammar"
>     "hey parrot, make that a bullet list"
>     "hey parrot, use the 24 hour clock"
>
> You see the new text before it replaces anything. Command-Return replaces,
> Escape cancels. Select nothing and it works on the last thing you dictated.

The last example matches no prompt at all — `free_form` sends the whole
instruction to the model. **Do not read the examples as a menu to memorise.**
A new install ships `bullets`, `terse` and `grammar` as tuned transforms;
everything else goes to `free_form`:

> Three are tuned for one job each. Everything else goes to the general one. You
> do not have to remember which is which.

`grammar` is also already on the pill — the **G** chip, right after any
dictation, no wake phrase needed. `bullets` and `terse` only run when asked out
loud.

A transform of their own goes in `transforms:` and needs a `description` —
`--check-config` reports one without it as an error.

**Slack handles, if they use Slack.** Skip this unless they use Slack.

The config ships a `slack_mentions` transform with three example names to
replace.

> Do you use Slack? I can teach it your colleagues' handles — then "hey parrot,
> use Slack mentions" turns "tell Marie the deadline moved" into "tell
> @marie.dupont the deadline moved".
>
> I need names and handles, and I cannot read your workspace. If your Slack has
> an assistant, ask it for the members of your team channel, or the people you
> have messaged in the last month. Paste the answer here in any format.

They can also just name the handful of people they message most. Either way the
source is them: **never invent or guess a handle.** A wrong one pings the wrong
person and nobody notices.

Put what they paste into the list inside that transform's prompt, one per line,
keeping the shape and dropping the examples:

```yaml
transforms:
  - name: slack_mentions
    prompt: |
      ...
        Marie   -> @marie.dupont
        Thomas  -> @tleroy
```

Then `--check-config`, and say what it does and does not do:

> It only runs when you ask — a message that names someone is not always a
> message that should ping them. With text selected you see the result first.
> And it never sends anything: you get text in your Slack box, and the last look
> is yours.

Check one thing with them: ask them to paste a handle into a message **without
sending** and say whether it turns blue. If it stays plain, it looks like a
mention but notifies nobody — tell them that.

## Hand over

> Done. Three things:
>
> **Dictate** — hold right Option, talk, let go.
>
> **Fix a word** — select it, hold the key, say "hey parrot". Or say the
> spelling: "hey parrot, Tasmin spells T A S M E E N".
>
> **Change text** — select it, hold the key, say what you want. You always see
> the result first.
>
> Settings are in `~/.config/parrotflow/config.yaml`, and the names it has
> learnt are in `vocabulary.yaml` beside it. Both reload on save. The menu bar
> icon has *Settings* — *Edit Config…* and *View Transforms* — and
> *Permissions…*.

---

## When things go wrong

**Nearly everything is in the log** — `tail -30 ~/Library/Logs/ParrotFlow.log`.
Every start records the key and both permissions; every clip records whether
speech was found and what was transcribed.

**The key does nothing.** Another app may own the combination; registration
failures show in `--check-config`. For a single modifier key, check it reaches
the app at all with `--watch-modifiers`.

**Permissions look granted but the app disagrees.** Toggling the switch does
not fix it — it reuses the same dead record.

```sh
tccutil reset Accessibility com.parrotflow.app
tccutil reset Microphone com.parrotflow.app
```

Then restart and grant from a clean start.

**A voice command does nothing, or says nothing to change.**

```sh
grep -E "router|transform|command|selection" ~/Library/Logs/ParrotFlow.log | tail -10
```

Wrong text → the selection was not readable, common in terminals where it is
dropped as soon as focus moves. Copy the text first, then say the command.

**Voice commands do nothing at all.** `curl -s --max-time 3
http://localhost:11434/api/version` and `ollama list | grep gemma4`.

**A name is still wrong after teaching it.**
`grep -A5 <name> ~/.config/parrotflow/vocabulary.yaml`.

**Dictation is slow the first time.** The first clip after launch loads the
speech model.

**A command never returns.** The app ignores an unknown flag and starts as a
menu bar app, which never exits — the installed app is older than this file.
Ctrl-C, rerun Step 2, retry.

**Do not** suggest turning off Gatekeeper, `xattr -dr com.apple.quarantine`, or
`sudo`. Nothing here needs them. If something looks like it does, something else
is wrong. Say so and stop.
