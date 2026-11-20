import AppKit
import Foundation

enum SpeechRuntimeStatus: Equatable, Sendable {
    case unknown
    case notInstalled            // no app, no agent, no token
    case stopped                 // installed, not answering, not yet started
    case starting
    case ready(models: [SpeechRuntimeModel])
    case needsModel              // ready but the selected model is not available
    case failed(String)

    var summary: String {
        switch self {
        case .unknown: return String(localized: "Speech Runtime status unknown")
        case .notInstalled: return String(localized: "Speech Runtime is not installed")
        case .stopped: return String(localized: "Speech Runtime is stopped")
        case .starting: return String(localized: "Starting Speech Runtime…")
        case .ready(let models):
            let names = models.map(\.model).joined(separator: ", ")
            return names.isEmpty
                ? String(localized: "Speech Runtime is ready")
                : String(localized: "Speech Runtime is ready · \(names)")
        case .needsModel: return String(
            localized: "Speech Runtime is ready, but the selected model is not available. Install it in Speech Runtime.")
        case .failed(let reason): return String(localized: "Speech Runtime error: \(reason)")
        }
    }
}

@MainActor
protocol SpeechRuntimeTransporting: AnyObject {
    var appInstalled: Bool { get }
    var agentPlistPath: String? { get }
    var tokenPresent: Bool { get }
    func health() async -> Bool
    func models() async throws -> [SpeechRuntimeModel]
    func launchctl(_ arguments: [String]) async -> (exit: Int32, output: String)
    func openApp() -> Bool
    func sleep(for duration: Duration) async
}

/// The real Mac: URL requests, app lookup, launchctl subprocesses.
@MainActor
final class SpeechRuntimeDeviceTransport: SpeechRuntimeTransporting {
    private let home: URL
    private let session: URLSession
    private let decoder = JSONDecoder()

    private static let appBundleIdentifier = "com.speechruntime.app"

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    private var support: URL {
        home.appendingPathComponent("Library/Application Support/SpeechRuntime", isDirectory: true)
    }

    var tokenURL: URL { support.appendingPathComponent("token") }

    var appInstalled: Bool { installedAppURL != nil }

    var agentPlistPath: String? {
        let url = support.appendingPathComponent("com.speechruntime.agent.plist")
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    var tokenPresent: Bool {
        (try? String(contentsOf: tokenURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// The installed app, wherever the user put it: workspace lookup first, then both
    /// application folders. Never invented.
    var installedAppURL: URL? {
        if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: Self.appBundleIdentifier) { return url }
        for directory in ["/Applications", "\(home.path)/Applications"] {
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent("Speech Runtime.app", isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    func health() async -> Bool {
        var request = URLRequest(url: SpeechRuntimeLaunchPlan.baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 2
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["ok"] as? Bool == true
        else { return false }
        return true
    }

    func models() async throws -> [SpeechRuntimeModel] {
        var request = URLRequest(url: SpeechRuntimeLaunchPlan.baseURL.appendingPathComponent("v1/models"))
        request.timeoutInterval = 4
        request.setValue("Bearer " + (try launchToken()), forHTTPHeaderField: "Authorization")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SpeechVoiceFailure(
                detail: "Cannot reach Speech Runtime at 127.0.0.1:8477: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SpeechVoiceFailure(detail: "Speech Runtime did not list models")
        }
        return try decoder.decode(SpeechRuntimeModels.self, from: data).models
    }

    /// /bin/launchctl with explicit arguments, never a shell string.
    func launchctl(_ arguments: [String]) async -> (exit: Int32, output: String) {
        await Self.runLaunchctl(arguments)
    }

    @concurrent
    private static func runLaunchctl(_ arguments: [String]) async -> (exit: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SpeechRuntimeLaunchPlan.launchctlPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        let exit: ProcessExit
        do { exit = try process.runObservingExit() } catch { return (-1, error.localizedDescription) }
        exit.wait()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    func openApp() -> Bool {
        guard let url = installedAppURL else { return false }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    func sleep(for duration: Duration) async {
        try? await Task.sleep(for: duration)
    }

    private func launchToken() throws -> String {
        guard let raw = try? String(contentsOf: tokenURL, encoding: .utf8) else {
            throw SpeechVoiceFailure(
                detail: "Speech Runtime token not found. Turn on Speech Runtime.app first.")
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw SpeechVoiceFailure(detail: "Speech Runtime token is empty") }
        return token
    }
}

/// Owns the Speech Runtime lifecycle for the app: probe, start through the runtime's own
/// mechanisms, model discovery, and pointing the user at where models are installed.
@MainActor
final class SpeechRuntimeService {
    private(set) var status: SpeechRuntimeStatus = .unknown

    private let transport: any SpeechRuntimeTransporting
    private let userID: uid_t
    private let home: URL
    private let pollInterval: Duration
    private let pollTimeout: Duration
    private var inFlight: Task<Bool, Never>?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         userID: uid_t = getuid(),
         transport: (any SpeechRuntimeTransporting)? = nil,
         pollInterval: Duration = .milliseconds(500),
         pollTimeout: Duration = .seconds(20)) {
        self.home = home
        self.userID = userID
        self.pollInterval = pollInterval
        self.pollTimeout = pollTimeout
        self.transport = transport ?? SpeechRuntimeDeviceTransport(home: home)
    }

    var tokenURL: URL {
        home.appendingPathComponent("Library/Application Support/SpeechRuntime/token")
    }

    var launchAgentPlistURL: URL? {
        guard let path = transport.agentPlistPath else { return nil }
        return URL(fileURLWithPath: path)
    }

    var installedAppURL: URL? {
        (transport as? SpeechRuntimeDeviceTransport)?.installedAppURL
    }

    private func environment(agentLoaded: Bool) -> SpeechRuntimeEnvironment {
        SpeechRuntimeEnvironment(
            appInstalled: transport.appInstalled,
            agentPlistInstalled: transport.agentPlistPath != nil,
            agentLoaded: agentLoaded,
            tokenPresent: transport.tokenPresent)
    }

    /// The label the installed plist declares, so a foreign job is addressed by its own name.
    private var agentLabel: String {
        guard let path = transport.agentPlistPath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let label = SpeechRuntimeLaunchPlan.label(fromPlistData: data)
        else { return SpeechRuntimeLaunchPlan.agentLabel }
        return label
    }

    func probe(model: String? = nil) async -> SpeechRuntimeStatus {
        if await transport.health() {
            let listed = try? await transport.models()
            if let model {
                status = finish(model: model, models: listed)
            } else {
                status = .ready(models: listed ?? [])
            }
        } else {
            status = environment(agentLoaded: false).isInstalled ? .stopped : .notInstalled
        }
        return status
    }

    /// Probe loopback, then start the installed service through its own mechanism — never a
    /// second copy, never a model download, never a foreground window unless nothing else works.
    func ensureRunning(model: String) async -> SpeechRuntimeStatus {
        if await transport.health() {
            status = finish(model: model, models: try? await transport.models())
            return status
        }

        let running = await startedOnce()
        if running {
            status = finish(model: model, models: try? await transport.models())
        }
        return status
    }

    private func startedOnce() async -> Bool {
        if let inFlight { return await inFlight.value }
        let task = Task { await self.launchAndWait() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    private func launchAndWait() async -> Bool {
        guard environment(agentLoaded: false).isInstalled else {
            status = .notInstalled
            return false
        }

        let loaded = await isAgentLoaded()
        switch SpeechRuntimeLaunchPlan.action(for: environment(agentLoaded: loaded)) {
        case .kickstart:
            let restarted = await transport.launchctl(
                SpeechRuntimeLaunchPlan.kickstartArguments(userID: userID, label: agentLabel))
            guard restarted.exit == 0 else {
                status = .failed(String(localized: "Could not restart the Speech Runtime agent"))
                return false
            }
        case .bootstrap:
            guard let path = transport.agentPlistPath else {
                status = .failed(String(localized: "Speech Runtime launch agent is missing"))
                return false
            }
            let bootstrapped = await transport.launchctl(
                SpeechRuntimeLaunchPlan.bootstrapArguments(plistPath: path, userID: userID))
            // Only "already bootstrapped" answers non-zero with the job absent, and `print` says
            // which of the two it was. That state is fixed by kickstart, not by a retry.
            if bootstrapped.exit != 0, await !isAgentLoaded() {
                let restarted = await transport.launchctl(
                    SpeechRuntimeLaunchPlan.kickstartArguments(userID: userID, label: agentLabel))
                guard restarted.exit == 0, await isAgentLoaded() else {
                    status = .failed(String(localized: "Could not start the Speech Runtime agent"))
                    return false
                }
            }
        case .openApp:
            guard transport.openApp() else {
                status = .failed(String(localized: "Could not open Speech Runtime"))
                return false
            }
        case .nothingInstalled:
            status = .notInstalled
            return false
        case .unavailable(let reason):
            status = .failed(reason)
            return false
        }

        status = .starting
        let deadline = ContinuousClock.now.advanced(by: pollTimeout)
        while ContinuousClock.now < deadline {
            await transport.sleep(for: pollInterval)
            if Task.isCancelled { break }
            if await transport.health() { return true }
        }
        let seconds = max(1, Int(pollTimeout.components.seconds))
        status = .failed(String(localized: "Speech Runtime did not answer within \(seconds) seconds"))
        return false
    }

    private func finish(model: String, models: [SpeechRuntimeModel]?) -> SpeechRuntimeStatus {
        guard let models else { return .needsModel }
        if model.isEmpty || models.contains(where: { $0.model == model }) {
            return .ready(models: models)
        }
        return .needsModel
    }

    /// Authenticated model listing. Model downloads belong to Speech Runtime.app, never here.
    func models() async throws -> [SpeechRuntimeModel] {
        try await transport.models()
    }

    /// Where the user installs models: opens the installed Speech Runtime app, its own UI.
    func openRuntimeApp() -> Bool {
        transport.openApp()
    }

    /// `launchctl print` answers 0 only for a loaded job in the caller's GUI domain.
    private func isAgentLoaded() async -> Bool {
        let printed = await transport.launchctl(
            ["print", SpeechRuntimeLaunchPlan.agentTarget(userID: userID, label: agentLabel)])
        return SpeechRuntimeLaunchPlan.isAgentLoaded(printExitStatus: printed.exit)
    }
}
