#!/usr/bin/env bash
# Records a region of the screen and writes an optimised GIF, which is how the
# ones in Resources/ are made.
#
# Two passes, because ffmpeg on its own encodes a GIF against a fixed generic
# palette rather than one taken from the clip. `palettegen` reads the whole
# recording first and picks 256 colours that suit it, which is what keeps a
# gradient — the pill's glass, a Slack background — from banding.
#
#   scripts/record-gif.sh Resources/refs.gif 12 "0,0,1280,800"
#
# The region is x,y,width,height in points. Leave it out for the whole screen,
# which is almost never what you want — a full retina screen makes a 20 MB GIF.
#
# Needs Screen Recording permission, and macOS credits it to the terminal you
# are in rather than to this script. Without it `screencapture` prints nothing
# and writes no file — there is no prompt to accept — and the grant only takes
# effect once that terminal is quit and reopened. The check below says so.
set -uo pipefail

OUT="${1:?usage: record-gif.sh <out.gif> [seconds] [x,y,w,h]}"
SECONDS_LIMIT="${2:-12}"
REGION="${3:-}"
FPS="${FPS:-12}"
WIDTH="${WIDTH:-760}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MOV="$TMP/capture.mov"

echo "==> Recording ${SECONDS_LIMIT}s${REGION:+ of $REGION}. Go."
if [ -n "$REGION" ]; then
  screencapture -v -V "$SECONDS_LIMIT" -R"$REGION" "$MOV"
else
  screencapture -v -V "$SECONDS_LIMIT" "$MOV"
fi
if [ ! -s "$MOV" ]; then
  # macOS credits the permission to the top-level bundle, not to this script,
  # so what needs ticking is the terminal you are in — or whatever launched it.
  owner="$(ps -o comm= -p "$(ps -o ppid= -p $PPID | tr -d ' ')" 2>/dev/null | sed 's|.*/||')"
  echo "✗ nothing was recorded."
  echo "  System Settings > Privacy & Security > Screen & System Audio Recording"
  echo "  Tick ${owner:-your terminal}, then quit and reopen it. The grant only"
  echo "  takes effect on a fresh launch, and until then this writes no file."
  exit 1
fi

echo "==> Converting at ${FPS}fps, ${WIDTH}px wide"
ffmpeg -hide_banner -loglevel error -i "$MOV" \
  -vf "fps=$FPS,scale=$WIDTH:-1:flags=lanczos,palettegen=stats_mode=diff" \
  -y "$TMP/palette.png" || exit 1
# Encoded beside the destination and moved onto it only once ffmpeg is happy.
# `-y` truncates the output when it opens it, so a conversion that dies partway
# — Ctrl-C, a full disk, a bad frame — leaves a fragment where the good GIF
# was. Measured: an 804K recording came back as a 2.3M half-file. Beside it
# rather than in $TMP so the move is a rename on the same filesystem.
# Keeps the .gif on the end: ffmpeg picks its muxer from the extension, and
# "$OUT.partial.123" has none it recognises.
PART="$OUT.partial.$$.gif"
trap 'rm -rf "$TMP"; rm -f "$PART"' EXIT
if ! ffmpeg -hide_banner -loglevel error -i "$MOV" -i "$TMP/palette.png" \
  -lavfi "fps=$FPS,scale=$WIDTH:-1:flags=lanczos[v];[v][1:v]paletteuse=dither=bayer:bayer_scale=3" \
  -y "$PART"; then
  echo "✗ conversion failed — ${OUT} is untouched"
  exit 1
fi
mv -f "$PART" "$OUT" || exit 1

printf '==> %s  %s\n' "$OUT" "$(du -h "$OUT" | cut -f1)"
