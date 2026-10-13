# Response to the final dataset and training-plan review

13 October 2026. Response to `REVIEW_FINAL_FINDINGS.md`. These are recommendations for revising the execution protocol; no training has started.

The review identifies the right priorities. I agree that the automatic deletion scorer should precede hesitation adaptation, that the synthetic corpus needs restrained sampling, and that natural spoken-language evaluation is essential. I verified the training-family counts and the 164 reparandum edges in the 539 local COSER sentences.

## Changes I recommend adopting

- Make the automatic candidate/deletion scorer a hard prerequisite for Stage H. Freeze its policy before evaluating the competing models. It must discover candidates from predictions without receiving gold earlier/later pairs. Keep the existing known-pair-assisted structural metric as a separate diagnostic.
- Start H at approximately **10% local hesitation exposure**, retaining each language's repair/KEEP proportions and the equal-step ordinary-UD control. Defer a 20% comparison until the first run shows a reason to increase exposure. Report per-family results and repetition counts.
- Use EN/FR/ES for this campaign, following the scope decision recorded in the review. Preserve Catalan data for later.
- Report natural-speech reparandum precision, recall and exact counts before/after H, alongside general LAS and automatic deletion safety. Retain GUM as well as ESLSpok for English; the small ESLSpok repair denominator alone is insufficient.
- Report token/subword exposures and annotation coverage per language, not only sentence counts. Latency can remain descriptive rather than an acceptance gate under the recorded owner preference; computational correctness and input-preserving failure behavior still matter.

## Wording and methodological corrections

**1. A natural-speech regression is evidence of a transfer problem, not proof of memorization.**

Please replace “a drop means the model learned templates, not repairs” with a statement that it triggers error analysis. Template memorization is one possible explanation; annotation conventions, domain mismatch, precision/recall shifts, ordinary forgetting and small denominators are others. Compare the hesitation arm with both its epoch-five parent and the matched UD continuation.

**2. Do not use overall seed spread as a significance threshold.**

Compare paired effects within each seed: `feature_score(seed) - control_score(seed)`. Report both effects, the mean, paired sentence-bootstrap intervals and language-specific regressions. Two seeds cannot estimate training variability reliably, and a sentence-bootstrap interval does not capture it. Keep a predeclared practical-effect threshold; classify borderline evidence as inconclusive. If the decision warrants more compute, a separately declared third confirmation seed is preferable to treating “gain > seed spread” as a statistical guarantee.

**3. Decide COSER's role before execution.**

COSER is currently evaluation-only test data. Prefer evaluating it once at the fixed endpoint after choices have been made using development data. It may veto promotion, but repeated tuning in response to that score consumes its independence. If it is used repeatedly to choose sampling ratios, epochs or architecture, explicitly call it a regression/development set and reserve different data for final confirmation. Apply the same clarity to the other spoken-language splits. Natural reparandum-edge accuracy is not itself a gold end-to-end deletion benchmark.

**4. Clarify candidate counts and the sampling budget.**

There are **1,327 full-tree candidates across all four languages and splits**, of which **915 are training rows**. For this EN/FR/ES campaign the corresponding counts are **688 train, 152 dev and 168 regression test**. Diagnostic-only and unresolved rows remain separate.

The review's **19,176 updates before NER** is correct for the 20% design. For the recommended approximately 10% design:

- Each language contributes 188 ordinary batches plus 21 local batches of 16 per H epoch.
- That is 3,000 ordinary + 336 local sentence exposures per language: **10.07% local**, preserving all eligible local rows through shuffled cycles.
- Three languages yield **627 updates per H epoch**.
- Two H epochs × two arms × two seeds yield **5,016 H updates**.
- G and S remain 13,536 updates combined, giving **18,552 updates before NER**.

Actual local-row repetition over H is approximately 2.9–3.0 exposures per row, versus approximately 6.5–6.6 at 20%. Record actual per-row/family sampling rather than treating these averages as exact coverage guarantees.

**5. Narrow the explanation for English bare “no.”**

“English no cannot negate a phrase” is too categorical to justify an annotation policy. The four particular English cases retain their adjudicated REPAIR interpretation; do not generalize this to a rule that every bare “no” marks a repair. Contrast and other legitimate uses still require protection. The record-level decision can stand without that universal linguistic claim.

## Remaining alignment before running

Please confirm agreement on the 10% starting ratio, COSER's endpoint-only versus regression role, and reporting paired seed effects without the seed-spread rule. Then the main plan and one-pager should be revised together: the appended review notes currently conflict with their four-language scope and 20% budgets.

No further review of all 1,412 rows is requested here. The useful next review is of the frozen training/evaluation protocol, automatic deletion scorer and a small set of concrete examples demonstrating its KEEP, latest-span and negation protections.

---

## Reply (Claude review orchestrator, 13 October 2026)

Agreed on all points. I checked the 10% budget arithmetic: 21 local batches give 10.07% local exposure, 627 updates per H epoch, 5,016 H updates and 18,552 updates before NER. All correct.

Confirmations requested:

1. **Starting ratio:** 10%, with a 20% comparison only if the first run gives a reason.
2. **COSER:** evaluate it once, at the fixed endpoint, as a veto. Do not tune on it. Use the French spoken dev splits (Rhapsodie, ParisStories) and English GUM/ESLSpok dev for development. Name them as development sets.
3. **Seeds:** report paired per-seed effects (feature − control) with paired sentence-bootstrap intervals, plus a predeclared practical threshold. Classify borderline results as inconclusive. Drop the "gain > seed spread" rule.

Wording corrections accepted:

- A natural-speech drop after H triggers error analysis against both the epoch-five parent and the matched UD control. It is not proof of memorisation.
- My English bare-`no` statement was too broad. English `no` does negate noun phrases ("tea, no sugar"). The four records keep REPAIR on their own merits, not as a general rule.

The review notes appended to `MULTILINGUAL_TRAINING_PLAN.md` are superseded by this reply wherever they conflict (the 20% budget, the seed-spread rule, the memorisation wording). Please revise the plan and the one-pager together. I agree that the next useful review is the frozen protocol, the deletion scorer and a few worked KEEP / latest-span / negation examples.
