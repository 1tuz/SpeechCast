#!/bin/bash
# SpeechCast: install or upgrade SpeechCast from a GitHub Release (or a local DMG).
#
# Trust model: every release — DMG and the .app inside it, nested helpers included —
# is signed with one permanent self-signed certificate. Its SHA256 is pinned below,
# so a curl one-liner is standalone: no Apple Developer ID, no notarization, no
# online trust service, no minisign-style second key. The signature is verified
# BEFORE the image is mounted; a corrupted or re-signed image is rejected.
# SHA256SUMS (published alongside the DMG) is a supplemental corruption check only.
#
# Local use:    SPEECHCAST_DMG=path/to/SpeechCast-0.12.0.dmg ./Scripts/install.sh
#               SPEECHCAST_INSTALL_DIR=$HOME/Applications overrides the destination.
#               SPEECHCAST_DMG_URL installs from a direct release URL.
#               SPEECHCAST_RELEASE_TAG=v0.12.0 pins a specific release.
#               (VOICECAST_DMG / VOICECAST_INSTALL_DIR still work, for old callers.)
# Environment never overrides the pin or any verification.
set -euo pipefail

repo="1tuz/SpeechCast"
expected_bundle="com.tinycast.app" # Preserved for existing Tinycast users.

# The release certificate pin — the SHA256 of the certificate's DER encoding.
# Authoritative copy: Config/signing.conf, checked against this literal by
# Scripts/check-signing-config.sh in CI. Do not edit one without the other.
pinned_cert_sha256="A0AA9BCD7AFBC13A3CF4B16CAC7B84A0632816143F9C9D217DF9757B8400FD62"

steps=4
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    bold=$'\033[1m'; dim=$'\033[2m'; green=$'\033[32m'; reset=$'\033[0m'
else
    bold=""; dim=""; green=""; reset=""
fi

fail() {
    printf '\n%sSpeechCast: %s%s\n' "$bold" "$1" "$reset" >&2
    exit 1
}
step() { printf '%s[%s/%s]%s %s\n' "$green" "$1" "$steps" "$reset" "$2"; }

printf '\n%s' "$bold"
printf '  ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\n'
printf '  ┃                SpeechCast                     ┃\n'
printf '  ┃      Search · Speak · Act · Automate        ┃\n'
printf '  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\n'
printf '%s%s\n\n' "$reset" "$dim"

[ "$(uname -s)" = Darwin ] || fail "macOS is required."
command -v curl >/dev/null || fail "curl is required."
command -v codesign >/dev/null || fail "codesign is required."
command -v hdiutil >/dev/null || fail "hdiutil is required."
command -v /usr/bin/openssl >/dev/null || fail "/usr/bin/openssl is required."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 26 ] || fail "macOS 26 or newer is required."

if [ -n "${SPEECHCAST_DMG:-}" ] && [ -n "${VOICECAST_DMG:-}" ]; then
    fail "Set SPEECHCAST_DMG or VOICECAST_DMG, not both."
fi
if [ -n "${SPEECHCAST_INSTALL_DIR:-}" ] && [ -n "${VOICECAST_INSTALL_DIR:-}" ]; then
    fail "Set SPEECHCAST_INSTALL_DIR or VOICECAST_INSTALL_DIR, not both."
fi
if [ -n "${SPEECHCAST_DMG_URL:-}" ] && [ -n "${SPEECHCAST_RELEASE_TAG:-}" ]; then
    fail "Set SPEECHCAST_DMG_URL or SPEECHCAST_RELEASE_TAG, not both."
fi

workdir="$(mktemp -d "${TMPDIR:-/tmp}/speechcast-install.XXXXXX")"
mount="$workdir/mount"
mounted=false
staged=""
backup=""
replaced=""
destination=""
placed_new=false
installed_new=false

# ---------------------------------------------------------------------------
# Transaction rollback: one handler for signals, errors, and normal exit.
# ---------------------------------------------------------------------------
rollback_transaction() {
    # Rollback only runs before the install commits (installed_new=false).
    # The new copy is removed FIRST, then the user's previous app is restored —
    # unconditionally while a backup exists, so a failed transaction can never
    # leave both a half-written new app and no old one. If restoring the backup
    # itself fails, the backup directory is KEPT: destroying the only copy of
    # the user's app is never an option. The backup is only ever deleted by the
    # success path at the very end of a fully committed install.
    if [ "$installed_new" = false ]; then
        if [ -n "$staged" ] && [ -e "$staged" ]; then
            rm -rf "$staged" 2>/dev/null || true
            staged=""
        fi
        if [ "$placed_new" = true ] && [ -e "$destination" ]; then
            rm -rf "$destination" 2>/dev/null || true
        fi
        if [ -n "$replaced" ] && [ -e "$backup" ] && [ ! -e "$replaced" ]; then
            if mv "$backup" "$replaced" 2>/dev/null; then
                echo "SpeechCast: previous app restored to $replaced" >&2
            else
                echo "SpeechCast: could not restore $replaced — your previous app is preserved at $backup" >&2
            fi
        fi
    fi
}

cleanup() {
    # Resolve first: under TMPDIR the mount table shows /private/var/... while $mount is
    # /var/..., so a path comparison against `mount` never matched and the image stayed
    # attached. Detach by the resolved path, then remove the tree.
    if [ "$mounted" = true ]; then
        resolved="$(cd "$mount" 2>/dev/null && pwd -P)" || resolved="$mount"
        hdiutil detach "$resolved" -force >/dev/null 2>&1 ||
            hdiutil detach "$mount" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$workdir" 2>/dev/null || true
}
on_exit() {
    code=$?
    # After a successful install nothing is left to roll back; staged/backup are
    # cleared as each phase completes, so this is exactly the failure path.
    rollback_transaction
    cleanup
    exit "$code"
}
trap on_exit EXIT
trap 'fail "Interrupted — the previous app was left untouched."' INT TERM

# ---------------------------------------------------------------------------
# Step 1/4: obtain the disk image (local file, direct URL, or GitHub release)
# ---------------------------------------------------------------------------
local_dmg="${SPEECHCAST_DMG:-${VOICECAST_DMG:-}}"
dmg=""
if [ -n "$local_dmg" ]; then
    [ -f "$local_dmg" ] || fail "SPEECHCAST_DMG/VOICECAST_DMG is not an existing file: $local_dmg."
    step 1 'Using local disk image'
    printf '  Local disk image: %s\n' "$local_dmg"
    dmg="$local_dmg"
elif [ -n "${SPEECHCAST_DMG_URL:-}" ]; then
    step 1 'Downloading disk image'
    case "$SPEECHCAST_DMG_URL" in
        "https://github.com/$repo/releases/download/"*) ;;
        *) fail "SPEECHCAST_DMG_URL must point at a $repo release download URL." ;;
    esac
    printf '  %s\n' "$SPEECHCAST_DMG_URL"
    dmg="$workdir/SpeechCast.dmg"
    curl --retry 3 -fL --connect-timeout 20 "$SPEECHCAST_DMG_URL" -o "$dmg" \
        || fail "Download failed."
else
    step 1 'Finding the release to install'
    if [ -n "${SPEECHCAST_RELEASE_TAG:-}" ]; then
        case "$SPEECHCAST_RELEASE_TAG" in
            v[0-9]*.[0-9]*.[0-9]*-beta[.0-9]*) ;;
            v[0-9]*.[0-9]*.[0-9]*) ;;
            *) fail "SPEECHCAST_RELEASE_TAG must look like v0.12.0 or v0.12.0-beta.1." ;;
        esac
        metadata="$(curl --retry 3 -fsSL --connect-timeout 15 \
            "https://api.github.com/repos/$repo/releases/tags/$SPEECHCAST_RELEASE_TAG")" \
            || fail "Cannot read GitHub release $SPEECHCAST_RELEASE_TAG."
        printf '  Release: %s\n' "$SPEECHCAST_RELEASE_TAG"
    else
        metadata="$(curl --retry 3 -fsSL --connect-timeout 15 \
            "https://api.github.com/repos/$repo/releases?per_page=30")" \
            || fail "Cannot read GitHub Releases."
    fi
    # Newest release with a SpeechCast/VoiceCast/Tinycast DMG. Drafts never appear in the
    # API list, so an unpublished draft cannot be installed.
    pair="$(printf '%s\n' "$metadata" | awk '
        /"tag_name"/ && !found { tag = $0; sub(/^.*"tag_name": "/, "", tag); sub(/".*$/, "", tag) }
        /"browser_download_url"/ && /(SpeechCast|VoiceCast|Tinycast)-[^"]*\.dmg"/ && !found {
            asset = $0; sub(/^.*"browser_download_url": "/, "", asset); sub(/".*$/, "", asset)
            found = 1
        }
        END { if (found) printf "%s\t%s\n", tag, asset }
    ')"
    [ -n "$pair" ] || fail "No SpeechCast DMG found. Releases may not be set up yet."
    version="${pair%%$'\t'*}"
    asset="${pair#*$'\t'}"
    case "$asset" in
        "https://github.com/$repo/releases/download/"*) ;;
        *) fail "Unexpected release asset URL." ;;
    esac
    printf '  Version: %s\n' "${version:-latest}"
    step 2 'Downloading disk image'
    asset_basename="${asset##*/}"
    curl --retry 3 -fL --connect-timeout 20 "$asset" -o "$workdir/$asset_basename" \
        || fail "Download failed."
    dmg="$workdir/$asset_basename"

    # Supplemental corruption check: SHA256SUMS is published with the DMG. The
    # cryptographic authenticity of the image is established by the pinned
    # certificate in step 3, regardless of this file. The sums reference the
    # ORIGINAL asset name, so match on it — not on any local temp name. A sums
    # file that exists but lists no entry for this asset is a release error.
    sums_url="${asset%$asset_basename}SHA256SUMS"
    if curl --retry 2 -fsSL --connect-timeout 10 "$sums_url" -o "$workdir/SHA256SUMS" 2>/dev/null; then
        expected="$(awk -v name="$asset_basename" \
            '$2 == name || $2 == "*"name { print tolower($1); exit }' "$workdir/SHA256SUMS")"
        if [ -z "$expected" ]; then
            fail "SHA256SUMS has no entry for $asset_basename — a broken release."
        fi
        actual="$(shasum -a 256 "$dmg" | awk '{print tolower($1)}')"
        [ "$actual" = "$expected" ] || fail "Checksum mismatch — the download is corrupted."
        printf '  %sChecksum verified (SHA256SUMS)%s\n' "$dim" "$reset"
    fi
fi

# ---------------------------------------------------------------------------
# Step 3/4: verify the pinned certificate BEFORE mounting, then the app inside.
# ---------------------------------------------------------------------------
step 3 'Verifying the pinned release signature'

verify_pinned_leaf() {
    # Verify the file's code signature and compare the signing certificate's
    # DER SHA256 against the pin. codesign writes extracted certs as <prefix><N>,
    # so the leaf is ${prefix}0. An ad-hoc signature has no certificates at all.
    local target="$1" prefix="$2" leaf_sha
    codesign --verify --strict "$target" >/dev/null 2>&1 ||
        fail "The signature is invalid (corrupted or modified): $target"
    rm -f "$prefix"*
    codesign -d --extract-certificates="$prefix" --verbose=4 "$target" >/dev/null 2>&1 ||
        fail "Cannot inspect the signature: $target"
    [ -f "${prefix}0" ] ||
        fail "Signed without a certificate (ad-hoc): $target"
    leaf_sha="$(/usr/bin/openssl dgst -sha256 -r "${prefix}0" 2>/dev/null | awk '{print toupper($1)}')"
    [ "$leaf_sha" = "$pinned_cert_sha256" ] ||
        fail "Signed by an unknown certificate — refusing to install: $target"
}

verify_pinned_leaf "$dmg" "$workdir/dmg-leaf"
printf '  Disk image: pinned certificate verified\n'

mkdir -p "$mount"
hdiutil attach -readonly -nobrowse -quiet -mountpoint "$mount" "$dmg" \
    || fail "Cannot mount the disk image."
mounted=true
app="$mount/SpeechCast.app"
if [ ! -d "$app" ] && [ -d "$mount/VoiceCast.app" ]; then app="$mount/VoiceCast.app"; fi
if [ ! -d "$app" ] && [ -d "$mount/Tinycast.app" ]; then app="$mount/Tinycast.app"; fi
if [ ! -d "$app" ]; then
    # Any other *.app at the image root: the name does not matter, the pinned
    # certificate below does (test fixtures and future renames alike).
    app="$(find "$mount" -maxdepth 1 -name '*.app' -type d -print -quit 2>/dev/null || true)"
fi
[ -d "$app" ] || fail "The DMG does not contain SpeechCast.app."

app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$app/Contents/Info.plist" 2>/dev/null)" || app_version=""
printf '  Version: %s\n' "${app_version:-unknown}"

# The app bundle itself must carry the same pinned certificate, with every nested
# Mach-O individually pinned — helpers hide exactly there, and --deep --strict
# alone proves only structural integrity of the seal.
codesign --verify --deep --strict "$app" >/dev/null 2>&1 ||
    fail "Invalid app code signature."
verify_pinned_leaf "$app" "$workdir/app-leaf"
# Every nested Mach-O is pinned individually (helpers hide exactly there); one
# extraction prefix per binary, removed before the next.
while IFS= read -r -d '' bin; do
    verify_pinned_leaf "$bin" "$workdir/nested-leaf"
    rm -f "$workdir"/nested-leaf*
done < <(while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q "Mach-O"; then printf '%s\0' "$f"; fi
done < <(find "$app/Contents" -type f -print0))

info="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" \
    || fail "Bundle identifier missing."
[ "$info" = "$expected_bundle" ] || fail "Unexpected bundle identifier: $info."

# A tag-pinned download must deliver the app the tag claims: exact version
# match after stripping the leading v, beta suffix included.
if [ -n "${version:-}" ] && [ -n "$app_version" ]; then
    # Exact normalized comparison: "0.12.0" == "v0.12.0", but "0.12.0-beta.1"
    # must NOT match a release that ships "0.12.0". The tag's full version,
    # beta suffix included, has to equal the app's.
    tag_version="${version#v}"
    [ "$tag_version" = "$app_version" ] ||
        fail "Release $version contains app version $app_version — a mismatched asset."
fi

# ---------------------------------------------------------------------------
# Step 4/4: staged install with backup and rollback
# ---------------------------------------------------------------------------
step 4 'Installing verified application'

install_root="${SPEECHCAST_INSTALL_DIR:-${VOICECAST_INSTALL_DIR:-}}"
if [ -z "$install_root" ]; then
    # An existing install keeps its location: wherever SpeechCast (or its legacy
    # name) already lives wins over the default, so an update never forks copies.
    for candidate in "$HOME/Applications" /Applications; do
        if [ -d "$candidate/SpeechCast.app" ] || [ -d "$candidate/VoiceCast.app" ] \
            || [ -d "$candidate/Tinycast.app" ]; then
            install_root="$candidate"
            break
        fi
    done
    if [ -z "$install_root" ]; then
        if [ -w /Applications ]; then install_root=/Applications; else install_root="$HOME/Applications"; fi
    fi
fi
mkdir -p "$install_root" || fail "Cannot create $install_root."
destination="$install_root/SpeechCast.app"

# Refuse to replace a running copy — but only at the destination we are writing
# to, so an isolated test install can proceed while the real app runs elsewhere.
# A legacy VoiceCast/Tinycast running anywhere also blocks the replacement.
running_app() {
    pgrep -f "^$(printf '%s' "$1" | sed 's/[][\\.*^$/]/\\&/g')/Contents/MacOS/" >/dev/null 2>&1
}
if [ -d "$destination" ] && running_app "$destination"; then
    fail "SpeechCast is running from $destination. Quit it before installing."
fi
for legacy_name in VoiceCast Tinycast; do
    if [ -d "$install_root/$legacy_name.app" ]; then
        pgrep -x "$legacy_name" >/dev/null 2>&1 &&
            fail "$legacy_name is running from $install_root. Quit it before installing."
    fi
done

# No same-version blind skip: installing over the same version is a repair, and
# it goes through the same verification as any other install.

legacy=""
for candidate in VoiceCast Tinycast; do
    if [ -e "$install_root/$candidate.app" ] && [ ! -e "$destination" ]; then
        [ -z "$legacy" ] || fail "Both VoiceCast.app and Tinycast.app exist. Remove the obsolete duplicate first."
        legacy="$install_root/$candidate.app"
    fi
done
[ "$legacy" = "" ] || [ ! -e "$destination" ] \
    || fail "Both SpeechCast.app and a legacy VoiceCast.app/Tinycast.app exist. Remove the obsolete duplicate first."

staged="$install_root/.SpeechCast.app.new.$$"
backup="$install_root/.SpeechCast.app.backup.$$"

if ! ditto "$app" "$staged"; then
    fail "Could not stage SpeechCast.app."
fi
codesign --verify --deep --strict "$staged" >/dev/null 2>&1 \
    || fail "Staged copy failed signature verification."
stage_leaf="$workdir/staged-leaf"
codesign -d --extract-certificates="$stage_leaf" --verbose=4 "$staged" >/dev/null 2>&1 \
    || fail "Cannot inspect the staged copy's signature."
[ -f "${stage_leaf}0" ] || fail "Staged copy: signed without a certificate."
stage_leaf_sha="$(/usr/bin/openssl dgst -sha256 -r "${stage_leaf}0" 2>/dev/null | awk '{print toupper($1)}')"
[ "$stage_leaf_sha" = "$pinned_cert_sha256" ] || fail "Staged copy was signed by an unknown certificate."

if [ -e "$destination" ]; then
    replaced="$destination"
elif [ -n "$legacy" ]; then
    replaced="$legacy"
fi
if [ -n "$replaced" ]; then
    # A replaced bundle must be an old SpeechCast install (same bundle id), not some
    # unrelated app that happens to carry the name.
    replaced_info="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$replaced/Contents/Info.plist" 2>/dev/null)" || replaced_info=""
    [ "$replaced_info" = "$expected_bundle" ] \
        || fail "Refusing to replace $replaced: not a SpeechCast bundle ($replaced_info)."
    mv "$replaced" "$backup" || fail "Cannot back up the existing app."
fi
if ! mv "$staged" "$destination"; then
    fail "Could not install SpeechCast.app."
fi
placed_new=true
staged=""

# Quarantine must not survive on a copy we proved is ours: Gatekeeper has no
# basis to judge a self-signed certificate and would just block the launch.
# This clears the flag only on the copy this installer placed; Gatekeeper
# itself stays enabled and untouched everywhere else. A failure here rolls the
# transaction back — the old app returns and the new copy is removed.
if ! xattr -dr com.apple.quarantine "$destination" 2>/dev/null; then
    fail "Could not clear the quarantine flag on the installed copy."
fi

# Commit point: everything verified, installed, and de-quarantined. From here
# the install is final; the exit handler no longer rolls anything back and the
# backup of the previous app can be removed.
installed_new=true

rm -rf "$backup" 2>/dev/null || true
backup=""
replaced=""

printf '\n%s✓%s Installed %s\n' "$green" "$reset" "$destination"
printf '%s  %s%s\n' "$dim" \
    "Verified against the pinned SpeechCast release certificate. Open it from Applications." "$reset"
