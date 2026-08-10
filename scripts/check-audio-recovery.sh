#!/usr/bin/env bash
# Checks that a change of audio input device leaves the recorder usable.
#
#   scripts/check-audio-recovery.sh
#
# The cases are in tests/audio-recovery-cases.yaml. Nothing here touches the
# machine's audio settings: the input binding is moved inside the process, so
# this is safe to run while somebody is dictating. It does not open the
# microphone either, which is also the limit of what it proves — see the note at
# the top of Sources/ParrotFlow/AudioRecoveryCommand.swift.
#
# The config is a scratch one. `audio.output_dir` decides where clips go *and*
# where the trace is written (main.swift), so a run against the real config
# would write into the recordings folder this app exists to keep clean.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/parrotflow-audio-recovery.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

mkdir -p "$SCRATCH/config" "$SCRATCH/clips"
cat > "$SCRATCH/config/config.yaml" <<YAML
# Written by scripts/check-audio-recovery.sh. Nothing reads it but this run.
audio:
  sample_rate: 16000
  output_dir: $SCRATCH/clips
  # The synthetic clips below are a few hundred milliseconds of wall clock, and
  # a floor would delete them before they could be measured.
  min_duration_seconds: 0
transcription:
  enabled: false
YAML

cd "$ROOT" || exit 1
PARROTFLOW_CONFIG_DIR="$SCRATCH/config" "$BIN" --audio-recovery --cases "$ROOT/tests/audio-recovery-cases.yaml"
