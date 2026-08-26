# How a bundle gets signed. Sourced, not executed.
#
# One copy because there are two callers. build-app.sh signs the bundle it
# assembles, and release.sh has to sign it again after stamping the version
# into Info.plist — editing the plist invalidates the signature. A bare
# `codesign --sign` in the second place would quietly drop the hardened runtime
# and the entitlements the first one set, and the app would ship unnotarizable
# or without a microphone.

# Picks the identity to sign with, unless the caller named one.
#
# Release prefers the Developer ID, because that is what Gatekeeper and
# notarization need. The self-signed certificates come next: they do nothing
# for Gatekeeper, but they keep Microphone and Accessibility across a rebuild,
# which is what makes a local install usable. Ad-hoc ("-") is the floor.
#
# The identity has to match the variant. TCC keys a grant to the certificate,
# not only the bundle id, so signing com.parrotflow.app with the Dev
# certificate makes a local copy a different identity than the distributed one
# and their grants stop lining up.
pf_signing_identity() {
    if [ -n "${CODESIGN_IDENTITY:-}" ]; then
        printf '%s\n' "$CODESIGN_IDENTITY"
        return
    fi

    local available candidates
    available="$(security find-identity -v -p codesigning 2>/dev/null || true)"

    if [ "${VARIANT:-dev}" = "release" ]; then
        candidates=("Developer ID Application" "ParrotFlow Release" "ParrotFlow Dev")
    else
        candidates=("ParrotFlow Dev" "ParrotFlow Release")
    fi

    local candidate
    for candidate in "${candidates[@]}"; do
        if printf '%s' "$available" | grep -qF "$candidate"; then
            printf '%s\n' "$candidate"
            return
        fi
    done

    printf '%s\n' "-"
}

pf_is_developer_id() {
    case "$1" in
        "Developer ID Application"*) return 0 ;;
        *) return 1 ;;
    esac
}

# Signs the bundle. With a Developer ID it adds what notarization requires:
# the hardened runtime, the microphone entitlement it would otherwise block,
# and a secure timestamp. Notarization refuses a submission missing any of
# them, and it refuses it after the upload, minutes later.
pf_sign() {
    local app="$1" identity="$2" root
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    # An interrupted codesign leaves a .cstemp behind, and the next run fails on
    # it with "invalid or unsupported format for signature" — which names the
    # temp file, not the cause, and sends you looking at the wrong thing.
    find "$app" -name '*.cstemp' -delete 2>/dev/null || true

    if pf_is_developer_id "$identity"; then
        codesign --force --options runtime --timestamp \
            --entitlements "$root/Resources/entitlements.plist" \
            --sign "$identity" "$app"
    else
        codesign --force --sign "$identity" "$app"
    fi
}

# The Team ID that release builds are signed under, read from install.sh so
# there is one declaration and not a third copy. check-pinned-certificate.sh is
# what keeps install.sh and Updates.swift saying the same thing.
pf_team_id() {
    local root
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    sed -n 's/^TEAM_ID="\([A-Z0-9]*\)"$/\1/p' "$root/scripts/install.sh" | head -1
}

# The designated requirement both install paths check a download against.
#
# `anchor apple generic` says the chain ends at Apple's root, which no
# self-signed certificate can claim. The OU of a Developer ID leaf is the Team
# ID. Together they say "Apple issued this to us" — and unlike a pinned leaf
# hash, they keep saying it after the certificate is renewed.
pf_requirement() {
    printf 'anchor apple generic and certificate leaf[subject.OU] = "%s"' "$1"
}
