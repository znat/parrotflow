# Multilingual parser training

Start with [the one-page plan](MULTILINGUAL_TRAINING_ONE_PAGER.md), then the
[campaign runbook](campaign/README.md) and [implementation report](MULTILINGUAL_PIPELINE_IMPLEMENTATION.md).

## Install and test

```sh
cd training/syntax-parser
uv sync --group dev
uv run python -m pytest -q
uv run python -m campaign.cli --help
```

The source-only tests need no model download. The corpus-import tests skip
explicitly when their separately distributed review artifacts are absent.
The local workspace validation ran all 43 tests with those artifacts present;
CPU and MPS integrated training smoke also passed with exact resume replay.
The clean PR checkout passes 27 tests and explicitly skips the 16 corpus checks;
[recorded verification](verification/implementation-smoke.json) separates the two.

## Data is a separate prerequisite

This source PR does **not** distribute checkpoints, model caches, dictation logs,
training corpora or experiment outputs. Links into `artifacts/` in historical
reports refer to local evidence, not files available in a fresh clone.

`campaign.cli prepare` consumes the frozen data already used in the research:
`artifacts/multilingual-layer12-language-feature-v1` (selection and protocol),
`artifacts/hesitation-multilingual-adjudicated-v1` (reviewed syntax candidates),
`artifacts/stanza-english-data` (pinned English parquet and hashes), cached pinned
French/Spanish parquet under `artifacts/hf-cache`, and official development/test
JSONL under `artifacts/data`. The pinned model/tokenizer cache is also required.
Provision these through the existing research-data handoff before preparation.
This PR does not offer a from-scratch corpus downloader or redistribute the data.
The reviewed multilingual NER corpus is a further, still outstanding input.

The campaign package is the supported entry point. Other Python modules are
included because it reuses their encoder, LoRA, target, parser and evaluation
helpers; their historical experiment CLIs require additional local artifacts.
The optional old candidate comparison reads `PARROTFLOW_REFERENCE_RULE` instead
of a machine-specific path and is not part of campaign execution.

The [CodeRabbit record](CODERABBIT_CAMPAIGN_REVIEW.md) states review coverage and
the quota-limited final check. Production app configuration and disfluency rules
are unchanged. Full campaign training and protected endpoint evaluation are
separate commands and have not been started by this PR.
