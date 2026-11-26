# .1tuz

Everything that makes this fork differ from [abue-ammar/tinycast](https://github.com/abue-ammar/tinycast).
`main` uses the upstream `main` tree plus these patches. Each sync commit keeps the previous fork `main` as its first parent, so publishing is a normal fast-forward push.

| File | What it does |
| --- | --- |
| `patches/0008-fork-updater.patch` | In-app updater and About link to `1tuz/tinycast` |
| `patches/0009-disable-support-reminders.patch` | Disables automatic Support reminders |
| `patches/0012-remove-website-link.patch` | Removes the upstream Website link from About |
| `patches/0013-curl-installer.patch` | Adds the one-line local installer and guide |
| `patches/0014-release-notes-install-guide.patch` | Uses the local install guide in generated release notes |
| `patches/0016-fork-readme-install-guide.patch` | Replaces upstream website and package-manager install text in README |
| `patches/0017-roadmap-features.patch` | Carries local roadmap features and removes upstream Dictation/microphone capture |
| `patches/0018-speech-runtime-voice.patch` | Restores Voice Ask with local Speech Runtime transcriptions, Hyper PTT and Quick AI delivery |
| `patches/0019-voice-commands.patch` | Voice control, typo-tolerant matching, searchable command catalog, multiple aliases and conservative ASR typo correction |
| `patches/0021-voicecast-rebrand.patch` | The pre-SpeechCast VoiceCast identity in source, tests, docs and build metadata, plus the Developer ID / notarized release posture. The SpeechCast overlay rebrands its visible output; the patch itself is not edited |
| `patches/0022-focus-sessions.patch` | Local Focus sessions: profiles, soft app and browser-tab blocking, menu bar and HUD timer, deterministic voice commands |
| `patches/0023-legibility-and-messenger-links.patch` | Restores glass legibility, fixes clipboard/text-area/AI accessibility handling, adds snippet copy/pin preferences, and expands documented meeting and messenger links |
| `patches/0024-raycast-voice-shared-window-manager.patch` | Voice launch/arguments for Raycast extensions and a shared AeroSpace/yabai window backend, with tiler-safe guards |
| `patches/0025-extension-contract.patch` | Optional versioned SpeechCast extension metadata, parser regression harness and the staged repository boundary plan |
| `patches/0026-window-managers-atomic-install.patch` | Shared tiler adapters, connection checks, atomic package installation and focused regression tests |
| `branding/` | The SpeechCast overlay: dock + menu bar icons and the logo. README, INSTALL, distribution guidance, `install.sh`, `build-dmg.sh` and `release-notes.sh` are canonical in the fork tree itself — the overlay never carries a second copy of them. `branding/apply.sh` reapplies the overlay idempotently after every patch queue run |
| `apply.sh` | Applies patches, reapplies the branding overlay, removes website source and publishing workflows, rewrites release links, regenerates the XcodeGen project |
| `gate.sh` | Guards the SpeechCast branding and pinned signing configuration, rejects paid Apple release dependencies, checks overlay drift, and runs a Release build and focused harnesses |
| `UPSTREAM` | Upstream commit SHA used for the last rebuild |

## Automation

- `fork-sync.yml` checks upstream `main` daily and on manual dispatch. It rebuilds the fork from upstream plus `.1tuz/patches`, preserves this fork's workflows, runs `gate.sh`, then pushes `main` as a fast-forward merge of the previous fork tree and upstream. Failed gates do not publish a new tree.
- GitHub Actions uses its built-in `GITHUB_TOKEN`; no extra push token is needed. The fork does not contain the website source or publishing workflow.
- `INSTALL.md` documents the verified installer. It needs no Xcode or root access. It authenticates the signed DMG and app using the persistent SpeechCast certificate, then clears quarantine only on the installed copy. Gatekeeper stays enabled. Old signing generations need one migration through this installer.
- `release.yml` accepts stable and beta tags or manual versions. It signs with the persistent self-signed certificate from two Actions secrets, verifies shipping signatures and installation/update behavior on fresh macOS runners, then publishes. See `docs/signing.md` and `docs/speechcast-distribution.md`. Keep public pin and updater changes in the patch queue when updating upstream.
  The Localizable.xcstrings full UI translation rebrand is tracked separately and is outside this overlay: `branding/apply.sh` covers the app name and icons only — the installer and release scripts are canonical tree files it never touches.
