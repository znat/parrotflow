#!/usr/bin/env bash
#
# Assembles .build/ParrotFlow.app around the SwiftPM binary.
#
# A real .app bundle is not optional: macOS reads NSMicrophoneUsageDescription
# and the bundle identifier out of Info.plist before it will grant microphone
# access, and it ties the TCC grant to the code signature.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ParrotFlow"
CONFIGURATION="${CONFIGURATION:-release}"
APP="$ROOT/.build/$APP_NAME.app"

echo "==> Building ($CONFIGURATION)"
swift build --package-path "$ROOT" -c "$CONFIGURATION"

BIN_DIR="$(swift build --package-path "$ROOT" -c "$CONFIGURATION" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
[ -x "$BIN" ] || { echo "error: $BIN not found"; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc ("-") by default. Set CODESIGN_IDENTITY to a self-signed identity to
# keep the microphone permission across rebuilds — see README.
IDENTITY="${CODESIGN_IDENTITY:--}"
echo "==> Signing with identity: $IDENTITY"
codesign --force --sign "$IDENTITY" "$APP"

echo "==> Done: $APP"
