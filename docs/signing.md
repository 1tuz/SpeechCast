# Signing

Public SpeechCast builds use one persistent self-signed RSA code-signing certificate. Apple Developer Program membership, Developer ID, a Team ID, App Store Connect keys and Apple notarization are not required. The release is not an Apple-trusted Developer ID application. Use the verified installer for the first installation; dragging a quarantined download out of a DMG is not the supported installation route.

Apple distinguishes signature validity and designated requirements from subsystem trust policy in
[Technical Note TN2206](https://developer.apple.com/library/archive/technotes/tn2206/).
Self-signed code can have a stable designated requirement without becoming Gatekeeper-trusted.

## Trust contract

The public certificate is `Config/SpeechCastSigning.pem`. Its SHA-256 fingerprint over DER bytes is pinned in `Config/signing.conf`, `BundleSignature.swift` and the standalone `Scripts/install.sh`:

```text
A0AA9BCD7AFBC13A3CF4B16CAC7B84A0632816143F9C9D217DF9757B8400FD62
```

A common name is not an identity check. Each verifier checks the cryptographic seal and the leaf certificate fingerprint. Public builds never use ad-hoc signing or a newly generated certificate. The DMG is signed by the same certificate as the app and its helper executables. The updater authenticates the DMG before mounting it, then verifies the extracted app, its bundle ID, version and nested executables before replacement. SHA-256 checksums detect corruption but do not establish authenticity by themselves.

`com.tinycast.app` remains the public bundle identifier. Keep the same certificate, private key and designated requirements across releases. Keep the hardened runtime enabled for Release and preserve `Tinycast/Tinycast.entitlements` and helper signing. Debug keeps its contributor identity and does not become a public release.

The reference [Obsidium release workflow](https://github.com/1tuz/Obsidium/blob/main/.github/workflows/release.yml)
separates update authenticity from Apple notarization with Tauri's update signature. SpeechCast
keeps its native Swift updater and uses the signed DMG plus the fixed certificate for that role.
It does not import Tauri, minisign or another updater process.

## One-time certificate creation

The repository already contains the public certificate and pin for this signing generation. The matching encrypted export was provisioned once in the ignored `build/signing/` directory. Back up the encrypted `.p12` and its password separately before deleting build output. The private key must never be committed or uploaded as a build artifact.

`Scripts/create-signing-certificate.sh` is the one-time generator for a new signing generation. It writes a password-protected `.p12`, a private password file and the public certificate into a new output directory. It refuses to overwrite existing material. Read its usage before running it. Do not run it during CI or before each release. Generating another certificate does not recreate the existing identity, even with the same name.

For an explicitly planned replacement generation, on a maintainer machine with OpenSSL 3:

```sh
./Scripts/create-signing-certificate.sh build/new-signing-generation
```

This creates a new identity. It does not configure CI, change pins or replace the current key.

If the existing private key is lost, stop releases. A replacement certificate needs an explicit pin change and a documented migration; installed apps will correctly reject it. If a key leaks, stop releases and treat already installed apps as requiring a trusted manual migration. There is no online revocation service for this self-signed identity.

## GitHub Actions secrets

Configure two repository Actions secrets in `1tuz/SpeechCast`. The exact names are listed in [the distribution runbook](speechcast-distribution.md). Their values are the base64-encoded encrypted `.p12` and its export password. Base64 is transport encoding, not encryption.

The workflow imports the export into a temporary keychain. It validates the imported public certificate against the committed pin, signs the Release app and nested code, signs the DMG, and removes the keychain and temporary export in an unconditional cleanup step. Secret values must not appear in logs or release artifacts. Do not import the release identity into a contributor's login keychain just to run tests.

## Local development

The Xcode project keeps the contributor identity `Tinycast Self-Signed`. A contributor can create their own persistent code-signing certificate for development. It is a different identity and the public installer and updater reject it. Keep its private key across local rebuilds if you want macOS to recognize the same designated requirement. Do not substitute that identity for the release certificate in CI.

## Entitlements and permissions

Release builds retain the hardened runtime. `Scripts/verify-signature.sh` checks the runtime on shipping Mach-O files, rejects `get-task-allow`, and checks the entitlement required by each declared protected-resource usage string.

| Entitlement | Purpose |
| --- | --- |
| `com.apple.security.cs.allow-jit` | JavaScriptCore JIT for extensions |
| `com.apple.security.automation.apple-events` | Apple Events automation |
| `com.apple.security.device.camera` | Camera access |
| `com.apple.security.device.audio-input` | Microphone access |
| `com.apple.security.personal-information.calendars` | Calendar access |

Do not infer permission preservation from the bundle ID or the switch in System Settings alone. Accessibility, Input Monitoring, Automation and other TCC grants can depend on signing requirements and path. A certificate change can require one-time reauthorization. See [the migration procedure](speechcast-distribution.md#one-time-migration).

## Verification

```sh
./Scripts/verify-signature.sh /Applications/SpeechCast.app
./Scripts/verify-release.sh app /Applications/SpeechCast.app
./Scripts/verify-release.sh dmg dist/SpeechCast-<version>.dmg --version <version>
```

A successful cryptographic verification is separate from Gatekeeper assessment of a quarantined self-signed download. Tests exercise the verified installer and actual launch after its scoped quarantine removal. They must not require Apple notarization or disable Gatekeeper.
