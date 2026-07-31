#!/usr/bin/env bash
#
# Assembles the .app bundle around the SwiftPM binary.
#
# A real .app bundle is not optional: macOS reads NSMicrophoneUsageDescription
# and the bundle identifier out of Info.plist before it will grant microphone
# access, and it ties the TCC grant to the code signature.
#
#   scripts/build-app.sh                  # ParrotFlowDev.app  (the default)
#   VARIANT=release scripts/build-app.sh  # ParrotFlow.app
#
# Defaulting to dev is the point: a routine `make run` should not be able to
# overwrite the copy you rely on, or invalidate its permissions.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/variant.sh
. "$ROOT/scripts/variant.sh"

CONFIGURATION="${CONFIGURATION:-release}"
APP="$ROOT/.build/$APP_NAME.app"

echo "==> Building $DISPLAY_NAME ($CONFIGURATION)"
swift build --package-path "$ROOT" -c "$CONFIGURATION"

BIN_DIR="$(swift build --package-path "$ROOT" -c "$CONFIGURATION" --show-bin-path)"
BIN="$BIN_DIR/$EXECUTABLE_NAME"
[ -x "$BIN" ] || { echo "error: $BIN not found"; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Resources/Info.plist carries the released identity; the dev bundle is that
# file with three keys rewritten. One template rather than two files means a key
# cannot be added to one variant and forgotten in the other.
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $DISPLAY_NAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$PLIST"

# Ad-hoc ("-") by default. Set CODESIGN_IDENTITY to a self-signed identity to
# keep the microphone permission across rebuilds — see README.
# Prefer a stable self-signed identity when one exists — see dev-certificate.sh.
if [ -z "${CODESIGN_IDENTITY:-}" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "ParrotFlow Dev"; then
    CODESIGN_IDENTITY="ParrotFlow Dev"
fi
IDENTITY="${CODESIGN_IDENTITY:--}"
echo "==> Signing with identity: $IDENTITY"
codesign --force --sign "$IDENTITY" "$APP"

echo "==> Done: $APP"
