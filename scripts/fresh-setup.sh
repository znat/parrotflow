#!/bin/sh
# Put a build back to the state a new Mac is in, then install it again.
#
# For testing the setup screen. That screen only appears with something to do:
# permissions that have never been answered, and models that are not on disk.
# This removes both.
#
# VARIANT selects the build, like everything else here, and defaults to dev.
set -eu

cd "$(dirname "$0")/.."
. scripts/variant.sh

ESPEAK=1 CONFIG=0 PURGE=0 INSTALL=1
for arg in "$@"; do
    case "$arg" in
        --keep-espeak) ESPEAK=0 ;;
        --config)      CONFIG=1 ;;
        --purge-old)   PURGE=1 ;;
        --no-install)  INSTALL=0 ;;
        -h|--help)
            cat <<'USAGE'
usage: scripts/fresh-setup.sh [options]

  --keep-espeak   leave eSpeak NG installed
  --config        move the config directory aside too
  --purge-old     delete .moved-* copies left by earlier runs
  --no-install    stop after the reset, do not build or launch

  VARIANT=release scripts/fresh-setup.sh   act on the shipped build instead
USAGE
            exit 0 ;;
        *) echo "error: unknown option '$arg' — try --help" >&2; exit 1 ;;
    esac
done

SUPPORT="$HOME/Library/Application Support/$DISPLAY_NAME"
SHARED="$HOME/Library/Application Support/FluidAudio/Models"
G2P="$HOME/.cache/fluidaudio/Models"
STAMP="$(date +%Y-%m-%d-%H%M%S)"

espeak_here() {
    [ "$ESPEAK" -eq 1 ] && command -v brew >/dev/null 2>&1 \
        && brew list espeak-ng >/dev/null 2>&1
}

echo "==> Resetting $DISPLAY_NAME ($BUNDLE_ID) to a first run."
echo
echo "  quit it, and remove /Applications/$APP_NAME.app"
echo "  tccutil reset All $BUNDLE_ID"
echo "  delete its defaults — the espeak answer, the microphone notice, the update reminder"
echo "  delete $SUPPORT/models"
echo "  move aside the speech models, which the other build reads from the same place:"
echo "      $SHARED/{parakeet-tdt-0.6b-v3,silero-vad}"
echo "      $G2P"
espeak_here && echo "  brew uninstall espeak-ng — this takes it from the other build too"
[ "$CONFIG" -eq 1 ] && echo "  move $HOME/$CONFIG_DIR aside"
[ "$PURGE" -eq 1 ] && echo "  delete every .moved-* copy from earlier runs"
[ "$INSTALL" -eq 1 ] && echo "  build, install and launch it again"
echo
echo "  kept: portraits and the phoneme table in $SUPPORT"
[ "$CONFIG" -eq 0 ] && echo "  kept: ~/$CONFIG_DIR — add --config to move it aside"
echo

pkill -f "$APP_NAME.app/Contents/MacOS/$EXECUTABLE_NAME" 2>/dev/null || true
sleep 1
rm -rf "/Applications/$APP_NAME.app"
echo "==> Quit, and removed from /Applications."

# All, not the three services the app asks for by name: it also captures the
# screen for context, and that is a fourth grant that survives the other three.
tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 || true
echo "==> Permissions forgotten."

# After the app is stopped. A running app writes its defaults back out.
defaults delete "$BUNDLE_ID" 2>/dev/null || true
echo "==> Defaults deleted."

rm -rf "$SUPPORT/models" "$SUPPORT/install-espeak-ng.command"
echo "==> Removed this build's own models."

# Moved rather than deleted. These three live outside the per-build directory,
# so deleting them costs the other build a 560 MB download it did not ask for.
# Once this run has downloaded them again the copies are dead weight.
for name in parakeet-tdt-0.6b-v3 silero-vad; do
    if [ -d "$SHARED/$name" ]; then
        mv "$SHARED/$name" "$SHARED/$name.moved-$STAMP"
    fi
done
if [ -d "$G2P" ]; then
    mv "$G2P" "$G2P.moved-$STAMP"
fi
echo "==> Shared speech models moved aside as .moved-$STAMP."

if espeak_here; then
    brew uninstall espeak-ng
    echo "==> eSpeak NG uninstalled."
fi

if [ "$CONFIG" -eq 1 ] && [ -d "$HOME/$CONFIG_DIR" ]; then
    mv "$HOME/$CONFIG_DIR" "$HOME/$CONFIG_DIR.moved-$STAMP"
    echo "==> Config moved to ~/$CONFIG_DIR.moved-$STAMP."
fi

if [ "$PURGE" -eq 1 ]; then
    find "$SHARED" "$SUPPORT" "$(dirname "$G2P")" -maxdepth 1 \
        -name "*.moved-*" ! -name "*$STAMP" -exec rm -rf {} + 2>/dev/null || true
    echo "==> Earlier .moved-* copies deleted."
fi

if [ "$INSTALL" -eq 1 ]; then
    echo
    make --no-print-directory install VARIANT="$VARIANT"
    echo
    echo "==> The setup window is open. Six models are downloading, about 1.5 GB."
    echo "    Watch them:  make logs VARIANT=$VARIANT"
    echo "    Stuck microphone dialog:  killall UserNotificationCenter"
    echo "    When the downloads finish:  scripts/fresh-setup.sh --purge-old --no-install"
fi
