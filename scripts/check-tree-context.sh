#!/usr/bin/env bash
# Scores the pure half of the tree context — what `TreeContext.assemble` makes
# of the labels a Slack window publishes.
#
#   scripts/check-tree-context.sh
#
# Deterministic and offline. The walk itself needs a running Slack and is
# checked with `--peek` against a real window, the same split `check-context.sh`
# makes for terminals.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }
"$BIN" --tree-test
