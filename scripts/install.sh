#!/bin/sh
#
# ParrotFlow installer.
#
#   curl -fsSL https://raw.githubusercontent.com/znat/parrotflow/main/scripts/install.sh | sh
#
# Downloads the latest release, checks it against its published SHA-256, and
# puts ParrotFlow.app in /Applications.
#
# There is a Homebrew cask too — `brew install znat/tap/parrotflow`. This stays
# the headline install because it needs nothing installed first. See
# docs/distribution.md.
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
#   PARROTFLOW_SETUP_VOICE=1   install Ollama and pull the model here, rather
#                              than printing how to
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
# whose signature it is. Without the line below, an archive swapped for
# somebody else's would install without a word, on a machine that is then asked
# for the microphone and for permission to type into every window.
#
# So the download is checked against a designated requirement. `anchor apple
# generic` says the certificate chain ends at Apple's root, which nothing
# self-signed can claim however it is named. The OU of a Developer ID leaf is
# the Team ID. Together they say Apple issued this certificate to us.
#
# This is checked rather than a pinned leaf hash on purpose. A Developer ID
# certificate expires after five years, and renewing it produces a new leaf
# with a new hash. A pin would then be wrong in every copy of the app already
# installed, and every user would have to re-run this script. The Team ID does
# not change when the certificate does.
TEAM_ID="VCCU2WY6HS"

if [ -n "${PARROTFLOW_BASE_URL:-}" ]; then
    # A local rehearsal (make try-install) builds and signs with whatever
    # identity is on that machine, which is a self-signed certificate for
    # anyone who is not cutting releases. Say the check was skipped rather than
    # let a rehearsal look like it proved more than it did.
    say "Local install — skipping the Developer ID and notarization checks"
else
    codesign --verify --deep --strict \
        -R "=anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\"" \
        "$TMP/unpacked/$APP_NAME.app" 2>/dev/null \
        || die "this app was not signed by ParrotFlow — not installing it.
       Expected a Developer ID certificate issued to Team ID $TEAM_ID.

       Nothing on this Mac has been changed. If you did not expect this,
       do not install ParrotFlow from anywhere else either — report it at
       https://github.com/$REPO/issues"

    # And what Gatekeeper itself concludes, asked the same way it asks. This
    # is the notarization ticket: a signature can be genuine and the build
    # still never submitted to Apple.
    spctl --assess --type execute "$TMP/unpacked/$APP_NAME.app" 2>/dev/null \
        || die "this app is signed but not notarized — not installing it.
       Report it at https://github.com/$REPO/issues"

    say "Signed by ParrotFlow and notarized by Apple"
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

    ParrotFlow is running — look for 🦜 in your menu bar.

    Next:
      1. Say yes to the microphone prompt — wait until it's granted.
      2. Click the 🦜 icon, choose Permissions…, grant Accessibility, and
         wait until that's granted too — without it, dictation transcribes
         but can't type the result in for you.
      3. Hold Right Command, say something, let go.

EOF

# --- What is still missing ---------------------------------------------------
#
# The speech model is reported, never installed: the app already downloads it
# on first use, with a progress figure and without blocking recording, which
# this script cannot match. See docs/distribution.md.
#
# Ollama is reported, never installed. `models:` in config.yaml names a model
# per job, and an entry there may be an OpenAI- or Anthropic-shaped endpoint as
# well as a local one — so running the vocabulary judge and spoken commands no
# longer means running a model on this Mac. What is still true is that they
# need *a* model: without one, a rule match ships with nothing reviewing it.
# So this prints both ways and installs neither. PARROTFLOW_SETUP_VOICE=1 does
# the local one here, for a machine that wants it all in one command.
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
    printf '    downloads it: about 470 MB, a minute or two, once. That wait is\n'
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

# Off unless the caller opted in. Read once, here, so every branch below tests
# the same value instead of re-reading the environment.
SETUP_VOICE="${PARROTFLOW_SETUP_VOICE:-0}"

# Set by any branch below that finds something to do, so the end of this
# section can say plainly that nothing was needed — silence reads as "did
# this even run", not as "already done".
NEEDED_SETUP=""

# What a model backs: not only spoken commands, but also the check that a
# vocabulary term applied in the right context. Dictation and the deterministic
# match still work without one; that match then ships unchecked instead of
# reviewed, so a name can land in the wrong place with nothing to catch it.
# Ollama is the way to run that model on this Mac, and `models:` in config.yaml
# is the way to run it somewhere else.
#
# Three checks in sequence, not mutually exclusive branches: installing Ollama
# still leaves the model to pull, and starting a stopped Ollama still leaves
# the model to check. A stopped service used to be a dead end — the script
# started it and stopped there, never looking at whether the model it needs
# was actually present.
if ! command -v ollama >/dev/null 2>&1; then
    NEEDED_SETUP=1
    printf '    Ollama is not on this Mac, and it is optional. A language model\n'
    printf '    backs two things: spoken commands, and the check that a vocabulary\n'
    printf '    match fits its sentence before it is kept. Without any model,\n'
    printf '    dictation still works, and vocabulary still matches — the match\n'
    printf '    just ships unreviewed.\n\n'
    if [ "$SETUP_VOICE" = "1" ]; then
        printf '    ParrotFlow is already running and dictation already works — this\n'
        printf '    download only unlocks spoken commands and the vocabulary check.\n\n'
        say "Installing Ollama"
        brew install ollama && brew services start ollama \
            || die "could not install or start Ollama"
    else
        printf '    To run the model here, on this Mac:\n\n'
        printf '      brew install ollama && brew services start ollama\n'
        printf '      ollama pull %s\n\n' "$MODEL"
        printf '    Or run it somewhere else: `models:` in config.yaml takes an\n'
        printf '    OpenAI- or Anthropic-shaped endpoint, and a transform names one\n'
        printf '    with `model:`. That sends your dictation off this Mac, and\n'
        printf '    --check-config says so every time. See docs/configuration.md.\n\n'
    fi
fi

if command -v ollama >/dev/null 2>&1 && ! INSTALLED="$(ollama list 2>/dev/null)"; then
    NEEDED_SETUP=1
    printf '    Ollama is installed but not answering, so anything pointed at it\n'
    printf '    will not work. Start it:\n\n'
    if [ "$SETUP_VOICE" = "1" ]; then
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
    NEEDED_SETUP=1
    printf '    The %s model is not downloaded yet. Spoken commands and the\n' "$MODEL"
    printf '    vocabulary context check need it:\n\n'
    # Only the default's size is known here. A model named in someone's own
    # config could be any size, and a wrong number is worse than none.
    if [ "$MODEL" = "gemma4:e4b-mlx" ]; then
        printf '    About 8.8 GB.\n\n'
    fi
    if [ "$SETUP_VOICE" = "1" ]; then
        printf '    ParrotFlow is already running and dictation already works — this\n'
        printf '    download only unlocks spoken commands and the vocabulary check.\n\n'
        say "Downloading $MODEL — this runs in the background, and dictation"
        printf '    keeps working the whole time.\n\n'
        ollama pull "$MODEL" || die "could not pull $MODEL"
    else
        printf '      ollama pull %s\n\n' "$MODEL"
        printf '    Dictation works the whole time it downloads.\n\n'
    fi
fi

if [ -z "$NEEDED_SETUP" ]; then
    printf '    Ollama and the %s model are already set up — spoken\n' "$MODEL"
    printf '    commands and the vocabulary check are ready now.\n\n'
fi

cat <<'EOF'
    Full setup, including spoken corrections:
      https://github.com/znat/parrotflow#install

EOF

if [ -n "$WAS_RUNNING" ]; then
    printf '    This was an upgrade. If dictation stops working, macOS dropped the\n'
    printf '    permission — re-tick ParrotFlow under Privacy & Security.\n\n'
fi
