#!/bin/bash
# One-time setup: create a self-signed code-signing certificate ("Spartan Dev")
# in the login keychain so the app's code signature — and therefore its Screen
# Recording permission — stays stable across rebuilds.
# May show one or two macOS authorization prompts.
set -euo pipefail

CERT_NAME="Spartan Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "'$CERT_NAME' already exists — nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
  -subj "/CN=$CERT_NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false"

openssl pkcs12 -export -legacy \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/spartan.p12" -passout pass:spartan \
  -name "$CERT_NAME" 2>/dev/null || \
openssl pkcs12 -export \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/spartan.p12" -passout pass:spartan \
  -name "$CERT_NAME"

security import "$TMP/spartan.p12" -k "$KEYCHAIN" -P spartan \
  -T /usr/bin/codesign -T /usr/bin/security

# Trust the cert for code signing (user trust domain; may prompt for password).
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" || {
  echo "note: could not add trust settings automatically." >&2
  echo "      If codesign complains, open Keychain Access, find '$CERT_NAME'," >&2
  echo "      and set Trust > Code Signing to 'Always Trust'." >&2
}

echo "created '$CERT_NAME'. Verify with: security find-identity -v -p codesigning"
