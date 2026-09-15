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
| Parakeet, the speech model | 470 MB | Step 3, automatic | dictation |
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

**After the permissions.** The setup window lists the models it is fetching —
about 1.5 GB, started at launch — with what each one costs. *Download* moves on;
the fetches started at launch and carry on behind it.

**eSpeak NG.** Then the one thing the app cannot fetch for you. It helps
ParrotFlow understand your own terms — your jargon, your teammates' names. It is
GPL-3 and a separate library, so the screen shows the Homebrew command, and
*Install with Terminal* runs it where it can be watched. The screen notices the
binary landing by itself. *Continue* moves on whether or not it is here.

It comes before the tour on purpose: it is the one step with a person in it, so
it is done while there is still a download to wait on.

**The tour.** Then the window plays a demonstration of what the app does, for as
long as the models take: correcting a name and having it remembered, a sentence
in Slack, and the kinds of transform. It turns its own pages.

Three things say what it is. The first screen says it in words, once — and only
once: the loop that follows leaves it out, because coming back to a screen that
says the download is starting says the download has started again. Every
screen carries a small "WHILE YOU WAIT" at the right of the header, because the
tour loops and somebody who looks away lands in the middle of one. And a row of
dots at the bottom says they are pages of one walk.

Each screen keeps the height of its own tallest beat, so none of them ends in a
band of nothing, and the window eases between the two heights over about six
tenths of a second rather than jumping at the cut. That long because the
distance is long: the opening screen is 286 points tall and the one after it is
578.

Both chat screens dim round what they are about. A whole sentence at full
brightness reads before the one word in it that changed does, and that word is
the screen. The rest goes down to a third for as long as it takes.

The vocabulary screen does it three times. Over each correction, the name in the
field and the surface asking whether to keep the change are lit. At the end,
where the line holds both names and nobody was asked about either, they are the
two lit things.

The Slack screen does it twice, once for each thing it teaches. First the link,
with the callout that says what happened to it — a sentence about the link is no
use dimmed. Then the mention, from the drag over the name to the send: the name,
and the surface offering to rewrite it.

A word gets a soft edge and a surface a hard one, on its own rim. A rectangle
round one word of a sentence reads as a box someone drew on the words; soft, it
reads as light. A surface already has a drawn edge, and blurring the dim only
smears it. The callout is soft too, because its box is the bubble plus the tail
under it, and a hard edge there draws a rectangle a little below a triangle.

The lit boxes are the views' own, reported up by the words, the pill and the
callout rather than written down here. They were numbers measured off a render
once, and taking one line off a screen moved every one of them.

The dots are the only thing on the tour to press. Clicking one plays from there,
which is the way back to a page that went past too quickly. They count pages and
not screens: the last screen is four config examples one after another, so there
are seven dots. A click cannot end the tour early — how long it has played
through is measured on how long it has been on screen, not on the clock a dot
moves.

The download sits above a divider, so the top of the window is this install and
the rest of it is the app. It is a bar, a shimmer over the filled part, the
percentage at the end, and on the left the model being fetched — "2 of 6 ·
Parakeet TDT 0.6B v3". The name is there because the bar was not enough to
watch: Parakeet is 461 MB of the 1.5 GB and FluidAudio reports it one file at a
time rather than one byte at a time, so the figure sat at 15% for a minute or
two and then stepped to 31%. A name that changes six times is something
happening on a bar that looks stopped.

The figure also fills its own gaps. The bar gains a point every three seconds on
its own, and the real figure wins whenever it is further on. It is a guess
between two known points and a slow one — a point every three seconds is 300
seconds for the whole download, and 1.5 GB has taken about two minutes on every
install measured here — so the truth is almost always ahead of it. It stops one
point short of full: a hundred is the download ending, and only the download
says that.

On the whole bar, not on the rows, which is where it was first. A row stops one
point short too, and Parakeet is 31% of the download, so a crawl that filled
Parakeet's row took the bar to 30% and parked it there. The figure is the downloader's own, weighted by the size
of each model, and it never reads 100%: a hundred is what ends the tour, so a
screen still up saying it has arrived would be contradicting itself.

It ends by itself once it has played through once **and** every model is in. It
ends wherever it is, mid-screen included: it used to wait for the next cut so no
demonstration was cut in half, and that is a demonstration held in front of
somebody whose app is ready. It also ends at once if a fetch a dictation waits
on fails. Both
conditions earn their place. The downloads start at launch and the tour starts
after the permissions, so most of the wait is spent in System Settings granting
accessibility: without the first condition the tour is reached with nothing left
to wait for and skipped before it draws a frame. And the second is every model
rather than the speech model, because that one lands first with about a gigabyte
still behind it.

**Ready.** The last screen. The title is the state: "Almost ready" while a model
a dictation waits on is still coming, then "Ready" with the key to hold, and one
bar under it for every download together.

**A model that did not arrive.** If one of the four a dictation never waits for
fails, the last screen says so: the name, what it costs until it is here, and
that ParrotFlow fetches it again the first time it needs one. No button. Each
fetch clears its own handle when it fails, so the next dictation that reads the
model tries again on its own.

The two a dictation does wait on — Parakeet and Silero VAD — are not this. One
of those failing takes the title, the sentence and the retry, and ends the tour
at once.

*Done* is greyed until those models are in — it closes the window, and an app
closed over a half-finished fetch is one that does not work yet. Pressing it
without eSpeak NG asks once, *Install it* or *Not now*, and remembers the
answer, so the question is asked once per install and not once per launch.

**Where the app went.** When the window closes on the end of an install, a
callout appears under the menu bar icon with an arrow pointing at it: the app's
name, the key to hold, and that its menu is under the bird. Nothing to press —
it goes on a click or after nine seconds.

Once ever, kept in a default like the eSpeak answer. A window opened later from
the menu bar was opened by somebody who already knows where the menu bar is, so
that one says nothing.

`--panels callout` draws it where a status item would be, for editing it.

*Finish Setup…* stays in the menu bar while eSpeak NG is missing, and opening it
that way shows the command again — it is the only route back to it.

**The Python a parse needs.** Once eSpeak NG is here, the app installs it in the
background: about 170 MB into `~/Library/Application Support/ParrotFlow/python`.
Nothing is asked and nothing waits for it. It is safe to do without a terminal
because eSpeak NG came from Homebrew and the Homebrew installer installs the
Command Line Tools, so by then there is a real `python3` to build on.

It pays for the fifth rule of the `disfluency` transform, the one that tells
"we'll let you know" from "you know, it broke". That rule only runs when a
dictation carries `you know`, `i mean` or `like` — 3.8% of 24,576 dictations in
one archive, but the first one was number 10 and all 33 days had one.

A Mac that never installed eSpeak NG still gets it: the transform publishes
`needs: parsing` the first time the rule is reachable and cannot run, and the
app installs it then. That dictation keeps its other four rules and says why in
`disfluency.declined`.

`ParrotFlow --setup-parsing` still does it by hand.

## Step 3 — Prove transcription works with no voice

Needs no microphone.

```sh
say -o /tmp/pf-check.wav --data-format=LEI16@16000 --channels=1 "Testing one two three"
/Applications/ParrotFlow.app/Contents/MacOS/ParrotFlow --transcribe /tmp/pf-check.wav
```

The first run downloads that model — tell them first:

> Downloading the speech model now. It is called Parakeet, about 470 MB, and it
> runs on your Mac. A minute or two.

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
NUMBERS=~/.config/parrotflow/transforms/examples/numbers
echo "I need two hundred and forty three of them by nineteen eighty four" | $NUMBERS/en.py
```

There is one script per language — `fr.py` beside it. English is the pipeline
step a new install gets, and `dates_en` above it writes a dictated date or
clock time. If they dictate in French, add a `numbers_fr` transform pointing at
`fr.py` and a step for it — see [docs/pipelines.md](pipelines.md). If they do not want numbers at all, delete
the `- transform: numbers_en` line. There is no `numbers:` setting — a config
carrying one is refused by `--check-config`, and so is the old `- numbers`
stage line.

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
> icon has *Settings* — *Edit Config…* and *View Transforms* — and *Finish
> Setup…* while something is still missing.

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
