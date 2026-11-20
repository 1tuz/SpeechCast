import AppKit
import Darwin

/// Select the same window-manager process that StableBar uses, not a second tiler.
enum SharedWindowManagerSelection: String, CaseIterable, Identifiable {
    case automatic, native, aerospace, yabai

    static let defaultsKey = "speechcast.windowManager.provider"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic (StableBar)"
        case .native: "SpeechCast (Accessibility)"
        case .aerospace: "AeroSpace"
        case .yabai: "yabai"
        }
    }
}

/// Small, allowlisted CLI adapter. StableBar continues to own only its UI; both
/// apps talk to the *same running* AeroSpace/yabai process and its workspaces.
@MainActor
enum SharedWindowManagerBridge {
    enum Backend: String { case aerospace, yabai }
    enum Resolution {
        case native
        case external(Backend, executable: String)
        case unavailable(String)
    }

    static func resolve() -> Resolution {
        let selected = SharedWindowManagerSelection(
            rawValue: UserDefaults.standard.string(forKey: SharedWindowManagerSelection.defaultsKey) ?? "automatic"
        ) ?? .automatic
        switch selected {
        case .native: return .native
        case .aerospace: return resolve(.aerospace)
        case .yabai: return resolve(.yabai)
        case .automatic:
            // StableBar's explicit workspaceSource takes precedence over an incidental
            // background window manager. Its other sources are not emulated here.
            if let configured = stableBarSource() {
                switch configured {
                case "aerospace": return resolve(.aerospace)
                case "yabai": return resolve(.yabai)
                case "spaces": return .native
                default: return .unavailable("StableBar uses \(configured). Select a compatible manager or native mode.")
                }
            }
            if isRunning(.aerospace) { return resolve(.aerospace) }
            if isRunning(.yabai) { return resolve(.yabai) }
            return .native
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
        switch backend {
        case .aerospace:
            return !NSRunningApplication.runningApplications(withBundleIdentifier: "bobko.aerospace").isEmpty
        case .yabai:
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
                } == "yabai"
            }
        }
    }

    private static func executable(for backend: Backend) -> String? {
        let name = backend.rawValue
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let dirs = path + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for directory in dirs {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
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
        }
    }

    static func workspace(_ index: Int, moveWindow: Bool, backend: Backend) -> [String] {
        let name = String(index)
        switch backend {
        case .aerospace:
            return moveWindow ? ["move-node-to-workspace", "--", name] : ["workspace", "--", name]
        case .yabai:
            return moveWindow ? ["-m", "window", "--space", name] : ["-m", "space", "--focus", name]
        }
    }

    /// Only pixel-geometry commands need to ask whether AX would fight a tiler.
    static func requiresFloatingCheck(_ id: WindowCommand.ID) -> Bool {
        switch id {
        case .previousSpace, .nextSpace, .nextDisplay, .previousDisplay,
             .toggleFullscreen, .minimize, .closeWindow:
            return false
        default: return true
        }
    }

    /// No shell interpolation. Reads a small result and times out a stalled CLI.
    static func execute(_ args: [String], executable: String) async throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let deadline = ContinuousClock.now + .seconds(3)
        while process.isRunning {
            if ContinuousClock.now >= deadline {
                process.terminate()
                throw SharedWindowManagerError.message("Window manager CLI timed out")
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw SharedWindowManagerError.message(error.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ? "Window manager command failed" : error)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func focusedWindowIsFloating(backend: Backend, executable: String) async throws -> Bool {
        switch backend {
        case .aerospace:
            return try await execute(
                ["list-windows", "--focused", "--format", "%{window-layout}"],
                executable: executable) == "floating"
        case .yabai:
            let output = try await execute(["-m", "query", "--windows", "--window"], executable: executable)
            guard let data = output.data(using: .utf8),
                  let window = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let floating = window["is-floating"] as? Bool else {
                throw SharedWindowManagerError.message("Could not read yabai's focused window layout")
            }
            return floating
        }
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
            core.showMessage("Choose AeroSpace or yabai to control numbered workspaces", tone: .neutral)
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
                if SharedWindowManagerBridge.requiresFloatingCheck(id) {
                    let floating = try await SharedWindowManagerBridge.focusedWindowIsFloating(
                        backend: backend, executable: executable)
                    if floating {
                        self.placeWindow(id, target: target, voiceFeedback: voiceFeedback)
                        return
                    }
                }
                guard let command else {
                    self.core.showMessage(
                        "This geometry action is unavailable for a tiled window. Use the manager's layout.",
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

    /// Custom frames still work for floating windows; a managed tile is not resized behind
    /// AeroSpace/yabai's back, since that would fight its own layout on every refresh.
    func runCustomWindowSize(id: UUID) {
        guard settings.windowManagementEnabled, let size = customSizes.size(id: id) else { return }
        switch SharedWindowManagerBridge.resolve() {
        case .native:
            windowMover.perform(size, target: handOffTarget(), gap: CGFloat(settings.windowGap))
        case .unavailable(let message): core.showMessage(message, tone: .danger)
        case .external(let backend, let executable):
            let target = handOffTarget()
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard let self else { return }
                do {
                    guard try await SharedWindowManagerBridge.focusedWindowIsFloating(
                        backend: backend, executable: executable) else {
                        self.core.showMessage("Custom sizing is available only for floating windows", tone: .neutral)
                        return
                    }
                    self.windowMover.perform(size, target: target, gap: CGFloat(self.settings.windowGap))
                } catch { self.core.showMessage(error.localizedDescription, tone: .danger) }
            }
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
