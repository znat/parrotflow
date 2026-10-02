# What ParrotFlow can do

One row per area: what it does, where it is set, what it costs per dictation,
the default, and what a user might ask. The detail is in the reference named
in the last column.

## Dictating

| Area | What it does | Key | Cost | Default | A user might ask | More |
|---|---|---|---|---|---|---|
| Hotkey | The key held (or tapped) to dictate | `hotkey.key`, `hotkey.mode` | none | right ⌘, hold to talk | "Use F5 and toggle" | settings |
| Tap gestures | Tap brings the pill back; tap then hold speaks an edit | `hotkey.press_delay_seconds` | none | on for bare modifiers | "How do I edit what I just said?" | settings |
| Microphone | Which mic records, best first | `audio.microphones` | none | the system input | "Always use my desk mic" | settings |
| Languages | Which languages it detects between | `transcription.languages` | none | `[en, fr]` | "I only speak English" | settings |
| Where text goes | Paste into the app, or copy only | `transcription.insert_mode` | none | paste | "Just put it on my clipboard" | settings |
| Second decode | Recovers words a decode skipped | `audio.second_opinion` | ~100 ms | on | "Make it a bit faster" | settings |
| Cancel | ⎋ while recording stops it, nothing written | — | none | on | "I said the wrong thing" | settings |

## What it writes

| Area | What it does | Key | Cost | Default | A user might ask | More |
|---|---|---|---|---|---|---|
| Sentence repair | Removes a full stop a pause put mid-sentence. English | `transcription.sentence_repair` | none on the path | on | "It breaks my sentences in two" | rewrites |
| Vocabulary | Writes names it was taught, checked against the sentence | `vocabulary.yaml`, `transcription.vocabulary` | none | on | "It never spells Tasmeen right" | spoken-commands |
| Screen spelling | Spells a word the way the screen shows it | `transcription.context_spelling` | none on the path | on | "Write the variable name as it is in my code" | context |
| Fillers | Deletes um, uh, euh | `transforms` `fillers`, `fillers_fr`; `lists` | none | in the pipeline | "Keep my ums" | rewrites |
| Dates and times | "March third at ten fifteen" → March 3 at 10:15 | `dates_en`, `dates_fr` | 30–100 ms | English only | "Make French dates work" | rewrites |
| Numbers | "two hundred forty-three" → 243 | `numbers_en`, `numbers_fr` | 30–100 ms | English only | "Write numbers as digits in French" | rewrites |
| Money | "twenty dollars" → $20 | `money_en`, `money_fr` | 30–100 ms | English only | "Euros too" | rewrites |
| Disfluency | Repeats and false starts: "the the" → "the" | `disfluency` | 40–100 ms | on | "Stop removing my repetitions" | rewrites |
| Your own rules | A word, symbol, pattern, link or format | `transforms`, `transcription.pipeline` | none to ~1.5 s | none | "When I say arrow, write →" | rewrites |
| Per-app rules | A step that runs only in some apps. A chip cannot be limited to an app | `app:` on a step | none | none | "Only in my terminal" | rewrites |
| Formatting into Slack | Lists, bold and links arrive formatted | — | none | Slack only | "Bullets in Slack" | rewrites |

## After a dictation

| Area | What it does | Key | Cost | Default | A user might ask | More |
|---|---|---|---|---|---|---|
| The pill's chips | A letter runs a transform on what was just said, in any app | `feedback.correct_offer`, `offer:`, `key:` | only when pressed | `V` vocabulary, `G` grammar, `S` Slack | "Add a chip to shorten text" | rewrites |
| Grammar | Fixes grammar on `G` | `transforms` `grammar` | ~1.5 s, needs a model | on the pill | "Fix my grammar" | models |
| Slack mentions | Names → @handles on `S` | `transforms/slack_mentions/slack_mentions.py` | 30–100 ms | roster empty | "Tag people in Slack" | rewrites |
| PR links | "PR 123" → a link to your repository | `github_refs` | none | defined, not on | "Link my pull requests" | rewrites |
| Confidence colours | Colours each word by how sure the decoder was | `feedback.confidence` | none | off | "Which words does it struggle with?" | settings |
| Low-confidence warning | An amber pill, and a reflex Return held | `feedback.low_confidence` | none | on | "Stop holding my Enter key" | settings |

## Talking to it

| Area | What it does | Key | Cost | Default | A user might ask | More |
|---|---|---|---|---|---|---|
| Spoken commands | "hey parrot, make that a list" | `transcription.activation_phrases` | ~1.5 s, needs a model | `[hey parrot]` | "Change the wake phrase" | spoken-commands |
| Mid-sentence commands | "… by the way parrot, format that name" | `activation_phrases` | ~1.5 s | needs a second phrase | "Edit while I talk" | spoken-commands |
| Catch-all | Any instruction no transform covers | `commands.catch_all` | ~1.5 s | the default model | "Only allow my own commands" | spoken-commands |
| Undo | "hey parrot, undo" | — | none | on | "How do I take that back?" | spoken-commands |
| Spelling a name | "hey parrot, Tasmin spells T A S M E E N" | `commands.spelling` | ~1.5 s | the default model | "Teach it a name by voice" | spoken-commands |

## Models

| Area | What it does | Key | Cost | Default | A user might ask | More |
|---|---|---|---|---|---|---|
| Local model | Ollama, on this Mac | `models` | RAM; 1.5 s warm, 6.7 s cold | none | "Use my Ollama" | models |
| Cloud model | OpenAI, Anthropic, or a compatible endpoint | `models`, keychain | sends text off the Mac | none | "Use GPT for spelling" | models |
| Which model does what | Per transform, router, spelling, catch-all | `model:`, `commands` | — | the default | "Keep the router local" | models |

## Looking at what happened

| Area | What it does | Key | Cost | Default | A user might ask | More |
|---|---|---|---|---|---|---|
| Log | Every skipped step and every model rewrite | `logging.text` | none | on | "Why did that not run?" | diagnose |
| Trace | One JSON line per dictation, words and timings | always on | none | on | "What does each step cost?" | diagnose |
| Timeline | Where each dictation spent its time | `logging.spans` | none | on | "Why was that slow?" | diagnose |
| Recordings | Keep each clip on disk | `logging.audio` | disk | off | "Keep my recordings" | settings |
| Updates | Offers a new release, and how long to wait first | `updates.after_days` | a request to GitHub | 0 days | "Wait a week before updating" | settings |
| Appearance | Theme and accent colour of the pill | `feedback.theme`, `feedback.primary_color` | none | follows macOS | "Make it green" | settings |
