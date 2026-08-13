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
# Two URLs, and they do not move together. This file is read from `main`, which
# changes whenever anything is pushed; the app is fetched from the latest
# release, which changes only when one is cut. So this script is always at least
# as new as the app it installs, and often newer. Nothing in here may depend on
# the app's own behaviour — not a flag, not an output format, not a config key
# it has only just learned. Ask the filesystem, ask another program, or ask the
# user's own config file. Those are true across the gap; the app is not.
#
#   PARROTFLOW_VERSION=0.2.0   install a specific version instead of the latest
#   PARROTFLOW_DEST=~/Applications   install somewhere other than /Applications
#   PARROTFLOW_SETUP_VOICE=0   skip installing Ollama and pulling the Gemma model
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

# The checksum travels with the archive, so on its own it catches a truncated
# or corrupted download and nothing more: whoever could replace the archive
# could replace the checksum beside it. Authenticity comes from the certificate
# check further down.
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

# And then: signed by whom.
#
# The check above proves the signature matches the bundle. It does not prove
# whose signature it is — anyone can make a self-signed certificate, sign an
# app with it, and pass. Without the line below, an archive swapped for
# somebody else's would install without a word, on a machine that is then asked
# for the microphone and for permission to type into every window.
#
# So the leaf certificate's SHA-256 is pinned. The name is not enough: a
# certificate can be issued to any common name, "ParrotFlow Release" included.
#
# Pinning a value inside a script is normally how you strand yourself on a
# rotated key. Not here: this file is read from main on every run, so the day
# the certificate changes, the pin changes with it in the same commit. And a
# release signed with a different certificate is one macOS would refuse the
# user's existing Microphone and Accessibility grants to anyway — refusing it
# here turns a silent loss of permissions into a stop with a reason.
CERT_SHA256="1fe06cb4b110d3f60ddb0a4d54e2694528b50ca1f40e939994306c8b068d2689"

if [ -n "${PARROTFLOW_BASE_URL:-}" ]; then
    # A local rehearsal (make try-install) builds and signs with whatever
    # identity is on that machine, which is the dev certificate for anyone who
    # is not cutting releases. Say the check was skipped rather than let a
    # rehearsal look like it proved more than it did.
    say "Local install — skipping the certificate check"
else
    codesign -d --extract-certificates="$TMP/cert" "$TMP/unpacked/$APP_NAME.app" 2>/dev/null \
        || die "could not read the signing certificate of the downloaded app"
    SIGNER="$(shasum -a 256 "$TMP/cert0" | cut -d' ' -f1)"
    [ "$SIGNER" = "$CERT_SHA256" ] || die "this app was signed by someone else — not installing it.
       expected certificate $CERT_SHA256
       found                $SIGNER

       Nothing on this Mac has been changed. If you did not expect this,
       do not install ParrotFlow from anywhere else either — report it at
       https://github.com/$REPO/issues"
    say "Signed by the ParrotFlow release certificate"
fi

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
      2. Click the 🎙 icon, choose Permissions…, and grant Accessibility —
         without it, dictation transcribes but can't type it in for you.
      3. Hold Right Option, say something, let go.

EOF

# --- What is still missing ---------------------------------------------------
#
# The speech model is reported, never installed: the app already downloads it
# on first use, with a progress figure and without blocking recording, which
# this script cannot match. See docs/distribution.md.
#
# Ollama and the Gemma model are installed here by default. This is not the
# grammar checker or a nice extra: the vocabulary judge that keeps a matched
# name from landing in the wrong sentence runs on this model, so a Mac without
# it gets rule matches with nothing reviewing them. PARROTFLOW_SETUP_VOICE=0
# skips it, for a script or a machine that wants the app alone.
#
# Every check below asks the filesystem or another program, never the app we
# just installed. That is the rule, and the reason is the URLs: this script is
# read from main, which moves, while the app comes from the latest release,
# which does not. A check written against a flag this app might not have yet
# would break for the person who most needs the script to work — the one who
# does not have the app.

MODELS="$HOME/Library/Application Support/FluidAudio/Models"
if ! ls -d "$MODELS"/parakeet-* >/dev/null 2>&1; then
    printf '    The speech model is not on this Mac yet. Your first dictation\n'
    printf '    downloads it: about 1.2 GB, a few minutes, once. That wait is\n'
    printf '    normal and only happens the first time.\n\n'
fi

# Their config wins if it names a different model; this file is the user's, so
# reading it costs nothing and does not depend on the app's version.
MODEL="gemma4:e4b-mlx"
CONFIG="$HOME/.config/parrotflow/config.yaml"
if [ -f "$CONFIG" ]; then
    NAMED="$(sed -n 's/^[[:space:]]*model:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$CONFIG" | head -1)"
    [ -n "$NAMED" ] && MODEL="$NAMED"
fi

# Set unless the caller opted out. Read once, here, so every branch below
# tests the same value instead of re-reading the environment.
SETUP_VOICE="${PARROTFLOW_SETUP_VOICE:-1}"

# What Ollama backs: not only spoken commands, but also the check that a
# vocabulary term applied in the right context. Dictation and the deterministic
# match still work without Ollama; that match then ships unchecked instead of
# reviewed, so a name can land in the wrong place with nothing to catch it.
#
# Three checks in sequence, not mutually exclusive branches: installing Ollama
# still leaves the model to pull, and starting a stopped Ollama still leaves
# the model to check. A stopped service used to be a dead end — the script
# started it and stopped there, never looking at whether the model it needs
# was actually present.
if ! command -v ollama >/dev/null 2>&1; then
    printf '    Ollama is not on this Mac. It runs the language model behind two\n'
    printf '    things: spoken commands, and the check that a vocabulary match fits\n'
    printf '    its sentence before it is kept. Without it, dictation still works,\n'
    printf '    and vocabulary still matches — the match just ships unreviewed.\n\n'
    if [ "$SETUP_VOICE" != "0" ]; then
        printf '    ParrotFlow is already running and dictation already works — this\n'
        printf '    download only unlocks spoken commands and the vocabulary check.\n\n'
        say "Installing Ollama"
        brew install ollama && brew services start ollama \
            || die "could not install or start Ollama"
    else
        printf '      brew install ollama && brew services start ollama\n'
        printf '      ollama pull %s\n\n' "$MODEL"
    fi
fi

if command -v ollama >/dev/null 2>&1 && ! INSTALLED="$(ollama list 2>/dev/null)"; then
    printf '    Ollama is installed but not answering, so spoken commands and the\n'
    printf '    vocabulary context check will not work. Start it:\n\n'
    if [ "$SETUP_VOICE" != "0" ]; then
        say "Starting Ollama"
        brew services start ollama || die "could not start Ollama"
        # Bounded poll, not a fixed sleep: freshly started is not freshly
        # listening, and a guessed delay that is too short makes the model
        # check below fail silently — it sees Ollama still not answering and
        # skips the pull with no explanation. Up to 15s, checked every second.
        i=0
        until ollama list >/dev/null 2>&1; do
            i=$((i + 1))
            if [ "$i" -ge 15 ]; then
                printf '    Ollama started but is not answering yet. Run this installer\n'
                printf '    again once it has, or pull the model yourself:\n\n'
                printf '      ollama pull %s\n\n' "$MODEL"
                break
            fi
            sleep 1
        done
    else
        printf '      brew services start ollama\n\n'
    fi
fi

if command -v ollama >/dev/null 2>&1 \
    && INSTALLED="$(ollama list 2>/dev/null)" \
    && ! printf '%s\n' "$INSTALLED" | grep -qF "$MODEL"; then
    printf '    The %s model is not downloaded yet. Spoken commands and the\n' "$MODEL"
    printf '    vocabulary context check need it:\n\n'
    # Only the default's size is known here. A model named in someone's own
    # config could be any size, and a wrong number is worse than none.
    if [ "$MODEL" = "gemma4:e4b-mlx" ]; then
        printf '    About 8.8 GB.\n\n'
    fi
    if [ "$SETUP_VOICE" != "0" ]; then
        printf '    ParrotFlow is already running and dictation already works — this\n'
        printf '    download only unlocks spoken commands and the vocabulary check.\n\n'
        say "Pulling $MODEL"
        ollama pull "$MODEL" || die "could not pull $MODEL"
    else
        printf '      ollama pull %s\n\n' "$MODEL"
        printf '    Dictation works the whole time it downloads.\n\n'
    fi
fi

cat <<'EOF'
    Full setup, including spoken corrections:
      https://github.com/znat/parrotflow#install

EOF

if [ -n "$WAS_RUNNING" ]; then
    printf '    This was an upgrade. If dictation stops working, macOS dropped the\n'
    printf '    permission — re-tick ParrotFlow under Privacy & Security.\n\n'
fi
