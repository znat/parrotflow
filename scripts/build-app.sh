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

# The icons are committed, not built here: they come out of Resources/parrot.svg
# via scripts/make-icons.py, which only needs running when the drawing changes.
# Rebuilding them on every `make run` would put a rasteriser between you and a
# working app for no gain.
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cp "$ROOT"/Resources/MenuBarParrot*.png "$APP/Contents/Resources/"

# The shipped transforms and the default config.yaml are seeded from here —
# copied, not baked into the binary as strings, so there is one copy of each
# and not two drifting apart. See Config.exampleTransformsDirectory and
# Config.configTemplateURL.
cp -R "$ROOT/examples" "$APP/Contents/Resources/examples"
find "$APP/Contents/Resources/examples" -name __pycache__ -type d -exec rm -rf {} +
cp "$ROOT/config.example.yaml" "$APP/Contents/Resources/config.example.yaml"

# Resources/Info.plist carries the released identity; the dev bundle is that
# file with three keys rewritten. One template rather than two files means a key
# cannot be added to one variant and forgotten in the other.
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $DISPLAY_NAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$PLIST"

# Which commit this bundle was built from, so a measurement can prove the
# installed app is the code under test. An installed app that silently lagged
# the working tree once cost a night of wrong conclusions. "-dirty" means the
# tree had uncommitted changes, so the hash alone does not describe the build.
# `Add` rather than `Set`: the template does not carry the key, and the bundle
# plist is a fresh copy of it on every build.
STAMP="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
    STAMP="$STAMP-dirty"
fi
/usr/libexec/PlistBuddy -c "Add :PFBuildStamp string $STAMP" "$PLIST"
echo "==> Build stamp: $STAMP"

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
