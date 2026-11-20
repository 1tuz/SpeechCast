#!/bin/bash
# Sign a built (unsigned) SpeechCast.app with the pinned release certificate.
#
# Why this exists: Xcode's codesign invocation resolves the signing identity
# through the user's keychain search list, which must never be modified on a
# shared machine (and the certificate lives only in an explicit ephemeral
# keychain). Direct `codesign --keychain <path> --sign "SpeechCast Release
# Signing"` works fine, so the release build is produced with
# CODE_SIGNING_ALLOWED=NO and this script signs the result explicitly.
#
# Order matters: nested code is signed deepest-first, the main executable
# bundle last, so each seal covers what is already inside it.
#
# Entitlements: only the app bundle carries Tinycast/Tinycast.entitlements —
# the same file Xcode uses, so a release never drifts from the entitlement
# contract. Helpers and any other nested code are signed with no entitlements.
#
# Usage: sign-release-app.sh <path-to-SpeechCast.app> <keychain-path>
set -euo pipefail

APP="${1:?usage: sign-release-app.sh <SpeechCast.app> <keychain>}"
KEYCHAIN="${2:?usage: sign-release-app.sh <SpeechCast.app> <keychain>}"
IDENTITY="SpeechCast Release Signing"
BUNDLE_ID="com.tinycast.app"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS="$ROOT/Tinycast/Tinycast.entitlements"

fail() { printf '::error::%s\n' "$1" >&2; printf '✗ %s\n' "$1" >&2; exit 1; }

[ -d "$APP" ] || fail "$APP is not an .app bundle."
[ -e "$KEYCHAIN" ] || fail "Keychain $KEYCHAIN does not exist — import the certificate first."
[ -f "$ENTITLEMENTS" ] || fail "Missing $ENTITLEMENTS."

# The identity must be resolvable in the keychain. No -v: a self-signed
# certificate is never in a trust store, so `find-identity -v` reports zero
# valid identities by design, not because the import failed. The trailing
# "(CSSMERR_TP_NOT_TRUSTED)" status is expected for a self-signed identity.
security find-identity -p codesigning "$KEYCHAIN" \
    | sed -nE 's/^[[:space:]]*[0-9]+\) [0-9A-F]+ "(.*)"([[:space:]].*)?$/\1/p' \
    | grep -xF "$IDENTITY" >/dev/null \
    || fail "Cannot resolve the '$IDENTITY' codesigning identity in $KEYCHAIN."

CODESIGN_ARGS=(--force --keychain "$KEYCHAIN" --sign "$IDENTITY"
    --options runtime --timestamp=none)

# --- Nested code, deepest first -------------------------------------------------
# Every Mach-O under Contents except the bundle's own main executable. Sort by
# path depth (component count) descending so the innermost seal is written
# before whatever contains it. For a Mach-O inside a nested bundle directory
# (.framework/.xpc/.bundle), the bundle root is the codesign unit, not the file.
nested_target() {
    local f="$1"
    case "$f" in
        # A Mach-O inside a nested framework/xpc/bundle is signed through the
        # bundle root. NOTE: no *.app case — the helpers under OUR app's
        # Contents/Helpers are plain Mach-O files and must be signed as
        # themselves, not collapsed into the app root.
        *.framework/Contents/*|*.xpc/Contents/*|*.bundle/Contents/*)
            printf '%s' "${f%%/Contents/*}" ;;
        *) printf '%s' "$f" ;;
    esac
}

# Collect nested targets into an array (a pipeline runs in a subshell, where a
# failure could not stop the script). Deepest path first so an inner seal is
# always written before whatever contains it; duplicates (several files inside
# one nested bundle root) collapse to the root.
NESTED_TARGETS=()
while IFS= read -r -d '' f; do
    file -b "$f" | grep -q "Mach-O" || continue
    t="$(nested_target "$f")"
    NESTED_TARGETS+=("$(awk -F/ '{print NF}' <<<"$t")"$'\t'"$t")
done < <(find "$APP/Contents" -type f ! -path "$APP/Contents/MacOS/*" -print0)

if [ "${#NESTED_TARGETS[@]}" -gt 0 ]; then
    while IFS= read -r target; do
        [ -n "$target" ] || continue
        # Unique identifier so two helpers can never collide.
        IDENT="$BUNDLE_ID$(printf '%s' "${target#"$APP/Contents/"}" | tr '/' '-')"
        codesign "${CODESIGN_ARGS[@]}" --identifier "$IDENT" "$target" \
            || fail "codesign failed for $target"
        codesign --verify --strict "$target" >/dev/null 2>&1 \
            || fail "$target does not verify after signing"
    done < <(printf '%s\n' "${NESTED_TARGETS[@]}" | sort -rn -t$'\t' -k1,1 | cut -f2- | awk '!seen[$0]++')
fi

# --- The app bundle last, with the entitlements ---------------------------------
codesign "${CODESIGN_ARGS[@]}" --identifier "$BUNDLE_ID" \
    --entitlements "$ENTITLEMENTS" "$APP" \
    || fail "codesign failed for the app bundle."

# Full gate immediately: pinned leaf, nested code, runtime flag.
"$ROOT/Scripts/verify-release.sh" app "$APP"

echo "✓ Signed $APP with the pinned release certificate (nested code first, entitlements on the app)"
