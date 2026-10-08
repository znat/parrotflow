#!/usr/bin/env bash
# Is the tree's binary worth driving, and what else is running? Read-only.
#   doctor.sh            binary, staleness, live apps, installed stamps
#   doctor.sh --ollama   also asks Ollama what it has and what is loaded
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git -C "$HERE" rev-parse --show-toplevel)"
BIN="$ROOT/.build/release/ParrotFlow"
bad=0

echo "## binary"
if [ ! -x "$BIN" ]; then
  echo "  ✗ no binary at $BIN; run: swift build -c release"
  exit 1
fi
echo "  $BIN  built $(stat -f '%Sm' "$BIN")"
# --version exits before the first log write.
if version="$("$BIN" --version 2>/dev/null)"; then
  echo "  --version: $version"
else
  echo "  ✗ --version failed; the binary does not run"
  bad=1
fi

newer="$(cd "$ROOT" && find Sources Package.swift Package.resolved -type f -newer "$BIN")"
if [ -n "$newer" ]; then
  echo "  ✗ stale: newer than the binary:"
  printf '%s\n' "$newer" | sed 's/^/      /'
  bad=1
else
  echo "  ✓ matches the tree: nothing under Sources/, Package.swift, Package.resolved is newer"
fi
echo "  HEAD $(git -C "$ROOT" rev-parse --short HEAD)$( [ -n "$(git -C "$ROOT" status --porcelain -- Sources Package.swift Package.resolved)" ] && echo ", Sources/ has uncommitted changes")"

echo "## live instances (never signal these)"
# shellcheck disable=SC2009  # pgrep cannot print lstart
ps -axo pid=,lstart=,command= | grep -E '/Contents/MacOS/ParrotFlow( |$)' | grep -v grep | while read -r pid rest; do
  # shellcheck disable=SC2088  # printed for a human, not opened
  case "$rest" in
    */ParrotFlowDev.app/*) log="~/Library/Logs/ParrotFlow-Dev.log  hotkey default right_option" ;;
    */ParrotFlow.app/*)    log="~/Library/Logs/ParrotFlow.log  hotkey default right_command" ;;
    *)                     log="unknown bundle" ;;
  esac
  echo "  pid $pid  $rest"
  echo "      log $log"
  for child in $(pgrep -P "$pid"); do
    echo "      child pid $child  $(ps -o command= -p "$child")"
  done
done
# shellcheck disable=SC2009  # pgrep -f would read the path as a regex
stray="$(ps -axo pid=,command= | grep -F "$BIN" | grep -v grep)"
if [ -n "$stray" ]; then
  echo "  ✗ a tree binary is running. If it has no flag it is a menu bar app this run started by mistake:"
  printf '%s\n' "$stray" | sed 's/^/      /'
  bad=1
fi

echo "## installed apps (what live dictation runs)"
for app in /Applications/ParrotFlowDev.app /Applications/ParrotFlow.app; do
  if [ -f "$app/Contents/Info.plist" ]; then
    echo "  $app  stamp $(plutil -extract PFBuildStamp raw "$app/Contents/Info.plist" 2>/dev/null || echo none)"
  else
    echo "  $app  not installed"
  fi
done

if [ "${1:-}" = "--ollama" ]; then
  echo "## ollama (read-only)"
  tags="$(curl -s -m 3 localhost:11434/api/tags)" || tags=""
  if [ -z "$tags" ]; then
    echo "  ✗ not answering on localhost:11434"
    bad=1
  else
    echo "  pulled: $(printf '%s' "$tags" | python3 -c 'import json,sys; print(" ".join(m["name"] for m in json.load(sys.stdin)["models"]))')"
    if loaded="$(curl -s -m 3 localhost:11434/api/ps | python3 -c 'import json,sys; print(" ".join(m["name"] for m in json.load(sys.stdin)["models"]) or "nothing")')"; then
      echo "  loaded: $loaded"
    else
      echo "  ✗ /api/ps did not answer; loaded models unknown"
      bad=1
    fi
  fi
fi

exit "$bad"
