#!/usr/bin/env bash
# Checks that the binary refuses to start the app from a terminal, and that it
# still answers every other way it is called.
#
#   scripts/check-terminal-launch.sh
#
# The cask puts `parrotflow` on the PATH, so somebody will type it with no
# arguments. TCC credits a permission to the responsible process, and for a
# binary exec'd from a shell that is the terminal — measured in
# docs/distribution.md, where the same bundle read `Granted` launched by macOS
# and `Not granted` run from a shell. A copy started that way is a menu bar app
# that cannot type and says nothing about why.
#
# `script -q /dev/null` is what gives the child a pty. Without it every case
# here has a pipe for stdout, the guard never fires, and the test passes while
# testing nothing.
#
# The `open` path is deliberately NOT exercised. Proving it would mean starting
# a second copy of the app, and two instances have left this Mac with a stuck
# microphone before. The condition is "no arguments AND stdout is a tty";
# `open` supplies neither.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || BIN="$ROOT/.build/debug/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

pass=0; total=0; failed=""

# Runs the binary with a pty and prints "<exit>|<output>".
on_a_tty() {
  local out code
  out="$(script -q /dev/null "$BIN" "$@" < /dev/null 2>&1)"
  code=$?
  printf '%s|%s' "$code" "$out"
}

wants() {
  total=$((total + 1))
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
  else
    failed="$failed
      $1"
    printf '  ✗ %s\n      want %s\n      got  %s\n' "$1" "$3" "$2"
  fi
}

says() {
  total=$((total + 1))
  if printf '%s' "$2" | grep -qaF -- "$3"; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
  else
    failed="$failed
      $1"
    printf '  ✗ %s\n      wanted to see  %s\n' "$1" "$3"
  fi
}

printf '\nno arguments, on a terminal\n'
r="$(on_a_tty)"
wants "refused, exit 2"            "${r%%|*}" "2"
says  "and says why"               "${r#*|}"  "does not start from a terminal"
says  "and how to start it"        "${r#*|}"  "open -a ParrotFlow"

printf '\nstill answers everything else\n'
r="$(on_a_tty --version)"
wants "--version exits 0"          "${r%%|*}" "0"

# Its exit code answers whether the config is healthy, which depends on the
# machine. What matters here is only that the subcommand ran at all.
r="$(on_a_tty --check-config)"
says  "--check-config runs"        "${r#*|}"  "config: "

# The guard that was already there: an unclaimed flag is a mistake, not a
# request to start the app. Four copies launched in one afternoon before it.
r="$(on_a_tty --no-such-flag)"
wants "an unknown flag exits 2"    "${r%%|*}" "2"
says  "and names the flag"         "${r#*|}"  "--no-such-flag"

printf '\n%d/%d\n' "$pass" "$total"
[ -n "$failed" ] && printf 'failed:%s\n' "$failed"
[ "$pass" -eq "$total" ]
