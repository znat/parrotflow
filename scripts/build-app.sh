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
# shellcheck source=scripts/codesign.sh
. "$ROOT/scripts/codesign.sh"

CONFIGURATION="${CONFIGURATION:-release}"
APP="$ROOT/.build/$APP_NAME.app"

# Named rather than left to the default, because the default moved: Swift 6.4
# picks swiftbuild, 6.3 picks the classic engine, and only swiftbuild compiles
# the 49 `.metal` files in mlx-swift into the metallib the app needs. The
# classic one drops them without a word, which is how v0.12.0 was packaged
# without its shaders. Both lines need it — `--show-bin-path` answers for the
# engine it is asked about, and the two engines write to different directories.
#
# swiftbuild builds every architecture the SDK calls standard, and on the
# macOS 26 SDK that is arm64 and x86_64. The app is arm64: MLX and Parakeet
# need Apple Silicon, and `Float(Float16)` in SlotProbe.swift does not compile
# for x86_64 at all. Newer SDKs drop x86_64 from the standard set, so a
# developer Mac never sees this and CI did.
#
# `--triple` and not `ARCHS`: both that and `ONLY_ACTIVE_ARCH` were set as
# environment variables on a CI run and ignored, because SwiftPM writes its own
# and wins. There is no `--arch` option.
SWIFT_BUILD=(
    swift build --package-path "$ROOT" -c "$CONFIGURATION"
    --build-system swiftbuild --triple arm64-apple-macosx
)

echo "==> Building $DISPLAY_NAME ($CONFIGURATION)"
"${SWIFT_BUILD[@]}"

BIN_DIR="$("${SWIFT_BUILD[@]}" --show-bin-path)"
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
# Two sets, and the glob for the first does not cover the second. The menu bar
# ones are the bird flat in three colours; ParrotSolid is the silhouette the
# pill pours the plumage through. Named separately rather than widened to
# `*Parrot*.png`, so adding a drawing to Resources/ is a decision here and not
# an accident.
cp "$ROOT"/Resources/MenuBarParrot*.png "$APP/Contents/Resources/"
cp "$ROOT"/Resources/ParrotSolid*.png "$APP/Contents/Resources/"
# The drawing itself, not a cut of it. AppKit renders SVG, and the launch panel
# draws the bird at 76 points — three times the largest PNG here.
cp "$ROOT/Resources/parrot.svg" "$APP/Contents/Resources/"

# The shipped transforms and the default config.yaml are seeded from here —
# copied, not baked into the binary as strings, so there is one copy of each
# and not two drifting apart. See Config.exampleTransformsDirectory and
# Config.configTemplateURL.
cp -R "$ROOT/examples" "$APP/Contents/Resources/examples"
find "$APP/Contents/Resources/examples" -name __pycache__ -type d -exec rm -rf {} +
cp "$ROOT/config.example.yaml" "$APP/Contents/Resources/config.example.yaml"

# The word list the auto-apply gate asks whether a name is a name. Named here
# rather than copying the whole of data/: the other files in it are read by
# scripts/calibrate.py on a checkout and have no business in the bundle. See
# WordPieces.fileURL.
cp "$ROOT/data/wordpiece.txt" "$APP/Contents/Resources/wordpiece.txt"
cp "$ROOT/data/parsing-requirements.txt" "$APP/Contents/Resources/parsing-requirements.txt"

# SwiftPM resource bundles, which the binary looks for beside itself.
#
# MLX keeps its Metal shaders in one of these. Without it every MLX call ends
# in "Failed to load the default metallib" and the process is torn down from
# inside the library, so the app dies mid-dictation with nothing in its own log.
# Copied by pattern rather than by name: a dependency that gains a bundle should
# not need this file edited to be packaged.
for bundle in "$BIN_DIR"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
    echo "==> Bundled $(basename "$bundle")"
done

# Named, because losing this one is silent until a dictation dies. MLX tears the
# process down from inside the library when its shaders are missing, so there is
# nothing in the app's own log to read afterwards. This is the guard that caught
# v0.12.0.
if [ ! -d "$APP/Contents/Resources/mlx-swift_Cmlx.bundle" ]; then
    echo "error: mlx-swift_Cmlx.bundle is not in the app — MLX will abort at the first call"
    exit 1
fi

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

# How this is signed lives in scripts/codesign.sh, because release.sh has to
# sign the same bundle again after it stamps the version in.
IDENTITY="$(pf_signing_identity)"
echo "==> Signing with identity: $IDENTITY"
pf_sign "$APP" "$IDENTITY"

echo "==> Done: $APP"
