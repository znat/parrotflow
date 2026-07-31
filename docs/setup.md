# Setting up ParrotFlow

**These are instructions for a coding agent, not for a person.** Someone has
asked you to set ParrotFlow up on their Mac. Follow this file top to bottom.

Read the whole thing before you start, then work through it. Do not improvise
extra steps, and do not skip the checks — most of what goes wrong here is
invisible until you look for it.

## How to talk while you do this

The person watching is a developer, but they know nothing about this app.

- Short sentences. One idea each.
- Say what you are about to do, do it, say what happened.
- No jargon they did not use first. Not "TCC", not "ASR", not "quantised".
- Never say "should work". Check, then say what is true.
- Lines shown as `> quoted text` are for you to say. Use your own words if
  they fit better, but keep them that short.

Two things you cannot do, ever:

1. **Grant permissions.** macOS only accepts those from a human, clicking. You
   can open the right pane and wait. You cannot click for them.
2. **Test dictation.** It needs a voice. Only they have one.

When you hit either, stop and ask. Then verify what they say they did — people
tick the wrong row in System Settings all the time.

## If ParrotFlow is already installed

Check first:

```sh
ls -d /Applications/ParrotFlow.app 2>/dev/null
```

If it is there, this is an upgrade or a repair, not a first install. Skip to
Step 3, run the installer anyway (it replaces the app in place), then go
straight to Step 9 to check the config and Ollama. Do not re-ask questions
they have already answered — read `~/.config/parrotflow/config.yaml` and only
ask about what is missing.

---

## Step 1 — Say what is about to happen

Before running anything. They should be able to stop you here.

> ParrotFlow is dictation that runs entirely on your Mac. You hold a key, talk,
> and the text appears in whatever app you are in. Nothing is uploaded — no
> account, no API key, no network call.
>
> Setup is seven steps. About five minutes of your attention, then a large
> download that finishes in the background.
>
> I will:
> 1. Check your Mac can run it
> 2. Install the app
> 3. Get you through two macOS permission prompts
> 4. Prove transcription works
> 5. Ask which languages you dictate in
> 6. Start a 10 GB model download for spoken commands — optional, and it runs
>    in the background
>
> You will need to click twice in System Settings. I cannot do that part.
>
> Ready?

Wait for an answer. If they ask what the 10 GB is for, tell them: it is only
for spoken corrections like *"hey parrot, Tasmin spells T A S M E E N"*.
Dictation itself does not need it.

## Step 2 — Check the Mac

```sh
sw_vers -productVersion          # need 14 or higher
uname -m                         # need arm64
sysctl -n hw.memsize             # bytes of RAM — write this down, Step 9 needs it
df -g / | tail -1 | awk '{print $4}'   # GB free — need 15 or more
```

**Remember the RAM figure.** It decides a setting later, and re-reading it is
easy to forget.

Stop if macOS is older than 14, or if the machine is Intel — speech
recognition runs on the Neural Engine, which Intel Macs do not have. Say so
plainly and stop; there is no workaround to offer.

If free disk is under 15 GB, say so and ask whether to continue. Dictation
needs about 1.5 GB. The spoken-command model needs another 10 GB and can be
skipped.

## Step 3 — Install

```sh
curl -fsSL https://raw.githubusercontent.com/znat/parrotflow/main/scripts/install.sh | sh
```

Downloads about 3 MB, verifies its checksum, puts the app in `/Applications`,
and launches it. The models come later and are much bigger — that is why this
part is quick.

> Installed. There is a microphone icon in your menu bar now, on the right.
> Can you see it?

If the download fails, there may be no release published yet — check
`https://github.com/znat/parrotflow/releases`. If `/Applications` is not
writable, re-run with `PARROTFLOW_DEST=~/Applications`.

## Step 4 — Microphone

The app asks on first launch. It may already be sitting there.

> macOS is asking whether ParrotFlow can use your microphone. Say yes —
> without it there is nothing to transcribe.

Then verify. Do not take their word for it:

```sh
/Applications/ParrotFlow.app/Contents/MacOS/ParrotFlow --check-config
```

Look for `✓ microphone  Granted`. Anything else, send them to
**System Settings → Privacy & Security → Microphone** and check again.

This command also prints the whole resolved config, which is worth reading —
it shows the hotkey, the insert mode and the languages you are about to change.

## Step 5 — Prove transcription works, and start the big-ish download

This is the step that makes the app real, and it needs no microphone.

```sh
say -o /tmp/pf-check.wav --data-format=LEI16@16000 --channels=1 "Testing one two three"
/Applications/ParrotFlow.app/Contents/MacOS/ParrotFlow --transcribe /tmp/pf-check.wav
```

`say` is built into macOS and writes exactly the 16 kHz mono WAV the speech
model expects. The first run downloads that model — about 1.2 GB — and prints
its progress. Expect a few minutes on a normal connection.

> Downloading the speech model, about 1.2 GB. This is the one dictation
> actually needs. A couple of minutes.

A transcript comes back at the end. It will be close to "Testing one two
three" but not identical — "Testing 123." is a normal and correct result. What
matters is that text came back at all.

If it fails, stop here and work it out before going further. Nothing after this
step will work if this one does not.

## Step 6 — Accessibility

Needed to type text into other apps, and to read what you have selected when
correcting a word. Recording works without it; the useful part does not.

> One more permission. This one lets ParrotFlow type into other apps —
> otherwise it can only copy to your clipboard.
>
> I have opened the pane. Find ParrotFlow in the list and switch it on.

```sh
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
```

**Verifying this is not obvious, so do it exactly this way.** Running
`--check-config` does *not* tell you — macOS credits a check made from a
terminal to the terminal, not to ParrotFlow, and it will report "not granted"
for an app that has the permission. The app tests it properly at launch and
writes the answer to its log. So restart it, then read the log:

```sh
pkill -f "ParrotFlow.app/Contents/MacOS/ParrotFlow"; sleep 1
open -a ParrotFlow; sleep 3
grep "launched —" ~/Library/Logs/ParrotFlow.log | tail -1
```

You want `accessibility=Granted` on that line. If it says `NotGranted`, the
switch is off or they ticked a different app. Ask them to look again, restart,
and re-read the log.

## Step 7 — Languages

> Which languages do you dictate in?

Dictation itself is multilingual and needs no setting — the speech model
handles whatever you speak. This list does something narrower: it picks which
correction prompt is used, and it is what ParrotFlow uses to work out which
language a transcript was in.

**Only `en` and `fr` are supported today.** Anything else is ignored. If they
name another language, be straight about it:

> Dictation will work in that language — the speech model is multilingual. But
> spoken corrections are only written for English and French so far, so I will
> leave this set to English.

Edit `~/.config/parrotflow/config.yaml`, under `transcription`, most-used
language first:

```yaml
transcription:
  languages: [en, fr]
```

One entry means no language detection runs at all, which is faster and more
accurate — so use one entry if they only dictate in one language. The app
picks the file up on save; no restart.

## Step 8 — Let them try it

The first real dictation. You cannot do this one.

> Your turn. Open any text field — a note, a chat box, this terminal.
>
> Hold the **right Option key**, say a sentence, let go.
>
> Wait about a second. The text should appear where your cursor is.

If nothing arrives:

```sh
grep -E "transcribed|speech gate|hotkey" ~/Library/Logs/ParrotFlow.log | tail -5
```

- Nothing logged at all → the hotkey never fired. Check `--check-config` for a
  registration failure, and ask whether another app owns that key.
- `speech gate: no speech detected` → the microphone heard nothing. Wrong input
  device, or they let go too fast.
- `transcribed: …` but nothing appeared → Accessibility. Back to Step 6.

Once it works, say so and move on. This is the moment they decide whether they
like the app.

## Step 9 — Spoken commands (the 10 GB part)

Everything above already works. This step adds one thing: saying
*"hey parrot, Tasmin spells T A S M E E N"* to teach it a name, instead of
typing the correction into a panel.

> Last piece, and it is optional. It downloads a 10 GB model so you can fix
> words by voice instead of typing them.
>
> Everything else already works — this only affects spoken corrections. The
> download runs in the background and you can use dictation the whole time.
>
> Want it?

If no: set `llm.enabled: false` in the config, tell them the correction panel
still works by hand, and go to Step 10.

**Check Ollama is installed and running.** This one call answers both:

```sh
curl -s --max-time 3 http://localhost:11434/api/version
```

- Returns `{"version":"0.31.1"}` or similar → running. Check the version below.
- Returns nothing → either not installed or not started.

```sh
command -v ollama            # installed?
```

If missing:

```sh
brew install ollama
brew services start ollama
```

If installed but not answering, start it — `brew services start ollama` when
it came from Homebrew (the path starts with `/opt/homebrew` or
`/usr/local/Cellar`), otherwise open the Ollama app.

**Minimum version is 0.22.0.** Earlier builds cannot run `gemma4`'s e-series
tags at all. Compare what `/api/version` returned. If it is older:

- Homebrew install → `brew upgrade ollama`
- Ollama app → tell them to update it from the Ollama menu, or re-download from
  ollama.com. You cannot update that one for them.

**Set `keep_loaded` from the RAM figure from Step 2.** The model is 9.6 GB and
this decides whether it stays resident:

| RAM | `llm.keep_loaded` | Why |
| --- | --- | --- |
| 32 GB or more | `true` | 9.6 GB resident is affordable. Corrections answer in 1–2s. |
| 16 GB to 32 GB | `false` | Pinning 9.6 GB of 16 would hurt everything else. Corrections take 7–10s, because Ollama reloads the model each time. |
| under 16 GB | `false`, and say something | It will work but swap. Tell them, and offer to set `llm.enabled: false` instead. |

Write it into `~/.config/parrotflow/config.yaml`:

```yaml
llm:
  enabled: true
  model: gemma4:e4b
  keep_loaded: true    # or false, per the table
```

**Then start the download in the background** and do not wait for it:

```sh
nohup ollama pull gemma4:e4b > /tmp/parrotflow-pull.log 2>&1 &
```

> Downloading in the background — 9.6 GB, so anywhere from a few minutes to
> half an hour.
>
> Dictation works right now. Don't wait for this. The only thing missing until
> it lands is fixing words by voice.

Check on it with:

```sh
tail -2 /tmp/parrotflow-pull.log
ollama list | grep gemma4
```

If the pull fails with an error about the model or manifest, Ollama is too old
regardless of what its version string said — upgrade it and pull again.

## Step 10 — Hand over

Keep this short. Two things they need, and where to look.

> Done. Two things worth remembering:
>
> **Dictate** — hold right Option, talk, let go.
>
> **Fix a word** — when a name comes out wrong, select it, hold right Option
> and say "hey parrot". A panel opens with what it heard and a box for what it
> should say. Or say the spelling: "hey parrot, Tasmin spells T A S M E E N".
>
> Settings are in `~/.config/parrotflow/config.yaml` — change the hotkey there.
> It reloads when you save.
>
> The menu bar icon has *Settings & Permissions* and *Correct a Word…*.

If the Ollama pull is still going, say so, and tell them spoken corrections
start working the moment it finishes — no restart needed.

---

## When things go wrong

**Everything worth knowing is in the log.**

```sh
tail -30 ~/Library/Logs/ParrotFlow.log
```

Every launch records the hotkey and both permissions. Every clip records
whether speech was found and what was transcribed.

**The hotkey does nothing.** Another app may own the combination; registration
failure shows in `--check-config` and in the menu bar item. For a bare modifier
like right Option, check the key is physically reaching the app:

```sh
/Applications/ParrotFlow.app/Contents/MacOS/ParrotFlow --watch-modifiers
```

**Permissions look granted but the app disagrees.** Almost always a signature
problem: macOS ties these grants to the app's signature, and an app that was
replaced by a different build loses them while System Settings still shows it
ticked. Un-ticking and re-ticking does not fix it — the dead entry is reused.
Reset the record properly and grant again:

```sh
tccutil reset Accessibility com.parrotflow.app
tccutil reset Microphone com.parrotflow.app
```

Then restart the app and grant from a clean slate.

**Transcripts arrive but a name is always wrong.** That is what the correction
panel is for. It is a feature, not a fault — teach it the word.

**Dictation is slow to start.** The first clip after launch loads the speech
model. After that it is fast.

**Do not** suggest disabling Gatekeeper, running `xattr -dr com.apple.quarantine`,
or `sudo` anything. Nothing in this setup needs them. If something looks like it
does, something else is wrong — say so and stop.
