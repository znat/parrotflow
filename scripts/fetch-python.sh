#!/usr/bin/env bash
#
# The Python the App Store build runs its own transforms with.
#
# Not the Mac's python3, and not one the user installs. The sandbox will only
# execute what is inside the app bundle, and App Store guideline 2.5.2 wants
# the app self-contained, so the interpreter ships with it — reviewed, signed
# and read-only like everything else in Contents/Resources.
#
# Downloads a prebuilt CPython, checks it against the hash pinned here, throws
# away everything the four shipped scripts do not import, and leaves the result
# in .build/python/. build-app.sh copies that into the bundle.
#
# Measured on the 20260901 build:
#
#   download          24 MB
#   extracted         66 MB
#   after the trim    28 MB
#   signable binaries  1   (bin/python3.13; no .so, no .dylib)
#
# That last line is the useful one. This build of CPython is statically linked
# — unicodedata, _sre, _json, _datetime, zlib and the rest are inside the
# executable, lib-dynload holds only _dbm and _tkinter, and both are trimmed.
# So there is exactly one Mach-O file to sign and library validation has
# nothing to complain about.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Pinned, not "latest". A version that moved under us would change what the
# scripts run on without anything here saying so, and the hash is what makes
# the download the one that was measured. To move it: pick a tag from
# github.com/astral-sh/python-build-standalone/releases, take the hash out of
# that release's SHA256SUMS, and run the transforms' case sets afterwards.
PYTHON_RELEASE="20260901"
PYTHON_VERSION="3.13.15"
PYTHON_SHA256="d3904bd6a072246e07aa0bdadee9a14e80521e42a943c0848059feb16a2816dc"

ARCHIVE="cpython-${PYTHON_VERSION}+${PYTHON_RELEASE}-aarch64-apple-darwin-install_only_stripped.tar.gz"
URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE}/${ARCHIVE}"

DEST="$ROOT/.build/python"
CACHE="$ROOT/.build/python-download"
STAMP="$DEST/.pinned"

# Nothing to do if the trimmed tree is already the pinned one. `make app` runs
# this every time, and a 24 MB download per build is not a thing to pay twice.
if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$PYTHON_SHA256" ]; then
    echo "==> Python $PYTHON_VERSION is already in .build/python"
    exit 0
fi

mkdir -p "$CACHE"
TARBALL="$CACHE/$ARCHIVE"

if [ ! -f "$TARBALL" ]; then
    echo "==> Downloading CPython $PYTHON_VERSION ($PYTHON_RELEASE)"
    curl -fsSL --retry 3 -o "$TARBALL.part" "$URL"
    mv "$TARBALL.part" "$TARBALL"
fi

echo "==> Checking the download"
ACTUAL="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
if [ "$ACTUAL" != "$PYTHON_SHA256" ]; then
    # Removed rather than left behind: a bad file that stays becomes the file
    # the next run finds already downloaded and does not re-fetch.
    rm -f "$TARBALL"
    echo "error: $ARCHIVE does not match the pinned hash" >&2
    echo "  expected $PYTHON_SHA256" >&2
    echo "  got      $ACTUAL" >&2
    exit 1
fi

echo "==> Unpacking"
rm -rf "$DEST" "$DEST.tmp"
mkdir -p "$DEST.tmp"
tar xzf "$TARBALL" -C "$DEST.tmp"
mv "$DEST.tmp/python" "$DEST"
rmdir "$DEST.tmp"

echo "==> Trimming"
cd "$DEST"

# Headers, the static library, pkg-config: build-time things in a runtime copy.
rm -rf include share lib/pkgconfig
find . -name '*.a' -delete

# Tcl/Tk, ~7 MB of it. Nothing here draws a window from Python.
rm -rf lib/tcl9.0 lib/tk9.0 lib/tcl9 lib/itcl4.3.8 lib/thread3.0.6
rm -f lib/libtcl9.0.dylib lib/libtcl9tk9.0.dylib
rm -rf lib/python3.13/tkinter lib/python3.13/idlelib lib/python3.13/turtledemo

# The shared library is 17 MB and nothing references it: this build links
# libpython into the executable. Checked rather than assumed — see below.
rm -f lib/libpython3.13.dylib

# pip and what installs it. The App Store build installs nothing, ever; a pip
# inside the bundle is a package manager Apple would be right to ask about.
rm -rf lib/python3.13/site-packages lib/python3.13/ensurepip
rm -f bin/pip* bin/idle* bin/pydoc* bin/python3.13-config bin/python3-config

# Documentation data and the test suites.
rm -rf lib/python3.13/pydoc_data lib/python3.13/test lib/python3.13/config-3.13-darwin
find lib/python3.13 -type d \( -name test -o -name tests \) -prune -exec rm -rf {} +

# The last two extension modules, both for things that were just removed.
rm -f lib/python3.13/lib-dynload/_dbm*.so lib/python3.13/lib-dynload/_tkinter*.so

# A helper shell script that downloads Mach-O binaries. Harmless and unused,
# and not a thing to leave in a bundle submitted for review.
rm -f lib/python3.13/ctypes/macholib/fetch_macholib*

# Bytecode, written now because it cannot be written later: the bundle is
# signed and read-only, and a .pyc appearing beside a .py at first import
# would either fail or invalidate the signature. CommandRunner also sets
# PYTHONDONTWRITEBYTECODE for the same reason.
echo "==> Precompiling"
./bin/python3 -m compileall -q -f lib/python3.13 >/dev/null 2>&1 || {
    echo "error: compileall failed — the bundled interpreter does not run here" >&2
    exit 1
}

# The claim the signing step depends on. If a future build of CPython gains a
# .so or starts linking the dylib, this is where it has to be noticed: every
# extra Mach-O file is one more thing to sign, and an unsigned one fails
# library validation at launch with a message that names none of this.
MACHO="$(find . -type f \( -name '*.so' -o -name '*.dylib' \) | wc -l | tr -d ' ')"
if [ "$MACHO" != "0" ]; then
    echo "error: $MACHO shared libraries survived the trim; codesign.sh signs only the" >&2
    echo "       interpreter. Sign them too, or trim them." >&2
    find . -type f \( -name '*.so' -o -name '*.dylib' \) >&2
    exit 1
fi

# The PSF licence has to ship with the interpreter. It survives the trim
# today because it sits in lib/python3.13/, not in share/ — which is luck, not
# design, so it is asserted rather than assumed. Shipping CPython without it
# is a licence violation, and one nothing else here would notice.
LICENSE="lib/python3.13/LICENSE.txt"
if ! grep -q "PYTHON SOFTWARE FOUNDATION LICENSE" "$LICENSE" 2>/dev/null; then
    echo "error: $LICENSE is missing or is not the PSF licence — the trim dropped it," >&2
    echo "       and CPython cannot be distributed without it." >&2
    exit 1
fi

printf '%s' "$PYTHON_SHA256" > "$STAMP"
echo "==> Python $PYTHON_VERSION trimmed to $(du -sh "$DEST" | cut -f1) in .build/python"
