# EN/FR/ES training pipeline

This package implements the reviewed layer-12 research campaign. It separates **preparation**, **disposable smoke training**, **campaign training**, and **one-time endpoint evaluation**. It does not change ParrotFlow's production configuration or run on microphone transcripts.

## Entry points

Run from `training/syntax-parser` using its `.venv`:

```sh
# Freeze the existing 9,000 UD and 688 local training rows, annotation inventories,
# source hashes, per-seed batch/view plans, protected content and endpoint eligibility.
.venv/bin/python -m campaign.cli prepare --output artifacts/NEW-data

# Short integrated check: grammar, context/features syntax, local/control continuation,
# augmentation, automatic deletion evaluation, NER fixtures and exact/tolerant resume.
.venv/bin/python -m campaign.cli smoke --data artifacts/NEW-data \
  --output artifacts/NEW-smoke --device cpu

# Full 18,552-update campaign. This command is deliberately separate from smoke.
.venv/bin/python -m campaign.cli train --data artifacts/NEW-data \
  --output artifacts/NEW-campaign --device mps

# Explicit one-time exposure, after completed training. Never called by train/smoke.
.venv/bin/python -m campaign.cli coser-endpoint --data artifacts/NEW-data \
  --output artifacts/NEW-campaign --device mps
```

Preparation refuses to overwrite an existing directory. Training can resume the same run only with matching code, prepared-data manifest and device. Full runs cannot consume smoke checkpoints. The copied English parquet files and cached French/Spanish sources are read locally; no downloads occur. `prepare` may reject changed/overlength inputs rather than silently alter the fixed campaign counts.

`artifacts/multilingual-campaign-data-v2` is a prepared corpus from this implementation task. The [validation record](../verification/implementation-smoke.json) records the final smoke and code revision. Prepared data and smoke outputs are provisioned separately and are not committed.

## Modules

| Module | Responsibility |
|---|---|
| `encoder.py`, `adapters.py`, `parser.py`, `trees.py` | Final block-12 representation, LoRA, biaffine decoding and strict UD targets |
| `dataset.py` | Raw UD annotation reconciliation, train-only inventories, unknown versus absent masks, split/family protection, 564/627-step schedules |
| `surface.py` | Source-unit alignment, lowercase offsets, terminal-leaf-period reduction, heldout collision rejection |
| `repair.py` | Predicted-tree-only candidate/deletion policy and separate gold scoring |
| `network.py` | Fresh block-12 grammar/syntax/NER LoRA packages and frozen teacher probability cache |
| `training.py` | Optimizer, full resumable state, implementation/data locks, runtime guard and per-epoch evaluation |
| `metrics.py` | Per-language/treebank/family metrics, paired language-stratified sentence bootstrap, feature decision |
| `ner.py`, `ner_runner.py` | Reviewed span schema, unknown-region masks, deterministic NER views, extension gate and one-time confirmation |
| `cli.py` | Staged orchestration, scorer preflight, H gates and protected COSER endpoint |

All randomness in sampling/augmentation is encoded in prepared plans. CPU/MPS dropout RNG and the exact batch cursor are saved in full resumes. Sparse morphology heads can legitimately have fewer AdamW updates than the global counter. CPU next-update verification is exact; smoke verification on MPS uses declared `rtol=1e-6`, `atol=1e-7` while separately reporting bitwise equality. This tolerance is recorded explicitly; it does not claim bitwise GPU determinism.

The feature screen requires mean paired macro LAS gain ≥0.20 points, a positive gain in both seeds, no language loss >0.50 points, **and each seed's conditional paired macro bootstrap lower bound >0**. Otherwise it records failed/inconclusive and retains context-only. This is a conservative engineering policy; its bootstrap does not quantify seed variability. COSER can veto if repair F1 declines or LAS declines >0.50 points versus either parent or matched control. Those policies are frozen before training.

## Automatic deletion policy

Inference receives only text, words, language, surface units and predicted heads/relations. Gold intent and earlier/latest spans are passed **only to `score` afterward**. Only explicit forward `reparandum` subtrees can authorize edits. Shared roles and `parataxis` generate candidates but never independently authorize deletion. The policy rejects discontinuous subtrees, unknown intervening material, whole-clause deletion, negation, partial contraction/clitic units, latest overlap and conflicting edits. Small explicit EN/FR/ES cue inventories are versioned in code.

This intentionally conservative policy may miss valid repairs. Its safety must be measured on model predictions. Handcrafted/gold-tree fixtures establish mechanics, not real-world precision. A correct score on fixtures cannot make a model's mistaken reparandum safe. Source UD/surface mappings remain an input requirement; raw-ASR segmentation and model export are separate deployment work.

Punctuation augmentation is deliberately **terminal leaf period removal**, not indiscriminate punctuation stripping. Cue commas, apostrophes, accents and clitic punctuation survive. Broader augmentation needs a new validated invariant-label policy. Unavailable surface alignment, nonleaf punctuation and heldout collisions fall back to the original row with a recorded reason.

## NER data gate

A reviewed EN/FR/ES NER corpus is not currently supplied. This is a data prerequisite, not a missing training path. Smoke fixtures do not satisfy the reviewed-data contract.

```sh
.venv/bin/python -m campaign.cli ner-prepare \
  --input reviewed-ner.json --output artifacts/NEW-ner-data
.venv/bin/python -m campaign.cli ner-train --data artifacts/NEW-data \
  --ner-data artifacts/NEW-ner-data --output artifacts/NEW-ner-run --device mps
.venv/bin/python -m campaign.cli ner-confirmation --data artifacts/NEW-data \
  --ner-data artifacts/NEW-ner-data --output artifacts/NEW-ner-run --device mps
```

Input is a JSON list. Every row must have `id`, `language` (`en/fr/es`), `split` (`train/dev/confirmation`), `text`, `spans`, `annotation_complete`, `reviewed: true`, nonempty `review_provenance`, `group_id`, `source_id`, `template_id` and `name_families` for named examples. Spans use source-character `[start,end)` boundaries and one of `person`, `vendor_platform`, `project`, `location`, `product_tool`. Partially labeled text needs explicit `unknown_spans`; these regions are masked and cannot overlap positive spans. A review flag records supplied provenance, not verification that a human reviewed it.

Each language must occur in all splits. Source/template/group/name families and normalized text must not cross splits. Preparation checks character/token alignment and the subword limit; language-balanced plans cycle smaller pools and record the update budget. Training uses three epochs/two seeds; epochs 4–5 run only if both seeds satisfy the frozen development gate. Confirmation is a separate one-time command. Optional grammar-feature NER is outside the required first context-only NER campaign.

## Review and tests

```sh
.venv/bin/python -m pytest -q
```

Endpoint commands create an exclusive consumption marker **before** evaluation. A failed endpoint stays marked for investigation instead of permitting an accidental rerun. Ordinary preparation may inspect COSER text/labels for exclusion and length eligibility, but neither training nor smoke evaluates its model predictions.

The training plan remains the rationale; this package and its frozen manifests are the execution contract. Full training, confirmation exposure and production promotion are distinct actions.

## Separately provisioned inputs

`prepare` reads the pinned research selection/protocol from
`artifacts/multilingual-layer12-language-feature-v1`, final reviewed syntax
candidates from `artifacts/hesitation-multilingual-adjudicated-v1`, English raw
parquet and hashes from `artifacts/stanza-english-data`, pinned French/Spanish
parquet from the local Hugging Face cache, and protected dev/test JSONL under
`artifacts/data`. These names identify source bundles; no corresponding probe
scripts run. The final prepared bundle can be supplied directly to `train`.

No source corpora or checkpoints are distributed here. The model/tokenizer cache
is also separate; set `HF_HOME` before invoking the CLI when it lives elsewhere.
Preparation rejects missing or changed sources. Training never recreates the
adjudications or interprets archived reviewer conversations.
