#!/bin/bash
# Fast gate for daily fork sync. Full Scripts/run-tests.sh is intentionally not run here.
# Usage: gate.sh <upstream-sha>
set -uo pipefail
UP="${1:?upstream sha}"
cd "$(git rev-parse --show-toplevel)"
TMP="${RUNNER_TEMP:-$(mktemp -d)}"

echo "::group::structure"
test -f Tinycast.xcodeproj/project.pbxproj || { echo "::error::missing Xcode project"; exit 1; }
test ! -d Tinycast/Features/Dictation || { echo "::error::Upstream Dictation sources must be absent"; exit 1; }
test -f Tinycast/Features/VoiceAsk/SpeechRuntimeVoiceAsk.swift || { echo "::error::Speech Runtime Voice Ask missing"; exit 1; }
test -f Tinycast/Features/VoiceAsk/SpeechVoiceCommandRouter.swift || { echo "::error::Voice command router missing"; exit 1; }
test -f Tinycast/Features/VoiceAsk/SpeechVoiceCommandParser.swift || { echo "::error::Voice command parser missing"; exit 1; }
test -f Tinycast/Features/VoiceAsk/SpeechVoiceCommandCatalog.swift || { echo "::error::Voice command catalog missing"; exit 1; }
test -f Tinycast/Features/Focus/Model/FocusProfile.swift || { echo "::error::Focus model missing"; exit 1; }
test -f Tinycast/Features/Focus/Service/FocusSessionCoordinator.swift || { echo "::error::Focus coordinator missing"; exit 1; }
test -f docs/features/focus.md || { echo "::error::Focus feature doc missing"; exit 1; }
grep -qF 'FocusSessionCoordinator' Tinycast/App/AppCore.swift \
  || { echo "::error::Focus coordinator is no longer owned by AppCore"; exit 1; }
! grep -qE '^import (AppKit|SwiftUI|Cocoa)' Tinycast/Features/Focus/Model/*.swift \
  || { echo "::error::Focus model must stay Foundation-only"; exit 1; }
if grep -RniE 'CodexRealtime|thread/realtime' Tinycast/Features/VoiceAsk; then
  echo "::error::obsolete cloud audio path detected"
  exit 1
fi
grep -qF 'static let repository = "1tuz/SpeechCast"' Tinycast/Features/Updates/Model/ReleaseFeed.swift \
  || { echo "::error::ReleaseFeed does not point at SpeechCast"; exit 1; }
grep -qF 'pump = nil' Tinycast/Features/Support/Service/SupportReminderStore.swift \
  || { echo "::error::Support reminder pump not disabled"; exit 1; }
grep -qF 'SpeechCast' Tinycast/Info.plist \
  || { echo "::error::SpeechCast display name missing"; exit 1; }
grep -qF 'speechcast.svg' Tinycast/tinycast.icon/icon.json \
  || { echo "::error::SpeechCast Dock icon not selected"; exit 1; }
grep -qF 'speechcast.svg' Tinycast/Assets.xcassets/MenuBarIcon.imageset/Contents.json \
  || { echo "::error::SpeechCast menu bar icon not selected"; exit 1; }
# Verify the committed public certificate and all consumers agree after an upstream sync.
# Cryptographic artifact checks and installation scenarios run in the release workflow.
./Scripts/check-signing-config.sh || exit 1
grep -qF 'Tinycast Self-Signed' project.yml \
  || { echo "::error::local development lost its persistent identity"; exit 1; }
if grep -Eq 'notarytool|stapler|APPLE_TEAM_ID|APPSTORE_API_' .github/workflows/release.yml; then
  echo "::error::paid Apple signing requirements returned to the release workflow"
  exit 1
fi
# The overlay is what the daily sync copies, so it may never drift from the canonical file.
for pair in \
  "Tinycast/tinycast.icon/icon.json:icon.json" \
  "Tinycast/tinycast.icon/Assets/speechcast.svg:icon.svg" \
  "Tinycast/Assets.xcassets/MenuBarIcon.imageset/Contents.json:menuicon.json" \
  "Tinycast/Assets.xcassets/MenuBarIcon.imageset/speechcast.svg:menubar.svg" \
  "docs/speechcast-logo.svg:logo.svg"; do
  canonical="${pair%%:*}"
  overlay=".1tuz/branding/${pair#*:}"
  cmp -s "$canonical" "$overlay" \
    || { echo "::error::$overlay drifted from $canonical; copy it back into the overlay"; exit 1; }
done
grep -qF 'SpeechCast' Scripts/install.sh \
  || { echo "::error::installer lost the SpeechCast branding"; exit 1; }
grep -qF 'SpeechCast' Scripts/release-notes.sh \
  || { echo "::error::release notes lost the SpeechCast branding"; exit 1; }
bash -n Scripts/install.sh Scripts/build-dmg.sh Scripts/release-notes.sh Scripts/verify-release.sh \
  && bash -n .1tuz/apply.sh .1tuz/gate.sh .1tuz/branding/apply.sh \
  || { echo "::error::shell syntax check failed"; exit 1; }
printf '%s\n' 'SpeechCast brand gate: ok'
echo "::endgroup::"

echo "::group::xcodebuild Release smoke"
if ! xcodebuild -project Tinycast.xcodeproj -scheme Tinycast -configuration Release \
  -derivedDataPath "$TMP/gate-dd" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- build > "$TMP/gate-build.log" 2>&1; then
  echo "::endgroup::"
  grep -E 'error:' "$TMP/gate-build.log" | head -40 || true
  tail -40 "$TMP/gate-build.log"
  echo "::error::build failed (upstream ${UP:0:7})"
  exit 1
fi
echo "::endgroup::"

echo "::group::focused harnesses"
FAILED=""
for t in hotkey-test ai-provider-test updates-test ranking-test developer-utility-test \
  ephemeral-snippet-test quick-action-test file-search-test file-search-session-test \
  calendar-test window-layout-test window-switch-test compact-bar-test \
  clipboard-search-test clipboard-thumbnail-test fallback-test launcher-settings-file-test \
  settings-backup-test hotkey-dispatch-test workflow-test voice-command-test \
  voice-alias-test focus-profile-test installer-fallback-test ext-contract-test; do
  echo "▸ $t"
  if ! ./Scripts/run-tests.sh "$t" > "$TMP/gate-$t.log" 2>&1; then
    echo "::error::harness failed: $t"
    tail -40 "$TMP/gate-$t.log" || true
    FAILED="$FAILED $t"
  fi
done
echo "::endgroup::"

if [ -n "$FAILED" ]; then
  echo "::error::gate failed on:$FAILED (upstream ${UP:0:7})"
  exit 1
fi

echo "gate.sh: ok on upstream ${UP:0:7}"
