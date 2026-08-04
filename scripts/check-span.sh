#!/usr/bin/env bash
# Scores span substitution against a real surface, from tests/span-cases.yaml.
#
#   scripts/check-span.sh              # the local fixture in Chrome, unattended
#   scripts/check-span.sh slack        # you focus Slack's composer, it scores
#   scripts/check-span.sh outlook      # you focus an Outlook message body
#
# The oracle is never the accessibility API, because the accessibility API is
# what is on trial — it has reported a corrupting paste as a clean write. So:
#
#   fixture   the page publishes its own DOM in document.title, read with
#             AppleScript. Owes nothing to accessibility and needs no typing.
#   an app    the text is read back with a synthetic Cmd-A Cmd-C and pbpaste,
#             which goes through the app's own copy implementation rather than
#             through the attribute the write used.
#
# Two counters, because the failures are not equally bad. A substitution that
# does not happen costs a trip to the clipboard. One that happens to the wrong
# characters costs the text, and that is the one this exists to prevent.
#
# Requires the dev app installed (`make install`) with Accessibility granted.
# The fixture mode also needs Chrome, and macOS will ask once for permission to
# control it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="/Applications/ParrotFlowDev.app"
TARGET="${1:-fixture}"
FIXTURE="$ROOT/tests/fixtures/composer.html"
LOG="$HOME/Library/Logs/ParrotFlow-Dev.log"

[ -d "$APP" ] || { echo "install the dev app first: make install"; exit 1; }

# --- the two oracles ---------------------------------------------------------

read_fixture() {
  osascript -e 'tell application "Google Chrome" to get title of active tab of front window' 2>/dev/null \
    | sed -n 's/^PFBOX|//p'
}

read_app() {
  osascript -e 'tell application "System Events" to keystroke "a" using command down' 2>/dev/null
  sleep 0.3
  osascript -e 'tell application "System Events" to keystroke "c" using command down' 2>/dev/null
  sleep 0.4
  pbpaste | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

seed_fixture() {
  local text="$1"
  local encoded
  encoded="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$text")"
  osascript >/dev/null 2>&1 <<OSA
tell application "Google Chrome"
  activate
  if (count of windows) = 0 then make new window
  set URL of active tab of front window to "file://$FIXTURE#$encoded"
end tell
OSA
  # Long enough for the navigation to settle and the page to take focus back
  # from the omnibox. Short of this the app reads the address bar instead of the
  # composer, refuses correctly, and the case scores a refusal that says nothing
  # about the write path.
  sleep 2
}

seed_app() {
  local text="$1"
  # Clear whatever is there, then type the seed. Typing rather than pasting:
  # a paste is the mechanism under test, and seeding with it would let a broken
  # paste hide behind a broken seed.
  osascript -e 'tell application "System Events" to keystroke "a" using command down' 2>/dev/null
  sleep 0.2
  osascript -e 'tell application "System Events" to key code 51' 2>/dev/null
  sleep 0.3
  osascript -e "tell application \"System Events\" to keystroke \"$text\"" 2>/dev/null
  sleep 0.8
}

case "$TARGET" in
  fixture) READ=read_fixture; SEED=seed_fixture ;;
  *)       READ=read_app;     SEED=seed_app ;;
esac

if [ "$TARGET" != "fixture" ]; then
  echo "Focus the $TARGET composer you want scored. Starting in 8s."
  echo "Everything in it will be selected and replaced — use a scratch message."
  sleep 8
fi

# --- the run -----------------------------------------------------------------

pass=0; total=0; refused=0; corrupted=0; skipped=0

while IFS='|' read -r name id seed target replacement expect; do
  [ -z "$name" ] && continue
  total=$((total + 1))

  $SEED "$seed"
  got="$($READ)"
  if [ "$got" != "$seed" ]; then
    printf '  ⊘ %s — seed did not land (read back "%s")\n' "$name" "$got"
    skipped=$((skipped + 1)); continue
  fi

  # Offsets computed from the seed we just confirmed is there, so the span is a
  # fact about the content rather than a number written by hand into the cases.
  read -r start length < <(python3 -c '
import sys
seed, target = sys.argv[1], sys.argv[2]
i = seed.index(target)
print(i, len(target))
' "$seed" "$target")

  [ "$expect" = "unchanged" ] && want="$seed" || want="$expect"

  open -g -na ParrotFlowDev --args \
    --span-test "$start" "$length" "$replacement" --find "$id" --after 2
  sleep 6

  got="$($READ)"
  # Curly quotes are not a failed write — most composers substitute them on the
  # way in, and the app folds them for exactly this reason.
  norm() { printf '%s' "$1" | sed "s/[’‘]/'/g; s/[“”]/\"/g"; }
  if [ "$(norm "$got")" = "$(norm "$want")" ]; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$name"
  elif [ "$(norm "$got")" = "$(norm "$seed")" ]; then
    refused=$((refused + 1))
    printf '  ✗ %s\n      refused — the text is untouched but should have changed\n' "$name"
  else
    corrupted=$((corrupted + 1))
    printf '  ✗ %s\n      got  %s\n      want %s\n      (altered into something neither)\n' \
      "$name" "$got" "$want"
  fi
done < <(python3 -c '
import sys, yaml
for c in yaml.safe_load(open(sys.argv[1]))["cases"]:
    print("|".join(str(c[k]) for k in
        ("name", "id", "seed", "target", "replacement", "expect")))
' "$ROOT/tests/span-cases.yaml")

echo
printf '  %d/%d  (%s)\n' "$pass" "$total" "$TARGET"
[ "$refused"   -gt 0 ] && printf '    %d refused when it should have substituted\n' "$refused"
[ "$corrupted" -gt 0 ] && printf '    %d altered the text  ← the one that costs you your words\n' "$corrupted"
[ "$skipped"   -gt 0 ] && printf '    %d skipped — the surface was not in a known state\n' "$skipped"
[ "$pass" = "$total" ]
