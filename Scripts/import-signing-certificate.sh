#!/bin/bash
# Import the SpeechCast release signing certificate into a dedicated keychain.
#
# Used by CI (from the SPEECHCAST_SIGNING_P12_BASE64 / SPEECHCAST_SIGNING_P12_PASSWORD
# secrets) and by maintainers locally (from build/signing/SpeechCast.p12). The
# import keychain is separate and explicit — the certificate never lands in a
# login or system keychain, and no global trust is granted: self-signed code
# verification does not need trust, only the certificate's presence for signing.
#
# After import the script proves the keychain holds exactly the certificate whose
# SHA256 is pinned in Config/signing.conf, and resolves the signing identity.
#
# Usage (from a .p12 file):
#   Scripts/import-signing-certificate.sh <path.p12> <password-file> <keychain-path>
# Usage (CI, from base64 on stdin):
#   base64… | Scripts/import-signing-certificate.sh - - <keychain-path>
#   (password comes from SPEECHCAST_SIGNING_P12_PASSWORD when <password-file> is -)
#
# Prints nothing secret; exports nothing. On success the caller signs with:
#   codesign --keychain <keychain-path> --sign "SpeechCast Release Signing" …
set -euo pipefail

P12="${1:?usage: import-signing-certificate.sh <path.p12|-> <password-file|-> <keychain-path>}"
PASSWORD_FILE="${2:?usage: import-signing-certificate.sh <path.p12|-> <password-file|-> <keychain-path>}"
KEYCHAIN="${3:?usage: import-signing-certificate.sh <path.p12|-> <password-file|-> <keychain-path>}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONF="$ROOT/Config/signing.conf"
CERT_IDENTITY="SpeechCast Release Signing"

fail() { printf '::error::%s\n' "$1" >&2; printf '✗ %s\n' "$1" >&2; exit 1; }

[ -f "$CONF" ] || fail "Config/signing.conf is missing."
PIN="$(sed -n 's/^SPEECHCAST_CERTIFICATE_SHA256=//p' "$CONF" | tail -n1 | tr -d '[:space:]')"
[ -n "$PIN" ] || fail "SPEECHCAST_CERTIFICATE_SHA256 is missing from Config/signing.conf."
[[ "$PIN" =~ ^[0-9A-F]{64}$ ]] || fail "Malformed pin in Config/signing.conf."

command -v security >/dev/null 2>&1 || fail "security is required (macOS only)."
command -v /usr/bin/openssl >/dev/null 2>&1 || fail "/usr/bin/openssl is required."

# A fresh random keychain password; never the .p12 password, never printed.
KEYCHAIN_PASSWORD="$(/usr/bin/openssl rand -hex 32)"
P12_PATH=""

cleanup() {
    [ -z "$P12_PATH" ] || rm -f "$P12_PATH"
}
trap cleanup EXIT

if [ "$P12" = "-" ]; then
    [ "$PASSWORD_FILE" = "-" ] ||
        fail "With a stdin .p12, pass - as the password file too (secret SPEECHCAST_SIGNING_P12_PASSWORD)."
    [ -n "${SPEECHCAST_SIGNING_P12_PASSWORD:-}" ] ||
        fail "SPEECHCAST_SIGNING_P12_PASSWORD is not set."
    P12="$(mktemp "${TMPDIR:-/tmp}/speechcast-cert.XXXXXX")"
    base64 -D > "$P12" || fail "stdin is not valid base64."
    P12_PATH="$P12"
    P12_PASSWORD="$SPEECHCAST_SIGNING_P12_PASSWORD"
else
    [ -f "$P12" ] || fail "$P12 is not an existing file."
    [ -f "$PASSWORD_FILE" ] || fail "$PASSWORD_FILE is not an existing file."
    P12_PATH=""
    P12_PASSWORD="$(cat "$PASSWORD_FILE")"
fi
[ -n "$P12_PASSWORD" ] || fail "The certificate password is empty."

# The keychain is replaced wholesale: a stale import can never survive a re-import.
if [ -e "$KEYCHAIN" ]; then
    security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || rm -f "$KEYCHAIN"
fi
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" \
    || fail "Cannot create $KEYCHAIN."
security set-keychain-settings -lut 900 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign \
    || fail "Cannot import the certificate into $KEYCHAIN."
# Narrow ACL: codesign (plus the system partition anchors) may use the key. No -A.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" \
    "$KEYCHAIN" >/dev/null 2>&1 || fail "Cannot set the key partition list."

# Prove the imported certificate IS the pinned one — before any signing happens.
CERT_PEM="$(security find-certificate -c "$CERT_IDENTITY" -p "$KEYCHAIN")" \
    || fail "No '$CERT_IDENTITY' certificate in $KEYCHAIN."
IMPORTED_PIN="$(printf '%s' "$CERT_PEM" | /usr/bin/openssl x509 -outform DER 2>/dev/null \
    | shasum -a 256 | awk '{print toupper($1)}')"
[ -n "$IMPORTED_PIN" ] || fail "The imported certificate cannot be parsed."
[ "$IMPORTED_PIN" = "$PIN" ] || \
    fail "Imported certificate hashes to $IMPORTED_PIN, but Config/signing.conf pins $PIN. Refusing to sign with the wrong identity."

# Resolve the identity. NOTE: no -v — a self-signed certificate is never in any
# trust store, so `find-identity -v` reports 0 valid identities by design.
IDENTITIES="$(security find-identity -p codesigning "$KEYCHAIN" \
    | sed -nE 's/^[[:space:]]*[0-9]+\) [0-9A-F]+ "(.*)"([[:space:]].*)?$/\1/p' \
    | grep -xF "$CERT_IDENTITY" || true)"
[ -n "$IDENTITIES" ] || fail "Cannot resolve the '$CERT_IDENTITY' codesigning identity in $KEYCHAIN."

echo "✓ Imported the pinned SpeechCast release certificate into $KEYCHAIN"
echo "  Sign with: codesign --keychain $KEYCHAIN --sign \"$CERT_IDENTITY\" …"
echo "  Cleanup when done: security delete-keychain $KEYCHAIN"
