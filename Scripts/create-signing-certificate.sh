#!/bin/bash
# One-time generator for the SpeechCast release signing certificate.
#
# Produces the permanent self-signed identity that signs every public release:
# DMG, app bundle, and nested helpers. There is no Apple Developer ID, no
# notarization, and no CA renewal path — this certificate is the root of trust
# pinned in Config/signing.conf and mirrored into Scripts/install.sh and the
# updater. It is long-lived (20 years) and must be kept, backed up, and never
# regenerated casually: a second certificate would split users between two pins.
#
# Output (in <dir>, default build/signing, created mode 700):
#   SpeechCast.pem       public certificate (commit a copy as Config/SpeechCastSigning.pem)
#   SpeechCast.cer       DER form of the same certificate
#   SpeechCast.p12       certificate + private key, encrypted PKCS#12 (--legacy, macOS-importable)
#   p12-password.txt     the generated password, mode 600
#   generation.log       subject, SHA256 pin, validity — never the password
#
# The script REFUSES to overwrite: it stops if any output file exists, and it
# never edits Config/signing.conf or Config/SpeechCastSigning.pem — pinning a
# new certificate for future releases is a deliberate, reviewed rotation, not a
# side effect of running a generator.
#
# Usage: Scripts/create-signing-certificate.sh [output-dir]
# Requires openssl 3: the PKCS#12 is written with the --legacy profile that
# macOS `security import` accepts, and only OpenSSL 3 emits that profile with a
# MAC the macOS side verifies. (macOS system LibreSSL cannot emit it.)
set -euo pipefail

OUT_DIR="${1:-build/signing}"
SUBJECT="/CN=SpeechCast Release Signing"
DAYS=7300 # 20 years
RSA_BITS=3072
NAME="SpeechCast Release Signing"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    bold=$'\033[1m'; yellow=$'\033[33m'; reset=$'\033[0m'
else
    bold=""; yellow=""; reset=""
fi

fail() { printf '%screate-signing-certificate: %s%s\n' "$bold" "$1" "$reset" >&2; exit 1; }
warn() { printf '%s%s%s\n' "$yellow" "$1" "$reset" >&2; }

command -v openssl >/dev/null 2>&1 || fail "openssl is required."
openssl version 2>/dev/null | grep -q "OpenSSL 3" \
    || fail "openssl 3.x is required (found: $(openssl version 2>/dev/null || echo none)). The --legacy PKCS#12 profile macOS imports needs OpenSSL 3."

# Private outputs from the first byte: the directory and every file under it.
umask 077
mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

for existing in SpeechCast.pem SpeechCast.cer SpeechCast.p12 p12-password.txt; do
    [ -e "$existing" ] || continue
    fail "Refusing to overwrite $OUT_DIR/$existing. A release certificate already exists; generating a second one would split users between two pins. Delete the old files deliberately (key rotation) if that is really intended."
done

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

echo "▸ Generating RSA-${RSA_BITS} code-signing certificate (valid ${DAYS} days)…" >&2
openssl req -x509 -newkey "rsa:${RSA_BITS}" -nodes -days "$DAYS" \
    -keyout "$WORK/key.pem" -out SpeechCast.pem \
    -subj "$SUBJECT" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    2>/dev/null || fail "openssl could not generate the certificate."

openssl x509 -in SpeechCast.pem -inform PEM -outform DER -out SpeechCast.cer \
    || fail "openssl could not convert the certificate to DER."

# Strong random password for the PKCS#12 encryption: 32 hex chars from CSPRNG,
# written mode 600 BEFORE the export, then passed via file: — the password never
# appears on a command line, in a process listing, or in a log.
openssl rand -hex 32 > p12-password.txt
chmod 600 p12-password.txt

# --legacy keeps RC2/SHA1 MAC pbes so `security import` on macOS accepts it.
openssl pkcs12 -export -inkey "$WORK/key.pem" -in SpeechCast.pem \
    -name "$NAME" -out SpeechCast.p12 -passout file:p12-password.txt -legacy \
    2>/dev/null || fail "openssl could not export the PKCS#12 bundle."

chmod 600 SpeechCast.pem SpeechCast.cer SpeechCast.p12 p12-password.txt

PIN="$(openssl dgst -sha256 -r SpeechCast.cer | awk '{print toupper($1)}')"

{
    echo "SpeechCast release signing certificate"
    echo "subject: $SUBJECT"
    echo "RSA bits: $RSA_BITS"
    echo "validity: ${DAYS} days (long-lived; keep and back up — there is no CA renewal path)"
    echo "SHA256 (DER): $PIN"
    echo "PKCS#12: --legacy encryption, password in p12-password.txt (mode 600)"
    echo "generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > generation.log
chmod 600 generation.log

rm -f "$WORK/key.pem"; rmdir "$WORK" 2>/dev/null || true

echo "✓ Certificate generated in $OUT_DIR:" >&2
echo "    SpeechCast.pem / SpeechCast.cer  (public — safe to publish)" >&2
echo "    SpeechCast.p12                   (PRIVATE — never commit, never share)" >&2
echo "    p12-password.txt                 (password, mode 600 — never print)" >&2
echo "" >&2
echo "${bold}SHA256 pin (DER):${reset} $PIN" >&2
echo "" >&2
warn "Next steps (manual, deliberate):"
echo "  1. Publish the public certificate: copy SpeechCast.pem to Config/SpeechCastSigning.pem (chmod 644)." >&2
echo "  2. Pin it: set SPEECHCAST_CERTIFICATE_SHA256=$PIN in Config/signing.conf," >&2
echo "     and update the literal in Scripts/install.sh and the updater (BundleSignature)." >&2
echo "  3. Run Scripts/check-signing-config.sh until everything agrees." >&2
echo "  4. Store the .p12 and password for CI as the SPEECHCAST_SIGNING_P12_BASE64 and" >&2
echo "     SPEECHCAST_SIGNING_P12_PASSWORD secrets. Keep a private backup of both." >&2
echo "  This generator did NOT touch any of those files: a future release must not pick up" >&2
echo "  a different certificate silently." >&2
