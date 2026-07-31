#!/usr/bin/env bash
#
# Creates the certificate that release builds are signed with, and prints the
# two repository secrets the release workflow needs.
#
# Run this ONCE, ever. The certificate is not a build detail: macOS keys the
# Microphone and Accessibility grants to it, so every release signed with the
# same certificate inherits the permissions the user already gave. Generate a
# new one and every existing user silently loses both — the app stops working
# and System Settings still shows it ticked.
#
# So: keep the .p12 and its password. Losing them means the next release breaks
# for everyone who already installed.
#
# This is a self-signed certificate, not a Developer ID. It makes permissions
# survive updates; it does not satisfy Gatekeeper, which is why ParrotFlow ships
# by curl rather than as a Homebrew cask. See docs/distribution.md.
set -euo pipefail

NAME="${1:-ParrotFlow Release}"
OUT="${PARROTFLOW_CERT_DIR:-$HOME/.parrotflow-release}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if [ -f "$OUT/cert.p12" ]; then
    echo "error: $OUT/cert.p12 already exists." >&2
    echo "       Reusing it is the point — see the note at the top of this file." >&2
    echo "       Delete it deliberately if you really mean to start over." >&2
    exit 1
fi

mkdir -p "$OUT"
chmod 700 "$OUT"

# System LibreSSL, not whatever is first in PATH: OpenSSL 3 writes PKCS#12 with
# a MAC that macOS cannot verify, and reports it as a wrong password.
SSL=/usr/bin/openssl
[ -x "$SSL" ] || SSL=openssl

P12PASS="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"

echo "==> Generating $NAME (valid 10 years)"
"$SSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$OUT/key.pem" -out "$OUT/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

if ! "$SSL" pkcs12 -export -out "$OUT/cert.p12" \
    -inkey "$OUT/key.pem" -in "$OUT/cert.pem" \
    -passout "pass:$P12PASS" 2>/dev/null; then
    "$SSL" pkcs12 -export -legacy -macalg sha1 -out "$OUT/cert.p12" \
        -inkey "$OUT/key.pem" -in "$OUT/cert.pem" \
        -passout "pass:$P12PASS" 2>/dev/null
fi

printf '%s\n' "$P12PASS" > "$OUT/password.txt"
chmod 600 "$OUT"/*

echo "==> Importing into your login keychain, so local release builds work too"
security import "$OUT/cert.p12" -k "$KEYCHAIN" -P "$P12PASS" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$OUT/cert.pem"
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

echo
echo "==> Saved to $OUT — back this up somewhere you will still have in a year."
echo
if command -v gh >/dev/null 2>&1; then
    echo "    Set the repository secrets with:"
    echo
    echo "      base64 -i $OUT/cert.p12 | gh secret set SIGNING_CERT_P12"
    echo "      gh secret set SIGNING_CERT_PASSWORD < $OUT/password.txt"
else
    echo "    Add these as repository secrets (Settings > Secrets and variables > Actions):"
    echo
    echo "      SIGNING_CERT_P12        $(base64 -i "$OUT/cert.p12" | head -c 40)…"
    echo "      SIGNING_CERT_PASSWORD   (the contents of $OUT/password.txt)"
fi
echo
echo "    Until they are set, the workflow still releases — signed ad-hoc, with"
echo "    a warning, and upgrading users will have to re-grant permissions."
