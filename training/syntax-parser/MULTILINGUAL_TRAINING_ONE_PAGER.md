# Multilingual training — one-page summary

13 October 2026. Revised after reviewer agreement. Research pipeline implemented and smoke-tested; full campaign training has not started.

**Goal.** Produce small English/French/Spanish task adapters for mmBERT: dependency trees for hesitation analysis, POS and morphology for grammatical context, and named-entity spans/types for vocabulary candidates. The model supplies structured predictions; a separate, conservative program decides whether to delete an earlier formulation or propose a vocabulary replacement. The latest formulation must survive.

**Architecture.** Keep the original pretrained mmBERT-small weights frozen. Read the raw output of block 12 and train rank-4 attention LoRA plus small task heads. Use one multilingual adapter per task path: grammar, syntax, and NER—not one adapter per language. POS and morphology share the grammar adapter. Syntax still uses a compact **biaffine head**; LoRA and biaffine are complementary components. Separate adapters require separate encoder paths, even when they share stored base weights.

**Why these choices.** At five matching English training epochs, block 12 beat block 11 by **0.80 LAS points on English500 and 0.90 on GUM**. A layer-mixture pilot did not justify its complexity; block 13 failed the improvement gate. A shared EN/FR/ES adapter improved English over an English-only control at the same English exposure, although it used more total compute. An explicit language feature had no consistent benefit. These results support our next baseline; they do not establish a universal best architecture or trained Catalan support.

**Data.** Start with a reproducible core of **3,000 ordinary UD training sentences per language**. Reuse the established EN/FR/ES selection; defer Catalan to a later campaign. The adjudicated dataset contributes **688 training candidates, 152 development cases and 168 regression-test cases** to this campaign. Catalan, diagnostic-only and unresolved rows remain outside its training manifest. Its labels are AI-reviewed proposals, and it is not a POS/morphology/NER corpus. NER needs its own multilingual span/type annotations.

**Training sequence.** First fit grammar for five epochs and freeze it. Screen syntax with versus without its predicted POS/morphology features for two matched epochs; continue the selected architecture to epoch five. Then branch the same syntax checkpoint into **two additional epochs with approximately 10% hesitation examples**, versus an equal-step ordinary-UD control. Keep the reviewed repair/KEEP proportions. Train fixed-category NER separately for three epochs once its data is ready; allow a predeclared two-epoch extension only if development results support it. Use seeds 42 and 43; evaluate and save a full resume every epoch.

**Optimization.** Retain the working AdamW recipe: head learning rate 0.001, LoRA 0.0001, weight decay 0.01, batch 16 and gradient clipping at 5. Keep learning rates constant in the first campaign. Do not introduce a new scheduler, rank search or joint multitask objective while testing multilingual transfer and hesitation supervision.

**Success.** Report each language, each seed, ordinary parsing accuracy, repair accuracy and harmful changes separately. Protect KEEP examples, negation and latest spans. Judge NER by exact spans/types and false candidates, not token accuracy. Existing synthetic holdouts are regression evidence; new real-dictation confirmation is required before deployment. No numerical Stanza-parity or production-safety promise follows from the present results.

**Implementation.** The [campaign package and runbook](campaign/README.md) now provide the frozen EN/FR/ES manifest, masked grammar training, both syntax branches, hesitation/control continuation, automatic deletion scorer and gated NER path. See the [implementation and validation report](MULTILINGUAL_PIPELINE_IMPLEMENTATION.md). The budget remains **18,552 updates before NER**. Full training has not started; COSER model evaluation remains untouched. Reviewed multilingual NER data is still a prerequisite.


[Full training plan: decisions, data, architecture, optimization, epoch budgets and validation](MULTILINGUAL_TRAINING_PLAN.md).
