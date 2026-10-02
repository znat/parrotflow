#!/usr/bin/env bash
# Opens a verification run: evidence dir, scratch config dir, before-snapshot.
#   start.sh            prints the run dir; pass it to pf.sh and finish.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git -C "$HERE" rev-parse --show-toplevel)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "no binary at $BIN; run: swift build -c release" >&2; exit 1; }

RUN="${PF_EVIDENCE_ROOT:-$HOME/Documents/parrotflow-scratch/verify}/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$(dirname "$RUN")"
mkdir "$RUN"
CFG="$(mktemp -d -t parrotflow-verify)"

# Plain KEY=value lines: pf.sh and finish.sh parse this file, they never source it.
{
  printf 'ROOT=%s\n' "$ROOT"
  printf 'BIN=%s\n' "$BIN"
  printf 'CFG=%s\n' "$CFG"
} > "$RUN/run.env"
"$HERE/snapshot.sh" "$RUN/state-before.txt"
echo "$RUN"
