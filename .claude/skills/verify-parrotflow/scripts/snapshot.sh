#!/usr/bin/env bash
# Shared state a CLI run can touch. Read-only.
#   snapshot.sh <out-file>
set -uo pipefail
[ $# -eq 1 ] || { echo "usage: snapshot.sh <out-file>" >&2; exit 2; }
OUT="$1"
ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
SUPPORT="$HOME/Library/Application Support/ParrotFlow"

{
  echo "## logs: lines bytes path"
  for f in "$HOME/Library/Logs/ParrotFlow.log" "$HOME/Library/Logs/ParrotFlow-Dev.log"; do
    if [ -f "$f" ]; then
      printf '%s %s %s\n' "$(wc -l < "$f" | tr -d ' ')" "$(wc -c < "$f" | tr -d ' ')" "${f/#$HOME/~}"
    else
      echo "missing ${f/#$HOME/~}"
    fi
  done

  # cli rows are --transcribe re-runs; live rows are the user dictating.
  echo "## traces: rows cli-rows path"
  for f in "$HOME/.config/parrotflow/recordings/trace.jsonl" \
           "$HOME/.config/parrotflow-dev/recordings/trace.jsonl" \
           "$HOME/Recordings/ParrotFlow/trace.jsonl" \
           "$HOME/Recordings/ParrotFlow Dev/trace.jsonl"; do
    if [ -f "$f" ]; then
      printf '%s %s %s\n' "$(wc -l < "$f" | tr -d ' ')" "$(grep -c '"source":"cli"' "$f")" "${f/#$HOME/~}"
    else
      echo "missing ${f/#$HOME/~}"
    fi
  done

  echo "## release support dir: mtime path (depth 2, python/ skipped)"
  find "$SUPPORT" -maxdepth 2 -type f ! -path '*/python/*' -exec stat -f '%m %N' {} + 2>/dev/null \
    | sed "s|$HOME|~|" | sort -k2

  echo "## git status --short"
  git -C "$ROOT" status --short
} > "$OUT"
