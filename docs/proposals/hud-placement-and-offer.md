# The HUD, where it goes, and what it offers

Status: **prototyped on `feat/hud-placement-and-offer`, not yet landed.**
Everything below works in a build. None of it has been split into reviewable
pieces; section 7 names the order to do that in.

This is the spec to implement against, PR by PR. Each section says what the
behaviour is, why, and what was measured to get there — because most of these
decisions were arrived at by being wrong first, and the wrong versions are the
part worth writing down.

Design mockup: <https://claude.ai/code/artifact/4b31fdb8-192f-40df-9e42-64efcb93665d>

---

## 1. The pill opens where the words will land

The pill used to appear 96pt off the bottom of the screen, always. It now opens
next to the place the dictation is about to go, and stays there for the whole of
it — recording, transcribing, and the offer, one position.

### Read it at the press, not at the end

This is the whole reason it works. An earlier version read the position *after*
the transcript was inserted and found the words by searching the field for them.
It worked about half the time — six dictations into a terminal, three found and
three fell back.

The cause was not accessibility being unreliable. It was asking at the worst
possible moment: the offer is raised the instant the insertion returns, and an
app redraws when it gets round to it, so half the time the words were not on
screen yet. Everything built on top of that — a 120ms retry, matching
progressively shorter tails of the sentence — was scaffolding around a race.

At key-down there is no race. Nothing has been inserted, nothing is redrawing,
and the caret is sitting exactly where the words are going to start.

### The ladder

In order, first answer wins:

| Rung | Source | What it is |
|---|---|---|
| 1 | `caret` | `AXBoundsForRange` over the selected range, read at the press |
| 2 | `field` | The focused control's own frame, **only if under 120pt tall** |
| 3 | `remembered` | Where the last dictation into this same element landed, **if the pane has not changed since** |
| 4 | `landed` | Worked out after the fact, by diffing the screen |
| — | none | The bottom of the screen, exactly as before |

### Measured, five apps, one Mac

```
iTerm2         AXBoundsForRange → 7x17, one character cell
Terminal.app   AXBoundsForRange → 546x14, the whole line
Notes          AXBoundsForRange → 466x16, the whole line
Ghostty        no bounds (AXError -25213); AXSelectedTextRange is always 0
VS Code        no focused element at all, only a window
```

Two findings that shaped the code:

**`kAXFocusedUIElementAttribute` on the system-wide element returned nothing for
all five apps.** The application element has to be asked directly. Ask both.

**A reported range of `0+0` is not always a caret.** Outlook reports `0+0` in a
text area holding 395,489 characters, and Ghostty reports it always. Believed, it
puts the pill at the first character of the document *and calls that a caret*,
which stops any lower rung from being tried — confidently wrong, and worse than
having no anchor. So a zero range in a field with more than 200 characters is not
trusted. The false negative is a document whose caret genuinely sits at the
start, and it costs nothing: the words are found afterwards instead.

### The row is the caret's; the column is not

Take the vertical position from the text and the horizontal from the **left edge
of the pane**.

Two versions chased the horizontal — centred on the inserted text, then aligned
to where it starts — and both moved for reasons invisible from outside: what an
app returns for a range is a line in one app and a cell in another, a wrapped
sentence starts somewhere other than where it appears to, and a terminal's column
count can only be inferred from the longest line on screen. Each answer was
correct; the result read as random. The left edge of the pane does not move.

### Under, not over

The caret is where you are looking, and a surface above it covers what you just
wrote. When there is no room below — the last line of a full-height window — it
goes above instead.

### Two rungs that need their reasons kept

**`field` is capped at 120pt.** A search box is 22pt tall and its rectangle is as
good as its caret. A terminal's text view is 915pt tall and its rectangle puts
the pill under the *window*, halfway down the screen — a third place for it to
be, and less predictable than either of the other two. Two predictable positions
beat three unpredictable ones.

**`landed` diffs, it does not search.** Capture the field's text at the press,
compare after. Nothing has to match, so it survives a pipeline stage rewriting
the sentence, a wrap putting a newline through the middle of it, and a terminal
padding it with spaces — all three broke the search. Bound the diff at **both**
ends: a spinner or clock ticking above would poison a common prefix on its own,
so take the common suffix too and the change sits between two fixed points. A
change spanning more than half the screen is a repaint, not an insertion, and is
refused.

Then ask the app for the bounds of *that* range. An app can keep no caret and
still measure text perfectly well — Outlook does — and the two failings are
unrelated. Only where there are no bounds fall back to the terminal grid:
`AXLineForIndex` on the last character gives the row count, and the height over
it gives the pitch. Measured on Ghostty at 53 rows of 17.3pt, a real line height
rather than a fit.

**A remembered anchor goes stale, and looks confident while it is.** A terminal
scrolls between dictations, so last time's row belongs to something else — often
the input box you are about to type into, which is where the pill was seen
sitting. Two things invalidate it: the pane's character count must match (one
cheap attribute, and it changes the moment anything is printed) and the landing
must be under a minute old. Refused, the pill opens at the bottom of the screen
and `landed` moves it a moment later — starting nowhere in particular beats
starting somewhere wrong.

**Poll, do not retry once.** Every 80ms for half a second, off the main thread —
Outlook's message pane reported 395,489 characters, copied out of another process
on every look. And nothing waits for it: the offer appears immediately at the old
position and moves if and when there is somewhere better to be, so a miss is not
a delay.

### Ghostty and VS Code cannot be fixed from here

Ghostty has no caret to report at any moment. It *does* know where it is — it
implements `firstRectForCharacterRange:actualRange:` for input methods — but that
is published to the text input system, not to accessibility. VS Code builds no
accessibility tree unless it detects a screen reader.

Two routes were considered and rejected: patching Ghostty upstream (means running
a private build until it lands) and shipping an Input Method Kit component (works
everywhere, but the user must select ParrotFlow as their input source and all
their typing routes through us). Ghostty gets rung 3 and 4 instead.

---

## 2. The dictating HUD

- **Near-black at 95%, no glass.** The last 5% is a hairline of what is
  underneath, so the surface reads as sitting *over* something rather than cut
  out of the screen. Below about 90% the text starts fighting the backdrop,
  which is the thing glass never solved.
- **The plumage loses a step of chroma** against near-black. The mockup's values
  are `#c25f59 / #c29a5c / #5fa383 / #5a89b5`. **Not yet done in the app** —
  `ParrotStyle` still carries the saturated set, which reads as neon on the new
  ground.
- **The meter is a triangle, not a diamond.** Rising to the middle and falling
  away reads as a shape with a peak — something that already happened. Rising
  the whole way reads as still opening, which is what a live microphone is.
- Everything else stands: pulsing dot, live meter, destination icon, and the
  narrow no-icon pill that says the words have nowhere to go.

---

## 3. The offer

### It shows commands, not the sentence

The dictated text is gone from the pill. It was there because the pill appeared
at the bottom of the screen with no connection to the words it was about; sitting
under them, the words are the subject and the pill has only to name what can be
done to them. For the same reason the old wording — *"Wrong? Right ⌘ to fix
it"* — is gone. It was a whole question because it had to be.

### The commands come from the config

```
["Correct"] + transforms where offer: true
```

`Correct` is first and is not a transform: it is the one command about the words
rather than about rewriting them, it needs no model, it cannot fail, and it is
where the selection starts. `offer: true` is a new key on a transform. Off by
default — the offer is on screen briefly and every entry costs the others room.

### Letters and the mouse, and nothing else

| | Does |
|---|---|
| a chip's letter — `C`, `F` | Runs that command |
| a click on a chip | Runs that command |
| hovering a chip | Lights it, and stops the clock |
| `esc` | Dismisses |
| `↩` | Dismisses, and is passed straight through |
| the hotkey | Starts a new dictation — **never** taken by the offer |

Three earlier versions are worth recording, because each was a key taken from
the system that had not earned it.

**The hotkey was the confirm.** That cost it its one job: pressing it while the
offer was up opened a panel instead of starting the dictation you had just
asked for.

**Then `↩`.** Wrong for a plainer reason — it is the key you press to *send*
what you just dictated, so accepting the offer cost you the thing the dictation
was for. It now means the errand is over: the offer vanishes at once, and the
keystroke is passed through untouched. Dismissing is a decision, and a decision
that took two more seconds to show on screen would read as the key not working.

**Then arrows to select and `space` to confirm.** Selecting with one key and
confirming with another is a menu, and this is two buttons. A letter on each
chip says how to press it and the pointer says the same thing again, so the
selection step was ceremony. Space in particular was the worst key to be
swallowing for nine seconds.

**Nothing is preselected.** The highlight is only ever the pointer's mark, and
it does not outlive the pointer — leaving the pill clears it. Nothing runs
without a letter or a click, so a chip lit before you have touched anything is
saying something about a command that is not about to happen.

**The letters come from the config.** `key: f` beside `offer: true`. A command
with no letter is still clickable.

### Taking a key without holding focus

The pill is a `nonactivatingPanel` and never takes keyboard focus — deliberately,
because it appears while you are typing into somebody else's window. A global
monitor can hear a key in that state but cannot swallow one, so a letter would
also be typed into your document. Only a `CGEvent` tap can consume without
focus.

Three fences on the tap, all required:

1. It exists only while the offer is up.
2. It consumes Escape and the letters the offer has claimed, and passes
   everything else through. A **modified** key goes through too — `⌘C` copies,
   `⇧F` types a capital F. Only the bare key belongs to the offer.
3. It carries its own expiry, so if it is ever not torn down the next key past
   the deadline kills it and goes through. It must also handle
   `tapDisabledByTimeout`, or macOS switches it off and the keys stop working
   with nothing in the log.

The failure mode has to be a key that works, not a keyboard that stops.

**The cost of bare letters, stated plainly.** For as long as the offer is up, a
bare `C` or `F` is swallowed. Finish dictating and immediately type a word
starting with one of those and the first keystroke runs a command instead. If
that turns out to bite, the fix is to dismiss the offer on the first keystroke
that is not one of its own, which cuts the exposure to a single keypress.

### The mouse

The pill ignores the mouse in **every state but this one**. It sits over
whatever you are working in, so a surface that swallowed clicks for the length
of a dictation would be a hole in your screen — but the offer is made of
buttons, and a button you cannot click is a picture of a button.

Two details that are not optional:

**The chips are not `Button`s.** The pill is never the key window, and SwiftUI
draws controls in an inactive window at reduced emphasis — so the lit chip came
up washed out until the pointer landed on it, which read as nothing being lit at
all. A tap gesture with an explicit `contentShape` draws the same whatever the
window is doing.

**Hover is bound to the whole pill, not to each chip.** Moving from one chip to
the other must not read as leaving.

### A command substitutes directly

No preview, whatever the transform's `confirm:` says. That flag is right for its
own case — reached by voice, over a selection you cannot see, a dialog is the
only thing between a model and text you did not check. From the offer there is
nothing left to confirm: the pill is under the sentence, you can read it, and you
chose the command with a key.

It goes down the same path a correction takes, and inherits its care: hand focus
back first, replace rather than paste after, refuse to write unless the field is
still the one that was dictated into, and update `lastTranscript` so a second
command works on the new text.

The target is captured when you **choose**, not when the model answers. A grammar
pass takes seconds and focus can move; the sentence it rewrites must be the one
that was on screen when you pressed the key.

---

## 4. Correct opens the correction panel

Not the preview panel. The offer names one thing and that is the surface that
does it.

**Save is deliberately unwired.** It logs what it would have written and does
nothing. Where a rule should go is settled — see the end of this section — but
writing it is a piece of work of its own.

### The panel, now built

Prototyped in `CorrectionSpans.swift`, `CorrectionSpansView.swift` and
`CorrectionPanel.swift`.

**The word field is AppKit, and has to be.** Half the gestures are about *where
in the word* the caret is — space splits at it, backspace joins only from the
start, the arrows cross only from an edge — and SwiftUI's `TextField` will not
say. `NSTextField` hands over its field editor, which reports its selection
exactly. Commands are intercepted through
`control(_:textView:doCommandBy:)`.

**`Context` is already taken.** The app has a `Context` of its own, so a bare
`Context` inside an `NSViewRepresentable` resolves to that and conformance
fails with a message about a "non-matching type" that names the right method
and the wrong reason. Spell out `NSViewRepresentableContext<…>`.

A rule's left side is a **span**, not a word. A span owns two lists — the words
that were heard and the words that replace them — and that is what lets one word
become two and two become one without either side losing the other.

Everything below the panel already works this way: the fuzzy pass scans two-word
windows, `Vocabulary.widerSpans` offers the wider span for a name the decoder
split, and `autoApplies` has a branch for exactly this. The panel is the only
place still counting in words.

Four gestures, all of them ones a text field already has:

| Gesture | Does |
|---|---|
| type | change a word |
| `space` | split one word into two, both under one heard term |
| `⌫` at the start | join a word to the word before |
| clear the field | remove the word |
| `⌘Z` | undo |

Details that matter:

- **The heard text sits above the word it became**, struck through, absolutely
  positioned so a word changing never moves the line it is in.
- **State lives on the underline.** Faint is untouched, sky is where you are,
  leaf is what will change. The bar also runs unbroken under a multi-word span,
  which is how "these are one thing you said" is said without adding anything.
- **Clearing a word just removes it.** It does not nest under the word before,
  and it teaches nothing — a rule mapping an ordinary word to nothing would fire
  on every dictation.
- **Arrows keep their edge.** From before the first character, `←` goes to before
  the first character of the word to the left; from after the last, `→` goes to
  after the last character of the word to the right. Tab is the exception: it is
  arriving somewhere to change it, so it lands on the last character.
- **The keys hint appears only after the first edit**, with a single linear
  left-to-right sweep across it — an event, not an ambience.
- **No gesture of its own.** An earlier pass had "click a struck word to release
  it"; needing a sentence to explain it was the argument against it. `⌘Z` is the
  only way back.
- Each heard word keeps its own trailing punctuation, so folding `his.` into
  `praise` does not cost the sentence its full stop.

### Where a taught rule should be written

A single term of five letters or more goes to `vocabulary.yaml` as a
pronunciation — which makes it a sound the spotter can search for **and** a rule,
since `Config.vocabularyRules` turns every pronunciation into one. Anything else
is a plain rule in `config.yaml`.

Today the panel only ever writes `transcription.replacements` in `config.yaml`.
Nothing in the app writes `vocabulary.yaml`; `ForgetCommand` only removes from it.

---

## 5. Also here

**A Bluetooth microphone is warned about, once.** Said instead of the offer, the
first time a given input is used — the moment it means something, because you
have just watched a transcript come back and if it lost your trailing words this
is why. At launch it would be advice about a thing you were not doing; every
dictation would be nagging.

Detected by asking CoreAudio for `kAudioDevicePropertyTransportType`, not by
matching names. A list of brands is wrong the day somebody buys a headset nobody
thought of, and it was the wrong question anyway: what costs you the ends of
your words is the transport, and a Bluetooth voice profile narrows the band and
gates quiet sound whatever is printed on the case.

> *<device> drops soft and trailing words — the built-in mic hears you better*

## 6. Not done

- The plumage is still the saturated set; only the pill went near-black. The
  correction and preview panels are still glass, so the surfaces have drifted
  apart — which is the one thing `ParrotStyle` exists to prevent.
- The correction panel's Save writes nothing.
- The launch panel from the design pass is not built at all, and its lettering
  was never chosen — Serif (New York, `design: .serif`), Rounded, or Wide caps.
- `--panels` sheet has not been reviewed since the pill changed shape.
- **A pane read after the paste is not a baseline, and nothing here can tell.**
  The `landed` rung takes the pane at the press on a background queue. A short
  dictation can be transcribed and written before that copy finishes, and then
  the baseline already holds the words: every retry compares equal strings, the
  diff reports the screen unchanged, and the pill never aims. It is not fixed
  here because the moment cannot be observed. `TextInserter` posts a ⌘V and the
  target app reads the pasteboard when it gets round to it, so no instant in
  this process means "the words are on screen" — a clock stands in for it badly
  in both directions, and rejecting on one throws away the baselines that were
  in time. A real fix is the insertion reporting when the target *took* the
  text, which belongs ahead of this work rather than inside it. The cost
  meanwhile is the documented fallback: the pill stays where it opened, which
  is where it opened before any of this. It is not a wrong position.
- **`lastTranscript` and `focusAtPress` are one slot each.** Dictations overlap,
  so a later one moves them under an earlier one. The offer reads neither now —
  it carries the transcript and the press it was raised for. Every other path
  that reads them is untouched and has the same shape of race.
- **None of this has been seen running.** Ghostty and Outlook need a person in
  front of them; the numbers in this section are the spike's. Whether Ghostty
  answers `AXVisibleCharacterRange` is unknown, and the grid rung needs it —
  without it that rung refuses and Ghostty falls back to `remembered`, or to
  the bottom of the screen.

## 7. The PRs

Fourteen, in this order. The rule for the boundaries: **each one is safe to
merge alone and can be judged on its own**. Where that meant splitting something
that was written together, it is split — the spike is one commit and does not
have to stay that shape.

Two run first because they are independent of everything else and one of them is
a live bug. Two more are independent enough to reorder if something is urgent:
**11** and the pair **1–2**.

### Ground

| # | Title | Why it is separate |
|---|---|---|
| 0 | `docs: what the HUD does, and where it goes` | This file. Lands first so every PR after it has a place to be argued against. |
| 1 | `fix: a read-back that undid a correction that had worked` | `Surface.swift` only. A real bug with a real reproduction — Outlook, 395k characters, the paste landed and the check said it had not. Nothing to do with the HUD; do not hold it behind this stack. |
| 2 | `feat: --peek says where the caret is` | `PeekCommand` only. Small, and it is the tool a reviewer needs to check #3 on their own machine. |

### Where the pill goes

| # | Title | Contains | Depends on |
|---|---|---|---|
| 3 | `feat: the pill opens where the words will land` | `CaretAnchor` rungs 1–2, the `0+0` trust rule, `across`, `flipped`, `PillHUD.aim`/`beside`, the press-time read | 2 for review |
| 4 | `feat: the pill finds the words in an app with no caret` | `landed` — the diff, the poll off the main thread, the terminal grid — and `remembered` with its staleness check | 3 |

**Why the split.** #3 is a complete feature on its own: it works in iTerm2,
Terminal.app, Notes and ordinary fields, and everywhere else it falls back to
exactly today's behaviour, so the blast radius is nil. #4 is the half with the
guesswork in it — a diff, a poll, an inferred row pitch — and it deserves its own
argument. Landing them together would make one reviewer judge both.

### How it looks

| # | Title | Contains |
|---|---|---|
| 5 | `feat: the floating surfaces are near-black` | `parrotSurface(solid:)`, the pill, **and** the correction and preview panels, plus the plumage's step of chroma |

**All the surfaces in one PR, not just the pill.** Drift between them is the one
thing `ParrotStyle` exists to prevent, and the spike has already caused some: the
pill is near-black and the panels are still glass. A PR that fixed only the pill
would be shipping that drift on purpose.

### What the pill offers

| # | Title | Contains | Depends on |
|---|---|---|---|
| 6 | `feat: the offer names what can be done` | Chips, `offer:` and `key:` in config, no sentence, no preselection, clicks, `ignoresMouseEvents` per state | — |
| 7 | `feat: the offer takes its own keys` | `OfferKeys` and the tap, letters, `esc` consumed, `↩` watched, the hotkey freed | 6 |
| 8 | `feat: the offer fades rather than vanishing` | Linear decay, nine seconds, held by the pointer, cut by a decision, the generation guard | 6, 7 |
| 9 | `feat: the offer follows every dictation` | All four endings; the clipboard messages move to the menu bar | 6 |
| 10 | `feat: a command from the offer rewrites in place` | `runOfferedTransform`, no preview whatever `confirm:` says | 6 |

**Why 6 before 7.** #6 is clickable on its own, so it is a working feature
without a system-wide event tap in it. #7 is the one PR that swallows keys from
every app on the machine, and it should be reviewed as exactly that and nothing
else.

### The rest

| # | Title | Notes |
|---|---|---|
| 11 | `feat: a Bluetooth microphone says so, once` | `Recorder.inputIsBluetooth` and `MicNotice`. Independent — reorder freely. |
| 12 | `feat: the correction panel works in spans` | `CorrectionSpans`, `CorrectionSpansView`, `CorrectionPanel`, the panels sheet. Save still writes nothing. The largest of these; expect it to want a second pass. |
| 13 | `feat: teaching a word writes it down` | Save. A single term of five letters or more becomes a pronunciation in `vocabulary.yaml` — which `Config.vocabularyRules` turns into a rule as well — and anything else is a rule in `config.yaml`. Nothing in the app writes `vocabulary.yaml` today. |

### What each one has to show

- **3, 4** — the `pill:` log line, and which rung answered, in at least a
  terminal and a native text field.
- **5, 6, 12** — `--panels-sheet`. Drift between surfaces is obvious side by
  side and invisible a week apart, which is what that sheet is for.
- **7** — that a modified key still reaches the app, and that the tap is gone
  the moment the offer is.
- **9, 10** — a dictation down each of the four endings.
- **13** — the file on disk, and a second dictation proving the rule fires.
