#!/usr/bin/env bash
# Endings the decoder wrote over silence, and endings it really heard.
#
#   scripts/check-invented-tail.sh
#
# The cases are in tests/invented-tail-cases.yaml, and every one of them is a
# decode taken out of trace.jsonl. No audio and no model: the words, their
# timings and their confidences are what the decoder returned, and the rule
# reads nothing else.
#
# Both halves of the trim are scored. `ASRResult.text` is a separate string
# from the token timings, so a run dropped from one and not the other leaves
# the screen and the trace describing different sentences — and nothing would
# say so.
#
# The config is a scratch one. `audio.output_dir` decides where clips and the
# trace go, so a run against the real config would write into the recordings
# folder.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/parrotflow-invented-tail.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

mkdir -p "$SCRATCH/config" "$SCRATCH/clips"
cat > "$SCRATCH/config/config.yaml" <<YAML
# Written by scripts/check-invented-tail.sh. Nothing reads it but this run.
audio:
  output_dir: $SCRATCH/clips
transcription:
  enabled: false
YAML

cd "$ROOT" || exit 1
PARROTFLOW_CONFIG_DIR="$SCRATCH/config" "$BIN" --invented-tail \
  --cases "$ROOT/tests/invented-tail-cases.yaml"
