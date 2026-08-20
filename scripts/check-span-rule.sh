#!/usr/bin/env bash
# Scores which range a rewrite should be written as — Surface.writableSpan.
#
#   scripts/check-span-rule.sh
#
# The half of the story that comes before scripts/check-span.sh. That one hands
# a real app a range that is already known and asks whether exactly those
# characters change. This asks what the range should be: a sentence and its
# rewrite go in, a range and a replacement come out.
#
# Pure, so it needs no app, no window and no accessibility grant. It is also
# where the answer was wrong three times in one afternoon — a paste with a
# trailing space that Slack trimmed, a paste at a caret that nothing could
# confirm, and an empty paste that wrote nothing while reporting success. All
# three are cases in here.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

swift build >/dev/null || exit 1
exec ./.build/debug/ParrotFlow --span-rule 2>/dev/null
