#!/usr/bin/env bash
# Scores in-place editing against a real Claude Code TUI, from tests/inplace-cases.yaml.
#
# Everything else in scripts/ is text in, text out, and can be checked in a
# pipe. This cannot: whether a correction lands depends entirely on the app it
# is landing in, and the app that matters most is the one whose accessibility
# value is a picture of a screen rather than an editable buffer.
#
# So the fixture is a real Claude Code running inside tmux, and the oracle is
# `tmux capture-pane`, which reads the pane through the pty. That is the whole
# design: the write path reports its own success through the accessibility API,
# and the accessibility API is exactly what is on trial — it has reported a
# corrupting paste as a clean write. A verdict has to come from somewhere else.
#
# Two counters, because the failures are not equally bad. A correction that
# does not happen costs a trip to the clipboard. One that happens to the wrong
# text costs the line, and that is the one this exists to prevent.
#
#   scripts/check-inplace.sh
#
# Requires tmux, the dev app installed (`make install`), and Accessibility
# granted to it. It opens a Terminal.app window as its viewport and leaves your
# own terminal alone.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMUX="$(command -v tmux || echo /opt/homebrew/bin/tmux)"
APP="/Applications/ParrotFlowDev.app"
BIN="$APP/Contents/MacOS/ParrotFlow"
SESSION="${PF_CHECK_SESSION:-pfcheck}"
CLAUDE="$(command -v claude || echo "$HOME/.local/bin/claude")"
SCRATCH="${TMPDIR:-/tmp}/pf-check-inplace"

[ -x "$TMUX" ]  || { echo "tmux not found"; exit 1; }
[ -d "$APP" ]   || { echo "install the dev app first: make install"; exit 1; }
[ -x "$CLAUDE" ] || { echo "claude not found"; exit 1; }

# The whole visible input, not just its first row — a wrapped line occupies
# several and comparing only the first would call a truncation a pass.
input_region() {
  "$TMUX" capture-pane -pt "$SESSION" \
    | awk '/^─+$/ {inside = !inside; next} inside {print}' \
    | sed 's/^[[:space:]]*//; s/^❯[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -v '^$' | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

# Clearing has to be checked, not assumed. A reset that half worked leaves the
# next case seeded onto somebody else's text, and it then measures nothing —
# which is how two passing cases turned into two silent refusals.
clear_input() {
  for _ in $(seq 1 12); do
    [ -z "$(input_region)" ] && return 0
    "$TMUX" send-keys -t "$SESSION" C-a; "$TMUX" send-keys -t "$SESSION" C-k
    sleep 0.35
  done
  return 1
}

start_fixture() {
  "$TMUX" kill-session -t "$SESSION" 2>/dev/null
  # claude as the session command, not typed at a shell: typing it races the
  # prompt, and a swallowed keystroke leaves a shell that looks close enough
  # to a TUI to fool the checks below.
  "$TMUX" new-session -d -s "$SESSION" -x 100 -y 30 "$CLAUDE"
  for _ in $(seq 1 60); do
    "$TMUX" capture-pane -pt "$SESSION" | grep -q 'auto mode\|for shortcuts' && break
    sleep 0.5
  done
  mkdir -p "$SCRATCH"
  printf '#!/bin/sh\nexec %s attach -t %s\n' "$TMUX" "$SESSION" > "$SCRATCH/attach.command"
  chmod +x "$SCRATCH/attach.command"
  # A freshly opened window is frontmost without anyone having to click, which
  # is what lets this run unattended.
  open -a Terminal "$SCRATCH/attach.command"
  sleep 4
}

LOG="$HOME/Library/Logs/ParrotFlow-Dev.log"
REPEATS="${PF_REPEATS:-1}"
pass=0; total=0; refused=0; corrupted=0; skipped=0; wrongpath=0

start_fixture
trap '"$TMUX" kill-session -t "$SESSION" 2>/dev/null' EXIT

while IFS='|' read -r name id dictated line heard corrected expect literal want_log; do
  [ -z "$name" ] && continue
  total=$((total + 1))

  if ! clear_input; then
    printf '  ⊘ %s — could not clear the fixture\n' "$name"; skipped=$((skipped + 1)); continue
  fi
  "$TMUX" send-keys -t "$SESSION" -l "$line"; sleep 1
  if [ "$(input_region)" != "$line" ]; then
    printf '  ⊘ %s — seed did not land\n' "$name"; skipped=$((skipped + 1)); continue
  fi

  [ "$expect" = "unchanged" ] && want="$line" || want="$expect"

  mark=$(grep -c "" "$LOG" 2>/dev/null || echo 0)
  open -a Terminal; sleep 2
  open -g -na ParrotFlowDev --args \
    --edit-test "$heard" "$corrected" --find "$id" --dictated "$dictated" $literal --after 3
  sleep 7

  got="$(input_region)"
  # What the line says and which path put it there are separate questions. A
  # case that expects no change passes just as happily when the app refused for
  # a reason nobody intended, or crashed before trying — so the branch it took
  # is asserted too, from the lines this run appended to the log.
  branch="$(tail -n "+$((mark + 1))" "$LOG" 2>/dev/null)"
  if [ -n "$want_log" ] && ! printf '%s' "$branch" | grep -qF "$want_log"; then
    wrongpath=$((wrongpath + 1))
    if [ "$got" = "$want" ]; then state="the text is right"; else state="the text is wrong too"; fi
    printf '  ✗ %s\n      wrong path (%s): expected the log to say %s\n' "$name" "$state" "$want_log"
    printf '      log said: %s\n' "$(printf '%s' "$branch" | grep -E 'rewrite:|edit-test:' | tail -2 | tr '\n' ';')"
    continue
  fi
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$name"
  elif [ "$got" = "$line" ]; then
    refused=$((refused + 1))
    printf '  ✗ %s\n      refused — the line is untouched but should have been corrected\n' "$name"
  else
    corrupted=$((corrupted + 1))
    printf '  ✗ %s\n      got  %s\n      want %s\n      (the line was altered into something neither)\n' \
      "$name" "$got" "$want"
  fi
done < <(python3 -c '
import sys, yaml
for c in yaml.safe_load(open(sys.argv[1]))["cases"]:
    print("|".join(str(c[k]) for k in
        ("name", "id", "dictated", "line", "heard", "corrected", "expect"))
          + "|" + ("--literal" if c.get("literal") else "")
          + "|" + str(c.get("log", "")))
' "$ROOT/tests/inplace-cases.yaml")

echo
printf '  %d/%d\n' "$pass" "$total"
[ "$refused"   -gt 0 ] && printf '    %d refused when it should have corrected\n' "$refused"
[ "$corrupted" -gt 0 ] && printf '    %d altered the line  ← the one that costs you your text\n' "$corrupted"
[ "$skipped"   -gt 0 ] && printf '    %d skipped — the fixture was not in a known state\n' "$skipped"
[ "$wrongpath" -gt 0 ] && printf '    %d reached the right text by the wrong path\n' "$wrongpath"
[ "$pass" = "$total" ]
