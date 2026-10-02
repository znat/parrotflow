# Settings

What each setting means and what it costs. With `schema=yes`, `--schema` is the
complete key list. These lists are the fallback for an app without it.

None of these costs anything per dictation unless the line says so.

## Hotkey

```yaml
hotkey:
  key: right_command     # the default
  modifiers: []
  mode: push_to_talk     # or toggle
```

- **A bare modifier**, used alone: `right_option`, `left_option`,
  `right_command`, `left_command`, `right_control`, `left_control`,
  `right_shift`, `left_shift`, `fn`. `modifiers` is ignored.
- **A character key**: `a`–`z`, `0`–`9`, `f1`–`f20`, `space`, `return`, `tab`,
  `escape`, `delete`, the arrows, `home`, `end`, `pageup`, `pagedown`, and
  punctuation names (`comma`, `period`, `slash`, `semicolon`, `quote`,
  `backslash`, `leftbracket`, `rightbracket`, `minus`, `equal`, `grave`).
  **It needs at least one modifier** from `command`, `control`, `option`,
  `shift`. macOS does not give a bare character key to one app. This includes
  the F-keys: `key: f5` with `modifiers: []` is an error. Ask the user which
  modifier they want, or offer a bare modifier such as `right_option`.
- **F-keys on Apple keyboards** are media keys by default, and F5 is often the
  macOS Dictation key. The user may need to hold fn, or turn on "Use F1, F2,
  etc. keys as standard function keys" in System Settings → Keyboard. Say so.
- **`mode`**: `push_to_talk` records while held. `toggle` starts on one press
  and stops on the next. A bare modifier wants `push_to_talk`: on `toggle`,
  every use of right ⌥ to type an accent would start recording.
- `hotkey.release_tail_seconds` (default 0.3): keeps recording this long after
  the key is up, so the last syllable is not cut. Push-to-talk only.
- `hotkey.press_delay_seconds` (default 0.18): a bare modifier must be held
  alone this long before it counts. That is what stops ⌘S from opening the
  mic. Raise it if a shortcut still starts a dictation.
- A combo another app already owns fails to register. The menu bar says so.
  Pick another.

**Tap the key** (bare modifiers only): a short tap brings the pill back with
its chips. Tap, then hold: speak an edit about the selection or the last
dictation. A combo like ⌃F5 has no taps, and neither does `release_tail_seconds`
on `toggle`. When moving from a bare modifier to a combo, tell the user they
lose the taps.

`--check-config` prints the result on its `hotkey` line, e.g.
`✓ hotkey ⌃F5 (toggle, Carbon)`.

## Where the text goes

- `transcription.insert_mode`: `paste` (default) types into the front app and
  needs Accessibility. `clipboard` only copies, needs no permission, and the
  user presses ⌘V.
- `transcription.rewrite_line` (default on): in terminals only, a correction
  clears the input line and retypes it.
- If the cursor moved to another field before the text arrived, the text goes
  to the clipboard with a notice. Nothing to configure.
- ⎋ while recording or transcribing cancels. Nothing is written.

## Languages

```yaml
transcription:
  languages: [en, fr]    # most spoken first
```

Supported: `en`, `fr`. The speech model hears both anyway. This list is what
ParrotFlow detects between, and the first entry is used for transcripts under
four words. One entry turns detection off. Adding `fr` here does **not** add
French dates, numbers or money: see "Adding French" in `rewrites.md`.

## Microphone

```yaml
audio:
  microphones:           # best first; the first one plugged in wins
    - Studio Display Microphone
    - MacBook Pro Microphone
```

- Names come from `"$PF" --microphones`. A fragment works: `AirPods` matches
  "Nathan's AirPods Pro". Case is ignored.
- `microphones: []` means follow the System Settings input. The key missing
  means the menu writes the list the first time it is opened.
- Only ParrotFlow moves. System Settings and other apps are untouched.
- **A Bluetooth microphone loses words**: the headset voice profile carries less
  of the voice and its delay makes the recogniser drop words in fast speech.
  Suggest the built-in or a wired one first.
- `audio.speech_gate` (default on): skips clips with no speech.
- `audio.second_opinion` (default on): decodes each clip again with silence
  padding and keeps the decode that reaches further. Costs about 100 ms per
  dictation and recovers the ~2% that lose words. Needs `speech_gate`.
- `audio.output_dir`: where recordings and the trace go. Default
  `recordings/` beside `config.yaml`.

## Feedback

```yaml
feedback:
  sound: true            # chime when the mic is live and when text lands
  sound_volume: 0.3      # 0 to 1, on top of the system volume
  overlay: true          # the pill; the only on-screen sign that it records
  correct_offer: true    # the chips after a dictation
  theme: system          # or dark, light
  primary_color: "#5F46CA"
  confidence: false      # colour each word by how sure the decoder was
  low_confidence:
    sentence: 0.80       # warn when the whole decode is poor
    word: 0.50           # and it holds a word this bad
    hold_return: 1.5     # hold a reflex Return this many seconds; 0 lets it through
```

- `correct_offer`: after a dictation the pill shows chips: `V` Vocabulary,
  then every transform with `offer: true`. For six seconds that bare letter is
  taken from every app. Pick chip letters people rarely start a word with.
- `confidence` is for a while, to learn which words are weak. It needs
  `correct_offer`.
- `low_confidence` warns on about 1 dictation in 26 at the defaults. Zero for
  either number turns it off. Holding Return needs Input Monitoring.
- `theme` and `primary_color` apply on save.

## Logging

```yaml
logging:
  text: true     # ~/Library/Logs/ParrotFlow.log, 1 MB rolling
  spans: true    # one timeline per dictation in spans.jsonl, rotating at 64 MB
  audio: false   # keep each recording on disk
```

`audio: true` keeps every clip in `recordings/`. Useful before calibrating or
re-running clips. Off by default, because recordings of a voice should not pile
up unasked. The trace, `recordings/trace.jsonl`, is always written.

## Updates

```yaml
updates:
  after_days: 0    # -1 never asks, 0 offers a release the day it ships, 7 waits a week
```

The app asks GitHub's release API whether there is a new release. Nothing about
the user is sent. The cask updates itself, so `brew upgrade` skips it unless
given `--greedy`; the menu's "Check for Updates" is the usual way.

## Retired keys

`--check-config` names these. Do not write them: `llm:` (now `models:` and
`commands:`), `free_form` (now `commands.catch_all`), `prompts:` (now
`transforms:`), `transcription.pipelines` (now one `pipeline:` list),
`transcription.replacements` (now a `replace:` transform or `vocabulary.yaml`),
`transcription.interpret` (now `transcription.sentence_repair`).
