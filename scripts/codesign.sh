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

    # The App Store wants its own certificates, and neither is a Developer ID.
    # The self-signed ones stay at the end so a local sandbox build works on a
    # machine that has never enrolled a store certificate — that build cannot
    # be submitted, only run and measured.
    if [ "${VARIANT:-dev}" = "appstore" ]; then
        candidates=("3rd Party Mac Developer Application" "Apple Distribution" \
                    "ParrotFlow Dev" "ParrotFlow Release")
    elif [ "${VARIANT:-dev}" = "release" ]; then
        candidates=("Developer ID Application" "ParrotFlow Release" "ParrotFlow Dev")
    else
        candidates=("ParrotFlow Dev" "ParrotFlow Release")
    fi

    # The full common name, not the substring that matched it. codesign takes a
    # substring, but it refuses one that matches two identities — and two is
    # exactly what a keychain holds for a while after a certificate is renewed.
    # Prefer the one carrying our Team ID, so a machine that also signs for
    # another team cannot pick the wrong certificate.
    local candidate match team
    team="$(pf_team_id)"
    for candidate in "${candidates[@]}"; do
        match="$(printf '%s\n' "$available" | grep -F "$candidate" | grep -F "($team)" | head -1)"
        [ -n "$match" ] || match="$(printf '%s\n' "$available" | grep -F "$candidate" | head -1)"
        if [ -n "$match" ]; then
            printf '%s\n' "$match" | sed -n 's/.*"\(.*\)".*/\1/p'
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
#
# PF_SANDBOX=1 signs with Resources/entitlements-sandbox.plist instead, on
# either identity. That is the App Store probe and not a way to ship: see
# docs/proposals/app-store.md. It applies to the self-signed path too, which
# otherwise passes no entitlements at all — a sandbox test that silently did
# not turn the sandbox on would answer the question wrongly and look like it
# had answered it.
pf_sign() {
    local app="$1" identity="$2" root entitlements
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    # An interrupted codesign leaves a .cstemp behind, and the next run fails on
    # it with "invalid or unsupported format for signature" — which names the
    # temp file, not the cause, and sends you looking at the wrong thing.
    find "$app" -name '*.cstemp' -delete 2>/dev/null || true

    if [ "${PF_SANDBOX:-}" = "1" ]; then
        entitlements="$root/Resources/entitlements-sandbox.plist"
        echo "==> Signing SANDBOXED (App Store probe) — not a shippable build"
        codesign --force --options runtime --entitlements "$entitlements" \
            --sign "$identity" "$app"
        return
    fi

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
