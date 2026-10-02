#!/usr/bin/env bash
# Runs the tree's binary once, under the run's scratch config, and keeps the proof.
#   pf.sh <run-dir> <label> --flag [args...]
# Writes <run-dir>/NN-<label>.{cmd,out,err,exit,log}. Prints stdout and the exit code.
set -uo pipefail
[ $# -ge 2 ] || { echo "usage: pf.sh <run-dir> <label> --flag [args...]" >&2; exit 2; }
LABEL="$2"
RUN="$(cd "$1" 2>/dev/null && pwd)" && [ -f "$RUN/run.env" ] || { echo "no $1/run.env; run start.sh first" >&2; exit 2; }
shift 2
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git -C "$HERE" rev-parse --show-toplevel)"
BIN="$ROOT/.build/release/ParrotFlow"
# run.env is read as data, never sourced.
CFG="$(sed -n 's/^CFG=//p' "$RUN/run.env" | tail -1)"
TMP="${TMPDIR:-/tmp}"; TMP="${TMP%/}"
# A direct child only: no "/" after the prefix, so no "..".
name="${CFG#"$TMP"/}"
case "$name" in
  */*|"$CFG") ok=no ;;
  parrotflow-verify.*) ok=yes ;;
  *) ok=no ;;
esac
[ "$ok" = yes ] || { echo "CFG in $RUN/run.env is not a parrotflow-verify dir under $TMP: '$CFG'" >&2; exit 2; }

refuse() { echo "refused: $1" >&2; exit 2; }

# No flag means the binary starts a menu bar app, as the release variant.
[ $# -gt 0 ] || refuse "no flag given; the binary would start a second menu bar app"

# The binary looks for each mode flag anywhere in its arguments, so every
# flag is checked, not only the first.
modes=0
for a in "$@"; do
  case "$a" in
    --pipeline|--replace|--check-config|--seed-config|--route|--eval|--version)
      modes=$((modes + 1));;
    --transcribe)
      [ "${PF_ALLOW_TRANSCRIBE:-}" = 1 ] \
        || refuse "--transcribe loads a ~1 GB model; ask the user, then set PF_ALLOW_TRANSCRIBE=1"
      modes=$((modes + 1));;
    --app|--quiet|--vars|--no-prompts|--keyed|--cases|--probe|--verbose|--no-vocab) ;;
    --*)
      refuse "$a is not one of the flags this skill drives (see SKILL.md)";;
  esac
done
case "$1" in --*) ;; *) refuse "first argument must be a flag, got '$1'";; esac
[ "$modes" -eq 1 ] || refuse "give exactly one of --pipeline, --replace, --check-config, --seed-config, --route, --eval, --transcribe, --version"

[ -d "$CFG" ] || { echo "scratch config $CFG is gone; start a new run" >&2; exit 2; }

n=$(find "$RUN" -maxdepth 1 -name '*.cmd' | wc -l | tr -d ' ')
STEM="$RUN/$(printf '%02d' $((n + 1)))-$LABEL"
LOG="$HOME/Library/Logs/ParrotFlow.log"
before=$( [ -f "$LOG" ] && wc -l < "$LOG" || echo 0 )

{ printf 'cd %q && PARROTFLOW_CONFIG_DIR=%q' "$ROOT" "$CFG"; printf ' %q' "$BIN" "$@"; echo; } > "$STEM.cmd"
(cd "$ROOT" && PARROTFLOW_CONFIG_DIR="$CFG" "$BIN" "$@" > "$STEM.out" 2> "$STEM.err" < /dev/null)
code=$?
echo "$code" > "$STEM.exit"

# The log truncates at 1 MB; a shorter log means it rolled over during the run.
after=$( [ -f "$LOG" ] && wc -l < "$LOG" || echo 0 )
if [ "$after" -ge "$before" ]; then
  tail -n "+$((before + 1))" "$LOG" > "$STEM.log"
else
  cp "$LOG" "$STEM.log"
fi

cat "$STEM.out"
echo "exit=$code  log+$(wc -l < "$STEM.log" | tr -d ' ')  evidence=$STEM.*"
exit "$code"
