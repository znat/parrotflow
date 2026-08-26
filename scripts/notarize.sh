#!/usr/bin/env bash
#
# Notarizes a signed .app and staples the ticket to it.
#
#   scripts/notarize.sh .build/ParrotFlow.app
#
# Notarization is what a Homebrew cask needs. A cask sets the quarantine
# attribute on what it installs, and Gatekeeper refuses a quarantined app that
# Apple has not notarized. curl sets no quarantine attribute, which is the only
# reason the curl install worked without this.
#
# Stapling matters as much as notarizing. Without a stapled ticket the first
# launch asks Apple's servers whether the app is notarized, so a user who is
# offline, or behind a network that blocks it, meets a Gatekeeper refusal for
# an app that is perfectly fine.
#
# Credentials, in the order tried:
#
#   1. An App Store Connect API key — NOTARY_KEY_PATH, NOTARY_KEY_ID and
#      NOTARY_ISSUER_ID. This is what CI uses. The key is revocable on its own
#      and carries only the Developer role, unlike an Apple ID password, which
#      is the whole account.
#   2. A keychain profile named by NOTARY_PROFILE (default "parrotflow"),
#      stored once with:
#
#        xcrun notarytool store-credentials parrotflow \
#          --apple-id you@example.com --team-id TEAMID \
#          --password <app-specific-password>
set -euo pipefail

APP="${1:?usage: notarize.sh <path to .app>}"
[ -d "$APP" ] || { echo "error: $APP is not a bundle" >&2; exit 1; }

CREDS=()
if [ -n "${NOTARY_KEY_PATH:-}" ]; then
    : "${NOTARY_KEY_ID:?NOTARY_KEY_PATH is set but NOTARY_KEY_ID is not}"
    : "${NOTARY_ISSUER_ID:?NOTARY_KEY_PATH is set but NOTARY_ISSUER_ID is not}"
    CREDS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
else
    CREDS=(--keychain-profile "${NOTARY_PROFILE:-parrotflow}")
fi

# Submitted as a zip made with ditto. Apple takes a zip, a dmg or a pkg, and
# ditto is the only one of these that preserves the metadata the signature
# covers — a bundle re-archived with `zip` arrives with a broken signature.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ZIP="$TMP/notarize.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Submitting $(basename "$APP") to Apple"
# --wait blocks until Apple answers, usually a couple of minutes. Without it
# the build would race ahead and staple a ticket that does not exist yet.
xcrun notarytool submit "$ZIP" "${CREDS[@]}" --wait

echo "==> Stapling the ticket"
xcrun stapler staple "$APP"

# What the user's Mac will conclude, asked the same way Gatekeeper asks.
echo "==> Verifying"
spctl --assess --type execute -vv "$APP"
