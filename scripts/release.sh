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

APP="$ROOT/.build/$APP_NAME.app"
DIST="$ROOT/dist"

VERSION="${1:-$(tr -d '[:space:]' < "$ROOT/version.txt")}"
VERSION="${VERSION#v}"

# Prefer a dedicated release identity, fall back to the dev one. Signing with a
# stable certificate is not cosmetic: TCC keys Microphone and Accessibility
# grants to the signing certificate, so a build signed with a different
# identity — or ad-hoc, which pins the binary hash instead — silently loses
# every permission the user granted to the previous version.
if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    for candidate in "ParrotFlow Release" "ParrotFlow Dev"; do
        if security find-identity -v -p codesigning 2>/dev/null | grep -q "$candidate"; then
            CODESIGN_IDENTITY="$candidate"
            break
        fi
    done
fi

if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    echo "warning: no signing identity found; signing ad-hoc." >&2
    echo "         Users who upgrade will have to grant Microphone and" >&2
    echo "         Accessibility again. See scripts/release-certificate.sh." >&2
    CODESIGN_IDENTITY="-"
fi
export CODESIGN_IDENTITY

echo "==> Releasing $DISPLAY_NAME $VERSION"
CONFIGURATION=release "$ROOT/scripts/build-app.sh"

# Stamp the version in, so a hand-run build cannot disagree with version.txt.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

# Editing Info.plist invalidates the signature — re-sign after stamping, not before.
codesign --force --sign "$CODESIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

rm -rf "$DIST"
mkdir -p "$DIST"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$APP_NAME.zip"

( cd "$DIST" && shasum -a 256 "$APP_NAME.zip" > "$APP_NAME.zip.sha256" )

echo "==> dist/$APP_NAME.zip  ($(du -h "$DIST/$APP_NAME.zip" | cut -f1))"
cat "$DIST/$APP_NAME.zip.sha256"
