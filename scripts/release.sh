#!/usr/bin/env bash
#
# Builds the release artefacts: dist/ParrotFlow.zip and its checksum.
#
# Run by the release workflow after release-please cuts a tag, and by hand when
# you want to see exactly what a user will download.
#
#   scripts/release.sh            # version from version.txt
#   scripts/release.sh 0.2.0      # explicit
#
# The archive is made with ditto rather than zip: a .app is a bundle, and zip
# does not preserve the resource forks and extended attributes the code
# signature covers. A zip-archived bundle arrives with a broken signature,
# which costs the user their permissions on every update.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# A release is a release build by definition — not something to inherit from the
# environment, where a stray VARIANT=dev would ship an app called ParrotFlow Dev
# that reads a config directory nobody has.
export VARIANT=release
# shellcheck source=scripts/variant.sh
. "$ROOT/scripts/variant.sh"
# shellcheck source=scripts/codesign.sh
. "$ROOT/scripts/codesign.sh"

APP="$ROOT/.build/$APP_NAME.app"
DIST="$ROOT/dist"

VERSION="${1:-$(tr -d '[:space:]' < "$ROOT/version.txt")}"
VERSION="${VERSION#v}"

# A release wants the Developer ID: it is what Gatekeeper accepts and what
# notarization signs off, and notarization is what a Homebrew cask needs. The
# self-signed certificates still work as a fallback for a local rehearsal, and
# ad-hoc is the floor. See scripts/codesign.sh.
CODESIGN_IDENTITY="$(pf_signing_identity)"

# Fail closed. Everything after this point succeeds whatever the identity is:
# the bundle is signed, the archive is written, the checksum is computed, and
# the workflow uploads both. So a wrong SIGNING_CERT_P12 would publish a green
# release that install.sh, the app's own updater and Gatekeeper all refuse, and
# nothing would say so until a user tried to install it.
#
# PARROTFLOW_REHEARSAL=1 is the way to build without a Developer ID, for
# `make try-install`. The release workflow does not set it and must not.
#
# Exactly "1", not merely set. PARROTFLOW_REHEARSAL=0 reads as "off" to anyone
# writing it, and a test for non-empty would turn it on.
if ! pf_is_developer_id "$CODESIGN_IDENTITY"; then
    if [ "${PARROTFLOW_REHEARSAL:-}" != "1" ]; then
        if [ "$CODESIGN_IDENTITY" = "-" ]; then
            echo "error: no signing identity found — refusing to build a release." >&2
        else
            echo "error: '$CODESIGN_IDENTITY' is not a Developer ID — refusing to build a release." >&2
        fi
        echo "       A release has to be signed with the Developer ID Application" >&2
        echo "       certificate for Team ID $(pf_team_id). See docs/distribution.md." >&2
        echo "       To rehearse the installer without one: PARROTFLOW_REHEARSAL=1" >&2
        exit 1
    fi
    echo "warning: rehearsal build, signed with '$CODESIGN_IDENTITY'." >&2
    echo "         Not notarized. install.sh and the updater refuse it." >&2
fi
export CODESIGN_IDENTITY

echo "==> Releasing $DISPLAY_NAME $VERSION"
CONFIGURATION=release "$ROOT/scripts/build-app.sh"

# Stamp the version in, so a hand-run build cannot disagree with version.txt.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

# Editing Info.plist invalidates the signature — re-sign after stamping, not before.
pf_sign "$APP" "$CODESIGN_IDENTITY"
codesign --verify --deep --strict "$APP"

if pf_is_developer_id "$CODESIGN_IDENTITY"; then
    TEAM_ID="$(pf_team_id)"
    if [ -z "$TEAM_ID" ] || [ "$TEAM_ID" = "PENDING" ]; then
        echo "error: TEAM_ID in scripts/install.sh is still '$TEAM_ID'." >&2
        echo "       Set it, and expectedTeamID in Updates.swift, to the Team ID" >&2
        echo "       this certificate was issued under:" >&2
        echo "         security find-identity -vp codesigning" >&2
        exit 1
    fi

    # Proves the bundle satisfies the requirement install.sh and the app's own
    # updater will check it against. A release that fails this installs
    # nowhere, and finding that out here costs a minute rather than a release.
    codesign --verify --deep --strict -R "=$(pf_requirement "$TEAM_ID")" "$APP" \
        || { echo "error: signed, but not under Team ID $TEAM_ID — no install path would accept it." >&2; exit 1; }

    "$ROOT/scripts/notarize.sh" "$APP"
fi

rm -rf "$DIST"
mkdir -p "$DIST"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$APP_NAME.zip"

( cd "$DIST" && shasum -a 256 "$APP_NAME.zip" > "$APP_NAME.zip.sha256" )

echo "==> dist/$APP_NAME.zip  ($(du -h "$DIST/$APP_NAME.zip" | cut -f1))"
cat "$DIST/$APP_NAME.zip.sha256"
