#!/usr/bin/env bash
#
# The Team ID releases are signed under is declared in two places, because
# there are two ways to install: the curl script and the app updating itself.
# A check that is only right in one of them is a door that checks less than the
# other, and that is the door an attacker uses.
#
# So they are compared here rather than trusted to stay in step.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

from_script="$(sed -n 's/^TEAM_ID="\([A-Z0-9]*\)"$/\1/p' "$ROOT/scripts/install.sh" | head -1)"
from_swift="$(sed -n 's/^ *static let expectedTeamID = "\([A-Z0-9]*\)"$/\1/p' "$ROOT/Sources/ParrotFlow/Updates.swift" | head -1)"

if [ -z "$from_script" ]; then
    echo "✗ no TEAM_ID found in scripts/install.sh" >&2
    exit 1
fi
if [ -z "$from_swift" ]; then
    echo "✗ no expectedTeamID found in Sources/ParrotFlow/Updates.swift" >&2
    exit 1
fi
if [ "$from_script" != "$from_swift" ]; then
    echo "✗ the two install paths expect different Team IDs" >&2
    echo "    scripts/install.sh   $from_script" >&2
    echo "    Updates.swift        $from_swift" >&2
    exit 1
fi

# Not a failure yet: the Developer ID is not issued until the Apple Developer
# account is. scripts/release.sh is the hard gate — it refuses to build a
# release while this is still the placeholder, which is the moment it matters.
if [ "$from_script" = "PENDING" ]; then
    echo "⚠ the Team ID is still PENDING in both places — set it before releasing"
    exit 0
fi

echo "✓ both install paths expect Team ID $from_script"
