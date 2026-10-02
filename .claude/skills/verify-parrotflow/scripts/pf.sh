#!/usr/bin/env bash
# Runs the tree's binary once, under the run's scratch config, and keeps the proof.
#   pf.sh <run-dir> <label> --flag [args...]
# Writes <run-dir>/NN-<label>.{cmd,out,err,exit,log}. Prints stdout and the exit code.
set -uo pipefail
[ $# -ge 2 ] || { echo "usage: pf.sh <run-dir> <label> --flag [args...]" >&2; exit 2; }
RUN="$1"; LABEL="$2"; shift 2
[ -f "$RUN/run.env" ] || { echo "no $RUN/run.env; run start.sh first" >&2; exit 2; }
# shellcheck source=/dev/null
. "$RUN/run.env"

refuse() { echo "refused: $1" >&2; exit 2; }

# No flag means the binary starts a menu bar app, as the release variant.
[ $# -gt 0 ] || refuse "no flag given; the binary would start a second menu bar app"
case "$1" in --*) ;; *) refuse "first argument must be a flag, got '$1'";; esac

for a in "$@"; do
  case "$a" in
    --panels|--preview-panel|--preview-transform|--empty|--panel-sheet|--tutorial-sheet|--tour-film)
      refuse "$a draws surfaces nobody can see or writes images; not part of verification";;
    --record|--watch-modifiers|--watch-taps|--audio-recovery|--set)
      refuse "$a uses the microphone, the keyboard, or changes the microphone list";;
    --peek|--edit-test|--span-test|--clipboard-test|--paste-probe|--field-dump|--context-test)
      refuse "$a reads or writes the frontmost app or the clipboard";;
    --set-key)
      refuse "$a writes the keychain";;
    --warm|--warm-models|--slot-model|--sentence-model|--phonemes|--setup-parsing|--update-check|--update-install)
      refuse "$a downloads models, installs software, or reaches the network";;
    --transcribe)
      [ "${PF_ALLOW_TRANSCRIBE:-}" = 1 ] \
        || refuse "--transcribe loads a ~1 GB model; ask the user, then set PF_ALLOW_TRANSCRIBE=1";;
  esac
done

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
