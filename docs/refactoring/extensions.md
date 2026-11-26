# SpeechCast extension boundary

Status: staged refactoring proposal with a small executable first step. The initial patch was
prepared against SpeechCast commit `606e1357357961edabccbf0470e22d339a1b77e4`.

## What this step changes

`ExtensionManifest` recognizes an optional, strict `speechcast` object in the existing `package.json`.
The parser is on the current installation and discovery paths. The standalone `ext-contract-test`
harness compiles that production source and checks both versioned and unversioned packages.
The separate `SpeechCast-Extensions` starter supplies the matching package schema, build tooling
and a source example. No extension runtime is replaced.

The root patch also carries the same source, test and documentation changes in
`.1tuz/patches/0025-extension-contract.patch`. The fork-sync workflow reconstructs the fork from
upstream plus that queue; a source-only change would otherwise disappear on a later sync.
Keep the queue patch aligned whenever changing this contract, and verify the whole queue against
the recorded upstream before publishing. Never apply the queue patch a second time to the fork
tree that already contains it.

This step is not a performance optimization, process sandbox, extension store, or a completed
AppCore refactor. No measurements of the running macOS application accompany it.

## Responsibility split

| Repository | Owns |
| --- | --- |
| `SpeechCast` | Native launcher and voice integration; settings and consent; hotkeys and window lifecycle; SwiftUI rendering; JavaScriptCore host; host capabilities; MCP/provider transport and trust |
| `SpeechCast-Extensions` | TypeScript extension sources; build and validation tooling; package examples; release metadata; extension-specific tests and documentation |
| `SpeechRuntime` | Existing speech recognition service and its lifecycle; not moved by this work |

Swift remains the language for native host capabilities and lifecycle. TypeScript compiles to
CommonJS for extension commands and to WebExtension bundles for a browser companion. Node is a
development/build dependency for these packages, not a newly required SpeechCast execution runtime.
An external MCP server may have its own runtime dependency; document that separately.

Do not introduce another SDK that duplicates `@raycast/api`. Start with the subset the host already
implements. Add a SpeechCast-specific API only for a concrete capability that cannot use the existing
surface, then version its schema and test its native implementation and bundle together.

## Version contract

The only accepted v1 metadata object is:

```json
{"schemaVersion": 1, "apiVersion": 1}
```

- Absence means the existing unversioned Raycast path, with unchanged behavior.
- Presence requires both numeric versions and no additional keys. `null` is not absence.
- Unsupported metadata fails parsing, including an unknown field such as `permissions`.
- `schemaVersion` is the object format. `apiVersion` is the supported host generation, not the npm
  version of `@raycast/api`. It does not assert complete Raycast compatibility.
- A package's release `version` is separate. The native updater does not acquire semantic-version
  or registry behavior from this patch.

The native parser and repository validator must be changed together for a future generation.
Retain fixtures with missing metadata, valid metadata, booleans, fractions, missing fields, unknown
fields and unsupported generations. JSON Schema treats `1.0` and `1e0` as the integer value 1; the
native parser follows that same rule.

## Subsequent changes, each independently reviewable

### 1. Establish measurements and narrow ownership boundaries

Use the recipes in `docs/testing.md`. Record launch time, idle RSS, palette latency and memory after
closing a view/no-view/menu-bar extension. Compare the same build configuration, package set and
workload. Measure with optional features disabled and enabled. A long `AppCore.swift` does not by
itself prove excessive memory use.

Keep `AppCore` as the composition/lifetime root. Extract policy only where a current responsibility
is mixed with another and a real caller can consume a narrower interface. In particular, separate
extension installation/update decisions from running a foreground session without creating a second
owner, parallel singleton or unused dependency-injection framework. Preserve lazy startup and
existing feature-off teardown.

Do not move native clipboard, hotkeys, dictation, window management, calendar or calculator into
JavaScript merely to shorten the core. External service integrations and optional tools are the
first candidates for separate packages. Preserve command IDs, aliases, hotkeys, preferences,
channel isolation and the upstream patch queue.

### 2. Make package installation and updates transactional

Use the existing `ExtensionCatalog` and version/update surfaces. Stage a new package outside the
active install, validate manifest and all required bundles, reject unsafe paths and links, verify
release integrity, then atomically replace the active package with a rollback path. Stop an affected
session through its existing owner. Preserve extension data and command identities.

The current installer removes the destination before copying files and can fail partway through;
repair this before introducing automatic updates from a second catalog. A checksum detects changed
bytes; it does not establish publisher trust by itself. Define the release signing/trust model
separately, including who may publish the registry. An empty starter registry is not a working
installation source.

### 3. Design enforceable capabilities and execution isolation

The current filesystem and process shims are broad. A declaration in JSON alone cannot restrict
them. Introduce an immutable extension identity and approved scope at each host-call boundary,
including synchronous Node shims, network access, clipboard, credentials and process execution.
Keep grants local to this app channel and outside imported settings/backups.

A helper process improves crash containment and makes a stuck synchronous JavaScript task
terminable. It is only a security boundary when combined with OS restrictions and brokered access;
an unsandboxed helper with arbitrary shell execution bypasses narrower API permissions. Specify
which existing packages require an explicitly trusted mode before changing default compatibility.
Do not label this starter's packages sandboxed.

### 4. Consolidate command exposure using existing catalogs

Start from `Launcher/Model/CommandCatalog.swift`, `CommandID`, `SettingsTab.ownedCommands`, the voice
command catalog/router and the extension manager's existing entries. Identify duplicated metadata
and dispatch paths before introducing a shared descriptor. Do not add a competing global registry.

Model actual action inputs, outputs, cancellation and permission requirements where shared
execution is needed. Launcher, voice and AI can then consume the same suitable action metadata.
A command that opens a view is not automatically a callable AI tool; opt tools in explicitly.
Keep the existing MCP manager, OAuth manager, provider routing and per-chat trust selection.

### 5. Add the browser companion as one complete feature

Treat browser code, its long-lived connection, the launcher view and MCP tools as separate parts of
one feature. A short-lived JavaScriptCore command context cannot own the browser connection across
palette closes. Reuse the existing MCP client for an initial external browser server evaluation;
do not rewrite a working server into Swift solely for language uniformity.

Evaluate Firefox and Chromium separately, including the intended Zen profile. A Chromium debugger
implementation is not portable to Firefox by renaming its manifest. For a native connection, define
pairing/authentication, session and tab ownership, request bounds, cancellation and disconnect
behavior. Treat page content as data, not instructions that can authorize additional capabilities.
Read-only context retrieval should precede actions with side effects.

## Validation before merging this starter

On macOS with the repository's Xcode/toolchain:

```sh
./Scripts/run-tests.sh ext-contract-test
./Scripts/run-tests.sh ext-refresh-test
./Scripts/run-tests.sh ext-test
./Scripts/run-tests.sh
./Scripts/lint.sh
xcodebuild -project Tinycast.xcodeproj -scheme Tinycast -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Import the built example using Add from folder, run it, close it, and confirm existing Raycast
packages and aliases still work. Try invalid metadata and confirm it cannot be installed. Disable
extensions and confirm no commands, menu items or background work remain. A JavaScript build check
on Linux is not a substitute for this native smoke test.

Replay the fork patch queue on the recorded upstream in a disposable checkout and run the fork gate
before publication. Static patch application against the current fork verifies the patch's starting
point, not a future upstream merge or native compilation.
