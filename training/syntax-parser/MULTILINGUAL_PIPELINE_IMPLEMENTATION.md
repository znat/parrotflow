# Multilingual training pipeline implementation

13 October 2026. Research implementation, ready for review. Full campaign training has not started. No COSER model predictions, confirmation evaluation or production changes were made.

## What is implemented

The executable entry point is `python -m campaign.cli`. The [runbook](campaign/README.md) lists preparation, smoke, full training, NER preparation/training and explicit endpoint commands. The [training plan](MULTILINGUAL_TRAINING_PLAN.md) explains the earlier layer/architecture choices.

| Component | Implemented behavior |
|---|---|
| Data | Frozen EN/FR/ES UD selection; reconciliation with pinned raw annotations; train-only inventories; eligibility, family/split/content locks; length and source-hash checks |
| Grammar | Fresh block-12 rank-4/alpha-8 LoRA; UPOS plus eight morphology attributes; unknown supervision masked separately from observed absence |
| Syntax | Fresh context-only and frozen grammar-feature arms; dynamic probability projection; matched seeds/batches; development selection with paired uncertainty |
| Hesitation | Epoch-five full-resume branches into two local-data epochs versus matched ordinary-UD control; preserved local repair/KEEP proportions |
| Augmentation | Frozen requested views; lowercase and terminal leaf period reduction; remapped offsets/heads; collision or alignment failures revert to original |
| Mechanical repair | Predicted-tree-only candidates; explicit forward reparandum required for deletion; surface-aware contractions; latest/negation/KEEP scoring after inference |
| NER | Five fixed types, BIO targets, reviewed-corpus schema, unknown-region masks, source/name/template split locks; three epochs and a conditional two-epoch extension |
| Reproducibility | Base/code/data/teacher locks, optimizer and CPU/MPS RNG, batch cursor, periodic full resumes, exact/tolerant replay test, runtime guard |
| Evaluation gates | Per-language/treebank/family counts; primary ordinary LAS and repair safety gates; newly harmed KEEP examples tracked individually; one-time COSER/NER confirmation markers |

The core schedule remains **18,552 updates before NER**, seeds 42/43, constant AdamW learning rates 0.001 for task heads and 0.0001 for adapters, weight decay 0.01, batch 16, gradient clipping 5. Smoke uses disposable checkpoints and cannot become a campaign parent.

## Prepared data

[Prepared manifest](artifacts/multilingual-campaign-data-v2/manifest.json) and [frozen protocol](artifacts/multilingual-campaign-data-v2/protocol.json).

| Language | Ordinary training sentences | Ordinary training words | Local training repairs | Local training KEEP |
|---|---:|---:|---:|---:|
| English | 3,000 | 47,910 | 125 | 108 |
| French | 3,000 | 62,373 | 121 | 106 |
| Spanish | 3,000 | 94,459 | 120 | 108 |
| Total | 9,000 | 204,742 | 366 | 322 |

Local development has 152 rows; the separate local regression partition has 168. These are reviewed synthetic syntax proposals, not human gold, and are not used as grammar/NER supervision. Catalan stays outside this campaign. All 539 COSER sentences pass the frozen input-length eligibility check, including 164 reparandum edges; this is a data check, not model evaluation.

Morphology coverage is inferred per treebank/attribute from whether that attribute occurs in the pinned training annotations. ESLSpok morphology is masked; AnCora Voice and the selected French treebanks' Degree are masked. This reproducible heuristic does not establish perfect annotation completeness. Missing-label conventions should remain visible during research review.

## Verification

The final regression suite covers import/data protections, the existing mechanical diagnostic, the new surface-aware policy, masked grammar loss, pairing/exposure, feature gates, NER spans/leakage, checkpoint replay, resume cursors, runtime-guard continuation and endpoint prerequisites.

**43 tests passed.** See [tests/test_campaign.py](tests/test_campaign.py) for the new tests and the runbook for the complete command.

The integrated smoke covers six paths: grammar, context syntax, grammar-feature syntax, hesitation mix, ordinary control and NER fixtures. It performs 24 stage updates and two replay-probe updates, using training examples only. It exercises both ordinary/local sampling and all three requested views; it does not estimate generalization or choose the feature arm.

Final smoke results and code hashes are recorded in [verification.json](artifacts/campaign-implementation-verification-v1.json). CPU and GPU checkpoint replay are checked independently; cross-backend equality is not claimed. The declared GPU replay tolerance is `rtol=1e-6, atol=1e-7`, with actual bitwise equality reported separately.

The integrated check caught and fixed a real frozen-teacher issue: inference-mode probability tensors could not be saved for fusion-layer backward. The teacher now uses no-grad tensors; a regression test confirms that fusion receives gradients while the teacher remains frozen.

## Mechanical-policy coverage

The [reference-tree mechanics report](artifacts/campaign-gold-tree-mechanics-v1.json) supplies the 688 **training** trees to the policy, isolating its behavior from parser errors.

| Language | Exact repairs | KEEP changed | Latest/negation deleted |
|---|---:|---:|---:|
| English | 64 / 125 | 0 / 108 | 0 |
| French | 51 / 121 | 0 / 106 | 0 |
| Spanish | 61 / 120 | 0 / 108 | 0 |
| Total | 176 / 366 | 0 / 322 | 0 |

This is **48.1% repair coverage on reference trees**, not trained-model accuracy or a safety guarantee. Whole-clause restarts, discontinuous spans and ambiguous parallel roles often abstain. Shared `obj`/`obl` roles and `parataxis` identify candidates but cannot authorize deletion alone. Broader deletion policies require their own scored change.

## External review

See [CodeRabbit review record](CODERABBIT_CAMPAIGN_REVIEW.md). The full package was reviewed in an isolated temporary repository containing only relevant source and context. No datasets, checkpoints or unrelated working-tree changes were submitted.

Validated findings were fixed: complete checkpoint dependency fingerprints; read-only endpoint prerequisites before consuming evaluation markers; runtime-guard continuation after an explicit resume. A final local audit also changed KEEP gating from aggregate counts to sentence identities, so equal counts cannot conceal newly broken examples.

## Remaining data and evidence boundaries

The grammar/syntax training path is prepared. **NER still needs a separately reviewed multilingual span/type corpus**; only its plumbing has been smoke-tested on tiny authored fixtures. A supplied `reviewed` flag records provenance and cannot certify human review.

Full epochs, language-level quality, natural-speech transfer, clustered uncertainty for hesitation/NER, detailed deployment latency and fresh real-dictation confirmation remain unmeasured. The current implementation exports detailed per-row/per-family predictions/counts and a sentence bootstrap for the syntax feature decision; it does not claim those other analyses have already been performed. The old English comparison checkpoints have not been replayed by this integrated smoke.

The checkpoints are research full resumes, not a standalone deployment export. Raw-transcript segmentation, code-switching, production model packaging and ParrotFlow binary integration remain separate deployment work. Existing production disfluency rules and application configuration are unchanged.
