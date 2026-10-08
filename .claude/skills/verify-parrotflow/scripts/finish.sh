#!/usr/bin/env bash
# Closes a run: after-snapshot, diff, removes the scratch config. Keeps the evidence.
#   finish.sh <run-dir>
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ $# -eq 1 ] || { echo "usage: finish.sh <run-dir>" >&2; exit 2; }
RUN="$1"
[ -f "$RUN/run.env" ] || { echo "no $RUN/run.env" >&2; exit 2; }
CFG="$(sed -n 's/^CFG=//p' "$RUN/run.env" | tail -1)"

[ -f "$RUN/state-before.txt" ] || { echo "no $RUN/state-before.txt; scratch config kept" >&2; exit 1; }
"$HERE/snapshot.sh" "$RUN/state-after.txt" || { echo "after-snapshot failed; scratch config kept" >&2; exit 1; }
diff "$RUN/state-before.txt" "$RUN/state-after.txt" > "$RUN/state-diff.txt"
# diff exits 1 when the files differ; 2 is an error.
[ $? -le 1 ] || { echo "diff failed; scratch config kept" >&2; exit 1; }
echo "## shared-state diff (before < > after)"
if [ -s "$RUN/state-diff.txt" ]; then cat "$RUN/state-diff.txt"; else echo "no change"; fi

# Only the dir start.sh made: a mktemp dir named parrotflow-verify.*
TMP="${TMPDIR:-/tmp}"; TMP="${TMP%/}"
# A direct child only: no "/" after the prefix, so no "..".
name="${CFG#"$TMP"/}"
case "$name" in
  */*|"$CFG") ok=no ;;
  parrotflow-verify.*) ok=yes ;;
  *) ok=no ;;
esac
case "$ok" in
  yes)
    if [ -d "$CFG" ]; then
      (cd "$CFG" && find . -maxdepth 2 | sort) > "$RUN/scratch-contents.txt"
      if [ -d "$CFG/recordings" ]; then
        for f in "$CFG"/recordings/*.jsonl; do
          [ -e "$f" ] || continue
          # shellcheck disable=SC2015  # the block runs when either step fails
          mkdir -p "$RUN/scratch-recordings" && cp "$f" "$RUN/scratch-recordings/" || {
            echo "could not copy $f; kept scratch config $CFG" | tee "$RUN/cleanup.txt"
            exit 1
          }
        done
      fi
      if rm -rf "$CFG"; then
        echo "removed scratch config $CFG" | tee "$RUN/cleanup.txt"
      else
        echo "could not remove scratch config $CFG" | tee "$RUN/cleanup.txt"
        exit 1
      fi
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
