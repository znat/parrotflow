#!/usr/bin/env bash
# Checks what `--bug-report` prints: every section the bug form asks for, no
# account name anywhere in it, and a prefilled URL GitHub will accept.
#
#   scripts/check-bug-report.sh
#
# Three things are being answered, and each was a decision:
#
#   every section is there      the point of the command is that nobody has to
#                              run four others. A section that quietly stops
#                              being assembled looks exactly like a section
#                              that had nothing to say
#   no absolute home path       the report goes to a public issue tracker. The
#                              home directory is rewritten to `~` in one place,
#                              and `/Users/` surviving anywhere means it was
#                              missed
#   the URL stays short         GitHub answers a URL over its limit with an
#                              error page, not with a truncated form. So the
#                              log and `--check-config` go to the clipboard and
#                              only the short fields go in the URL
#
# Run against a config directory in /tmp, so this says nothing about — and does
# nothing to — the config on this machine. An empty one is also what a broken
# install looks like, which is the install most likely to be reported.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

WORK="$(mktemp -d -t parrotflow-bug-report)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

pass=0; total=0; failed=""

check() {  # check <name> <got> <want>
  total=$((total + 1))
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
    printf '  ✓ %s\n' "$1"
  else
    failed="$failed
      $1"
    printf '  ✗ %s\n      got   %s\n      want  %s\n' "$1" "$2" "$3"
  fi
}

EMPTY="$WORK/empty"
mkdir -p "$EMPTY"

report="$(PARROTFLOW_CONFIG_DIR="$EMPTY" "$BIN" --bug-report 2>/dev/null)"
status="$(PARROTFLOW_CONFIG_DIR="$EMPTY" "$BIN" --bug-report > /dev/null 2>&1; echo $?)"

# --- it comes out at all, with nothing configured ---------------------------
#
# The microphone is not granted on a runner and there is no log file. Neither
# is a reason to refuse: a report about an install that does not work is the
# one that has to be printable.
check "exits 0 with no config directory" "$status" "0"

# --- every section the form asks for ----------------------------------------
for section in \
  "ParrotFlow bug report" \
  "Version" \
  "Permissions" \
  "--check-config" \
  "Log — last 50 lines"
do
  # `--` first: a pattern starting with a dash is otherwise read as an option,
  # and BSD grep exits 2 with a usage message.
  check "the report names \"$section\"" \
    "$(printf '%s\n' "$report" | grep -cF -- "$section")" \
    "1"
done

check "the version line is filled in" \
  "$(printf '%s\n' "$report" | grep -cE '^  app +[^ ]')" \
  "1"

check "macOS and the chip are named" \
  "$(printf '%s\n' "$report" | grep -cE '^  (macOS|chip) +[^ ]')" \
  "2"

check "the microphone permission is reported" \
  "$(printf '%s\n' "$report" | grep -cE '^  microphone +[^ ]')" \
  "1"

# Accessibility read from a terminal is credited to the terminal, so the answer
# would be "not granted" on a Mac where it is granted. It says so instead.
# Anchored on the report's own line. `--check-config` carries the same caveat
# further down, and an unanchored pattern counts both.
check "accessibility says it cannot be answered from a terminal" \
  "$(printf '%s\n' "$report" | grep -cE '^  accessibility  not checkable from a terminal')" \
  "1"

check "--check-config output is included, not summarised" \
  "$(printf '%s\n' "$report" | grep -c '^  · transcription')" \
  "1"

# The section is never empty: either the tail, or a line saying there is no log
# to tail. Which one shows up here is not fixed — the process writes its own
# build line to the log at startup, so a machine with no log file at all is
# rarer than a machine with one line in it. Both are a section, not a failure.
lines_or_notice="$(printf '%s\n' "$report" \
  | grep -cE 'not found — (no log file|the log file is empty)|^[0-9]{4}-[0-9]{2}-[0-9]{2} ')"

check "the log section holds either a tail or a clear \"not found\"" \
  "$([ "$lines_or_notice" -ge 1 ] && echo yes || echo no)" \
  "yes"

check "the log section never carries more than 50 lines" \
  "$([ "$(printf '%s\n' "$report" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2} ')" -le 50 ] \
     && echo yes || echo no)" \
  "yes"

# --- the account name -------------------------------------------------------
#
# The one thing this file exists to prove. `--check-config` alone prints the
# config path, the output directory, the log path and every transform's
# resolved path, and all of them start with the home directory.
check "no absolute home path survives" \
  "$(printf '%s\n' "$report" | grep -c '/Users/')" \
  "0"

# The config directory above is in a temporary folder, so its own path says
# nothing about `$HOME`. This one is built against the real home, where every
# path `--check-config` prints starts with it.
home_report="$("$BIN" --bug-report 2>/dev/null)"

check "nor from a report built against the real home" \
  "$(printf '%s\n' "$home_report" | grep -c '/Users/')" \
  "0"

check "and the home directory is written as ~ instead" \
  "$(printf '%s\n' "$home_report" | grep -c '^config: ~/')" \
  "1"

# An apostrophe is legal in a macOS account name, and the pattern used to stop
# at one — `/Users/o'connor/…` came out as `~'connor/…`, which is still the
# name. Written into `output_dir`, which --check-config prints as an absolute
# path whatever is there.
QUOTED="$WORK/quoted"
mkdir -p "$QUOTED"
cat > "$QUOTED/config.yaml" <<'YAML'
audio:
  output_dir: "/Users/o'connor/Recordings"
YAML
quoted="$(PARROTFLOW_CONFIG_DIR="$QUOTED" "$BIN" --bug-report 2>/dev/null)"

check "an account name holding an apostrophe is redacted too" \
  "$(printf '%s\n' "$quoted" | grep -c "o'connor")" \
  "0"

check "and nothing under /Users/ is left in that report either" \
  "$(printf '%s\n' "$quoted" | grep -c '/Users/')" \
  "0"

# --- the URL ----------------------------------------------------------------
url="$(PARROTFLOW_CONFIG_DIR="$EMPTY" "$BIN" --bug-report --url 2>/dev/null)"

check "the URL is under 2000 characters" \
  "$([ "${#url}" -lt 2000 ] && echo yes || echo no)" \
  "yes"

check "it opens the issue form from AppVariant.repository" \
  "$(printf '%s\n' "$url" | grep -c '^https://github.com/znat/parrotflow/issues/new?')" \
  "1"

# The names are field ids in .github/ISSUE_TEMPLATE/bug.yml. A name that is not
# one is dropped by GitHub without a word, so the form arrives empty and nobody
# finds out why.
for field in "template=bug.yml" "labels=bug" "version=" "macos="; do
  check "the URL carries $field" \
    "$(printf '%s\n' "$url" | grep -cF -- "$field")" \
    "1"
done

# Percent-encoded, so a space in "macOS 15.5, Apple M2 Pro" cannot end the value
# early.
check "the URL has no raw spaces" \
  "$(printf '%s\n' "$url" | grep -c ' ')" \
  "0"

# The bulk goes to the clipboard. In the URL it would overflow the limit and
# the reporter would get an error page.
check "neither the log nor --check-config is in the URL" \
  "$(printf '%s\n' "$url" | grep -c 'check-config=\|log=')" \
  "0"

echo
echo "  $pass/$total$failed"
[ "$pass" = "$total" ]
