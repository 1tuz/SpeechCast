#!/bin/bash
# Package the release .app into the signed DMG and ZIP that ship on GitHub.
#
# This is the CI path for a REAL release: the app must already be built and
# signed with the pinned SpeechCast release certificate. The DMG itself is
# signed with the same certificate — that signature is what the installer
# (and the updater) verify before mounting, so its authenticity is
# cryptographic, not advisory.
#
# Usage: Scripts/package-release.sh <path-to-SpeechCast.app> <version> <dist-dir> <keychain>
# Output: <dist-dir>/SpeechCast-<version>.dmg      (signed)
#         <dist-dir>/SpeechCast-<version>.zip      (ditto zip of the signed app)
#         <dist-dir>/SpeechCast-<version>.sha256sums
set -euo pipefail

APP="${1:?usage: package-release.sh <SpeechCast.app> <version> <dist-dir> <keychain>}"
VERSION="${2:?usage: package-release.sh <SpeechCast.app> <version> <dist-dir> <keychain>}"
DIST="${3:?usage: package-release.sh <SpeechCast.app> <version> <dist-dir> <keychain>}"
KEYCHAIN="${4:?usage: package-release.sh <SpeechCast.app> <version> <dist-dir> <keychain>}"

IDENTITY="SpeechCast Release Signing"

fail() { printf '::error::%s\n' "$1" >&2; printf '✗ %s\n' "$1" >&2; exit 1; }

[ -d "$APP" ] || fail "$APP is not an .app bundle."
[ -e "$KEYCHAIN" ] || fail "Keychain $KEYCHAIN does not exist — import the certificate first."
[ -d "$DIST" ] || mkdir -p "$DIST" || fail "Cannot create $DIST."
DMG="$DIST/SpeechCast-${VERSION}.dmg"
ZIP="$DIST/SpeechCast-${VERSION}.zip"
SUMS="$DIST/SpeechCast-${VERSION}.sha256sums"

[ -f "$DMG" ] && fail "$DMG already exists — refusing to mix outputs."
[ -f "$ZIP" ] && fail "$ZIP already exists — refusing to mix outputs."

STAGE="$(mktemp -d)"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

# Copy, do not move: the build's signed bundle stays untouched for the zip.
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
diskutil image create from "$STAGE" --format UDZO --volumeName "SpeechCast" "$DMG" \
    >/dev/null || fail "diskutil could not create the image."

# Sign the image with the pinned certificate: runtime flags do not apply to a
# disk image, and a self-signed identity has no timestamp authority.
codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" --timestamp=none "$DMG" \
    || fail "codesign could not sign the DMG."
codesign --verify --strict "$DMG" || fail "The signed DMG does not verify."

# `ditto -c -k --keepParent --sequesterRsrc` is the only zip that leaves the code
# signature verifiable; plain `zip` drops symlinks and breaks the seal.
ditto -c -k --keepParent --sequesterRsrc "$APP" "$ZIP" \
    || fail "ditto could not create the zip."

# Checksums: supplemental corruption detection. Authenticity is the signature.
{
    shasum -a 256 "$DMG"
    shasum -a 256 "$ZIP"
} | sed "s|$DIST/||" > "$SUMS"

# Contractual self-check before anything leaves this script: the outputs must
# pass the full release gate (pinned certificate on the image and the app
# inside it, version, nested code included).
"$(cd "$(dirname "$0")" && pwd)/verify-release.sh" dmg "$DMG" --version "$VERSION"

echo "✓ $DMG (signed with the pinned release certificate)"
echo "✓ $ZIP"
echo "✓ $SUMS"
