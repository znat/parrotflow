# Acting on what is on screen

Hold the action key, look at something, say what to do. "Click on Antonio."
"Open the thread with Ian." "Reply here: on it, thanks."

This is not dictation and it is not a transform. Nothing is typed, nothing is
rewritten, and the words never reach the document — they say what to do to the
window you are looking at.

Off by default, and off completely: no key registered, no file read, nothing
sent.

## Before you turn it on

**It sends the window you are looking at off this Mac.** Not what you
dictated — the window: its buttons, its labels, the names in the sidebar, the
messages visible in it. That is what the decider needs to pick a target, and
it is a different bargain from every other model in this config.

`--check-config` prints it whenever the block is on:

```
  ✓ actions           Right ⌃ acts on what is on screen where you look
      gaze from       ~/Documents/gaze-overlay/gaze.pos (the mouse when it is stale)
      ⚠︎ sends the window you are looking at to api.typesafe.ai
         its buttons, labels and visible text — not only what you said.
         model jev-latest, key from ~/.typesafe_api_key
      sends messages  no — typed, not sent
```

## Turning it on

```yaml
actions:
  enabled: true
  hotkey:
    key: right_control
  gaze: ~/Documents/gaze-overlay/gaze.pos
  decider:
    api_key: file:~/.typesafe_api_key
```

Every key is in [configuration.md](configuration.md); the whole block with its
defaults is in `config.example.yaml`.

`send:` is the one to think about. Off, a message is typed into the composer
and left there for you to send. On, Return is pressed.

## What happens, in order

1. **The key goes down.** The gaze is read *now*, from `actions.gaze` — one
   line, `x y ms`, in screen coordinates, written by whatever is tracking you.
   Older than 1.5 s means it is not tracking, and the mouse pointer is used.

   Read at the press and not later, because the transcript arrives about a
   second after you let go and by then you are looking at something else.

2. **You speak, you let go, it decodes.** The same recorder, the same model,
   the same vocabulary as a dictation — names matter here more than anywhere.

3. **The window is read.** `ScreenTargets` walks the window under the gaze and
   comes back with everything worth naming: buttons, rows, labels, text
   fields, each with its distance from where you were looking. About 0.4 s on
   a Slack window of 224 targets.

4. **One question, four answers.** The 40 nearest targets, plus any whose name
   matches a word of what you said, go to the decider with the utterance. It
   answers: which action, which target, does the utterance carry the words to
   type, and does it point rather than name. About 0.65 s.

5. **It happens.** A click, a paste, a key. Never a keystroke per character:
   the paste is the app's own, the same one dictation uses.

Anything that fails — no window under the gaze, no key, the decider times out
— leaves the screen exactly as it was and says why on the pill.

## Who decides what

The split is the whole design, and it was measured rather than assumed.

| Question | Decided by | Why |
| --- | --- | --- |
| Which action | the model | six choices, one answer, no arguments to get wrong |
| Which target | the model, from the list it was shown | a name in the utterance beats distance: John's button at 7.5 cm wins over his message at 5.1 |
| Which target, when you said "this one" | the gaze | the model cannot: over the three nearest it answered 0.27 / 0.24 / 0.20 |
| What to type | the utterance itself | the model is never asked to write anything |
| Where the search field is | code | Slack's is not a text field in the accessibility API, so it can never be offered — `search` is mapped to ⌘G |
| Opening a new message | code | the picker is a shortcut, not a target, so `new_message` is mapped to ⌘N. Who it is to is a second step, over the window the picker draws |

The gaze only overrides a target the model could not use — a label, or none at
all. It used to override every deictic, and on the twelve measured utterances
that cost two of them: "reply here: on it, thanks" and "reply to this message:
sounds good" both reach the composer through the model, and both were dragged
onto a pressable group 0.7 cm nearer.

## Measuring it

`--act` runs the whole path without a microphone.

```sh
PF=/Applications/ParrotFlow.app/Contents/MacOS/ParrotFlow

# Look, decide, do nothing. --at a point, --gaze the tracker's, --app a window.
$PF --act "click on Antonio" --app Slack

# Read a window and keep it. --look stops before the decision, so it costs
# nothing: this is how a case set is built.
$PF --act "" --app Slack --look --save slack.json

# Decide against a saved window. No screen, no gaze, same answer.
$PF --act "clique sur Antonio" --snapshot slack.json

# The live path, with the click.
$PF --act "open the thread with Ian" --gaze --execute
```

A saved snapshot is a window frozen, and it is the only thing that makes this
measurable: the same file and the same utterance have to produce the same
decision after the next change.

**Run from a terminal, `--act` reads the screen with the terminal's
Accessibility grant, not ParrotFlow's** — TCC credits the responsible process.
A shell that has the grant works; one that does not reports nothing while the
app itself is fine. Same wrinkle as `--peek`, same way round it:
`open -na ParrotFlowDev --args --act "…"`, then read the log.

### The port's gate

This began as a prototype outside the repository: `axsnap` printed the window,
`jev_probe.py` asked the questions, `axdo` clicked. All three moved in here.
The gate for that port was: the snapshot the prototype measured on
2026-09-20, the same twelve utterances, the same answers.

Twelve of twelve, on the model's own choice:

| # | utterance | action | target |
| --- | --- | --- | --- |
| 1 | send a message to john | send_message | t25 Button "John Bledsoe", 7.5 cm |
| 2 | click on antonio | click | t40 Group "Antonio Nava, …", 12 cm |
| 3 | search for "media" | search | t2 composer — and the target is ignored, ⌘G |
| 4 | reply here: on it, thanks | send_message | t2 composer |
| 5 | open this one | click | t0, by the gaze — the model chose a label |
| 6 | reply to this message: sounds good | send_message | t2 composer |
| 7 | envoie un message à John | send_message | t25 Button "John Bledsoe" |
| 8 | clique sur Antonio | click | t40 Group "Antonio Nava, …" |
| 9 | what time is it | none | — |
| 10 | open the thread with Ian | click | t4 Group "Ian Macomber: …", 2.6 cm |
| 11 | scroll down | scroll | none |
| 12 | go to jira | click | t8 Row "Jira", 4 cm |

610-770 ms per call, 3.1-3.5k input tokens.

One case is unstable and always was. "Open the thread with Ian" scored 0.61 for
his message against 0.39 for his button in the prototype's own run, and it
flips about one run in four. Both answers open something of Ian's. Three runs
in four are 12/12, and no run has ever chosen the wrong *action*.

**The snapshot is not in this repository and will not be.** It is 224 items of
somebody's Slack window: colleagues' names, and the first line of what they
wrote. Take your own with `--look --save` and write the answers down beside
it.

## What is known to be wrong

Measured, or seen once and not yet measured. None of it is fixed.

- **A sequence is one step at a time, and only the first step is decided.**
  "Send a message to Antonio and Peter" from an open DM has no right one-step
  answer: it picks one of the two and drops the other. From the new-message
  picker it is right in one click, because Slack offers the existing "Antonio
  Nava, Peter Bohnert" conversation as a single target, chosen at 0.91. So the
  two-recipient case mostly collapses rather than needing a sequence.
  `--act --done "<step>"` puts what has already happened into the state and it
  does move the answer on — Peter goes from 0.47 to 0.93 once Antonio is in
  `done` — but nothing in the app passes it, and it will not stop on its own.
- **Only Slack, Ghostty, ChatGPT and TextEdit have been tried.** The action
  list, the composer rule and the ⌘G mapping are all Slack-shaped.
- **A full-window text area** was dropped by the 12 % container rule until
  TextEdit showed it: a text field is now exempt, because it holds no targets
  — it is one.
- **The deictic threshold is 0.5** and "the nearest thing that can be clicked"
  is a guess. Only the narrowing above was measured.
- **The words to type come from a regex** — quotes, or after
  "saying"/"that"/":". Clicking first and dictating afterwards needs no
  extraction at all, and already works.
- **The gaze is a point, not a region.** At 4-7 cm of error it lands on a
  neighbour often enough that the name in what you say is doing most of the
  work.

## Where the pieces are

| Piece | File |
| --- | --- |
| The gaze file, and the mouse when it is stale | `Gaze.swift` |
| The accessibility walk | `ScreenTargets.swift` |
| The questions, and what the answers mean | `ActionDecider.swift` |
| Clicks, keys and the paste | `ScreenAction.swift` |
| `--act` | `ActCommand.swift` |
| The second hotkey | `HotKeyManager.swift`, `AppDelegate.act(on:for:)` |
