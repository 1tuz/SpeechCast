#!/bin/bash
# Release verification for a SpeechCast .app or released .dmg signed with the
# permanent self-signed release certificate pinned in Config/signing.conf.
#
# Every check is a hard failure: this is the release gate, run on macOS CI and
# usable locally. It replaces the old Developer ID/notarization gate: there is
# no Apple team, no notarization ticket, no stapler, no spctl acceptance —
# authenticity is the pinned certificate leaf, proven with codesign.
#
# Usage:
#   verify-release.sh app <path.app> [--version VERSION]
#   verify-release.sh dmg <path.dmg> [--version VERSION]
set -euo pipefail

MODE="${1:-}"
BUNDLE_ID="com.tinycast.app"
PIN="A0AA9BCD7AFBC13A3CF4B16CAC7B84A0632816143F9C9D217DF9757B8400FD62"
VERSION=""

usage() {
    echo "usage: $0 app <path.app> [--version VERSION]" >&2
    echo "       $0 dmg <path.dmg> [--version VERSION]" >&2
    exit 2
}

fail() {
    echo "::error::$1" >&2
    echo "✗ $1" >&2
    exit 1
}

[ "$#" -ge 2 ] || usage
case "$MODE" in
    app | dmg) ;;
    *) usage ;;
esac
TARGET="$2"
shift 2

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
        *) usage ;;
    esac
done

# The gate requires Apple CLIs that only exist on macOS. A missing tool is a
# failure, never a skip. No xcrun/python/node/jq anywhere: plain macOS CLIs.
require_tool() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 is required but not found"
}
require_tool codesign
require_tool hdiutil
require_tool file
require_tool /usr/bin/openssl
require_tool shasum

MOUNTPOINT=""
DEVICE=""
cleanup() {
    if [ -n "$DEVICE" ]; then hdiutil detach "$DEVICE" -quiet >/dev/null 2>&1 || true; fi
    [ -z "$MOUNTPOINT" ] || rm -rf "$MOUNTPOINT" 2>/dev/null || true
    [ -z "$EXTRACT_DIR" ] || rm -rf "$EXTRACT_DIR" 2>/dev/null || true
}
trap cleanup EXIT

verify_pinned_leaf() {
    # $1: target (app bundle, Mach-O binary, or dmg file); $2: label for errors.
    # codesign writes extracted certs as <prefix><N>, so the leaf is ${prefix}0.
    # An ad-hoc signature has no certificates at all.
    local target="$1" label="$2" prefix leaf_sha
    codesign --verify --strict "$target" >/dev/null 2>&1 ||
        fail "$label: code signature is invalid (corrupted or modified)"
    EXTRACT_DIR="$(mktemp -d)"
    prefix="$EXTRACT_DIR/leaf"
    codesign -d --extract-certificates="$prefix" --verbose=4 "$target" >/dev/null 2>&1 ||
        fail "$label: cannot inspect the signature"
    [ -f "${prefix}0" ] ||
        fail "$label: signed without a certificate (ad-hoc or unsigned)"
    leaf_sha="$(/usr/bin/openssl dgst -sha256 -r "${prefix}0" 2>/dev/null | awk '{print toupper($1)}')"
    [ "$leaf_sha" = "$PIN" ] ||
        fail "$label: signing certificate is not the pinned SpeechCast release certificate ($leaf_sha)"
    rm -rf "$EXTRACT_DIR"; EXTRACT_DIR=""
}

# Enumerate every Mach-O under Contents: main executable, Helpers, Frameworks,
# PlugIns, XPCServices, and anything else that ships code.
machos_in_app() {
    local app="$1" f
    while IFS= read -r -d '' f; do
        if file -b "$f" | grep -q "Mach-O"; then
            echo "$f"
        fi
    done < <(find "$app/Contents" -type f -print0)
    true
}

# Check a single Mach-O: deep-strict signature, pinned leaf certificate, hardened
# runtime, and no get-task-allow entitlement. Self-signed releases carry no Team
# identifier and no secure timestamp (there is no authority to timestamp them).
verify_macho() {
    local app="$1" bin="$2"
    local rel="${bin#"$app"/}"
    local info

    codesign --verify --strict "$bin" >/dev/null 2>&1 ||
        fail "$rel: signature does not verify"

    # The runtime flag appears inside the CodeDirectory line, e.g.
    # "CodeDirectory v=20500 ... flags=0x10000(runtime) ...", never on its own.
    info="$(codesign -dv --verbose=4 "$bin" 2>&1)" || fail "$rel: cannot inspect the signature"
    printf '%s\n' "$info" | grep -q "flags=0x[0-9a-fA-F]*([^)]*runtime" ||
        fail "$rel: hardened runtime is not enabled"

    verify_pinned_leaf "$bin" "$rel"

    if codesign -d --entitlements - --xml "$bin" 2>/dev/null | grep -q get-task-allow; then
        fail "$rel: get-task-allow is present"
    fi
}

verify_app() {
    local app="$1"
    local name
    name="$(basename "$app" .app)"

    [ -d "$app" ] || fail "$app is not an .app bundle"
    [ -d "$app/Contents" ] || fail "$name.app has no Contents directory"

    local main_exe="$app/Contents/MacOS/SpeechCast"
    [ -f "$main_exe" ] || fail "$name.app: missing Contents/MacOS/SpeechCast"
    [ -x "$main_exe" ] || fail "$name.app: Contents/MacOS/SpeechCast is not executable"

    # Nested code (helpers) must be sealed and signed by the pinned certificate.
    codesign --verify --deep --strict --verbose=2 "$app" >/dev/null 2>&1 ||
        fail "$name.app: codesign --verify --deep --strict failed"

    local info
    info="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
        "$app/Contents/Info.plist" 2>/dev/null || true)"
    [ "$info" = "$BUNDLE_ID" ] ||
        fail "$name.app: CFBundleIdentifier is '$info', expected '$BUNDLE_ID'"

    if [ -n "$VERSION" ]; then
        local ver
        ver="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
            "$app/Contents/Info.plist" 2>/dev/null || true)"
        [ "$ver" = "$VERSION" ] ||
            fail "$name.app: CFBundleShortVersionString is '$ver', expected '$VERSION'"
    fi

    # The app bundle's own seal must carry the pinned leaf (the main executable's
    # certificate is checked per-Mach-O below).
    verify_pinned_leaf "$app" "$name.app"

    local bins
    bins="$(machos_in_app "$app")"
    [ -n "$bins" ] || fail "$name.app: no Mach-O binaries found under Contents"

    local bin
    while IFS= read -r bin; do
        verify_macho "$app" "$bin"
    done <<< "$bins"

    echo "✓ $name.app passed release verification (pinned certificate, ${BUNDLE_ID})"
}

verify_dmg() {
    local dmg="$1"
    local base
    base="$(basename "$dmg" .dmg)"

    [ -f "$dmg" ] || fail "$dmg does not exist"

    # The image itself must be signed by the pinned certificate BEFORE it is
    # mounted anywhere: that is the download-authenticity check.
    verify_pinned_leaf "$dmg" "$base.dmg"

    MOUNTPOINT="$(mktemp -d)"
    rmdir "$MOUNTPOINT"
    local attach_log
    attach_log="$(hdiutil attach "$dmg" -mountpoint "$MOUNTPOINT" -readonly -nobrowse 2>&1)" ||
        fail "$base.dmg: could not mount image: $attach_log"
    DEVICE="$(printf '%s\n' "$attach_log" | awk '/^\/dev\/disk/ { print $1; exit }')"
    [ -n "$DEVICE" ] || fail "$base.dmg: could not identify the mounted device"

    local app
    app="$(find "$MOUNTPOINT" -maxdepth 2 -name "*.app" -type d -print -quit 2>/dev/null || true)"
    [ -n "$app" ] || fail "$base.dmg: no .app bundle found in the image"

    verify_app "$app"

    hdiutil detach "$DEVICE" -quiet || fail "$base.dmg: failed to detach $DEVICE"
    DEVICE=""
    rm -rf "$MOUNTPOINT"
    MOUNTPOINT=""

    echo "✓ $base.dmg passed release verification (pinned certificate, ${BUNDLE_ID})"
}

case "$MODE" in
    app)
        [ "${TARGET%.app}" != "$TARGET" ] || fail "app mode requires a .app path"
        verify_app "$TARGET"
        ;;
    dmg)
        [ "${TARGET%.dmg}" != "$TARGET" ] || fail "dmg mode requires a .dmg path"
        verify_dmg "$TARGET"
        ;;
esac
