#!/usr/bin/env bash
#
# Points the Homebrew cask at the release that was just published.
#
#   VERSION=0.10.0 TAG=v0.10.0 GH_TOKEN=... scripts/bump-cask.sh
#
# The cask lives in znat/homebrew-tap and is written from here, so the thing
# that decides what a `brew install` gets is reviewed in the same repository as
# the app. The tap holds no logic of its own.
#
# The checksum is read off the release rather than computed: install.sh and the
# app's own updater already check that same published number, so a cask that
# used a different one could send brew a build the other two paths would refuse.
set -euo pipefail

: "${VERSION:?VERSION is required}"
: "${TAG:?TAG is required}"

# A warning, not an error. The release itself is already published by the time
# this runs, so a missing token should leave the cask behind rather than mark a
# good release failed.
if [ -z "${GH_TOKEN:-}" ]; then
    echo "::warning::TAP_TOKEN is not set — the Homebrew cask still points at the previous version."
    exit 0
fi

TAP="${TAP:-znat/homebrew-tap}"
REPO="${REPO:-znat/parrotflow}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Reading the published checksum for $TAG"
gh release download "$TAG" --repo "$REPO" --pattern 'ParrotFlow.zip.sha256' --dir "$TMP"
SHA256="$(cut -d' ' -f1 < "$TMP/ParrotFlow.zip.sha256")"
[ -n "$SHA256" ] || { echo "error: no checksum in the release asset" >&2; exit 1; }

echo "==> Cloning $TAP"
git clone --depth 1 "https://x-access-token:$GH_TOKEN@github.com/$TAP.git" "$TMP/tap"
mkdir -p "$TMP/tap/Casks"

cat > "$TMP/tap/Casks/parrotflow.rb" <<EOF
# Written by scripts/bump-cask.sh in $REPO. Edit it there.
cask "parrotflow" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/$REPO/releases/download/v#{version}/ParrotFlow.zip",
      verified: "github.com/$REPO/"
  name "ParrotFlow"
  desc "Programmable dictation for macOS"
  homepage "https://github.com/$REPO"

  # The app checks GitHub hourly and installs its own updates, so brew should
  # not treat a self-updated copy as outdated. See docs/distribution.md.
  auto_updates true

  livecheck do
    url :url
    strategy :github_latest
  end

  # macOS 14 is FluidAudio's floor — the speech models need CoreML on the ANE.
  depends_on macos: ">= :sonoma"

  app "ParrotFlow.app"

  zap trash: [
    "~/.config/parrotflow",
    "~/Library/Logs/ParrotFlow.log",
    "~/Library/Preferences/com.parrotflow.app.plist",
    # The speech models, about 1.2 GB of them.
    "~/Library/Application Support/FluidAudio",
  ]
end
EOF

cd "$TMP/tap"
if git diff --quiet; then
    echo "==> Cask already points at $VERSION, nothing to do"
    exit 0
fi

git -c user.name="github-actions[bot]" \
    -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit -am "parrotflow $VERSION"
git push
echo "==> $TAP now serves parrotflow $VERSION"
