# Proposal: the audio as a second channel

**Status.** Analysis. Nothing here is built, and the build order at the end is
a suggestion, not a plan that has been agreed.

**The question.** Gemma 4 E4B takes audio. Parakeet takes audio. What do we get
if both hear the clip, before the optional Gemma pass that handles commands?
Not a second transcript to choose from — structured facts about the sound, that
a deterministic program applies to the transcript Parakeet wrote. And is it
better to run them together, or to wait for the transcript and ask afterwards?

**The finding, in one paragraph.** Most of what is wanted here does not need
Gemma. But punctuation is not an insertion job — Parakeet already writes stops
from the pause, and puts one wherever you hesitate. So the job is to remove the wrong
ones, and the signal that separates a hesitation from a boundary is pitch, not
pause length. Pitch is a DSP pass, no model. Gemma-with-audio earns its cost as
a tiebreak on what pitch cannot call, and on **the vocabulary judge, which
today decides what a sound was without ever hearing it.** The parallel-or-serial
question is a false choice: send the audio at t=0, ask at t=+1s, one KV cache.

---

## 1. What each channel actually knows

| Fact | Parakeet TDT | The CTC grid | DSP | Gemma + audio |
| --- | --- | --- | --- | --- |
| The words | yes | no | no | worse, and slower |
| Where each word starts and ends | **yes, shipped** | yes, finer | no | unreliable |
| Per-word confidence | **yes, shipped** | per frame | no | no |
| Pause length between words | yes — and already used, see §2 | yes | yes | roughly |
| Pitch reset across a pause | no | no | **yes** | yes, as a judgement |
| Pitch, terminal rise | no | no | **yes** | yes, as a judgement |
| Loudness, emphasis | no | no | **yes** | yes, as a judgement |
| Frame-level uncertainty | no | **yes** | no | no |
| A word fragment the decoder dropped | no | maybe | no | **yes** |
| "Was that name Vercel or Versailles" | no | scores a guess | no | **yes** |
| "Was that Claude or cloud" | no | **no — see §4** | no | **yes** |

Word timings and confidences are already computed, already published as
`asr.confidence` / `asr.words`, and already written to `trace.jsonl` per word
(`Trace.words`, `Sources/ParrotFlow/Trace.swift:283`). Nothing downstream reads
them. That is worth fixing, but §2 is why it is not the win it looks like:
the pause is the one signal Parakeet has already consumed.

The rows that matter are the ones with **yes** in a column Parakeet's is
empty — pitch, frame-level uncertainty, and the two name questions.

## 2. The pause is not unused — it is already spent, and spent wrong

The first version of this document said the gaps between words were free
information nobody reads. That is wrong in the way that matters.

Parakeet writes punctuation itself, and it writes it from the pause. Hesitate
in the middle of a sentence and it ends the sentence: a full stop lands, and
the next word starts a new one — sometimes capitalised, sometimes not.

Two consequences, and both are load-bearing.

**A pause-length threshold in a post-pass is the same classifier that just
failed.** Parakeet already read the gap and decided. Reading the same gap again
downstream, with less of the acoustic context and none of the model's internal
state, cannot do better. Anything built here has to use a signal Parakeet did
not have.

**The job is repair, not insertion.** That is a narrower and better-defined
problem. Given the *N* full stops in a transcript, which of them are real? One
bit per stop. It is the only shape worth building, because inserting
punctuation into text that already has some means arbitrating with a decision
already made, and removing a wrong stop is a clean edit that cannot damage a
transcript that was right.

The inconsistent capitalisation is part of the same picture, and it is not only
noise. A full stop followed by a lowercase word is the P&C head contradicting
itself. It cannot decide anything — but it is a very cheap way to *find*
candidates.

## 3. What actually separates a hesitation from a boundary

Not the length of the pause. Three things, none of which Parakeet can see —
it is a token transducer whose punctuation was learned from text conventions,
with no pitch anywhere in it.

**Pitch reset.** This is the strongest one, and it is measured across the gap
rather than inside it. At a real sentence end F0 falls to the speaker's floor,
and the next phrase starts back up at a fresh high baseline. At a hesitation
the speaker holds pitch level — the continuation contour, which means "I have
not finished" — and picks up afterwards roughly where they left off. Falling
then resetting is a boundary. Level then continuing is a hesitation.

**Final lengthening.** The last syllable before a real boundary stretches.
Before a hesitation it usually does not; the speaker either holds a vowel or
cuts off. Word durations for this are already in `tokenTimings`.

**A filled pause next to the stop.** "um", "euh", "uh" immediately before a
full stop is strong evidence that the stop was a hesitation.

F0 extraction (YIN or pYIN) over 16 kHz mono is a few milliseconds for a ten
second clip. Terminal contour also gives the question mark for free, which is
the other thing text cannot hold: "Tu viens." and "Tu viens ?" are the same
words, and in speech the second is the ordinary way to ask.

F0 range is speaker-specific, so "falls to the floor" needs a per-speaker
baseline. The app already has somewhere to keep one — `voice/`, beside
`config.yaml`, which exists precisely because a fact about a mouth and a
microphone is not a setting.

### One ordering trap

Filler removal runs on the finished transcript and deletes "um" and "euh". A
filled pause beside a full stop is the best cheap evidence that the stop is
spurious. **Delete the filler first and the evidence is gone.** The stop
decision has to be taken before or together with filler removal, never after.

### The token nobody reads

`result.tokenTimings` carries a confidence per token, and the full stop is a
token. `Trace.words` folds it into the preceding word's minimum
(`Sources/ParrotFlow/Trace.swift:283`), so the trace cannot show it, but the
pipeline holds the raw array.

Whether SentencePiece emits `.` as its own piece or glues it into
`▁sentence.` decides how much of this is a threshold rather than a model.
**Unverified, and it is the cheapest thing to check here**: dump
`tokenTimings` from `--transcribe` and look. Twenty lines of CLI, one clip,
no Ollama.

### Building the labelled set in an hour

Ground truth is which stops were wrong, and hand-labelling an archive is slow.
Mine candidates instead: a full stop followed by a lowercase word, or by a word
that cannot begin a sentence — "and", "but", "so", "which", "mais", "qui",
"que", "dans", "pour". A stop list, which is an idiom this repo already has,
against word lists it already ships in `data/`.

That is a candidate miner, not a decider. It finds the clips worth labelling.

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

What that leaves. Number the full stops Parakeet wrote and ask which are real:

```json
{"drop":[2]}
```

Six tokens. The model writes no words, invents no times, and competes with
Parakeet on nothing. It answers one prosodic question per candidate — did the
voice end there, or hesitate — which is what an audio model should be good at
and what an ASR head with no pitch cannot do at all.

That is the shape to aim for everywhere. For the judge it is already the shape:
the same KEEP or REVERT per change, with the audio added to the message and
nothing else altered.

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
| 0 | Dump `tokenTimings` from `--transcribe`. Does the full stop carry its own confidence? | 20 lines | one clip, by eye |
| 1 | Mine the archive for suspect stops — followed by a lowercase word or a non-starter. Label them | none | this *is* the case set |
| 2 | Publish per-stop features into the scope: gap, stop confidence, filled pause before, final lengthening | none | `--pipeline --vars` shows them |
| 3 | F0, and the pitch-reset test across each candidate stop, with a per-speaker floor in `voice/` | ~ms | the set from step 1 |
| 4 | A deterministic pass that drops the stops the test rejects, before filler removal | ~0.035 s | the same set, both failure kinds counted apart as `check-grammar.sh` does |
| 5 | Gemma-with-audio as the tiebreak, gated on an unresolved candidate existing | 0 s when none | the residue step 4 could not call |
| 6 | Audio into the existing `vocabulary:` judge, `/v1/` endpoint, canary first | 0 s on 59% of clips | the 74 substitutions, `--runs 3`, against 63/74 and both blind controls |
| 7 | `floor: off` terms allowed back as proposals, decided by the audio-aware judge | as above | clips containing Claude/cloud, Matthieu/Matthew |
| 8 | Turn-one audio prefill at t=0, turn-two question at t=+1s | measure whether the cache holds | wall clock, against B |

Steps 0–4 need no model. Step 0 might shrink the whole thing to a threshold,
and it costs an afternoon to find out.

**Do not start at step 5 or 6.** They are the interesting ones, and they are
the ones that cannot be scored without first building the endpoint, the canary,
the fail-open path — and, for step 5, the case set that says whether the
deterministic version already handles it.
