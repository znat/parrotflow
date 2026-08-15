# Proposal: the audio as a second channel

**Status.** Analysis. Nothing here is built, and the build order at the end is
a suggestion, not a plan that has been agreed.

**The question.** Gemma 4 E4B takes audio. Parakeet takes audio. What do we get
if both hear the clip, before the optional Gemma pass that handles commands?
Not a second transcript to choose from — structured facts about the sound, that
a deterministic program applies to the transcript Parakeet wrote. And is it
better to run them together, or to wait for the transcript and ask afterwards?

**The finding, in one paragraph.** Most of what is wanted here does not need
Gemma. Punctuation and disfluency want pause lengths and pitch, and the pause
lengths are already in `trace.jsonl` for every dictation ever taken on this
machine. Pitch costs a DSP pass, no model, microseconds. Gemma-with-audio earns
its cost on exactly one job: **the vocabulary judge, which today decides what a
sound was without ever hearing it.** And the parallel-or-serial question is a
false choice — send the audio at t=0, ask the question at t=+1s, on the same
KV cache.

---

## 1. What each channel actually knows

| Fact | Parakeet TDT | The CTC grid | DSP | Gemma + audio |
| --- | --- | --- | --- | --- |
| The words | yes | no | no | worse, and slower |
| Where each word starts and ends | **yes, shipped** | yes, finer | no | unreliable |
| Per-word confidence | **yes, shipped** | per frame | no | no |
| Pause length between words | **yes, by subtraction** | yes | yes | roughly |
| Pitch, terminal rise | no | no | **yes** | yes, as a judgement |
| Loudness, emphasis | no | no | **yes** | yes, as a judgement |
| Frame-level uncertainty | no | **yes** | no | no |
| A word fragment the decoder dropped | no | maybe | no | **yes** |
| "Was that name Vercel or Versailles" | no | scores a guess | no | **yes** |
| "Was that Claude or cloud" | no | **no — see §4** | no | **yes** |

Read the first three rows again. Word timings and confidences are already
computed, already published as `asr.confidence` / `asr.words`, and already
written to `trace.jsonl` per word (`Trace.words`, `Sources/ParrotFlow/Trace.swift:283`).
Nothing downstream reads the gaps.

## 2. The free win: the pauses are already on disk

`Trace.Word` carries `word`, `start`, `end`, `confidence`. TDT predicts
durations as a first-class output, so the gap between word *i* and word *i+1*
is a subtraction, not an estimate.

That gap is the classic prosodic-break feature. From it, with no model:

- a gap over roughly half a second is a sentence boundary
- a shorter gap plus a lengthened final syllable is a comma
- a local collapse in speech rate marks a hesitation
- a repeated stem across a short gap marks a false start: "I want — I need to"
- a confidence dip over one or two short words marks the discarded half of a
  repair

None of this costs a model call. `replacements`, `numbers` and a `replace:`
transform together measure 0.035 s on a line; a `prompt:` transform costs
~1.5 s warm and 6.7 s cold. This is the side of that gap the repo already says
to stay on.

**And it can be scored today, offline.** Every archived dictation has its word
timings in `trace.jsonl` and its audio beside it. A script can propose
punctuation from gaps alone and be scored against a hand-built case set, the
way `--numbers` was. No microphone, no Ollama, no build.

The honest cost: a punctuation pass rewrites transcripts that were already
right. That is the same objection `transcription.numbers` carries, and it
wants the same answer — off unless asked for.

## 3. The cheap win: pitch, which text cannot hold

Parakeet TDT v3 writes punctuation, but it writes it from the words. So it
gets "where are you going?" right and "you're going?" wrong, because the only
thing that makes the second a question is the pitch at the end.

This matters more in French than in English. "Tu viens." and "Tu viens ?" are
the same words. In speech the second is by far the more common way to ask, and
nothing in the text separates them.

F0 extraction (YIN or pYIN) over 16 kHz mono is a few milliseconds for a ten
second clip. It gives:

| Signal | Read as |
| --- | --- |
| rise over the last ~300 ms | question mark |
| fall to floor | full stop |
| flat, held | the speaker had not finished — no punctuation |
| RMS peak on one word | emphasis |

This is deterministic, testable against a case set, and fails open by
returning nothing.

## 4. Where Gemma-with-audio actually pays: the judge

The vocabulary judge today is shown three things: the sentence the recogniser
wrote, the sentence after the pass, and what changed. It answers KEEP or
REVERT per change. **It is deciding what a sound was, and it has never heard
the sound.**

Its measured score, on 74 substitutions, `--runs 3`:

| | all | name was said | name was not |
| --- | --- | --- | --- |
| shipped judge | 63/74 | 21/22 | 42/52 |

The headroom is ten wrong KEEPs and one wrong REVERT. That is a small, exact,
already-instrumented target, with two blind controls sitting beside it.

Better than the headroom, though, is the set the judge cannot reach at all.
`floor: off` exists because "Claude" and "cloud" both come back from the
decoder as `cloud`, and "Matthieu" and "Matthew" both as `Matthew`. The
documented reason is that "the distinction is gone before anything downstream
can look."

That is true of the decoder's output, and true of the CTC spotter, which
searches a grid trained to produce the decoder's tokens. **It is not true of
the audio.** The vowel in "Claude" is not the vowel in "cloud". A model that
hears the clip is not bound by what the decoder collapsed.

So `floor: off` terms are the one place where audio in the judge could do
something no other mechanism in this app can do. They are also a clean
experiment: the terms are already listed, the failure is already documented,
and the control is the shipped judge.

The cost of trying this is close to zero, because **there is no new stage.**
The `vocabulary:` stage already exists, already fires on 41% of clips
(77 of 190), and already pays ~1.5 s when it does. Adding audio adds one input
to a message that is already being sent. No new parsing, no new output shape,
no new latency on the 59% of clips where the stage is skipped.

Gate it on length: `when: vocabulary.count > 0 && asr.duration < 25`.
`asr.duration` is already published.

## 5. The ordering question — you do not have to choose

Three shapes, with the numbers from
[architecture.md](../architecture.md#where-the-time-goes):

**A. Parallel, blind.** Audio to both at t=0. Gemma has no transcript, so it
can only answer global questions ("did this end as a question?") or
self-describing ones ("the name was Vercel") that have to be located in the
text afterwards by fuzzy match. Wall clock ≈ max(Parakeet, Gemma) ≈ 1.0 s if
the answer is tiny. Free, and weak.

**B. Serial.** Wait for the transcript, then hand Gemma audio *and* text. The
task collapses from understanding to labelling, and the answer can be word
indices, which are short and exact. Wall clock ≈ 1.0 + 1.5 = 2.5 s. Strong,
and it taxes every dictation.

**C. Prefill parallel, ask serial.** Send the audio at t=0 as turn one. When
Parakeet lands at t≈1.0 s, send the transcript and the question as turn two on
the same conversation. The audio prefill and its KV cache are already done, so
turn two pays for the new text tokens plus decode only. Wall clock ≈ 1.3–1.5 s.

C is the answer to the question as asked. **The audio should not wait for the
transcript. The question should.**

C depends on the server keeping the prefix cached between the two turns. Ollama
and llama.cpp both do prefix caching per slot, and `llm.keep_loaded` already
pins the model. It has not been measured here. If the cache misses, C degrades
to B, which is the current cost of a prompt stage — so the downside is bounded.

## 6. The payload rule

`gemma4:e4b` matches `gemma4:12b` on the correction set at half the latency,
because **output tokens dominate, not parameter count.** That single measured
fact fixes the design:

> The answer must be shorter than the transcript. If the model re-emits the
> words, we have paid for transcription twice and taken the worse one.

`num_predict: 32` is already the setting. Keep it, and treat it as the spec
rather than a guard.

What that rules out:

- returning a corrected sentence — this is the "regenerate and hope" shape, and
  it is already measured as worse: the same model scores 68% asked to rewrite a
  sentence and 8/8 asked only to name which words matter
- returning a per-word table — too long
- **returning timestamps** — long *and* wrong. Audio LLM timestamps come from
  soft attention and are unstable; CTC and TDT alignment is the reliable
  source, biased by a measurable ~50 ms. Never ask Gemma when something
  happened. Ask what it was, and anchor it with an index Parakeet supplied.

What that leaves. Blind, turn one:

```json
{"end":"?","frag":1,"lang":"fr"}
```

With the transcript, turn two, words numbered by Parakeet:

```json
{"cut":[4,5],"q":[11]}
```

And for the judge, no change at all: the same KEEP/REVERT per change, with the
audio added to the message.

## 7. What will break

These are integration facts, not design opinions. Each needs checking on the
machine before anything is built on it.

1. **Ollama's native `/api/chat` silently ignores an `audios` field.** The
   model then answers about audio it never received, and says so in its
   reasoning, confidently. For a codebase whose first rule is fail open, this
   is the worst failure shape available: it does not fail, it invents. Audio
   goes through the OpenAI-compatible `/v1/chat/completions` endpoint as an
   `input_audio` content block (base64 WAV), and the path needs a canary at
   startup — a clip whose answer is known — before it is trusted.
   (llama.cpp discussion #21334, ollama #21868.)

2. **Thinking is reported on by default for `gemma4:e4b` audio in Ollama
   0.30.x**, producing hallucinated transcription; and thinking mode returns
   empty responses for audio inputs. We already set `think: false` — 98 s
   against 4.5 s. But `think` is an Ollama-native field, and the audio path is
   the OpenAI-compatible one. Confirm it is honoured there. If it is not, a
   `llama-server` sidecar is the fallback.
   (ollama #16584, #16583.)

3. **Intermittent GGML assertion crash during audio inference** (ollama
   #15333). Fail-open has to cover a crashed server, not only a timeout.

4. **E4B is reported to cap audio at 30 seconds.** A long dictation must be
   skipped or chunked. `when: asr.duration < 25` is the one-line version.

5. **Memory.** Parakeet on the Neural Engine plus a pinned Gemma 4 E4B plus an
   audio KV block. On an 8 GB Mac this is the constraint that decides whether
   any of this ships.

## 8. Build order, and how each step is scored

Cheapest and most certain first. Each step is measurable before the next
starts.

| | Step | Cost | Scored against |
| --- | --- | --- | --- |
| 1 | Publish gaps, rate and confidence dips into the pipeline scope from timings already computed | none | `--pipeline --vars` shows them |
| 2 | A deterministic punctuation and repair pass over those variables | ~0.035 s | a hand-built case set, offline, over archived `trace.jsonl` |
| 3 | F0 and RMS, as more variables | ~ms | the same set, plus French yes/no questions |
| 4 | Audio into the existing `vocabulary:` judge, `/v1/` endpoint, canary first | 0 s on 59% of clips | the same 74 substitutions, `--runs 3`, against 63/74 and both blind controls |
| 5 | `floor: off` terms allowed back as proposals, decided by the audio-aware judge | as above | clips containing Claude/cloud, Matthieu/Matthew |
| 6 | Turn-one audio prefill at t=0, turn-two question at t=+1s | measure whether the cache holds | wall clock, against B |

Steps 1–3 need no model and can be scored from data that is already on disk.
If they close most of the punctuation gap, steps 4–6 are about names only,
which is where the measurements say the remaining errors are.

**Do not start at step 4.** It is the interesting one, and it is the one that
cannot be scored without also building the endpoint, the canary and the
fail-open path.
