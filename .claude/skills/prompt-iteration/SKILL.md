---
name: prompt-iteration
description: Decide what should do a narrow text job — a prompt, a regex, a script, or a combination of them — by measuring against a validation set instead of judging by eye. Use when tuning a prompt for extraction, classification or rewriting, especially with a small local model; when a prompt "works" but fails unpredictably; or when deciding whether a model is needed at all. Covers building the set, splitting model work from code, proposing the combination, and the failure patterns measurement exposes.
---

# Deciding what does the job, and proving it

Two questions, and they are usually asked in the wrong order.

The one people start with is "how do I make this prompt better". The one that
decides the outcome is **"what should be doing this at all"** — a model, a
substitution table, a script, or some combination where each does the part it
is good at. Tuning by eye cannot answer either: each change fixes the example
in front of you and silently breaks one you are not looking at.

The fix is unglamorous. Build a set of cases first. Measure every candidate
implementation against it, including one with no model in it. Then change one
thing at a time. Everything below is downstream of that.

## Build the set before touching anything

Twenty to forty cases is enough. Fewer and you cannot tell a real change from
noise; more and you stop running it.

Write cases from the failure you are actually trying to fix, then deliberately
add the categories you have not thought about. Some rules:

**Use real inputs, not clean ones.** If the input comes from speech
recognition, OCR, or a user typing quickly, the test inputs must be mangled
the same way. A set built from tidy examples measures nothing, because tidy
inputs were never the problem.

**Include negative cases.** Roughly one in five should have no valid answer —
and if the thing you are building runs on *everything* rather than on demand,
make it closer to half. Models are strongly biased toward producing output, and
a set without negatives will not show you that. This is usually where the worst
failures hide: a confident wrong answer beats a refusal on any set that lacks
them.

**Include the boundary you keep arguing with yourself about.** If you are
unsure whether a multi-word span counts, put three of them in. The set turns
an argument into a number.

**Cover the categories separately.** Group cases so a regression shows up as
"all the two-word ones broke" rather than an unattributable drop of four
points.

**Write the contract down in the file.** What counts as a case for this
feature, and what is deliberately out of scope, belongs at the top of the set
in prose. It is the thing you will disagree with yourself about in a week.

Store it as data, not code — YAML or JSON — so cases can be added without
touching the runner.

## Three tools, and how to tell which one

Before writing a prompt, work out which of these the job actually wants. Most
features end up using more than one.

**A substitution table or regex.** The answer is already in the input, marked
by something literal — a phrase like "called X", a run of separated letters, a
word that always precedes what you want. Exact, free, and it never invents.
Cheapest thing that can work; try it first.

**A script.** The answer is a mechanical function of the input, but not one a
pattern can express — joining words with capitalisation, arithmetic, a lookup,
anything with a branch in it. Costs a process start, roughly 30ms for `python3`
and 5ms for a shell script. Deterministic, testable, and yours to change.

**A prompt.** The answer needs world knowledge or a judgement about what a
human meant — which of these words is the name, is this an instruction at all,
what does this abbreviation stand for. Costs about a second, varies between
runs and between models, and is the only tool of the three that can be
confidently wrong.

Three tests that decide it quickly:

- **Is the answer present verbatim in the input?** Then copying it is the job,
  and a model is the worst available copier. Take the letters from the text,
  not from the model.
- **Is it character-level editing?** Removing a letter, doubling one, changing
  case, adding an accent. Always code. Measured: asked to apply "Phillip with
  one l", a 4B answered "Phill" and a 12B "Philp" — 5/10 and 8/10 on ten
  cases, where a function scored 10/10 on both. Bigger models fail this the
  same way, which is the tell that no prompt fixes it.
- **Does the thing announce itself with a literal marker?** "a python function
  called…", "spells T A S M E E N". Then there is nothing for a model to
  *find*, and the marker is the implementation.

**The combination is usually the answer, and it is usually model-narrow.** The
strongest shape found repeatedly: the model does one judgement call it is
uniquely good at, and code does everything on either side of it. For spoken
spelling corrections the model names which words in the transcript the speaker
meant — a genuine judgement, since recognition mangled the name twice over —
and code reads the letters, applies described changes, snaps the span to the
transcript and refuses a rule that maps a word to itself. Every job moved out
of the model raised the score.

**How to ship each one here.** A `transforms:` entry in `config.yaml` takes
`prompt:`, `replace:` (a substitution table) or `command:` (a program, the
transcript on stdin and the rewrite on stdout). A pipeline step runs it. That
means the choice between the three tools is a configuration choice, not an
architecture change, and a proposal can name the body it would use.

## Split what the model must do from what code should do

Then score the model on its part alone, and score the whole pipeline
separately. The two numbers answer different questions:

- Model-only accuracy tells you whether the prompt is working.
- Pipeline accuracy tells you whether the feature is working.

A large gap between them means you are asking the model to do something your
code should be doing. Move it and the gap closes. In one case the gap ran the
other way and was worth 15 points: the model's raw spans scored 74% while the
finished feature scored 89%, because the repair layer was doing the work — the
more of an answer that is built from the text, the less the model has to be
good at, and the smaller a model you can ship.

## Score the code you actually ship

Both numbers are lies if the runner's version of the pipeline has drifted from
the application's. This is easy to miss because the runner keeps working — it
just answers a question about code nobody runs.

Twice in this repo the runner understated the real pipeline: once because the
app had moved on to a better way of reading the spelled letters, and once
because it did not model the app's repair step at all. The second gap was worth
31 points to a small model. If the application post-processes the model's answer
— repairs it, validates it, falls back — the runner has to do the same thing,
and the honest move is to port that code rather than approximate it.

When the implementation is a script, score *that file*, not a copy of its logic
inside the runner. Two copies of an algorithm drift, and only one of them ships.

## Keep a control with no model in it, and give it the same discipline

Add a mode that runs the pipeline with the model removed and something
plausible in its place. It costs a few lines and it is the only thing that
answers the question you actually care about: is the model earning its place?

Make it a real candidate, not a strawman. If a regex for the marker plus a
casing function could implement the whole feature, that is the control, and it
should be written as well as you would write the shipped thing. Then iterate on
it as you iterate on prompts — tune the stop lists, fix the false positives,
one change at a time.

Two controls, two outcomes, both from this repo:

- Spelling corrections: the control scored 59% and the 0.8B model 62%. Four
  prompt variants and a day of tuning had been spent on three points of noise.
- Spoken identifiers: the control scored 100% and the best model 68%. The
  feature shipped as a thirty-line script and the model was dropped entirely.

**A control you tuned on the set is not a measurement.** Tuning the identifier
control against its own failures took it from 93% to 100%, which proves
nothing. Write fresh cases afterwards, ones that were used to fix nothing, and
score on those — that is where its real 93% came from, and where the one
genuine bug left in it turned up. Fold them into the set when you are done, and
note that the next change needs new ones.

## The loop

1. Run the set. Record the number.
2. Change **one** thing.
3. Run again. Keep it if it improved, revert if not.
4. Read the failures each time, not just the score.

Two disciplines make this work:

**Change one thing.** Two edits at once and you cannot attribute the result.
When a score drops, the change you just made is the suspect, not the previous
one.

**Keep failed variants in the file, with their scores.** They are the record of
what has been tried, and they stop you re-proposing a change that was already
measured and rejected. A comment saying "v3 scored lower, it over-trimmed" is
worth more than the diff that removed it.

**Re-open the tool choice at every new shape.** The decision is not made once.
A feature that was correctly a prompt can stop being one when a second kind of
input arrives — described spelling changes re-opened a settled design, and
moving that half into code then paid for a shorter prompt on the original half
as well.

## Failure patterns that show up repeatedly

**"Output nothing" does not work.** Asking for empty output on the negative
case is asking the model to emit zero tokens, which is unnatural — it will
produce *something*, usually an invented answer. Give the null case a token:
`NO MATCH`, `{"action":"none"}`. Then parse loosely: a model that answers
`X => NO MATCH` has made the right decision and formatted it badly, and the
parser should accept it rather than the prompt fight it.

**Examples teach boundaries; rules over-apply them.** A prose rule is applied
uniformly, including where it should not be. "Never include surrounding words"
stopped an over-long span and started truncating legitimate ones. Two examples
— one showing the trim, one showing the keep — taught the distinction with no
rule to over-apply. Reach for an example whenever the correct behaviour depends
on context.

**Examples teach the shape you did not mean to teach.** Every added example is
also a claim about what answers look like. Three new examples with a one-word
span were enough to start truncating two-word spans that had been right for
months. If the examples all share an incidental property, the model learns that
property.

**A rewriting prompt rewrites more than you asked.** Anything that returns the
whole text will also capitalise a word, add an article, or translate a name it
found foreign. On a stage that runs on every input rather than on demand, that
is disqualifying however well it does the actual job — the user would have to
proof-read everything. Half the set should be inputs that must come back byte
for byte.

**Procedural sections invite narration.** A `# Steps` block with numbered
instructions is read as an instruction to *show* the steps. On a thinking model
this is expensive; on any model it is output you then have to parse around.
Describe the output, not the method.

**Check whether the model is a thinking model.** They reason by default and
will spend hundreds of tokens on a one-line answer. Latency here is dominated
by output tokens, not parameters — disabling thinking can be a 20x speedup, and
a smaller model with it off will often beat a larger one with it on. Check the
model's capabilities before optimising anything else.

**Cap the output length.** A one-line answer cannot need more than a handful of
tokens. A low limit costs nothing and bounds the damage when the model starts
rambling.

**Cold start is not latency.** Time a warm run. First-call timings include
loading weights and will send you optimising the wrong thing. Back-to-back runs
of the same prompt are also not a measurement — a cached prompt reads in a
sixth of the time, and the second number is the one that flatters.

## Choosing a model, and knowing when not to

Run the same set across candidates. Three things regularly surprise:

- **Bigger is often slower and no better** for narrow tasks. If output tokens
  dominate, an 8B model can match a 12B at half the latency.
- **Capability is not the constraint; restraint usually is.** On a rewriting
  task the failure mode that matters is a model that improves your prose when
  asked not to. A perfectly capable model can be unusable for this while a
  weaker one is fine.
- **There is a floor, and prompting does not reach below it.** Past some size
  the failures stop being instruction-following and start being the model
  producing garbage — echoing the format placeholder instead of filling it in,
  answering `YES MATCH`, shouting the input line back in capitals. No wording
  fixes that.

Two tells worth knowing by heart:

**If several genuinely different prompts score the same, you are measuring the
model, not the prompt.** Stop writing variants.

**A larger model is the cheap capability check.** When it fails the same way as
the small one, the job is wrong for models and belongs in code. When it
succeeds, the small model's failures are a prompt problem after all. One run of
ten cases answers a question that three prompt variants cannot.

## The runner

Keep it in the repo, next to the set. It should take an implementation — a
model and a variant, a script, or nothing at all — and print per-case results,
the score, and the failures. If it takes more than a few seconds to invoke you
will stop using it, and then you are back to guessing.

Worth including:

- Variants side by side in one file, so they can be diffed and compared.
- A mode per candidate implementation: `--variant` for prompts, `--script` for
  a program, `--code-only` for the control. One set, one comparison.
- A verbose mode showing every case, and a default that shows only failures.
- Separate scoring for the model's part and the pipeline's, as above.
- Scores split by the halves that fail differently — the cases that must change
  and the cases that must not.
- Deterministic settings — temperature 0 — so a re-run is a re-run.
- The scoreboard and what it decided, in a comment at the top or bottom. It is
  the memory of the whole exercise and it outlives everyone's recollection.

## Worked example 1: a combination

`tests/spelling-cases.yaml` and `scripts/validate-prompt.py`. The task: map a
misheard name to the spelling the user read out, or to the change they
described.

The set is 62 cases — names from ten language backgrounds, product names that
recognition splits into English words, negatives, two corrections in one
breath, described changes. Inputs are real recogniser output, mangled twice
over, because that double-mishearing is the actual difficulty.

Scores across the prompt versions, on gemma4:e4b:

| | full line | model's part |
| --- | --- | --- |
| v1, silence for no-match | 71% | — |
| v2, `NO MATCH` token | 89% | 91% |
| v3, + rule against extra words | 86% | 91% |
| v4, examples instead of the rule | 94% | 100% |
| v8, − the "ordinary English word" clause | 95% | 100% |
| v9, + a three-word example | 92% | 97% |

v3 is the regression that justifies the whole method: a change that looked
obviously correct, made things worse, and would have shipped unnoticed without
the set. v9 is the same lesson a second time — one extra example, and spans
started over-running to "Graph on a dashboards".

v8 is the one only a second model could find. Its deleted clause cost gemma
nothing, so on gemma it was invisible; on granite4:3b it was firing on the
names that *are* ordinary English words, and removing it was worth two points.
A rule that helps no model and hurts a small one is pure liability, and you
cannot see it with one model.

Then the same set across models, scored end-to-end as the app runs it:

| | | |
| --- | --- | --- |
| gemma4:e4b, 9.6GB | 89% | 1.4s |
| granite4:3b, 2.1GB | 89% | 0.2s |
| qwen3.5:0.8b, 1.0GB | 62% | 0.4s |
| no model at all | 50% | — |

The 0.8B is the floor: four variants, an output format designed around its
weakness, and thinking mode all left it level with the control. The 3B matching
the 9.6GB model at a sixth of the latency is not the 3B being clever — its raw
spans score 74% — it is how much of the answer code builds.

## Worked example 2: no model at all

`tests/identifier-cases.yaml` and `scripts/validate-identifiers.py`. The task:
turn a name said out loud into the identifier a language spells it as — "a
python function called max retries" into `max_retries`.

56 cases, 23 of which must come back byte for byte, because this runs on every
transcript rather than on demand.

| | change | keep | overall | latency |
| --- | --- | --- | --- | --- |
| a 30-line script | 100% | 100% | 100% | 0.03s |
| gemma4:e4b, v1 | 58% | 83% | 68% | 0.97s |
| gemma4:e4b, v2 | 58% | 83% | 68% | 1.15s |
| granite4:3b, v2 | 39% | 78% | 55% | 0.49s |

Two prompts a rewrite apart scored identically, which said the model was being
measured rather than the prompt. And the model's failures were the wrong kind:
it capitalised "python" to "Python", added articles, and translated French
names into English — words it was told not to touch.

The design that had been sketched before measuring was a two-stage one, where a
prompt marks the names and a table cases them. The set killed that too: a
spoken name announces itself with a literal marker, so there was nothing for a
model to find. Both halves were code, and the honest total was a script.

What that decided in the app was smaller and more general than the feature: the
missing piece had looked like a case operator for the substitution engine, and
what shipped instead was a `command:` transform body — any program, stdin to
stdout — so the next idea needs no new primitive either.
