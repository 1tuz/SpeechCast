# SpeechCast distribution runbook

SpeechCast ships native Swift app updates through GitHub Releases in `1tuz/SpeechCast`. The persistent self-signed release certificate authenticates the app, helpers and DMG. See [signing.md](signing.md) for the pin and trust model.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/1tuz/SpeechCast/main/Scripts/install.sh | /bin/bash
```

The standalone installer uses tools supplied by macOS; users do not need Xcode or Command Line Tools. It verifies the signed DMG before mounting, then verifies the application, nested code, pinned certificate and `com.tinycast.app` bundle ID. Only after verification does it install and clear quarantine on its installed copy. Gatekeeper and SIP remain enabled. The script does not use a privileged helper or delete settings.

A self-signed certificate does not make a quarantined app Apple-trusted. Download-and-drag installation can be blocked by Gatekeeper. The supported initial install is the script above. Subsequent releases install through the native update window.

## Initial secret provisioning

The matching certificate export and password are stored locally in ignored `build/signing/SpeechCast.p12` and `build/signing/p12-password.txt`. These files are not release artifacts. Back them up outside disposable build storage. Transfer the values directly into repository Actions secrets without printing them:

```sh
base64 -i build/signing/SpeechCast.p12 | tr -d '\n' | gh secret set SPEECHCAST_SIGNING_P12_BASE64 --repo 1tuz/SpeechCast
gh secret set SPEECHCAST_SIGNING_P12_PASSWORD --repo 1tuz/SpeechCast < build/signing/p12-password.txt
```

| Secret | Value |
| --- | --- |
| `SPEECHCAST_SIGNING_P12_BASE64` | Base64 of the existing password-encrypted `.p12`, including its private key |
| `SPEECHCAST_SIGNING_P12_PASSWORD` | The export password for that exact `.p12` |

The release workflow accepts the former `SIGNING_P12_BASE64` and `SIGNING_P12_PASSWORD` names during migration. Move their values to the canonical names, then remove the former secrets.

The workflow's repository `GITHUB_TOKEN` handles release publication. No Apple secrets are required. Former `DEVELOPER_ID_APPLICATION_*`, `APPLE_TEAM_ID` and `APPSTORE_*` secrets are unused and can be removed after migration. Do not regenerate the certificate to configure a missing secret.

For a future explicitly approved signing generation, use the one-time `Scripts/create-signing-certificate.sh` generator. Review its usage and update all public pins together. That is a certificate migration, not routine release preparation. A new certificate cannot update apps that trust only the previous pin.

## Release gates

The workflow accepts a version tag or a manual version. Supported forms include `v0.11.1`, `v0.11.1-beta` and `v0.11.1-beta.1`. The prerelease flag must agree with the tag. Release builds target Apple Silicon and retain bundle ID `com.tinycast.app`.

The build imports the encrypted certificate into a temporary keychain, checks it against the committed public certificate, builds with the hardened runtime and signs every executable. It packages a signed DMG and a ZIP that preserves bundle metadata. Release metadata and checksums describe the exact shipping bytes. Checksums do not replace certificate verification.

Installation and update gates run on fresh macOS runners without private signing keys. They use the verified installer, inject a real quarantine attribute, and exercise launch and the production Swift installation path. A failed check prevents the release from becoming public. An uploaded draft is a staging area, not a published update. Do not edit or replace assets in an already published version.

The scripts must reject an unknown leaf, ad-hoc code, changed sealed resources, corrupt DMGs and mismatched bundle IDs or versions. They must not accept a file merely because its name, environment variables or an unsigned checksum look correct.

## One-time migration

1. Quit SpeechCast and any older VoiceCast or Tinycast instance. Keep your settings and user data in place. Do not uninstall the old app or clear its preferences.
2. Run the installation command above once. Old updaters that trust the previous certificate cannot securely accept the new certificate by themselves. The script verifies the new signing identity independently and migrates an existing `Tinycast.app` or `VoiceCast.app` to `SpeechCast.app`.
3. Launch the installed app from its permanent Applications directory. Preferences remain under the existing paths, including `~/.config/tinycast`, `~/Library/Preferences/com.tinycast.app.plist` and bundle-based application support paths. The installer changes app bundles only.
4. Test the actual functions that need Accessibility, Input Monitoring and Automation: invoke the launcher shortcut, paste or run a voice action, and run an automation action. A checked switch alone is not proof of access.
5. If macOS requests a permission again, grant it in System Settings. If an old entry remains stale, quit the app, remove only that SpeechCast/Tinycast/VoiceCast entry for the affected service, reopen the installed SpeechCast and grant it again. Do not reset all TCC permissions. Do not edit the TCC database.
6. Check launch at login after the product path changes. If macOS marks the existing login item stale, toggle SpeechCast's launch-at-login setting off and on. Other login items are unaffected.
7. Use Check for Updates for later versions. The new updater trusts the fixed release certificate, including a transition from an installed beta to its stable version.

Stable identity and bundle ID maximize permission continuity for later releases. macOS does not guarantee that every existing grant survives either the first certificate migration or a future OS policy change. Neither the installer nor the updater silently resets or grants permissions.

## Recovery and manual checks

If installation fails during replacement, the transaction restores the old application before reporting the error. Retain any reported backup until the installed version has launched successfully. A crash after a completed installation is different from a failed file transaction: do not claim that the updater can prove future runtime health. Reinstall a known-good release using a trusted installer if runtime recovery is needed.

On a Mac with no previous install, run the public install command, launch SpeechCast through LaunchServices and confirm that the process remains alive. Verify the executable's signature with `Scripts/verify-release.sh app`. Then update from version N to N+1 in the native update window and verify settings, notes, snippets, permissions and launch at login. Repeat on physical hardware when macOS changes TCC or Gatekeeper behavior.
