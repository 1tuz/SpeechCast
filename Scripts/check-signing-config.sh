#!/bin/bash
# Guard: the release pin is stated in exactly one authoritative place (Config/signing.conf)
# and every other copy must agree, and the committed certificate must hash to the pin.
#
# Cross-checks:
#   1. Config/SpeechCastSigning.pem  -- its DER bytes must hash to the pin in the conf.
#   2. Scripts/install.sh            -- must embed the same literal pin (standalone curl).
#   3. Tinycast/Features/Updates/Service/BundleSignature.swift -- the updater's pin.
#   4. Config/SpeechCastSigning.pem leaf and pin formats (uppercase hex, 64 chars).
#
# Exit 0 = consistent; any drift fails with ::error for CI.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONF="$ROOT/Config/signing.conf"
PEM="$ROOT/Config/SpeechCastSigning.pem"
STATUS=0

fail() {
    echo "::error::$1" >&2
    echo "✗ $1" >&2
    STATUS=1
}

note() { echo "✓ $1"; }

# ---- 1. Parse the authoritative pin ---------------------------------------------
if [ ! -f "$CONF" ]; then
    fail "Config/signing.conf is missing — the release pin has no home."
    exit 1
fi
PIN="$(sed -n 's/^SPEECHCAST_CERTIFICATE_SHA256=//p' "$CONF" | tail -n1 | tr -d '[:space:]')"
BUNDLE_ID="$(sed -n 's/^SPEECHCAST_BUNDLE_ID=//p' "$CONF" | tail -n1 | tr -d '[:space:]')"
[ -n "$PIN" ] || fail "SPEECHCAST_CERTIFICATE_SHA256 is missing from Config/signing.conf."
[ -n "$BUNDLE_ID" ] || fail "SPEECHCAST_BUNDLE_ID is missing from Config/signing.conf."

[[ "$PIN" =~ ^[0-9A-F]{64}$ ]] ||
    fail "The pin must be 64 uppercase hex characters (DER SHA256), got: '${PIN:-<empty>}'"

# ---- 2. The committed certificate must hash to the pin ---------------------------
if [ ! -f "$PEM" ]; then
    fail "Config/SpeechCastSigning.pem is missing — the public certificate must be committed."
else
    CERT_PIN="$(openssl x509 -in "$PEM" -outform DER 2>/dev/null | shasum -a 256 | awk '{print toupper($1)}')"
    [ -n "$CERT_PIN" ] || fail "Config/SpeechCastSigning.pem is not a parsable certificate."
    [ "$CERT_PIN" = "$PIN" ] ||
        fail "Config/SpeechCastSigning.pem hashes to $CERT_PIN, but signing.conf pins $PIN."
    note "certificate PEM matches the pin"
fi

# ---- 3. Installer literal pin ----------------------------------------------------
INSTALLER="$ROOT/Scripts/install.sh"
if [ ! -f "$INSTALLER" ]; then
    fail "Scripts/install.sh is missing."
else
    grep -qF "\"$PIN\"" "$INSTALLER" ||
        fail "Scripts/install.sh does not embed the pin $PIN (standalone curl needs the literal)."
    note "installer pin matches"
fi

# ---- 4. Updater pin (Swift) ------------------------------------------------------
SWIFT="$ROOT/Tinycast/Features/Updates/Service/BundleSignature.swift"
if [ ! -f "$SWIFT" ]; then
    fail "Tinycast/Features/Updates/Service/BundleSignature.swift is missing."
else
    grep -qE "pinnedCertificateSHA256[[:space:]]*=[[:space:]]*\"$PIN\"" "$SWIFT" ||
        fail "BundleSignature.swift does not pin $PIN (the updater would reject releases)."
    grep -qE "expectedBundleIdentifier[[:space:]]*=[[:space:]]*\"$BUNDLE_ID\"" "$SWIFT" ||
        fail "BundleSignature.swift does not pin bundle id $BUNDLE_ID."
    note "updater pin matches"
fi

if [ "$STATUS" -eq 0 ]; then
    echo "✓ signing pin is consistent everywhere (Config, installer, updater)"
fi
exit "$STATUS"
