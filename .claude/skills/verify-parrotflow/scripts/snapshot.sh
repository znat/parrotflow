#!/usr/bin/env bash
# Shared state a CLI run can touch. Read-only.
#   snapshot.sh <out-file>
set -uo pipefail
[ $# -eq 1 ] || { echo "usage: snapshot.sh <out-file>" >&2; exit 2; }
OUT="$1"
ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
SUPPORT="$HOME/Library/Application Support/ParrotFlow"
rc=0

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

  echo "## release support dir: mtime size path (depth 2, python/ skipped)"
  if [ -d "$SUPPORT" ]; then
    find "$SUPPORT" -maxdepth 2 -type f ! -path '*/python/*' -exec stat -f '%Fm %z %N' {} + \
      | sed "s|$HOME|~|" | sort -k3 || rc=1
  else
    echo "missing ${SUPPORT/#$HOME/~}"
  fi

  echo "## git status --short"
  git -C "$ROOT" status --short || rc=1
} > "$OUT" || rc=1
[ "$rc" -eq 0 ] || echo "snapshot.sh: $OUT is incomplete" >&2
exit "$rc"
