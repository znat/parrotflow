---
name: prompt-iteration
description: Iterate on a prompt against a validation set instead of by eye. Use when tuning a prompt for a narrow, repeatable task — extraction, classification, rewriting — especially with a small local model, or when a prompt "works" but fails unpredictably. Covers building the set, splitting model work from deterministic work, and the failure patterns that measurement exposes.
---

# Iterating on a prompt with a validation set

Prompt tuning by eye does not converge. Each change fixes the example in front
of you and silently breaks one you are not looking at. You cannot see the
regression because you are only ever testing the case that prompted the edit.

The fix is unglamorous: build a set of cases first, then change one thing at a
time and re-measure. Everything below is downstream of that.

## Build the set before touching the prompt

Twenty to forty cases is enough. Fewer and you cannot tell a real change from
noise; more and you stop running it.

Write cases from the failure you are actually trying to fix, then deliberately
add the categories you have not thought about. Some rules:

**Use real inputs, not clean ones.** If the input comes from speech
recognition, OCR, or a user typing quickly, the test inputs must be mangled
the same way. A set built from tidy examples measures nothing, because tidy
inputs were never the problem.

**Include negative cases.** Roughly one in five should have no valid answer.
Models are strongly biased toward producing output, and a set without
negatives will not show you that. This is usually where the worst failures
hide — a confident wrong answer beats a refusal on any set that lacks them.

**Include the boundary you keep arguing with yourself about.** If you are
unsure whether a multi-word span counts, put three of them in. The set turns
an argument into a number.

**Cover the categories separately.** Group cases so a regression shows up as
"all the two-word ones broke" rather than an unattributable drop of four
points.

Store it as data, not code — YAML or JSON — so cases can be added without
touching the runner.

## Split what the model must do from what code should do

This is the highest-leverage step and it is easy to skip.

Before optimising anything, ask which parts of the output a model is
genuinely needed for. Anything mechanical — extracting a substring that is
present verbatim, joining characters, formatting, arithmetic — should be code.
Models are unreliable at exactly this kind of copying, in ways that get worse
under quantisation, and every such job you hand them is a source of error you
cannot prompt away.

Then score the model on its part alone, and score the whole pipeline
separately. The two numbers answer different questions:

- Model-only accuracy tells you whether the prompt is working.
- Pipeline accuracy tells you whether the feature is working.

A large gap between them means you are asking the model to do something your
code should be doing. Move it and the gap closes.

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
loading weights and will send you optimising the wrong thing.

## Choosing a model

Run the same set across candidates. Two things regularly surprise:

- **Bigger is often slower and no better** for narrow tasks. If output tokens
  dominate, an 8B model can match a 12B at half the latency.
- **Capability is not the constraint; restraint usually is.** On a rewriting
  task the failure mode that matters is a model that improves your prose when
  asked not to. A perfectly capable model can be unusable for this while a
  weaker one is fine.

## The runner

Keep it in the repo, next to the set. It should take a model and a variant, and
print per-case results, the score, and the failures. If it takes more than a
few seconds to invoke you will stop using it, and then you are back to guessing.

Worth including:

- Variants side by side in one file, so they can be diffed and compared.
- A verbose mode showing every case, and a default that shows only failures.
- Separate scoring for the model's part and the pipeline's, as above.
- Deterministic settings — temperature 0 — so a re-run is a re-run.

## Worked example in this repo

`tests/spelling-cases.yaml` and `scripts/validate-prompt.py` are a working
instance. The task: map a misheard name to a spelling the user read out aloud.

The set is 35 cases — names from ten language backgrounds, product names that
recognition splits into English words, three negatives, one already-correct.
Inputs are real recogniser output, mangled twice over, because that
double-mishearing is the actual difficulty.

Scores across four prompt versions:

| | full line | model's part |
| --- | --- | --- |
| v1, silence for no-match | 71% | — |
| v2, `NO MATCH` token | 89% | 91% |
| v3, + rule against extra words | 86% | 91% |
| v4, examples instead of the rule | 94% | 100% |

v3 is the regression that justifies the whole method: a change that looked
obviously correct, made things worse, and would have shipped unnoticed without
the set. And the gap between the last two columns is the split — the model's
remaining errors were all in copying letters, which is now a regex, taking the
pipeline to 100%.
