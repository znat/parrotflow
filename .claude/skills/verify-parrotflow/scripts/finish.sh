#!/usr/bin/env bash
# Closes a run: after-snapshot, diff, removes the scratch config. Keeps the evidence.
#   finish.sh <run-dir>
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ $# -eq 1 ] || { echo "usage: finish.sh <run-dir>" >&2; exit 2; }
RUN="$1"
[ -f "$RUN/run.env" ] || { echo "no $RUN/run.env" >&2; exit 2; }
# shellcheck source=/dev/null
. "$RUN/run.env"

"$HERE/snapshot.sh" "$RUN/state-after.txt"
diff "$RUN/state-before.txt" "$RUN/state-after.txt" > "$RUN/state-diff.txt"
echo "## shared-state diff (before < > after)"
if [ -s "$RUN/state-diff.txt" ]; then cat "$RUN/state-diff.txt"; else echo "no change"; fi

# Only the dir start.sh made: a mktemp dir named parrotflow-verify.*
TMP="${TMPDIR:-/tmp}"; TMP="${TMP%/}"
case "$CFG" in
  "$TMP"/parrotflow-verify.*)
    if [ -d "$CFG" ]; then
      (cd "$CFG" && find . -maxdepth 2 | sort) > "$RUN/scratch-contents.txt"
      if [ -d "$CFG/recordings" ]; then
        for f in "$CFG"/recordings/*.jsonl; do
          [ -e "$f" ] || continue
          mkdir -p "$RUN/scratch-recordings" && cp "$f" "$RUN/scratch-recordings/" || {
            echo "could not copy $f; kept scratch config $CFG" | tee "$RUN/cleanup.txt"
            exit 1
          }
        done
      fi
      rm -rf "$CFG" && echo "removed scratch config $CFG" | tee "$RUN/cleanup.txt"
    else
      echo "scratch config already gone: $CFG" | tee "$RUN/cleanup.txt"
    fi
    ;;
  *)
    echo "not removing $CFG: not a parrotflow-verify dir under $TMP" | tee "$RUN/cleanup.txt"
    exit 1
    ;;
esac

echo "## evidence kept at $RUN"
ls -la "$RUN"
