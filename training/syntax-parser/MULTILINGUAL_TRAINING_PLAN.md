# Final multilingual training plan

## Executive summary

Train one shared EN/FR/ES adapter for each task path on the original frozen
mmBERT-small: grammar, dependency syntax and fixed-category NER. Read raw block
12 before final normalization. Grammar predicts UPOS and eight morphology
attributes; syntax uses a compact biaffine head and is compared with versus
without frozen grammar probabilities. After selecting syntax features on dev,
continue the selected syntax model, then measure the effect of reviewed
hesitation examples against a matched ordinary-text control.

The grammar/syntax campaign is bounded at **18,552 updates across seeds 42/43**.
NER is separate and cannot start without reviewed multilingual span/type data.
No full campaign or protected endpoint evaluation has run. Short synthetic and
training-row smoke tests validate implementation only. Deployment requires
fresh real-dictation confirmation and application integration.

## Architecture and optimization

- Base: pinned `jhu-clsp/mmBERT-small`; exact model and UD revisions in `config.json`.
- Representation: raw block 12 with aligned mean word pooling and the established
  FP16-to-FP32 pooling roundtrip; no layer search or learned layer mixture.
- LoRA: rank 4, alpha 8, attention Wqkv/Wo in blocks 1–12. Base weights remain frozen.
- Grammar: linear UPOS head plus Number, Person, Tense, VerbForm, Mood, Degree,
  Voice and Gender heads. Train-only inventories distinguish observed absence
  from unannotated attributes. Lemma is outside this campaign.
- Syntax: biaffine arc/label dimensions 128/64, dropout 0.2. Arc and relation
  cross-entropy supervise gold parents during training; inference decodes a
  single-root tree without gold parent hints.
- Optional syntax features: concatenate the frozen grammar teacher's probability
  vectors, project them to 384 dimensions and add them to syntax word states.
  The teacher is fixed at grammar epoch five and uses its own adapter path.
- NER: 11 BIO labels for person, vendor_platform, project, location, product_tool.
- AdamW: head/fusion learning rate 0.001, adapter learning rate 0.0001,
  weight decay 0.01, betas 0.9/0.999, epsilon 1e-8; gradient clipping 5.
  Batch size 16, constant learning rates, seeds 42 and 43.

Implementation: [encoder](campaign/encoder.py), [adapters](campaign/adapters.py),
[task modules](campaign/network.py), [biaffine head](campaign/parser.py).

## Data contract

Freeze 3,000 ordinary UD training sentences per language (9,000 total), the
established primary dev partitions and separate English GUM regression partition.
Add only the final adjudicated, eligible EN/FR/ES hesitation candidates:
688 train, 152 dev and 168 separate regression cases. Catalan and ambiguous or
diagnostic-only records remain excluded. The local annotations are reviewed
synthetic syntax proposals, not human gold and not grammar/NER supervision.

| Language | Ordinary training words | Local repairs | Local KEEP |
|---|---:|---:|---:|
| English | 47,910 | 125 | 108 |
| French | 62,373 | 121 | 106 |
| Spanish | 94,459 | 120 | 108 |

Validate source hashes, official splits, shared-family boundaries, normalized
text/target leakage, alignment, one-root trees and root-label consistency.
Reject overlength inputs (>256 subwords) rather than truncating trees.
Morphology coverage is inferred per treebank/attribute from pinned training
annotations; this masks unsupported attributes but does not prove perfect
annotation completeness. Preserve this limitation in result interpretation.

NER needs its own reviewed EN/FR/ES corpus, including source/template/name-family
split locks, entity-free hard negatives, explicit unknown spans and operational
type definitions. Generic ORG labels do not establish vendor/project identity.
The source-only tests do not substitute for that corpus.

## Bounded training sequence

| Stage | Runs | Epochs | New updates |
|---|---:|---|---:|
| Grammar | 2 seeds | 1–5 | 5,640 |
| Syntax feature comparison | 2 arms × 2 seeds | 1–2 | 4,512 |
| Selected syntax architecture | 2 seeds | 3–5 | 3,384 |
| Hesitation versus ordinary control | 2 arms × 2 seeds | 6–7 | 5,016 |
| Total before NER | | | 18,552 |

Grammar uses ordinary UD only: UPOS cross-entropy plus the mean loss over
observed morphology attributes. Missing targets contribute no loss.

Both syntax arms have matched initializations and batch order. Select grammar
features only when mean paired macro LAS gain is at least 0.20 percentage points,
both seeds improve, no language loses over 0.50 points, and each seed's conditional
paired sentence-bootstrap lower bound exceeds zero. Otherwise retain context-only.
GUM is separate regression evidence and does not change the three-language macro.
The sentence bootstrap does not estimate seed uncertainty.

At syntax epoch five, fork the full optimizer/RNG state into H mix and H control.
Each language retains 188 ordinary batches and adds 21 full 16-row slots per
epoch: 627 updates and 10,008 sentence exposures overall. Mix uses 1,008 local
exposures (10.07%); control fills the same slots with ordinary rows. Local rows
cycle before repeats, preserving the reviewed repair/KEEP proportions. Different
sequence lengths mean identical step counts are not identical compute/dropout.

Requested H views are frozen before training: 50% original, 25% lowercase and
25% terminal-leaf-period reduction. Preserve lexical punctuation, cue commas,
accents and clitics. Remap word heads and surface offsets, reject heldout
collisions, and revert unsafe transforms to the original with a recorded reason.
Teacher features are computed from the actual transformed input.

NER trains three epochs for both seeds once its data gate passes. Continue for
exactly two more only if both seeds gain at least 0.50 macro typed F1 points from
epoch 2 to 3, no language loses more than one point, and negative-case false
candidate rates do not rise. Confirmation is a separate single-use command.

## Evaluation and repair policy

The automatic deletion policy receives only source text, aligned words/surface
units and predicted trees. Explicit forward reparandum is required for deletion.
Parallel roles and parataxis are candidates, never independent deletion authority.
Reject malformed trees, discontinuous or whole-clause edits, unknown cue gaps,
partial contractions, negation loss, latest-span overlap and conflicting edits.
Gold earlier/latest/intent annotations enter only afterward for scoring.

Report each seed and language, ordinary gold-PUNCT-excluded UAS/LAS, natural
reparandum edges, grammar/NER counts, synthetic all-token structure and exact
output repairs separately. Track newly damaged KEEP cases by sentence identity,
not only aggregate counts. H needs positive macro repair gain in both seeds,
no primary-language LAS loss over 0.50 points versus control, no new harmful KEEP
cases, and zero latest/negation deletions. Natural-repair regressions require analysis.

COSER's 539 sentences/164 repair edges are reserved for one fixed endpoint job:
compare parent S5, H7 control and H7 mix for both seeds. A repair-F1 decline or
LAS loss over 0.50 points versus either reference vetoes promotion. Source and
checkpoint prerequisites precede the exclusive consumption marker; after
reservation, failure stays marked to prevent silent repeat exposure. Never tune
on this endpoint. Local synthetic dev/test and existing English/GUM sets are
regression evidence, not fresh confirmation.

## Resuming and interpreting results

Save adapter/head/fusion parameters, optimizer moments/counters, RNG, exact batch
cursor, accumulated loss/rejection counters, teacher identity and code/data/base
hashes. A resumed epoch retains its statistics and replaces its history entry.
Code changes require a new run. Preserve the base hash each epoch, and verify
next-update replay in smoke tests. CPU replay is exact; MPS uses a declared tight
tolerance and reports actual equality separately.

Run one MPS training process at a time. At the first 20 fresh-epoch updates, save
and stop if projected epoch time exceeds 10 minutes; an explicit resume can
continue after investigation. Do not silently change batch size, precision,
selection or budgets. Execution commands are in the [runbook](campaign/README.md).

Full model-quality evidence, clustered uncertainty for hesitation/NER, standalone
model export, raw-ASR segmentation, code-switching and fresh dictation confirmation
remain subsequent evaluation/deployment work. Tests and smoke establish program
behavior, not Stanza parity or production deletion safety.
