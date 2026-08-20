#!/usr/bin/env bash
# Checks the rules that decide whether this app may write to the clipboard.
#
#   scripts/check-clipboard.sh
#
# No app bundle, no accessibility, no window: it builds with swift and runs the
# rules against the real NSPasteboard. Real, because what is being tested is
# which calls move NSPasteboard.changeCount — clearContents does, setString does
# not — and a fake that answers that is the assumption restated.
#
# Both rules are about the same collision. A refused in-place edit leaves the
# rewrite on the clipboard, and the ladder it just came down pastes, so the
# count has moved and this app is what moved it. One rule has to see that and
# still write; the other has to see it and not put the pre-paste contents back
# over the rewrite 0.4s later.
#
# Your own clipboard is saved and put back.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

swift build >/dev/null || exit 1
exec ./.build/debug/ParrotFlow --clipboard-test 2>/dev/null
