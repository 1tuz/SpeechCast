import AppKit
import Darwin

/// Select the same window-manager process that StableBar uses, not a second tiler.
enum SharedWindowManagerSelection: String, CaseIterable, Identifiable {
    case automatic, native, aerospace, yabai, rift, omniwm, kiwidesk

    static let defaultsKey = "speechcast.windowManager.provider"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic (StableBar)"
        case .native: "SpeechCast (Accessibility)"
        case .aerospace: "AeroSpace"
        case .yabai: "yabai"
        case .rift: "Rift"
        case .omniwm: "OmniWM"
        case .kiwidesk: "KiwiDesk"
        }
    }
}

/// The CLI executable names deliberately differ from workspaceSource for Rift and OmniWM.
enum SharedWindowManagerBackend: String, CaseIterable, Sendable {
    case aerospace, yabai, rift, omniwm, kiwidesk

    var cliName: String {
        switch self {
        case .rift: "rift-cli"
        case .omniwm: "omniwmctl"
        default: rawValue
        }
    }

    var appExecutableName: String? {
        switch self {
        case .aerospace: "AeroSpace"
        case .omniwm: "OmniWM"
        case .kiwidesk: "KiwiDesk"
        case .yabai, .rift: nil
        }
    }

    var probe: [String] {
        switch self {
        case .aerospace: ["list-workspaces", "--focused"]
        case .yabai: ["-m", "query", "--spaces", "--space"]
        case .rift: ["query", "workspaces"]
        case .omniwm: ["ping"]
        case .kiwidesk: ["get_state"]
        }
    }

}

enum SharedWindowManagerPolicy {
    typealias Backend = SharedWindowManagerBackend

    enum Choice: Equatable {
        case native
        case external(Backend)
        case unavailable(String)
    }

    static func choose(
        _ selection: SharedWindowManagerSelection, stableBarSource: String?, running: Set<Backend>
    ) -> Choice {
        guard running.count <= 1 else {
            return .unavailable("Multiple window managers are running. Stop all but one.")
        }
        if selection == .native {
            guard running.isEmpty else {
                return .unavailable("A window manager is running. Select it to manage its windows.")
            }
            return .native
        }
        if selection != .automatic, let backend = Backend(rawValue: selection.rawValue) {
            return .external(backend)
        }
        if let source = stableBarSource?.lowercased(), source != "spaces" {
            guard let backend = Backend(rawValue: source) else {
                return .unavailable("StableBar uses \(source). Choose a window manager explicitly.")
            }
            return .external(backend)
        }
        // Spaces is a bar display source, not evidence that no tiler owns the windows.
        if let backend = running.first { return .external(backend) }
        return .native
    }

    /// Only commands that a tiler owns. In particular, arbitrary half/third
    /// placements are NOT sent through AX for tiled windows behind its back.
    static func command(_ id: WindowCommand.ID, for backend: Backend) -> [String]? {
        switch backend {
        case .aerospace:
            switch id {
            case .previousSpace: return ["workspace", "prev"]
            case .nextSpace: return ["workspace", "next"]
            case .nextDisplay: return ["move-node-to-monitor", "next"]
            case .previousDisplay: return ["move-node-to-monitor", "prev"]
            case .moveLeft: return ["move", "left"]
            case .moveRight: return ["move", "right"]
            case .moveUp: return ["move", "up"]
            case .moveDown: return ["move", "down"]
            case .makeLarger: return ["resize", "smart", "+50"]
            case .makeSmaller: return ["resize", "smart", "-50"]
            case .maximize: return ["fullscreen", "on"]
            case .toggleFullscreen: return ["macos-native-fullscreen"]
            case .minimize: return ["macos-native-minimize"]
            case .closeWindow: return ["close"]
            default: return nil
            }
        case .yabai:
            switch id {
            case .previousSpace: return ["-m", "space", "--focus", "prev"]
            case .nextSpace: return ["-m", "space", "--focus", "next"]
            case .nextDisplay: return ["-m", "window", "--display", "next"]
            case .previousDisplay: return ["-m", "window", "--display", "prev"]
            case .moveLeft: return ["-m", "window", "--warp", "west"]
            case .moveRight: return ["-m", "window", "--warp", "east"]
            case .moveUp: return ["-m", "window", "--warp", "north"]
            case .moveDown: return ["-m", "window", "--warp", "south"]
            case .toggleFullscreen: return ["-m", "window", "--toggle", "native-fullscreen"]
            case .minimize: return ["-m", "window", "--minimize"]
            case .closeWindow: return ["-m", "window", "--close"]
            default: return nil
            }
        case .rift:
            switch id {
            case .previousSpace: return ["execute", "workspace", "prev"]
            case .nextSpace: return ["execute", "workspace", "next"]
            case .moveLeft: return ["execute", "layout", "move-node", "left"]
            case .moveRight: return ["execute", "layout", "move-node", "right"]
            case .moveUp: return ["execute", "layout", "move-node", "up"]
            case .moveDown: return ["execute", "layout", "move-node", "down"]
            case .makeLarger: return ["execute", "window", "resize-grow", "--orientation", "smart"]
            case .makeSmaller: return ["execute", "window", "resize-shrink", "--orientation", "smart"]
            case .closeWindow: return ["execute", "window", "close"]
            default: return nil
            }
        case .omniwm:
            switch id {
            case .previousSpace: return ["command", "switch-workspace", "prev"]
            case .nextSpace: return ["command", "switch-workspace", "next"]
            case .moveLeft: return ["command", "move", "left"]
            case .moveRight: return ["command", "move", "right"]
            case .moveUp: return ["command", "move", "up"]
            case .moveDown: return ["command", "move", "down"]
            // Dwindle only; Niri has a different, span-based sizing API.
            case .makeLarger: return ["command", "resize-focused", "grow"]
            case .makeSmaller: return ["command", "resize-focused", "shrink"]
            case .toggleFullscreen: return ["command", "toggle-native-fullscreen"]
            case .closeWindow: return ["command", "close-focused-window"]
            default: return nil
            }
        case .kiwidesk:
            switch id {
            case .previousSpace: return ["focus_space_previous"]
            case .nextSpace: return ["focus_space_next"]
            case .moveLeft: return ["swap", "left"]
            case .moveRight: return ["swap", "right"]
            case .moveUp: return ["swap", "up"]
            case .moveDown: return ["swap", "down"]
            case .makeLarger: return ["resize", "x", "50"]
            case .makeSmaller: return ["resize", "x", "-50"]
            case .closeWindow: return ["close_window"]
            default: return nil
            }
        }
    }

    static func workspace(_ index: Int, moveWindow: Bool, backend: Backend) -> [String] {
        let name = String(index)
        switch backend {
        case .aerospace:
            return moveWindow ? ["move-node-to-workspace", "--", name] : ["workspace", "--", name]
        case .yabai:
            return moveWindow ? ["-m", "window", "--space", name] : ["-m", "space", "--focus", name]
        case .rift:
            // Rift indexes workspaces from zero; SpeechCast numbers them from one.
            return ["execute", "workspace", moveWindow ? "move-window" : "switch", String(index - 1)]
        case .omniwm:
            return ["command", moveWindow ? "move-to-workspace" : "switch-workspace", name]
        case .kiwidesk:
            return [moveWindow ? "move_to_space" : "focus_space", name]
        }
    }

}

/// Small, allowlisted CLI adapter. StableBar owns its UI; both apps talk to the
/// same running window manager. Never fall back to AX after an external CLI fails.
@MainActor
enum SharedWindowManagerBridge {
    typealias Backend = SharedWindowManagerBackend
    enum Resolution {
        case native
        case external(Backend, executable: String)
        case unavailable(String)
    }

    static func resolve() -> Resolution {
        let selected = SharedWindowManagerSelection(
            rawValue: UserDefaults.standard.string(forKey: SharedWindowManagerSelection.defaultsKey) ?? "automatic"
        ) ?? .automatic
        let running = Set(Backend.allCases.filter { isRunning($0) })
        switch SharedWindowManagerPolicy.choose(selected, stableBarSource: stableBarSource(), running: running) {
        case .native: return .native
        case .external(let backend): return resolve(backend)
        case .unavailable(let message): return .unavailable(message)
        }
    }

    static func connectionStatus() async -> String {
        switch resolve() {
        case .native: return "Native Accessibility mode (no external manager selected)."
        case .unavailable(let message): return message
        case .external(let backend, let executable):
            do {
                _ = try await execute(backend.probe, executable: executable)
                return "\(backend.rawValue): connected"
            } catch {
                return "\(backend.rawValue): \(error.localizedDescription)"
            }
        }
    }

    private static func resolve(_ backend: Backend) -> Resolution {
        guard isRunning(backend) else {
            return .unavailable("\(backend.rawValue) is not running. Window geometry was not changed.")
        }
        guard let executable = executable(for: backend) else {
            return .unavailable("\(backend.rawValue) CLI was not found. Check your PATH or Homebrew installation.")
        }
        return .external(backend, executable: executable)
    }

    private static func stableBarSource() -> String? {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/stablebar/config.json")
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["workspaceSource"] as? String
    }

    private static func isRunning(_ backend: Backend) -> Bool {
        if backend == .aerospace {
            return !NSRunningApplication.runningApplications(withBundleIdentifier: "bobko.aerospace").isEmpty
        }
        if let appName = backend.appExecutableName {
            return NSWorkspace.shared.runningApplications.contains {
                $0.executableURL?.lastPathComponent.caseInsensitiveCompare(appName) == .orderedSame
                    && !$0.isTerminated
            }
        }
        // yabai and Rift may be launched as per-user background services, without an app bundle.
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        let user = getuid()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        return pids.prefix(Int(max(count, 0))).contains { pid in
            var info = proc_bsdshortinfo()
            guard pid > 0,
                  proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size,
                  info.pbsi_uid == user else { return false }
            return withUnsafeBytes(of: info.pbsi_comm) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            } == backend.rawValue
        }
    }

    private static func executable(for backend: Backend) -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let name = backend.cliName
        // Prefer a CLI belonging to the running GUI app rather than a stale Homebrew link.
        if let appName = backend.appExecutableName {
            let bundledName = backend == .kiwidesk ? appName : name
            let runningDirs = NSWorkspace.shared.runningApplications.compactMap { app -> URL? in
                guard app.executableURL?.lastPathComponent.caseInsensitiveCompare(appName) == .orderedSame
                else { return nil }
                return app.executableURL?.deletingLastPathComponent()
            }
            for directory in runningDirs {
                let candidate = directory.appendingPathComponent(bundledName).path
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        let dirs = path + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
                           home.appendingPathComponent(".local/bin").path,
                           home.appendingPathComponent("bin").path,
                           home.appendingPathComponent(".cargo/bin").path]
        for directory in dirs {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func command(_ id: WindowCommand.ID, for backend: Backend) -> [String]? {
        SharedWindowManagerPolicy.command(id, for: backend)
    }

    static func workspace(_ index: Int, moveWindow: Bool, backend: Backend) -> [String] {
        SharedWindowManagerPolicy.workspace(index, moveWindow: moveWindow, backend: backend)
    }

    /// No shell interpolation. Private capture files avoid the pipe-buffer deadlock while a
    /// manager writes a JSON response. Cancellation and timeout stop the CLI, never the manager.
    static func execute(_ args: [String], executable: String) async throws -> String {
        try Task.checkCancellation()
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("speechcast-wm-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }
        let outURL = directory.appendingPathComponent("stdout")
        let errURL = directory.appendingPathComponent("stderr")
        guard fm.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              fm.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw SharedWindowManagerError.message("Could not capture window manager output")
        }
        let stdout = try FileHandle(forWritingTo: outURL)
        defer { try? stdout.close() }
        let stderr = try FileHandle(forWritingTo: errURL)
        defer { try? stderr.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while process.isRunning {
            if ContinuousClock.now >= deadline {
                throw SharedWindowManagerError.message("Window manager CLI timed out")
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        try Task.checkCancellation()
        func read(_ url: URL) throws -> String {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard process.terminationStatus == 0 else {
            let error = try read(errURL)
            throw SharedWindowManagerError.message(error.isEmpty ? "Window manager command failed" : error)
        }
        return try read(outURL)
    }

}

private enum SharedWindowManagerError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        guard case .message(let text) = self else { return nil }
        return text
    }
}

/// One funnel for keyboard, palette and speech. A tiler is never silently
/// overridden by our direct Accessibility geometry writes.
@MainActor
final class WindowCommandCoordinator {
    private let settings: AppSettings
    private let paletteCoordinator: PaletteCoordinator
    private let windowMover: WindowMover
    private let spaceSwitcher: SpaceSwitcher
    private let customSizes: CustomWindowSizeStore
    private unowned let core: AppCore

    init(
        settings: AppSettings, paletteCoordinator: PaletteCoordinator, windowMover: WindowMover,
        spaceSwitcher: SpaceSwitcher, customSizes: CustomWindowSizeStore, core: AppCore
    ) {
        self.settings = settings
        self.paletteCoordinator = paletteCoordinator
        self.windowMover = windowMover
        self.spaceSwitcher = spaceSwitcher
        self.customSizes = customSizes
        self.core = core
    }

    func runWindowCommand(id: WindowCommand.ID, voiceFeedback: Bool = false) {
        guard settings.windowManagementEnabled else { return }
        switch SharedWindowManagerBridge.resolve() {
        case .native: runNative(id, voiceFeedback: voiceFeedback)
        case .unavailable(let message): core.showMessage(message, tone: .danger)
        case .external(let backend, let executable):
            runShared(id, backend: backend, executable: executable, voiceFeedback: voiceFeedback)
        }
    }

    /// A numbered workspace is sent only to the shared manager, never imitated
    /// by synthesizing macOS desktop shortcuts.
    func runWorkspace(number: Int, moveWindow: Bool) {
        guard settings.windowManagementEnabled, (1...20).contains(number) else { return }
        switch SharedWindowManagerBridge.resolve() {
        case .native:
            core.showMessage("Choose an external window manager to control numbered workspaces", tone: .neutral)
        case .unavailable(let message): core.showMessage(message, tone: .danger)
        case .external(let backend, let executable):
            if paletteCoordinator.isVisible {
                paletteCoordinator.hidePalette(restoreFocus: moveWindow)
            }
            runCLI(SharedWindowManagerBridge.workspace(number, moveWindow: moveWindow, backend: backend),
                   executable: executable, afterFocusRestore: moveWindow, voiceFeedback: true)
        }
    }

    private func runNative(_ id: WindowCommand.ID, voiceFeedback: Bool) {
        if let direction = SpaceDirection(id) {
            if paletteCoordinator.isVisible { paletteCoordinator.hidePalette(restoreFocus: false) }
            spaceSwitcher.perform(direction)
            return
        }
        placeWindow(id, target: handOffTarget(), voiceFeedback: voiceFeedback)
    }

    private func placeWindow(_ id: WindowCommand.ID, target: WindowTarget?, voiceFeedback: Bool) {
        let outcome = windowMover.perform(
            id, target: target, gap: CGFloat(settings.windowGap), cycle: settings.windowCycle,
            requireReadback: voiceFeedback)
        guard voiceFeedback else { return }
        switch outcome {
        case .changed:
            let message = WindowCommandCatalog.movesOnly.contains(id)
                ? String(localized: "Window moved") : String(localized: "Window changed")
            core.showMessage(message)
        case .unchanged:
            core.showMessage(String(localized: "Window unchanged"), tone: .neutral)
        case .accepted:
            showVoiceCommandAccepted()
        case .failed:
            core.showMessage(String(localized: "Could not apply or verify the window command"), tone: .danger)
        }
    }

    private func showVoiceCommandAccepted() {
        core.showMessage(String(localized: "Command accepted"), tone: .neutral)
    }

    private func runShared(_ id: WindowCommand.ID, backend: SharedWindowManagerBridge.Backend,
                           executable: String, voiceFeedback: Bool) {
        let command = SharedWindowManagerBridge.command(id, for: backend)
        if id == .previousSpace || id == .nextSpace {
            if paletteCoordinator.isVisible { paletteCoordinator.hidePalette(restoreFocus: false) }
            if let command { runCLI(command, executable: executable, voiceFeedback: voiceFeedback) }
            return
        }
        let target = handOffTarget()
        Task { [weak self] in
            // Let the launcher return focus before asking the external manager
            // which window is focused (especially on a cold voice invocation).
            try? await Task.sleep(for: .milliseconds(120))
            guard let self else { return }
            do {
                guard self.targetStillFocused(target) else {
                    self.core.showMessage("Window focus changed; command cancelled", tone: .neutral)
                    return
                }
                guard let command else {
                    self.core.showMessage(
                        "This action has no safe mapping for the selected manager or current window layout.",
                        tone: .neutral)
                    return
                }
                _ = try await SharedWindowManagerBridge.execute(command, executable: executable)
                if voiceFeedback { self.showVoiceCommandAccepted() }
            } catch {
                self.core.showMessage(error.localizedDescription, tone: .danger)
            }
        }
    }

    private func runCLI(_ args: [String], executable: String, afterFocusRestore: Bool = false,
                        voiceFeedback: Bool) {
        Task { [weak self] in
            if afterFocusRestore { try? await Task.sleep(for: .milliseconds(120)) }
            do {
                _ = try await SharedWindowManagerBridge.execute(args, executable: executable)
                if voiceFeedback { self?.showVoiceCommandAccepted() }
            } catch {
                self?.core.showMessage(error.localizedDescription, tone: .danger)
            }
        }
    }

    func runCustomWindowSize(id: UUID) {
        guard settings.windowManagementEnabled, let size = customSizes.size(id: id) else { return }
        switch SharedWindowManagerBridge.resolve() {
        case .native:
            windowMover.perform(size, target: handOffTarget(), gap: CGFloat(settings.windowGap))
        case .unavailable(let message): core.showMessage(message, tone: .danger)
        case .external:
            core.showMessage("Custom pixel sizing is unavailable while a window manager is running.", tone: .neutral)
        }
    }

    private func targetStillFocused(_ target: WindowTarget?) -> Bool {
        switch (target, WindowTarget.current()) {
        case (.some(.external(let expected)), .some(.external(let current))):
            return expected.processIdentifier == current.processIdentifier
        case (.some(.own(let expected)), .some(.own(let current))):
            return expected === current
        default: return false
        }
    }

    /// The window to place, read before the palette hides and hands focus back to it.
    private func handOffTarget() -> WindowTarget? {
        guard paletteCoordinator.isVisible else { return WindowTarget.current() }
        let target = WindowTarget.behindPalette(
            ownWindow: paletteCoordinator.previousOwnWindow, app: paletteCoordinator.targetApp)
        paletteCoordinator.hidePalette(restoreFocus: true)
        return target
    }
}
