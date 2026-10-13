# Hesitation dataset and training plan: final review findings

13 October 2026. AI agent review (Claude Opus 5.5), not human or native-speaker review.

## 1. Dataset review

**Scope.** All 1,412 hesitation records: 353 each in English, French, Spanish and Catalan. Every record and every token row was read. A script check also passed on all of them: valid trees, deletions that match the targets, KEEP targets equal to inputs, and no family crossing splits.

**Main problems found and fixed** in `artifacts/hesitation-multilingual-adjudicated-v1`:
- **French final punctuation:** in 41 records, the final `.` attached to the last phrase instead of the root. Only 10 of those were non-projective, so a projectivity check would miss most of them.
- **Translation slips, fixed in both input and target:**
  - 30 clausal-subject sentences needed a capital `Que` and the subjunctive;
  - 36 inputs started with a lowercase letter;
  - smaller errors, such as Catalan `La llum` → `El llum` ("lamp").
- **Spanish:**
  - `iobj` replaced by `obl`: the pinned AnCora has 0 `iobj`;
  - `de nuevo` and `más bien` parsed as `fixed` locutions.
- **Catalan:**
  - `al costat` split into `a` + `el`;
  - in `haver de`, `de` now attaches to the infinitive;
  - pronominal clitics changed to `obj`;
  - wrong POS candidates fixed (infinitives tagged NOUN);
  - Catalan stays out of training for now (section 3).
- **Missing POS:** Spanish and English have no POS at all, so the hesitation data is syntax supervision only.

**What the analyst's follow-up changed.** I agreed with all six points and replied in `REVIEWER_FOLLOWUP_EN_FR_ES_CA.md`.
- **No forced cross-language labels.** The four English bare-`no` rows stay REPAIR, because English `no` cannot negate a phrase.
- **Ambiguous intent is excluded, not given a KEEP gold tree.** This covers English "I mean to X" and unpunctuated `no` / "I mean" in FR/ES/CA.
- **Cue commas follow each language's treebank.**
- **`a unusually` is a deliberate error and is kept.** I had wrongly called it a template slip.

**Result.** 915 rows are eligible for full-tree supervision. Diagnostic-only, excluded and replacement rows are kept separate. Everything remains AI-reviewed proposals, not gold.

## 2. Training plan review

`MULTILINGUAL_TRAINING_PLAN.md` is sound, bounded and honest about its limits. Its update arithmetic is correct, and its data table matches the adjudicated dataset exactly.

**Changes before running** (also appended to the plan as review notes):
1. **Build the automatic deletion scorer before Stage H.** Without it, H's safety gates (no deleted latest span or negation, no harmful KEEP deletion) cannot be measured.
2. **Reduce template repetition.** Each language has about 230 training rows from only 27–29 families. At 20%, each row is seen about 6.5 times over H. Use 10%, or compare 10% against 20%. Report dev results per family.
3. **Check repairs on real speech.** Pinned `es_ancora` has no `reparandum`, so Spanish repairs come only from synthetic data. Add natural-repair checks to the H gate: Rhapsodie and ParisStories (FR), ESLSpok (EN) and **`es_coser` (164 real Spanish repairs)**. A drop on these after H means the model learned templates.
4. **Tighten the grammar-feature gate.** A +0.20 LAS gain over two seeds is within the observed noise. Require the gain to exceed the seed spread.
5. **Minor:** report tokens per language. Spanish sentences are about twice as long as English ones.

Latency is not a concern: the owner confirmed this from earlier experiments.

## 3. Decisions taken

- **Catalan is out of this campaign.** Train English, French and Spanish only. The schedule becomes 564 updates per epoch and 19,176 updates before NER. Hesitation data: 688 train, 152 dev, 168 test. `ca_ancora` is in the same pinned UD dataset and can be added later.
- **Heldout sets are not fresh.** The hesitation dev and test sets have been inspected and share templates with train, so they count as regression evidence. Real-dictation confirmation is still needed before deployment.

## Files

- Dataset follow-up and replies: `training/syntax-parser/REVIEWER_FOLLOWUP_EN_FR_ES_CA.md`
- Adjudicated dataset: `training/syntax-parser/artifacts/hesitation-multilingual-adjudicated-v1/`
- Full review outputs:
  - `training/syntax-parser/artifacts/multilingual-review-handoff-v1-agent-review/`
  - `training/syntax-parser/artifacts/english-review-handoff-v1-agent-review/`
- Training plan with review notes: `training/syntax-parser/MULTILINGUAL_TRAINING_PLAN.md`
