# Install SpeechCast

SpeechCast requires macOS 26 or later on Apple silicon.

## Install a verified release

```sh
curl -fsSL https://raw.githubusercontent.com/1tuz/SpeechCast/main/Scripts/install.sh | /bin/bash
```

The installer downloads the current release from `1tuz/SpeechCast`. It verifies the signed DMG
before mounting it, then checks the application seal, the pinned SpeechCast certificate and
bundle ID `com.tinycast.app`. It uses `/Applications` when writable, otherwise `~/Applications`.
No Xcode, Command Line Tools, paid Apple account or root access is needed.

Public builds use one persistent self-signed code-signing certificate. They are not Apple
notarized. A browser download followed by dragging the app out of the DMG can trigger Gatekeeper.
Use the command above: it removes quarantine only from the verified installed copy and leaves
Gatekeeper enabled. No manual `xattr` command is needed.

The installer replaces an existing `SpeechCast.app`, `VoiceCast.app` or `Tinycast.app` without
deleting settings or user data. Quit the old app before installing. It stages the replacement
and restores the previous application if installation fails.

An older app cannot learn a new certificate through its existing updater. Run the installer once
to migrate to this signing system. Later releases use the same certificate and install through
SpeechCast's native update window. macOS can require one-time permission grants after the
certificate changes. See [the migration runbook](docs/speechcast-distribution.md).

## Source builds

The original `Tinycast.xcodeproj` and scheme intentionally retain their names to
simplify upstream merges. Build using Xcode 26/27 with a local code-signing identity:

```sh
xcodebuild -project Tinycast.xcodeproj -scheme Tinycast -configuration Release \
  -derivedDataPath build/DerivedData build
```

Source builds use a contributor's local signing identity. The public installer deliberately
rejects those builds: only the pinned release certificate is accepted. Do not distribute a
locally generated identity as SpeechCast. See [docs/signing.md](docs/signing.md) for certificate
setup and [docs/speechcast-distribution.md](docs/speechcast-distribution.md) for release operations.
