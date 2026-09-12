#!/usr/bin/env bash
# The invariant a v3 trace rests on.
#
#   scripts/check-trace-edits.sh
#
# A stage no longer stores its input and its output — it stores what it
# changed, in the coordinates of the text it was handed. That is only worth
# something if it replays: apply the edits in order and you must get the
# output back.
#
# Nothing at run time reads an edit, so a bug here cannot damage a transcript.
# It can quietly make the whole corpus wrong, which nothing else would say.
#
# No audio, no model, no config. `--trace-edits` carries its own cases and
# fuzzes several thousand more, because the pairs that break a diff are never
# the ones anybody thinks to write down.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

cd "$ROOT" || exit 1
"$BIN" --trace-edits || exit 1

# And the other half: the decode arms close their spans from sibling tasks, so
# several threads append to one array. An unlocked append there is memory
# corruption rather than a wrong number — the one failure in this feature that
# could take the app down. Run it under the thread sanitiser to prove the
# locking itself:
#
#   swift build --sanitize=thread --scratch-path .build-tsan
#   .build-tsan/debug/ParrotFlow --trace-spans
"$BIN" --trace-spans
