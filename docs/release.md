# Release

SpeechCast releases come from `1tuz/SpeechCast`. Public builds use the persistent self-signed certificate documented in [signing.md](signing.md). The secret setup and migration procedure are in [speechcast-distribution.md](speechcast-distribution.md).

## Versions and artifacts

Release tags use `vMAJOR.MINOR.PATCH`, optionally followed by `-beta` or `-beta.N`. Stable versions outrank their betas. A release's GitHub prerelease flag must agree with its tag. Drafts are never offered by the updater.

Each version carries an Apple Silicon `SpeechCast-<version>.dmg` and `SpeechCast-<version>.zip`, plus integrity metadata. The DMG and app are cryptographically signed with the pinned certificate. The ZIP preserves bundle signatures with `ditto`; it is an extra download format, not the native updater's installation format.

## Release workflow

Trigger `.github/workflows/release.yml` with a version tag or a manual version. It validates the version, dependencies, secrets and public pin before building. It retains `com.tinycast.app`, existing entitlements, nested helper signatures and the Release hardened runtime. It does not require an Apple Team ID, notarization or a paid Apple account.

The build uses a temporary keychain and deletes signing material unconditionally. Verification checks shipping bytes, every nested executable and the pinned certificate. Fresh macOS runners test the installer with quarantine present and exercise the production Swift updater, settings preservation, migration and rejection paths. Publication is gated on those checks. Failed staging drafts must not become public updates.

The installer and updater authenticate the DMG before mounting it. SHA-256 metadata detects corruption but is not an independent root of trust. Do not replace cryptographic signature verification with checksums from GitHub metadata.

## Local packaging

`Scripts/build-dmg.sh` builds and packages a release using an already imported signing identity. Consult the script's usage for identity and output settings. It does not generate a certificate. A contributor's `Tinycast Self-Signed` identity remains for local development; it cannot produce an artifact accepted by the public installer. Keep the actual public release private key in protected storage and GitHub Actions Secrets.

## Installation

Use the command in [INSTALL.md](../INSTALL.md). A quarantined self-signed app is not Developer ID-trusted. The verified installer clears quarantine only on its installed copy; it does not disable Gatekeeper. The native updater applies the same trust policy.

An old Tinycast, VoiceCast or SpeechCast updater that pins the previous certificate needs one installation through the script. Stable bundle ID and data paths preserve settings. macOS can require one-time permission grants when the certificate changes.

## Release notes

`Scripts/release-notes.sh` composes a GitHub changelog followed by the `<!-- tinycast:install -->` marker and installation instructions. The native update window shows only the changelog above that marker. Contributor handles and PR numbers resolve against `ReleaseFeed.repository`.

Run the script against a tag to preview notes without publishing. Release assets and signing keys must not be committed as version-bump changes. Treat public versions as immutable.
