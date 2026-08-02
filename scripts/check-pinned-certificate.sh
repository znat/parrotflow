#!/usr/bin/env bash
#
# The certificate is pinned in two places, because there are two ways to
# install: the curl script and the app updating itself. A pin that is only
# right in one of them is a door that checks less than the other, and that is
# the door an attacker uses.
#
# So they are compared here rather than trusted to stay in step.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

from_script="$(sed -n 's/^CERT_SHA256="\([0-9a-f]*\)"$/\1/p' "$ROOT/scripts/install.sh" | head -1)"
from_swift="$(sed -n 's/^ *"\([0-9a-f]\{64\}\)"$/\1/p' "$ROOT/Sources/ParrotFlow/Updates.swift" | head -1)"

if [ -z "$from_script" ]; then
    echo "✗ no pinned certificate found in scripts/install.sh" >&2
    exit 1
fi
if [ -z "$from_swift" ]; then
    echo "✗ no pinned certificate found in Sources/ParrotFlow/Updates.swift" >&2
    exit 1
fi
if [ "$from_script" != "$from_swift" ]; then
    echo "✗ the two pinned certificates disagree" >&2
    echo "    scripts/install.sh   $from_script" >&2
    echo "    Updates.swift        $from_swift" >&2
    exit 1
fi

echo "✓ both install paths pin the same certificate  ${from_script:0:16}…"
