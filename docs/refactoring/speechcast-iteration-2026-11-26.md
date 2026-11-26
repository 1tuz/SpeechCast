# SpeechCast: shared window managers and extension installation

Base: `1tuz/SpeechCast` commit `606e1357357961edabccbf0470e22d339a1b77e4`.
Apply the extension contract (0025) before 0026. Both are carried in the fork patch queue.
This is a source patch; it is not a macOS-tested release.

## Window management

Keep the existing WindowCommandCoordinator as the single dispatcher for shortcuts, launcher
and voice. Automatic mode follows a recognized explicit StableBar workspace source; otherwise
it selects a single running supported tiler, refuses an ambiguous set, or uses native AX
when none is running. A StableBar source of `spaces` does not imply that a tiler is absent.
Explicit selection never silently falls back if the manager is missing or its CLI fails.
Native mode remains an explicit user choice. No external configuration is rewritten.

| Backend | CLI | Workspaces | Directional movement | Resize |
| --- | --- | --- | --- | --- |
| AeroSpace | `aerospace` | Existing switch/move | Existing | Existing |
| yabai | `yabai` | Existing switch/move | Existing warp | Existing floating AX only |
| Rift | `rift-cli` | Switch/move, zero-based CLI indices | Move node | Smart grow/shrink |
| OmniWM | `omniwmctl` | Switch/move | Move | Dwindle grow/shrink |
| KiwiDesk | `kiwidesk` | Focus/move | Swap | Horizontal delta |

The UI includes a read-only connection check. OmniWM IPC must be enabled; Rift needs its
workspace support available. CLI paths, arguments and permissions need smoke tests against
the installed versions. New backends intentionally do not permit arbitrary AX frame changes:
there is no verified floating-window query implemented for them. Rooms and exact custom
layouts remain native-only. Unsupported actions fail explicitly. The app does not parse or
modify another manager's hotkey configuration; assign each chord to one owner.
The legacy AeroSpace/yabai floating check is retained with a same-application focus guard;
that guard is not a persistent exact window identifier. There is no new full window-layout
persistence implementation. The process timeout requests termination of the CLI, not the
window manager itself.

References for backend command verification:
- https://github.com/nikitabobko/AeroSpace
- https://github.com/koekeishiya/yabai
- https://github.com/acsandmann/rift
- https://github.com/OmniNull/OmniWM
- https://github.com/KiwiCanopy/KiwiDesk

## Extensions

Retain optional strict version-1 manifest metadata from the previous contract patch.
Stage a complete payload in a hidden directory on the same volume, validate it, then publish
with an exclusive rename or atomically exchange it with the previous version. If staging or
exchange fails, the previous directory remains in place. Never touch extension user data
as part of installation. Refuse a flattened-name collision, traversal, symlinks and special
files in the payload, and incomplete versioned builds. This intentionally rejects legacy
packages that rely on symlinked assets or dependencies: package them as self-contained files.
This is a disk-level transaction, not a sandbox or a guarantee of safe live replacement:
quiescing active extension runtimes, serializing concurrent updates across processes, and
cleaning up stale hidden stages after a crash remain separate work. The external extensions
repository, remote registry, browser companion and permission model are not part of this patch.

## Verification

Run on macOS from the patched checkout:

```bash
./Scripts/run-tests.sh ext-contract-test
./Scripts/test-shared-window-managers.sh
./Scripts/test-extension-install-transaction.sh
./.1tuz/gate.sh
```

Then build the app with Xcode and verify actual workspace switching and move, keyboard and
voice entry points, failure when the manager stops, focus restoration, arbitrary-size refusal,
Floating/Rooms guards, UI selection persistence, and extension upgrades with data retained.
Test each running manager and a simultaneous-manager configuration. Test fork queue replay
against the recorded upstream before publishing. The portable policy harness does not prove
CLI compatibility or UI behavior; the Darwin rename test must run on macOS.
