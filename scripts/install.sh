#!/bin/sh
#
# ParrotFlow installer.
#
#   curl -fsSL https://raw.githubusercontent.com/znat/parrotflow/main/scripts/install.sh | sh
#
# Downloads the latest release, checks it against its published SHA-256, and
# puts ParrotFlow.app in /Applications.
#
# Why curl and not Homebrew: a cask would arrive carrying macOS's quarantine
# attribute, and ParrotFlow is signed with a self-signed certificate rather than
# a Developer ID, so Gatekeeper would refuse to open it. Homebrew removed the
# --no-quarantine escape hatch in 5.0. Files fetched with curl are never
# quarantined in the first place, which is why this route works and a cask does
# not. See docs/distribution.md.
#
# Nothing here is interactive: this script is read from stdin when piped to sh,
# so it can never prompt.
#
#   PARROTFLOW_VERSION=0.2.0   install a specific version instead of the latest
#   PARROTFLOW_DEST=~/Applications   install somewhere other than /Applications
set -eu

REPO="znat/parrotflow"
APP_NAME="ParrotFlow"
DEST="${PARROTFLOW_DEST:-/Applications}"
DEST="$(eval echo "$DEST")"

die() { printf '\nerror: %s\n' "$1" >&2; exit 1; }
say() { printf '==> %s\n' "$1"; }

# --- Preflight ---------------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || die "ParrotFlow is macOS only."

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MACOS_MAJOR" -ge 14 ] 2>/dev/null \
    || die "ParrotFlow needs macOS 14 or later; this is $(sw_vers -productVersion)."

# Parakeet runs on the Neural Engine through CoreML, which Intel Macs do not have.
[ "$(uname -m)" = "arm64" ] \
    || die "ParrotFlow needs an Apple Silicon Mac; speech recognition runs on the Neural Engine."

if [ ! -w "$DEST" ]; then
    die "$DEST is not writable.
       Re-run with a destination you own:
         curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | PARROTFLOW_DEST=~/Applications sh"
fi

# --- Download ----------------------------------------------------------------

if [ -n "${PARROTFLOW_BASE_URL:-}" ]; then
    # Point at a local dist/ to rehearse a release before publishing it.
    BASE="$PARROTFLOW_BASE_URL"
    say "Installing from $BASE"
elif [ -n "${PARROTFLOW_VERSION:-}" ]; then
    BASE="https://github.com/$REPO/releases/download/v${PARROTFLOW_VERSION#v}"
    say "Downloading ParrotFlow ${PARROTFLOW_VERSION#v}"
else
    BASE="https://github.com/$REPO/releases/latest/download"
    say "Downloading the latest ParrotFlow"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

fetch() {
    curl -fsSL --retry 3 -o "$2" "$1" 2>/dev/null
}

fetch "$BASE/$APP_NAME.zip" "$TMP/$APP_NAME.zip" || die "could not download the app.
       Tried: $BASE/$APP_NAME.zip
       Check https://github.com/$REPO/releases for a published release,
       and that you are online."
fetch "$BASE/$APP_NAME.zip.sha256" "$TMP/$APP_NAME.zip.sha256" \
    || die "the app downloaded but its checksum did not. Not installing an
       archive that cannot be verified."

# Integrity, not authenticity: the checksum travels with the archive, so it
# catches a truncated or corrupted download and nothing more. Verifying the
# publisher needs a signature, which arrives with Developer ID.
say "Checking the download"
EXPECTED="$(cut -d' ' -f1 < "$TMP/$APP_NAME.zip.sha256")"
ACTUAL="$(shasum -a 256 "$TMP/$APP_NAME.zip" | cut -d' ' -f1)"
[ "$EXPECTED" = "$ACTUAL" ] || die "checksum mismatch — the download is not what was published.
       expected $EXPECTED
       got      $ACTUAL"

# ditto, not unzip: a .app is a bundle, and unzip drops the metadata the code
# signature covers. A bundle unpacked with unzip fails signature verification,
# which costs the user their microphone and accessibility grants.
ditto -x -k "$TMP/$APP_NAME.zip" "$TMP/unpacked" || die "could not unpack the download"
[ -d "$TMP/unpacked/$APP_NAME.app" ] || die "the archive did not contain $APP_NAME.app"

codesign --verify --deep --strict "$TMP/unpacked/$APP_NAME.app" 2>/dev/null \
    || die "the downloaded app failed signature verification; not installing it"

# --- Install -----------------------------------------------------------------

WAS_RUNNING=""
if pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
    WAS_RUNNING="yes"
    say "Quitting the running copy"
    pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 || true
    sleep 1
fi

say "Installing to $DEST/$APP_NAME.app"
rm -rf "$DEST/$APP_NAME.app"
mv "$TMP/unpacked/$APP_NAME.app" "$DEST/$APP_NAME.app" \
    || die "could not move the app into $DEST"

# Should never fire on a curl download — curl does not set the quarantine
# attribute — but say so plainly rather than let the user meet a Gatekeeper
# dialog with no explanation.
if xattr -p com.apple.quarantine "$DEST/$APP_NAME.app" >/dev/null 2>&1; then
    printf '\nwarning: the app arrived quarantined, so macOS may refuse to open it.\n' >&2
    printf '         Remove it with: xattr -dr com.apple.quarantine %s\n\n' "$DEST/$APP_NAME.app" >&2
fi

VERSION="$(/usr/bin/defaults read "$DEST/$APP_NAME.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")"
say "Installed ParrotFlow $VERSION"

open "$DEST/$APP_NAME.app" || die "installed, but could not launch it"

cat <<'EOF'

    ParrotFlow is running — look for 🎙 in your menu bar.

    Next:
      1. Say yes to the microphone prompt.
      2. Hold Right Option, say something, let go.

    Full setup, including spoken corrections:
      https://github.com/znat/parrotflow#install

EOF

if [ -n "$WAS_RUNNING" ]; then
    printf '    This was an upgrade. If dictation stops working, macOS dropped the\n'
    printf '    permission — re-tick ParrotFlow under Privacy & Security.\n\n'
fi
