#!/bin/bash
# Exercise the shipping installer with real signed bytes. Never changes the user's app.
# Usage: test-release-installation.sh release.dmg version [--launch]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
umask 077
DMG="${1:?release DMG required}"
VERSION="${2:?release version required}"
LAUNCH="${3:-}"
DMG="$(cd "$(dirname "$DMG")" && pwd)/$(basename "$DMG")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/speechcast-install-test.XXXXXX")"
FOREIGN_KEYCHAIN=""
cleanup() {
    if [ -n "$FOREIGN_KEYCHAIN" ]; then security delete-keychain "$FOREIGN_KEYCHAIN" >/dev/null 2>&1 || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "::error::$*" >&2; exit 1; }
install_to() {
    HOME="$WORK/home" SPEECHCAST_DMG="$1" SPEECHCAST_INSTALL_DIR="$2" "$ROOT/Scripts/install.sh"
}
expect_rejection() {
    if install_to "$1" "$2" > "$WORK/rejection.log" 2>&1; then
        fail "Installer accepted $3"
    fi
    [ ! -e "$2/SpeechCast.app" ] || fail "Rejected $3 left an installed app"
}

"$ROOT/Scripts/verify-release.sh" dmg "$DMG" --version "$VERSION"
cp "$DMG" "$WORK/release.dmg"
xattr -w com.apple.quarantine "0083;$(printf '%x' "$(date +%s)");Safari;" "$WORK/release.dmg"
mkdir -p "$WORK/home/.config/tinycast" "$WORK/home/Library/Application Support/com.tinycast.app"
printf '{"sentinel":"preserve-settings"}\n' > "$WORK/home/.config/tinycast/settings.json"
printf 'preserve-user-data\n' > "$WORK/home/Library/Application Support/com.tinycast.app/notes"
BEFORE_SETTINGS="$(shasum -a 256 "$WORK/home/.config/tinycast/settings.json")"
BEFORE_DATA="$(shasum -a 256 "$WORK/home/Library/Application Support/com.tinycast.app/notes")"

install_to "$WORK/release.dmg" "$WORK/Applications"
APP="$WORK/Applications/SpeechCast.app"
"$ROOT/Scripts/verify-release.sh" app "$APP" --version "$VERSION"
if xattr -lr "$APP" | grep -q 'com.apple.quarantine'; then
    fail "Verified installed copy still has quarantine"
fi
# A second install must remain safe and must not remove data.
install_to "$WORK/release.dmg" "$WORK/Applications"

for OLD in Tinycast VoiceCast; do
    DIR="$WORK/$OLD-migration"
    mkdir -p "$DIR"
    ditto "$APP" "$DIR/$OLD.app"
    install_to "$WORK/release.dmg" "$DIR"
    [ ! -e "$DIR/$OLD.app" ] || fail "$OLD legacy app was not migrated"
    "$ROOT/Scripts/verify-release.sh" app "$DIR/SpeechCast.app" --version "$VERSION"
done

# Real corruption: retain the certificate while changing signed container bytes.
cp "$WORK/release.dmg" "$WORK/corrupt.dmg"
printf 'CORRUPTED-SPEECHCAST' | dd of="$WORK/corrupt.dmg" bs=1 seek=64 conv=notrunc 2>/dev/null
expect_rejection "$WORK/corrupt.dmg" "$WORK/corrupt-install" 'a damaged signed DMG'
# Real untrusted signature: replace the certificate signature with ad-hoc signing.
cp "$WORK/release.dmg" "$WORK/adhoc.dmg"
codesign --force --sign - --timestamp=none "$WORK/adhoc.dmg"
expect_rejection "$WORK/adhoc.dmg" "$WORK/adhoc-install" 'an ad-hoc DMG'
# A rejected update must preserve an already installed copy.
INSTALLED_BEFORE="$(shasum -a 256 "$APP/Contents/Info.plist")"
# A valid signature from another certificate must fail even if its seal is intact.
# Strip the embedded signature by replacing it with a new, real signing identity.
mkdir -p "$WORK/foreign-key"
cat > "$WORK/foreign-key/openssl.cnf" <<'CONFIG'
[req]
distinguished_name=dn
x509_extensions=signing
prompt=no
[dn]
CN=SpeechCast-Untrusted-Test
[signing]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CONFIG
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$WORK/foreign-key/key.pem" -out "$WORK/foreign-key/cert.pem" \
    -config "$WORK/foreign-key/openssl.cnf" > "$WORK/foreign-key/generation.log" 2>&1
/usr/bin/openssl pkcs12 -export -inkey "$WORK/foreign-key/key.pem" \
    -in "$WORK/foreign-key/cert.pem" -out "$WORK/foreign-key/cert.p12" \
    -passout pass:ephemeral-test-only
FOREIGN_KEYCHAIN="$WORK/foreign-key/test.keychain-db"
security create-keychain -p ephemeral-test-only "$FOREIGN_KEYCHAIN"
security unlock-keychain -p ephemeral-test-only "$FOREIGN_KEYCHAIN"
security import "$WORK/foreign-key/cert.p12" -k "$FOREIGN_KEYCHAIN" \
    -P ephemeral-test-only -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k ephemeral-test-only "$FOREIGN_KEYCHAIN" >/dev/null
cp "$WORK/release.dmg" "$WORK/foreign.dmg"
codesign --force --keychain "$FOREIGN_KEYCHAIN" --sign SpeechCast-Untrusted-Test \
    --timestamp=none "$WORK/foreign.dmg"
codesign --verify --strict "$WORK/foreign.dmg"
expect_rejection "$WORK/foreign.dmg" "$WORK/foreign-install" 'a valid DMG signed by an unknown certificate'
security delete-keychain "$FOREIGN_KEYCHAIN"
FOREIGN_KEYCHAIN=""
if install_to "$WORK/corrupt.dmg" "$WORK/Applications" > "$WORK/corrupt-update.log" 2>&1; then
    fail 'Installer accepted corrupt bytes over an existing installation'
fi
[ "$INSTALLED_BEFORE" = "$(shasum -a 256 "$APP/Contents/Info.plist")" ] || fail 'Rejected update damaged the previous copy'
"$ROOT/Scripts/verify-release.sh" app "$APP" --version "$VERSION"

OCCUPIED="$WORK/occupied"
UNRELATED="$OCCUPIED/SpeechCast.app/Contents/Info.plist"
mkdir -p "$(dirname "$UNRELATED")"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string org.example.unrelated' "$UNRELATED"
UNRELATED_BEFORE="$(shasum -a 256 "$UNRELATED")"
if install_to "$DMG" "$OCCUPIED" > "$WORK/occupied.log" 2>&1; then
    fail 'Installer accepted a destination occupied by an unrelated app'
fi
[ "$UNRELATED_BEFORE" = "$(shasum -a 256 "$UNRELATED")" ] || fail 'Installer damaged the unrelated app'

[ "$BEFORE_SETTINGS" = "$(shasum -a 256 "$WORK/home/.config/tinycast/settings.json")" ] || fail 'Settings changed'
[ "$BEFORE_DATA" = "$(shasum -a 256 "$WORK/home/Library/Application Support/com.tinycast.app/notes")" ] || fail 'User data changed'

if [ "$LAUNCH" = --launch ]; then
    # Use only on a clean CI account: LaunchServices and the app have real per-user effects.
    open -n "$APP"
    sleep 5
    /usr/sbin/lsof -t "$APP/Contents/MacOS/SpeechCast" > "$WORK/launched-pids" || fail 'Installed SpeechCast did not remain running'
    while IFS= read -r PID; do
        [ -n "$PID" ] && kill -TERM "$PID"
    done < "$WORK/launched-pids"
fi
printf 'Verified installer: clean install, quarantine, reinstall, Tinycast/VoiceCast migration, tamper and ad-hoc rejection, settings preservation.\n'
