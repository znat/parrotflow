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
SESSION="${PF_CHECK_SESSION:-pfcheck-$$}"
CLAUDE="$(command -v claude || echo "$HOME/.local/bin/claude")"
SCRATCH="${TMPDIR:-/tmp}/pf-check-inplace"
# Which terminal hosts the fixture. Terminal.app by default because it is on
# every Mac; the point of the switch is that "does in-place editing work in a
# terminal" has a different answer per terminal, and the only way to know is to
# run the set in each one.
#
#   PF_VIEWPORT=Ghostty scripts/check-inplace.sh
VIEWPORT="${PF_VIEWPORT:-Terminal}"

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

# A locked screen answers every accessibility read as `loginwindow` with an
# empty value. That is indistinguishable from a window refusing the edit, so
# without this the whole set scores 0/8 and blames the app. caffeinate keeps a
# screen awake; it cannot wake one that has already locked.
screen_is_locked() {
  ioreg -n Root -d1 -a 2>/dev/null | grep -q CGSSessionScreenIsLocked
}

# Whether pid $1 is the one this run's own launch started: $SESSION as the
# exact argument right after "-t" in its command line. Not merely present as
# some word anywhere in it — a process whose title or some other argument
# happens to contain $SESSION would pass that test too, and this is what
# cleanup trusts before killing something.
owns_fixture() {
  local args
  read -ra args <<< "$(ps -o command= -p "$1" 2>/dev/null)"
  local i
  for i in "${!args[@]}"; do
    [ "${args[$i]}" = "-t" ] && [ "${args[$((i + 1))]:-}" = "$SESSION" ] && return 0
  done
  return 1
}

start_fixture() {
  if screen_is_locked; then
    echo "the screen is locked — unlock it and run this again"
    echo "  (every case would read an empty window and score 0/8)"
    exit 1
  fi
  # The display must stay awake for the whole run. This drives a real window
  # and reads it back through the accessibility API, and a locked screen
  # answers as `loginwindow` with an empty value — which reads exactly like a
  # window that would not take the edit. Two runs were lost to that before it
  # was worth a line.
  caffeinate -d -i -w $$ &
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
  # A freshly opened window is frontmost without anyone having to click, which
  # is what lets this run unattended.
  #
  # How you open one is per terminal, and getting it wrong is silent: the
  # window never appears, `open -a` falls back to focusing whatever window that
  # app already had, and every case then reports "nothing readable is focused"
  # while the real answer is that the fixture was never on screen. That is what
  # PF_VIEWPORT=Ghostty did for as long as this only knew Terminal.app.
  case "$VIEWPORT" in
    Terminal)
      # Terminal.app runs a `.command` file as its session.
      printf '#!/bin/sh\nexec %s attach -t %s\n' "$TMUX" "$SESSION" > "$SCRATCH/attach.command"
      chmod +x "$SCRATCH/attach.command"
      before_windows="$(osascript -e 'tell application "Terminal" to id of every window' \
        2>/dev/null | tr -d ' ' | tr ',' '\n' | sort)"
      open -a "$VIEWPORT" "$SCRATCH/attach.command"
      sleep 1
      # The window that appeared, not whichever is frontmost a second later:
      # "frontmost" is whatever the window server settled on, and Terminal can
      # keep an existing window in front of a new one that opened behind it.
      after_windows="$(osascript -e 'tell application "Terminal" to id of every window' \
        2>/dev/null | tr -d ' ' | tr ',' '\n' | sort)"
      TERMINAL_WINDOW_ID="$(comm -13 <(echo "$before_windows") <(echo "$after_windows") | head -1)"
      ;;
    *)
      # Ghostty and friends take `-e`, and on macOS only through `open`:
      # "launching the terminal emulator from the CLI is not supported".
      # `-n` for a new instance, so the fixture cannot land in a window you
      # are using.
      before="$(pgrep -i "$VIEWPORT" | sort)"
      # The command as separate arguments, not one quoted string. Quoted, the
      # window opens and `-e` is silently ignored — you get a shell, tmux is
      # never attached, and every case then reads an empty window and refuses
      # to write. Measured: `list-clients` says 0 with the quotes and 1 without.
      open -na "$VIEWPORT.app" --args -e "$TMUX" attach -t "$SESSION"
      sleep 3
      # A pid that appeared in this window is not proof it is ours — anything
      # else that launched the same app in the same three seconds passes that
      # test too, and cleanup would then kill somebody's own terminal while
      # the fixture kept running. Only the process we just started carries
      # "attach -t $SESSION" in its own command line, so that is what is
      # checked, not just who is new.
      for pid in $(comm -13 <(echo "$before") <(pgrep -i "$VIEWPORT" | sort)); do
        if owns_fixture "$pid"; then
          VIEWPORT_PID="$pid"
          break
        fi
      done
      ;;
  esac
  sleep 4
  # Terminal.app is one process for every window, so the newest match is
  # always the right one, and cleanup never kills it by pid anyway. Any other
  # terminal has to have matched its own launch command line above: a
  # name-wide fallback here could be someone's own window, and cleanup would
  # kill it.
  if [ "$VIEWPORT" = Terminal ]; then
    [ -n "${VIEWPORT_PID:-}" ] || VIEWPORT_PID="$(pgrep -n -i "$VIEWPORT" || true)"
  fi
  [ -n "${VIEWPORT_PID:-}" ] || { echo "could not find the new $VIEWPORT window it opened"; exit 1; }
  echo "  viewport: $VIEWPORT pid $VIEWPORT_PID"
}

# Bring the fixture forward, by process id. Never by name: see start_fixture.
focus_viewport() {
  local err
  err="$(osascript -e "tell application \"System Events\" to set frontmost of \
    (first process whose unix id is $VIEWPORT_PID) to true" 2>&1 >/dev/null)"
  [ -n "$err" ] && echo "  focus failed: $err"
  # Read the frontmost process back. `set frontmost` returns before the window
  # actually comes forward, and without this second round trip the case that
  # follows reads whatever was in front before — "nothing readable is focused"
  # on all 8. The answer is discarded; making the call is the point.
  osascript -e 'tell application "System Events" to get unix id of \
    first process whose frontmost is true' >/dev/null 2>&1
  return 0
}

LOG="$HOME/Library/Logs/ParrotFlow-Dev.log"
REPEATS="${PF_REPEATS:-1}"
pass=0; total=0; refused=0; corrupted=0; skipped=0; wrongpath=0

start_fixture
# Close the window as well as the session. `open -na` starts a whole instance
# per run, and without this every run leaves one behind — nine of them stacked
# up in one sitting before it was noticed.
cleanup() {
  "$TMUX" kill-session -t "$SESSION" 2>/dev/null
  if [ "$VIEWPORT" = Terminal ]; then
    # Terminal.app is one process for every window you have open, so killing
    # the pid would take yours with it. Close the one window instead — by id,
    # captured when it was opened, never by matching its title: a title
    # substring can match a window this run did not open, and PF_CHECK_SESSION
    # is not guaranteed unique the way the default is.
    if [[ "${TERMINAL_WINDOW_ID:-}" =~ ^[0-9]+$ ]]; then
      osascript -e "tell application \"Terminal\" to close window id $TERMINAL_WINDOW_ID" \
        >/dev/null 2>&1
    fi
  elif [ -n "${VIEWPORT_PID:-}" ]; then
    # The pid can have been recycled between launch and here. Checked again
    # right before the kill, not just once at launch — killing a pid we can no
    # longer attribute to this run is exactly the bug that got fixed above.
    if owns_fixture "$VIEWPORT_PID"; then
      kill "$VIEWPORT_PID" 2>/dev/null
    fi
  fi
  return 0
}
trap cleanup EXIT

while IFS='|' read -r name id dictated line heard corrected expect literal want_log span; do
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
  focus_viewport; sleep 2
  # A span case names the range; the offsets come from the seeded line, which
  # the check above has just confirmed is what is on screen. Computed here
  # rather than written into the case file, so they cannot drift from the text.
  if [ -n "$span" ]; then
    read -r start length < <(python3 -c '
import sys
line, heard = sys.argv[1], sys.argv[2]
i = line.index(heard)
print(i, len(heard))
' "$line" "$heard")
    open -g -na ParrotFlowDev --args \
      --span-test "$start" "$length" "$corrected" --find "$id" --dictated "$dictated" --after 3
  else
    open -g -na ParrotFlowDev --args \
      --edit-test "$heard" "$corrected" --find "$id" --dictated "$dictated" $literal --after 3
  fi
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
          + "|" + str(c.get("log", ""))
          + "|" + ("span" if c.get("span") else ""))
' "$ROOT/tests/inplace-cases.yaml")

echo
printf '  %d/%d\n' "$pass" "$total"
[ "$refused"   -gt 0 ] && printf '    %d refused when it should have corrected\n' "$refused"
[ "$corrupted" -gt 0 ] && printf '    %d altered the line  ← the one that costs you your text\n' "$corrupted"
[ "$skipped"   -gt 0 ] && printf '    %d skipped — the fixture was not in a known state\n' "$skipped"
[ "$wrongpath" -gt 0 ] && printf '    %d reached the right text by the wrong path\n' "$wrongpath"
[ "$pass" = "$total" ]
