# Multilingual training pipeline

The final research pipeline trains **English, French and Spanish** task adapters
on frozen mmBERT-small, using **raw block 12** throughout. POS/morphology, syntax
and fixed-category NER have separate LoRA adapters and task heads.

Start with the [training plan](MULTILINGUAL_TRAINING_PLAN.md) and
[run commands and input contracts](campaign/README.md).

```sh
cd training/syntax-parser
uv sync --group dev
uv run python -m pytest -q
uv run python -m campaign.cli --help
```

All committed tests use small synthetic fixtures and run without model downloads
or private datasets. The [validation record](verification/implementation-smoke.json)
states the final source test and CPU/MPS smoke results. Smoke training is an
implementation check, not a trained model or generalization score.

The `campaign/` package is self-contained. It contains the selected encoder path,
LoRA, biaffine head, data contracts, training orchestration and evaluation policy.
Layer-search probes, historical training entry points and review exchanges are
not part of the maintained pipeline.

No training corpora, dictation logs, model caches or checkpoints are committed.
Preparation requires the separately provisioned pinned sources listed in the
runbook. A reviewed multilingual NER corpus remains an outstanding input.
Full training and protected endpoint evaluation are explicit separate commands;
production application configuration is unchanged.
