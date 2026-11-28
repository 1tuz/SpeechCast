# SpeechCast: Raycast voice actions and a shared window manager

## Voice actions

Enable Extensions and local voice commands in Settings. Installed, visible Raycast
commands appear in the searchable voice catalog, where they can be assigned aliases.

- `Запусти расширение Find Issue` resolves the extension command by name.
- `Запусти расширение Find Issue с текстом DEV-123` passes `DEV-123` to the one declared text argument.
- Assign the alias `найди задачу` to that command to say `найди задачу DEV-123`.

All spoken extension launches require confirmation because JavaScript view commands
may still perform side effects. If a command declares multiple, non-text or required
arguments that were not supplied, SpeechCast does not guess them or run it silently.
It offers the normal launcher form for required arguments.

## Sharing window management with StableBar

Select **Settings > Window Management > Window manager**:

- **Automatic (StableBar)** reads `workspaceSource` from
  `~/.config/stablebar/config.json` when present, then falls back to a running
  AeroSpace or yabai. The config may use includes/layers; in that case explicitly
  choose the provider if automatic detection does not match your active widget.
- **AeroSpace** or **yabai** requires the existing manager process and its CLI
  installed on PATH or in `/opt/homebrew/bin` or `/usr/local/bin`.
- **SpeechCast (Accessibility)** uses independent window controls only when no supported tiler is running.

When a shared tiler is active, window movement, monitor/workspace changes, close,
minimize and fullscreen commands go through the manager CLI. Unsupported half/third/preset
geometry and custom pixel sizing are rejected while a tiler runs. Saved pixel layouts,
rooms and auto-layout-on-app-launch are suspended. If several supported managers run at once,
SpeechCast refuses window commands until only one remains. StableBar remains the presenter
of workspaces; no second tiler or daemon is installed. Shortcuts must be assigned to one app.

Voice examples (requires AeroSpace/yabai and existing destination workspace):

- `Отправь окно на рабочий стол 3`
- `Переключись на рабочий стол 3`

The workspace commands accept numeric IDs 1 through 20. yabai uses Mission Control
space indices; AeroSpace uses workspace names `1`, `2`, ... instead. Unsupported
providers (OmniWM, Rift) are not rewritten to an unrelated backend.

Source changes stay in `.1tuz/patches/0024-raycast-voice-shared-window-manager.patch`.
