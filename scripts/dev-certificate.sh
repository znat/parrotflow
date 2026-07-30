#!/usr/bin/env bash
#
# Creates a self-signed code-signing certificate so macOS stops forgetting
# ParrotFlow's permissions on every rebuild.
#
# TCC pins Accessibility and Microphone grants to the binary's cdhash when the
# signature is ad-hoc, and the cdhash changes with every build. Signing with a
# stable certificate makes the designated requirement key on the certificate
# instead, so grants survive rebuilds.
#
# Run once. macOS will ask for your password when the certificate is added to
# the login keychain.
set -euo pipefail

NAME="${1:-ParrotFlow Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "==> '$NAME' already exists. Build with:"
    echo "    CODESIGN_IDENTITY=\"$NAME\" make install"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Use the system LibreSSL, not whatever is first in PATH. OpenSSL 3 writes
# PKCS#12 with an AES-256/SHA-256 MAC that macOS's Security framework cannot
# verify — the import fails with "MAC verification failed (wrong password?)",
# which is misleading: the password is fine, the MAC algorithm is not.
SSL=/usr/bin/openssl
[ -x "$SSL" ] || SSL=openssl

# A throwaway password rather than an empty one; empty passphrases are another
# reliable way to upset SecKeychainItemImport.
P12PASS="parrotflow-temp"

echo "==> Generating a self-signed code-signing certificate: $NAME"
"$SSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

if ! "$SSL" pkcs12 -export -out "$TMP/cert.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -passout "pass:$P12PASS" 2>/dev/null; then
    # Newer OpenSSL needs -legacy to emit something macOS will accept.
    "$SSL" pkcs12 -export -legacy -macalg sha1 -out "$TMP/cert.p12" \
        -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -passout "pass:$P12PASS" 2>/dev/null
fi

echo "==> Importing into your login keychain"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$P12PASS" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "==> Trusting it for code signing (macOS will ask for your password)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

# Stops codesign prompting for keychain access on every build.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

echo
if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "==> Done. From now on build with:"
    echo "    CODESIGN_IDENTITY=\"$NAME\" make install"
    echo
    echo "    Then grant permissions once — they will survive rebuilds."
else
    echo "==> Certificate created but not yet valid for code signing."
    echo "    Open Keychain Access, find '$NAME', and set Trust >"
    echo "    Code Signing to 'Always Trust'."
fi
