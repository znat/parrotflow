# Proposal: trace v3 — one timeline per dictation

**Status.** Designed 2026-09-05 to 2026-09-07, written 2026-09-07, rebased onto
main on 2026-09-12. This document is the design; what shipped differs from it in
the ways noted under "What shipped".

The stage called `interpret` throughout this document is named `sentence_repair`
since #306. The old spelling is still read from a config. Every mention below is
left as it was written, because the measurements were taken under that name.

**Goal.** A dictation can be traced end to end: every step, every model call,
every change to the text, with real timings. The trace is a feature, not a
developer's private artefact — anyone running ParrotFlow can open one, and a
bug report can carry one.

**Why now.** The app measures a lot and keeps almost none of it. Three quarters
of a dictation's wall clock is not recorded anywhere, and the parts that are
recorded cannot be lined up against each other.

---

## What today's files can and cannot answer

`ParrotFlow.log` is not a timing source. `Log.swift:23` formats to
`yyyy-MM-dd HH:mm:ss` — one second of resolution — and the file truncates
itself at 1 MB (`Log.swift:58`). It is prose for reading over someone's
shoulder.

`trace.jsonl` is the corpus. It times every pipeline step around the same span
for a table, a script and a model call (`Pipeline.swift:817-843`), records a
step that declined with its reason (`:797`), and keeps `asr.processing`,
`asr.duration`, the VAD segments and the two `capture` numbers.

What is missing, measured on the dev corpus of 23,545 lines:

| Gap | Where |
|---|---|
| No absolute start | `at` is evaluated in `Trace.record`'s `defer`, so it is when the pipeline *ended*. The press's wall clock is never stored, and `stamp()` uses `.withInternetDateTime` — no fractional seconds. End-to-end latency is not reconstructable. |
| The speech gate is untimed | `runSpeechGate` (`Transcriber.swift:772`) reads the whole clip and runs VAD with no clock. The 53 lines carrying `capture` but no `asr` are gate rejections: the verdict is kept, never its cost. |
| Model load is untimed | `prepare(config:)` can download and load ~1 GB. |
| Only the winning decode is recorded | `recordASR` fires once (`Transcriber.swift:569`). A dictation that ran the long-pause retry (`:426`) and both padded arms (`silenceRetryPads = [0.5, 1.0]`, `:1136`) reports one `processing` figure. These are the largest untimed cost in the app. |
| A failed arm vanishes | The arm catch blocks log and return nil (`startSecondOpinions:699`). An arm failing every time is invisible in the file; it simply never wins. |
| Delivery is outside the trace | `Trace.record` closes at `AppDelegate.swift:2179`; `finishTranscription` (`:5285`) runs after it. |
| Sub-steps are one number | `vocabulary` publishes `sound_ms` and `gate_ms` (`Pipeline.swift:1092-1093`), but `gate_ms` covers the slot gate (`:1198`) and the sentence gate (`:1209`) together. `interpret` measures every boundary read (`SentenceJoin.swift:403`, `:419`) and throws the number into a log line. |

Two data-quality problems in the file itself:

- `asr.duration` is 0 on 167 of 637 recent lines. It is exactly the clips over
  15 seconds: all 167 have `vad.total` ≥ 15.1s, and 469 of 470 good lines are
  under it. FluidAudio's chunked path does not fill `duration`.
- `capture` is on 690 of 8,343 live dev lines and 0 of 116 release lines. The
  release build predates the field.

---

## Decisions already taken

Settled 2026-09-05 to 2026-09-07. Do not relitigate.

| | |
|---|---|
| Shape | One timeline per dictation: a flat array of spans threaded by `parent`. Not a stage list with model calls beside it. |
| Two files | `trace.jsonl` stays the corpus and keeps every key it has. `spans.jsonl` is new, capped and rolling. |
| Diff | Stage `before`/`after` become an `edits` array. |
| Version | `Trace.version` → 3. |
| Old lines | Never converted. Nothing in v3 is derivable from v2 except `edits`, and a line stamped v3 with no spans breaks the contract the version field exists to keep. |
| Opening one | A `command:` transform with `offer: true` and `key: t`. No new config grammar, no new primitive beside transforms. |
| Shipping it | Documented in `docs/cli.md`, never in `config.example.yaml`. No default pipeline changes and no install gains a chip. |
| Viewer | Chrome Trace Event JSON, exported by a command, opened in Perfetto. Not stored in that format. |
| Audience | Everyone, not the maintainer. Defaults, read path and redaction follow from that. |

---

## The two files

The split is on retention, not on compatibility.

`trace.jsonl` answers questions asked across every dictation ever given — what
does the vocabulary stage cost, which words does the decoder doubt, how often
does an arm win. `Trace.swift` says why it has no size cap: *"This is the
corpus, not a debug buffer."*

A span tree answers one question about one dictation, it is only ever wanted
for something recent, and it is where the bytes are. The dev corpus is 90 MB
over 34 days — about 970 MB a year. Spans roughly double a line. In their own
file they can be capped and deleted; inside `trace.jsonl` nothing can ever be
deleted again.

Joined by `wav`. Both are JSONL, appended with `O_APPEND` as `Trace.append`
already does.

---

## `trace.jsonl` v3

Keeps every key. One removal, the rest additive — so every `jq` recipe in
`docs/cli.md` that does not read `before`/`after` keeps working.

**Removed:** `stages[].before` and `stages[].after`.

**Added:**

| Field | What |
|---|---|
| `stages[].edits` | See below. |
| `stages[].parts[]` | `{name, seconds, note}` — the sub-steps of a stage. |
| `capture.at` | The press, in wall clock, with milliseconds. |
| `capture.stopped` | Key up, seconds from the press. |
| `vad.seconds` | What the gate cost. Distinct from `vad.total`, which is audio. |
| `prepare` | `{seconds}`, absent when the models were warm. |
| `decodes[]` | `{pad, seconds, reached, taken, error}`, one per arm. |
| `asr.arm` | Which row above won. |

The file gets about 20% **smaller**. Stage `before`/`after` is 24.7% of it
today, and only 6.4% of stages change the text at all — so 93.6% of those
copies are one sentence written twice to say nothing happened, which
`changed: false` already said.

Fix `asr.duration` on clips over 15 seconds while here: fall back to the clip
length the app already knows.

---

## `edits` — the diff

One shape, on any node that changed the text.

```jsonc
{ "at": 71, "was": "is is", "now": "is" }
```

`at` is a character offset **into that node's input**, not into the running
text — so a node's edits apply right to left, or left to right with a running
delta. Characters, not bytes, matching `Trace.Edit.range`, which is already
"in characters".

**The invariant.** `asr.text` with every edit applied in order equals `final`.
That is checkable, and the check is a test. Nothing today ties the stage list
to the two anchors.

It requires that text-editing nodes never overlap. True now — only pipeline
stages edit, and they run in sequence. Write it down, because the day something
edits in parallel the invariant is how anyone finds out.

`scripts/watch.py:51` already computes a word-level diff at read time, with a
comment complaining that seven stages printing input and output is fourteen
copies of the sentence. This moves that into the file and makes it exact, which
matters because `interpret` and `punctuation` change punctuation and a word
diff cannot see it.

---

## `spans.jsonl` — the timeline

One line per dictation.

```jsonc
{ "v": 3, "kind": "dictation",
  "t0": "2026-09-05T17:26:35.412Z",
  "wav": "parrotflow-2026-09-05T19-26-35-8716DE1C.wav",
  "source": "live", "lang": "en",
  "app": { "name": "Ghostty", "bundle_id": "com.mitchellh.ghostty" },
  "spans": [ /* ~30 */ ],
  "final": "…" }
```

### The span

```jsonc
{ "id": 12, "parent": 9, "name": "sound", "kind": "model",
  "at": 14.940, "dur": 0.817,
  "model": "kokoro", "runtime": "coreml", "n": 12,
  "out": { "over_floor": 0 } }
```

Six fields carry the timeline; everything else is payload keyed by `kind`.
`at` and `dur` are seconds from `t0`. `t0` is the press for a live dictation,
and the start of the traced body for a `--transcribe` replay, which was never
pressed for.

Flat with a `parent`, not nested, for three reasons. The decode arms
**overlap**, so they have no single place in a tree. A span finishes at a
different time from its parent, so a writer that appends is simpler than one
that reaches into a nested object. And a flat array is one query away from
every question, where a nested one needs a different path per depth.

### Two time domains

**A span is something the app spent wall-clock time doing.** Word timings and
VAD segments are positions **in the audio**. They both look like
`{start, end}` and they mean nothing alike — 19 word "spans" on a timeline
would draw a picture that is false.

Word timings and VAD segments stay as payload on the spans that produced them.
They never become spans.

### Span kinds

| `kind` | Payload |
|---|---|
| `dictation` | the root, id 1, parent null |
| `record` | `engine`, `first_sample` — press to key up |
| `gate` | `speech`, `total`, `segments` |
| `decode` | `pad`, `text`, `confidence`, `reached`, `taken`, `words`, `error` |
| `stage` | `vars`, `skip` |
| `part` | `note` — a sub-step that calls no model |
| `model` | `model`, `revision`, `runtime`, `units`, `n`, `cached`, `loaded`, `in`, `out`, `error` |
| `deliver` | `route`, `app` |

A skipped stage is a span with `dur: 0` and a `skip` object, so the stage list
stays complete in one place.

### Where the spans come from

| Span | Call site |
|---|---|
| `record`, `deliver` | `AppDelegate.swift:2113`, `:5285` |
| `gate` | `runSpeechGate`, `Transcriber.swift:772` |
| `decode` × n | first pass `:406`, long-pause retry `:426`, padded arms `:677`, empty-decode retry `:480` |
| `stage` × n | the pipeline loop, `Pipeline.swift:843` |
| `part` in `vocabulary` | `exact`, `fuzzy`, `sound` (`:1140`), `slots` (`:1149`), `slot_gate` (`:1198`), `sentence_gate` (`:1209`) |
| `part` in `interpret` | `scan`, `pauses`, and one `read` per boundary — `SentenceJoin.swift:403-419` already computes that number |
| `model` | wherever a model is actually called, at whatever depth |

### Model spans

`model` and `revision` both. `Trace.ASR`'s comment says Parakeet exposes no
revision so none is invented, but `SlotModel` pins `a983542`,
`SentenceReadings` pins `f493c65` and `WordVectors` pins `6c3ae70`. A silent
model swap between two runs is otherwise invisible.

`units` — `ane`/`gpu`/`cpu` — because the ANE costs real fidelity and 74% of
slot fillers differ from PyTorch. If a number moves, this is the first thing to
check and it is nowhere on disk today.

`loaded` — seconds this call paid loading. `SentenceReadings` is 320 MB and a
1.3s load. A stage that includes a cold load is not comparable to one that does
not, and today they look identical.

`cached` — a G2P call that hits the `NeuralPhonemes` cache costs ~0 ms. Without
this a cache hit and a fast model are the same row.

`error` — **a failed call is still a row.** This is the one that fixes a real
blind spot.

Three rules on `in`/`out`, or the payload becomes the file again:

1. **Never store a vector.** Store the decision it produced.
2. **Never store a prompt body.** Name and hash. The hash is what says the
   prompt changed between two runs.
3. **Never repeat the transcript.** A call stores the clipped span it looked
   at, not the sentence around it.

### What it draws

The dictation of 2026-09-05 17:26:35, real numbers except gate and delivery:

```
t0 = press                                                        16.05s total
├─ record                    ████████████████████████████████████████  14.523
│    engine ready 0.232 · first sample 0.361
├─ gate            silero-vad                                       ▏  0.094
├─ decode          parakeet · first pass · reached 14.08            ▏  0.318
├─ pipeline                                                         ███ 1.033
│  ├─ interpret                                                     ▏  0.004
│  ├─ context                                                       ▏  0.001
│  ├─ vocabulary                                                    ██  0.822
│  │  ├─ exact                                                      ▏  0.001
│  │  ├─ fuzzy                                                      ▏  0.003
│  │  ├─ sound       kokoro · n=12 · 0 over floor                   ██  0.817
│  │  └─ slots       0 slots from 0 proposals                       ▏  0.001
│  ├─ numbers                                                       ▏  0.003
│  ├─ punctuation                                                   ▎  0.107
│  ├─ code_identifiers   ⨯ skipped: when_unmatched                  ·  —
│  ├─ repetitions        "is is" → "is"                             ▏  0.045
│  └─ join                                                          ▏  0.050
└─ deliver         paste → Ghostty                                  ▏  0.081
```

80% of the pipeline went to a phoneme pass over 12 terms that matched none, and
the only change to the transcript was five characters. Neither fact is
available today.

---

## Opening a trace

### The transform

No new primitive. `command:`, `offer:` and `key:` already exist
(`Config.swift:780-782`), the chip row is built from them
(`AppDelegate.swift:513-515`), and `OfferKeys` claims the letter.

**It does not ship in `config.example.yaml`.** No default pipeline gains a
stage, and no install gains a chip. It is documented in `docs/cli.md` as
something to paste into your own config:

```yaml
transforms:
  - name: trace
    description: open this dictation's trace
    offer: true
    key: t
    command: parrotflow --trace-view
```

`returns: none` is **not** needed. `finishOfferedTransform:4574` already
declines to write back when the text is unchanged:

```swift
guard cleaned != before else { … return }
```

So a command that does its side effect and echoes stdin is safe. The failure
path is safe too — `runOfferedTransform:4522` fails open, *"losing a rewrite
costs a second attempt; losing the sentence costs the sentence."*

One visible seam. `finishOfferedTransform:4574` flashes
`"trace: nothing to change"` after every open — true about the text, wrong
about what happened. Nobody is given this by default, so it is not a shipped
defect, but it is the first thing anyone who adds the transform will report:
a `done:` key, one optional string of the same kind as `display:`. PR 3.

The command reads `spans.jsonl` itself, so it needs nothing from `ctx`, and
`ctx.trace` stays nil at chip time without anyone caring. The same command runs
from the terminal and from a `when:` condition.

Selecting the last one is not `tail -1` — the file has dictations, corrections,
edits, and a concurrent `--transcribe` sweep by design:

```sh
jq -c 'select(.kind=="dictation" and .source=="live")' spans.jsonl | tail -1
```

### The letter

`t`, for trace.

`OfferKeys`' own doc warns that the offer holds its letters for nine seconds
after every dictation, and *"a sentence that happens to start with a chip's own
letter — `V` for Vocabulary — still runs that command on its first keystroke."*
`t` is a common opener — "the", "this", "that" — so a misfire is likely.

It is accepted here for two reasons. Nobody gets this chip without adding it, so
the exposure is the person who chose it. And the misfire is benign: the command
is read-only and the worst it does is open a viewer. A destructive chip would
need `x` or `z`, which nothing starts with.

The docs entry says this, so whoever pastes it in knows what they are choosing.

### The viewer

Chrome Trace Event JSON, exported by `--trace-view`, opened in Perfetto.

| Ours | Trace Event |
|---|---|
| `at` | `ts`, × 1e6 |
| `dur` | `dur`, × 1e6 |
| `name` | `name` |
| `kind` | `cat` |
| payload | `args` |
| — | `ph`, always `"X"` |
| `parent` | dropped — nesting is inferred from time containment on a `tid` |

Overlapping siblings need their own `tid`, so each decode arm is a lane. That
is the picture the arms are worth drawing, and it is why Perfetto beats
speedscope here: speedscope is a flamegraph and wants a stack, which
overlapping arms do not have.

Emit `visStart` at the `record` span's end, so the view opens on the 1.5s that
matter instead of a hairline beside 14.5s of held key.

Deep linking, checked against Perfetto's docs:

- `?url=` is **HTTPS only — not localhost, not HTTP, not `file://`** — and
  needs CORS. Useless here, and wrong for transcripts.
- **postMessage** is the supported local path. Open `ui.perfetto.dev`, send
  `PING` until it answers `PONG`, then post
  `{perfetto: {buffer, title}}`. `window.open` must follow a user gesture, so
  the shim is a page with a button — and that button is where the app says what
  it is about to do, so the gesture Perfetto requires and the consent
  `BugReport` requires are the same click. Their words: *"Traces pushed via
  postMessage() are kept only in the browser memory/cache and are not sent to
  any server."*

So `--trace-view` writes the Trace Event file and a small HTML shim beside it,
and calls `open`. Storing Trace Event as the corpus format would be the
mistake: `args` is untyped, there is no place for the edit invariant, and every
recipe would be reaching into a shape that exists to make a flamegraph draw.

---

## It is a feature, not a debug artefact

This reframing arrived last and changes three things.

### Defaults

`logging.spans`, beside `text` and `audio` in `Config.Logging:2574`. On for
everyone, not `AppVariant.isDev`.

With the chip no longer shipped, the bug report carries this default on its own:
you cannot turn a flight recorder on after the crash. A trace has to already
exist on the day someone hits the thing they are reporting, and that is the only
reason the setting is on for people who will never open one themselves.

The cap is what makes that safe, and the config comment has to state it.

**Deferred in the first cut.** With no cap, nothing is evicted, so a replay
writing a timeline costs only bytes — and it is how the feature is tested from
a terminal. The rule below lands with the rotation.

**A `--transcribe` sweep must not write spans.** `Trace.append`'s doc says the
sweep writes to the corpus concurrently by design, and that is right for
`trace.jsonl`. For a capped `spans.jsonl` it is not: one sweep over 20,000 clips
evicts every live dictation, and "re-open the last one" opens a replay. Either
the sweep writes no spans at all, or the cap counts only `source: live`. The
first is simpler.

Still to decide: the cap. Something like 2,000 dictations or 50 MB, oldest
dropped. Rotation is a rename, not `Log.write`'s truncate-to-zero — truncating
loses the line you just wanted. One loss case remains: another process holding
the old descriptor keeps writing to the renamed inode. That costs a line, not a
crash.

### The read path

Perfetto is reasonable for this audience — ParrotFlow's users dictate into
terminals and editors, and the config has `code_identifiers` and `github_refs`
in it. But opening a Google-hosted page with a dictation in it is a statement
the app has to make before it makes it, not after.

`BugReport`'s first rule applies verbatim: *"Nothing is copied or opened before
the person has read it — this app hears what people say, and the log can carry
a transcript."*

### Redaction, and the bug report

**A timing-only trace is fully shareable.** Timings survive redaction perfectly;
text does not. Drop every text field — `text`, `final`, `edits[].was/now`,
`words`, `in`, `out`, `app` — and the shape, the durations and the model calls
all survive. Someone can send a timeline with no words in it, and it still
shows that the sound pass took 817 ms.

That is the strongest use of this feature. `BugReport.swift` already assembles
version, machine, permissions and 50 prose log lines, already writes every home
path as `~` in one place, and already has `redacted(_:)` at `:116`. A redacted
trace is the attachment that makes a report actionable, and it is what turns
this from the maintainer's tool into everyone's.

Proposed: `--trace-view --redacted`, and a checkbox in the bug report window.

---

## Risks

**Everything here is write-only.** No span, no part, no edit is read back by
the transcript path. A bug produces a wrong picture, never a wrong sentence.
The one exception is a transform reading `ctx.trace` and acting on it, which is
opt-in.

Two real crash vectors, both on the path every user runs:

1. **String index math in `edits`.** Swift traps on an out-of-range
   `String.Index`. Derive edits from a diff that never indexes back into the
   string, or clamp every offset before use and drop the edit rather than trust
   it. This is the top review item, and it is where PR 1's effort actually goes:
   the work is coalescing per-character `CollectionDifference` operations into
   `{at, was, now}` runs stated in the node's *input* coordinates. The diff is
   not the easy part of that PR.
2. **Concurrent appends from the decode arms.** `stages` is appended only by
   the pipeline loop today, sequentially. Per-arm spans mean several tasks
   appending at once. `Collector` is `@unchecked Sendable` with an `NSLock` and
   every existing recorder takes it; the rule has to hold for the new ones. An
   unlocked array append from two threads is memory corruption.

Everything else fails silent if it copies `Trace.append`: `guard let
directory`, `try?` on the directory, `open()` < 0 → return, one `write`.

Bound the collector: a cap on spans per dictation, so a pathological clip
cannot grow the array without end.

---

## What shipped

The open decisions, as they were settled.

| | |
|---|---|
| The cap | 64 MB on `spans.jsonl`, rotated by renaming to `spans.1.jsonl`. A rename, not `Log`'s truncate-to-zero, which would throw away the timeline you were about to look at. |
| `sound` | One span with a note, not one per term. |
| `final` | Kept. Derivable, but it makes every "what did it say" query a one-liner and it is the check on the invariant. |
| `deliver` | Its own line in `spans.jsonl`, joined by `wav`. `Trace.record` still appends in its `defer`, so "append on exit, even if it threw" is unchanged. |
| Span collection | **Always on.** Only the *file* is behind `logging.spans`. `parts` and `decodes` in `trace.jsonl` are read off the same spans, so the two files cannot disagree about what a step cost. |
| The bug report | No checkbox. `--bug-report` gains a wordless timeline, rendered by the same code as `--trace-view` with `notes: false`. |

### The viewer is text

The design assumed Perfetto. What shipped renders the timeline as text, and
`--perfetto` is a secondary export for when you want to zoom.

Two measurements pushed it there, both worth keeping written down:

- **Perfetto will not take a trace from a `file://` page.** Its embedding guide:
  *"Serve your host page over http(s), not file://. The embedding protocol
  relies on postMessage between windows, which browsers disable for file://
  origins."* So a page opened off disk cannot hand it anything.
- **`?url=` cannot reach a local file either.** Tested: a loopback server with
  `Access-Control-Allow-Origin: *`, reachable by `curl`, and Perfetto answered
  *"Could not fetch the trace at http://127.0.0.1:8779/trace.json: TypeError:
  Failed to fetch."* An `https` page will not fetch `http://127.0.0.1`. The
  only URLs it accepts are public HTTPS ones, which would mean putting
  dictations on a public host to look at a chart.

Working around that took a loopback HTTP server inside the command, serving one
page that did Perfetto's `PING`/`PONG` handshake. It worked — verified end to
end in a browser — and it was ~130 lines to put a chart behind a random
localhost port. Text is smaller, and it does three things the chart cannot:
it **diffs**, it pastes into an issue, and it needs no network.

### Other departures from the design

- **No `record` span.** Holding a key for fifteen seconds is not work the app
  did, and drawn to scale it squashes the second that is. Zero on the timeline
  is the key coming *up*; what the press cost stays in `capture`.
- **`load models` is a span**, which the design did not have. Measured at 29.9s
  on the first dictation after a launch — recorded only as a field, it left the
  timeline with a half-minute hole where the entire wait was.
- **Decode arms are numbered** — `decode pass 1/2/3` — with the padding in the
  note. How far the silence moved is a detail of the third one; how many
  decodes you paid for is the thing being read.
- **Renderings go to the temporary directory**, named after the clip. A fixed
  name means the second press rewrites a file an editor already holds, and an
  editor shows you the buffer it loaded — which produced a real case of reading
  a sixteen-minute-old trace and believing it was the current one.

Two things in this document were **not** built:

- **A `model` span around each model call.** The spans go as deep as a stage's
  sub-steps. `sound`, `slot_gate` and `sentence_gate` are `part` spans, because
  they wrap a step that *may* call a model rather than the call itself.
- **`revision`, `units`, `loaded`, `cached`, `n`, `in`/`out` on a span.** They
  need the per-call spans above. `note` carries what a step found out, in one
  string.

## Still open

1. **The cold start, and what the pill says during it.** A dictation that waits
   on `prepare()` shows "Transcribing…" for as long as it takes —
   `AppDelegate.swift:2095-2103` knows only "Downloading …" and "Transcribing…",
   and loading from disk is neither. Measured at 29.9s, which reads as a hang.
   Warming the models at startup, and the label, are **a separate PR** — not
   this one.
2. **A `--transcribe` sweep still writes spans.** With a cap in place, one sweep
   over 20,000 clips evicts every live dictation. Gate it on `source == .live`,
   or exempt replays from the cap.
3. **The `extends` guard.** On three measured dictations the padded arms reached
   further into the audio than the first pass and the first pass was taken every
   time — the guard rejecting arms that rewrote earlier text. Whether it is
   rejecting them correctly is now answerable from the trace, and is not
   answered here.
4. **The per-call `model` span**, and the fields that depend on it.
5. **Whether the chip ships.** It does not. It is documented in `docs/cli.md`.

## Build order

Three PRs. Each is independently useful and each can ship alone.

**PR 1 — `trace.jsonl` v3.** `edits` replacing `before`/`after`, the new
timing fields, `decodes[]`, `parts[]`, the `asr.duration` fix, `v: 3`, and the
`docs/cli.md` recipes. `scripts/watch.py` reads `before`/`after` at `:51` and is
updated here, not later — it gets shorter, since it computes the diff itself
today. No spans, no viewer. The riskiest code in the whole
proposal is the diff, and it lands here alone where it can be reviewed by
itself. ~180 lines.

**PR 2 — `spans.jsonl`.** The span collection, the second file, the cap,
`logging.spans`. Touches the decode path, which is where the invented-tail
guard (#272) and the empty-decode retry live. ~200 lines.

**PR 3 — reading one.** `--trace-view` and `TraceText`, the Trace Event export
behind `--perfetto`, `--redacted`, the `done:` key on a transform, the transform
documented in `docs/cli.md` — not added to `config.example.yaml` — and the
wordless timeline in `--bug-report`. None of it in the dictation path.

All three shipped together, in one pull request.
