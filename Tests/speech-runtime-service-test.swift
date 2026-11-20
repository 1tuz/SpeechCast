import Foundation

@main
@MainActor
struct SpeechRuntimeServiceTest {
    static var failures = 0

    static func main() async {
        statusSummaries()
        launchDecisions()
        plistLabelParsing()
        healthJSONDecoding()
        modelsJSONDecoding()
        await ensureRunningRetrySucceeds()
        await ensureRunningTimeoutFailsThenRecovers()
        await loadedAgentIsKickstartedOnce()
        await unloadedAgentIsBootstrappedOnce()
        await appOnlyOpensTheApp()
        await nothingInstalledShortCircuits()
        await concurrentEnsureRunningIsCoalesced()
        await modelRequirements()
        print(failures == 0 ? "All Speech Runtime service checks passed"
                           : "\(failures) Speech Runtime service check(s) failed")
        if failures > 0 { exit(1) }
    }

    static func check(_ description: String, _ condition: Bool) {
        print((condition ? "PASS  " : "FAIL  ") + description)
        if !condition { failures += 1 }
    }

    static func statusSummaries() {
        check("unknown has a summary",
              !SpeechRuntimeStatus.unknown.summary.isEmpty)
        check("notInstalled names the missing install",
              SpeechRuntimeStatus.notInstalled.summary == "Speech Runtime is not installed")
        check("stopped names the stopped state",
              SpeechRuntimeStatus.stopped.summary == "Speech Runtime is stopped")
        check("starting names progress",
              SpeechRuntimeStatus.starting.summary == "Starting Speech Runtime…")
        let model = SpeechRuntimeModel(model: "parakeet-ultra", loaded: true,
                                       capabilities: SpeechRuntimeModel.Capabilities(streamingSessions: true))
        check("ready lists the models",
              SpeechRuntimeStatus.ready(models: [model]).summary
                  == "Speech Runtime is ready · parakeet-ultra")
        check("ready with no models stays short",
              SpeechRuntimeStatus.ready(models: []).summary == "Speech Runtime is ready")
        check("ready with several models joins names",
              SpeechRuntimeStatus.ready(models: [model, SpeechRuntimeModel(
                  model: "whisper-small", loaded: false, capabilities: nil)]).summary
                  == "Speech Runtime is ready · parakeet-ultra, whisper-small")
        check("needsModel points at Speech Runtime",
              SpeechRuntimeStatus.needsModel.summary.contains("model"))
        check("failed carries its reason",
              SpeechRuntimeStatus.failed("boom").summary == "Speech Runtime error: boom")
    }

    static func launchDecisions() {
        let action = SpeechRuntimeLaunchPlan.action(for:)
        check("nothing installed decides so",
              action(.init(appInstalled: false, agentPlistInstalled: false, agentLoaded: false,
                           tokenPresent: false)) == .nothingInstalled)
        check("a token alone still counts as installed",
              action(.init(appInstalled: false, agentPlistInstalled: false, agentLoaded: false,
                           tokenPresent: true)) != .nothingInstalled)
        check("loaded agent is restarted, not re-registered",
              action(.init(appInstalled: true, agentPlistInstalled: true, agentLoaded: true,
                           tokenPresent: true)) == .kickstart)
        check("unloaded agent is bootstrapped",
              action(.init(appInstalled: true, agentPlistInstalled: true, agentLoaded: false,
                           tokenPresent: true)) == .bootstrap)
        check("plist without an app still bootstraps",
              action(.init(appInstalled: false, agentPlistInstalled: true, agentLoaded: false,
                           tokenPresent: true)) == .bootstrap)
        check("app without an agent falls back to opening it",
              action(.init(appInstalled: true, agentPlistInstalled: false, agentLoaded: false,
                           tokenPresent: true)) == .openApp)
        check("app alone, no token, still opens the app",
              action(.init(appInstalled: true, agentPlistInstalled: false, agentLoaded: false,
                           tokenPresent: false)) == .openApp)
        check("token alone is not startable",
              action(.init(appInstalled: false, agentPlistInstalled: false, agentLoaded: false,
                           tokenPresent: true)) == .unavailable(reason: "Speech Runtime is not fully installed"))
    }

    static func plistLabelParsing() {
        let plist = [
            "Label": "com.speechruntime.agent",
            "ProgramArguments": ["/bin/true"],
        ] as [String: Any]
        let data = (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
            ?? Data()
        check("the agent label is read from the plist",
              SpeechRuntimeLaunchPlan.label(fromPlistData: data) == "com.speechruntime.agent")
        check("a plist without a label parses to nil",
              SpeechRuntimeLaunchPlan.label(fromPlistData: Data("not a plist".utf8)) == nil)
        check("the canonical label is fixed",
              SpeechRuntimeLaunchPlan.agentLabel == "com.speechruntime.agent")
        check("the launchctl target is the gui-domain job",
              SpeechRuntimeLaunchPlan.agentTarget(userID: 501) == "gui/501/com.speechruntime.agent")
        check("launchctl runs from /bin with no shell",
              SpeechRuntimeLaunchPlan.launchctlPath == "/bin/launchctl")
        check("kickstart restarts the registered job",
              SpeechRuntimeLaunchPlan.kickstartArguments(userID: 501)
                  == ["kickstart", "-k", "gui/501/com.speechruntime.agent"])
        check("bootstrap takes the plist path",
              SpeechRuntimeLaunchPlan.bootstrapArguments(plistPath: "/tmp/a.plist", userID: 501)
                  == ["bootstrap", "gui/501", "/tmp/a.plist"])
        check("print status 0 means loaded",
              SpeechRuntimeLaunchPlan.isAgentLoaded(printExitStatus: 0))
        check("print status non-zero means not loaded",
              !SpeechRuntimeLaunchPlan.isAgentLoaded(printExitStatus: 1))
    }

    static func healthJSONDecoding() {
        // Shape from Router.swift's /health handler: token-free readiness.
        let fixture = """
        {"ok": true, "version": "0.1.0", "uptime_s": 12, "streams": 0,
         "memory": {"rss": 1}, "worker": {"pid": 42},
         "tts": {"loaded": false}}
        """
        let object = (try? JSONSerialization.jsonObject(with: Data(fixture.utf8))) as? [String: Any]
        check("/health decodes and reports ok", object?["ok"] as? Bool == true)
        let down = """
        {"ok": false}
        """
        let object2 = (try? JSONSerialization.jsonObject(with: Data(down.utf8))) as? [String: Any]
        check("a not-ok health is not readiness", object2?["ok"] as? Bool == false)
    }

    static func modelsJSONDecoding() {
        // Shape from Router.swift's /v1/models handler.
        let fixture = """
        {"models": [
            {"model": "parakeet-ultra", "path": "/m/parakeet.gguf", "backend": "ane",
             "languages": ["ru", "en"], "loaded": true,
             "capabilities": {"streaming_sessions": true},
             "device": "ane", "queued_interactive": 0, "queued_batch": 0, "done": 3},
            {"model": "whisper-small", "path": "/m/whisper.gguf", "backend": "auto",
             "languages": [], "loaded": false,
             "capabilities": {"streaming_sessions": false}}
        ]}
        """
        let models = try? JSONDecoder().decode(SpeechRuntimeModels.self, from: Data(fixture.utf8)).models
        check("the model list decodes", models?.count == 2)
        check("the first model keeps its name", models?.first?.model == "parakeet-ultra")
        check("loaded survives decoding", models?.first?.loaded == true)
        check("streaming capability uses the snake_case key",
              models?.first?.capabilities?.streamingSessions == true)
        check("a model that never ran reports loaded false",
              models?.last?.loaded == false)
        check("the stream payload decodes",
              (try? JSONDecoder().decode(
                  SpeechRuntimeStream.self, from: Data(#"{"stream": "s1"}"#.utf8)))?.stream == "s1")
        check("the events payload decodes",
              (try? JSONDecoder().decode(
                  SpeechRuntimeEvents.self,
                  from: Data(#"{"next": 4, "ended": false, "events": [{"event": "final", "data": {"text": "привет"}}]}"#.utf8)))?
              .events.first?.data.text == "привет")
        check("an error body decodes its message",
              (try? JSONDecoder().decode(
                  SpeechRuntimeErrorBody.self, from: Data(#"{"error": "nope"}"#.utf8)))?.error == "nope")
    }

    // MARK: - Runtime service orchestration

    static func makeService(_ fake: FakeSpeechRuntimeTransport,
                            pollTimeout: Duration = .milliseconds(50)) -> SpeechRuntimeService {
        SpeechRuntimeService(home: URL(fileURLWithPath: "/tmp/none"), userID: 501,
                             transport: fake, pollInterval: .milliseconds(1),
                             pollTimeout: pollTimeout)
    }

    static func isReady(_ status: SpeechRuntimeStatus, models: [String] = ["m"]) -> Bool {
        guard case .ready(let list) = status else { return false }
        return list.map(\.model) == models
    }

    static func isFailed(_ status: SpeechRuntimeStatus) -> Bool {
        if case .failed = status { return true }
        return false
    }

    static func isNeedsModel(_ status: SpeechRuntimeStatus) -> Bool {
        if case .needsModel = status { return true }
        return false
    }

    static func ensureRunningRetrySucceeds() async {
        let fake = FakeSpeechRuntimeTransport()
        fake.appInstalled = true
        fake.agentPlistPath = "/tmp/none/Library/LaunchAgents/com.speechruntime.agent.plist"
        fake.tokenPresent = true
        fake.models = [SpeechRuntimeModel(model: "m", loaded: true,
                                          capabilities: SpeechRuntimeModel.Capabilities(streamingSessions: true))]
        fake.onLaunch = { args in
            if args.first == "bootstrap" { fake.agentLoaded = true; fake.healthy = true }
        }
        let service = makeService(fake)
        let status = await service.ensureRunning(model: "m")
        check("bootstrap path retries into ready", isReady(status))
        check("bootstrap path issues print then bootstrap in order",
              fake.launchCalls == [
                  ["print", "gui/501/com.speechruntime.agent"],
                  ["bootstrap", "gui/501",
                   "/tmp/none/Library/LaunchAgents/com.speechruntime.agent.plist"],
              ])
    }

    static func ensureRunningTimeoutFailsThenRecovers() async {
        let fake = FakeSpeechRuntimeTransport()
        fake.appInstalled = true
        fake.agentPlistPath = "/tmp/none/Library/LaunchAgents/com.speechruntime.agent.plist"
        fake.tokenPresent = true
        fake.healthy = false
        fake.agentLoaded = true
        fake.models = [SpeechRuntimeModel(model: "m", loaded: true,
                                          capabilities: SpeechRuntimeModel.Capabilities(streamingSessions: true))]
        let service = makeService(fake, pollTimeout: .milliseconds(20))
        let timedOut = await service.ensureRunning(model: "m")
        check("polling eventually fails when the agent never turns healthy",
              isFailed(timedOut))
        fake.healthy = true
        let recovered = await service.ensureRunning(model: "m")
        check("a later ensureRunning recovers once the agent is healthy",
              isReady(recovered))
    }

    static func loadedAgentIsKickstartedOnce() async {
        let fake = FakeSpeechRuntimeTransport()
        fake.appInstalled = true
        fake.agentPlistPath = "/tmp/none/Library/LaunchAgents/com.speechruntime.agent.plist"
        fake.agentLoaded = true
        fake.tokenPresent = true
        fake.models = [SpeechRuntimeModel(model: "m", loaded: true,
                                          capabilities: SpeechRuntimeModel.Capabilities(streamingSessions: true))]
        fake.onLaunch = { args in
            if args.first == "kickstart" { fake.healthy = true }
        }
        let service = makeService(fake)
        let status = await service.ensureRunning(model: "m")
        check("a loaded agent is kickstarted exactly once and never bootstrapped",
              isReady(status)
                  && fake.launchCalls.filter { $0.first == "kickstart" }.count == 1
                  && fake.launchCalls.filter { $0.first == "bootstrap" }.isEmpty)
    }

    static func unloadedAgentIsBootstrappedOnce() async {
        let fake = FakeSpeechRuntimeTransport()
        fake.appInstalled = true
        fake.agentPlistPath = "/tmp/none/Library/LaunchAgents/com.speechruntime.agent.plist"
        fake.agentLoaded = false
        fake.tokenPresent = true
        fake.models = [SpeechRuntimeModel(model: "m", loaded: true,
                                          capabilities: SpeechRuntimeModel.Capabilities(streamingSessions: true))]
        fake.onLaunch = { args in
            if args.first == "bootstrap" { fake.healthy = true }
        }
        let service = makeService(fake)
        let status = await service.ensureRunning(model: "m")
        check("an unloaded agent is bootstrapped exactly once with the plist path",
              isReady(status)
                  && fake.launchCalls.filter { $0.first == "bootstrap" }.count == 1
                  && fake.launchCalls.contains { $0 == ["bootstrap", "gui/501",
                      "/tmp/none/Library/LaunchAgents/com.speechruntime.agent.plist"] })
    }

    static func appOnlyOpensTheApp() async {
        let fake = FakeSpeechRuntimeTransport()
        fake.appInstalled = true
        fake.agentPlistPath = nil
        fake.tokenPresent = true
        fake.openAppResult = true
        fake.models = [SpeechRuntimeModel(model: "m", loaded: true,
                                          capabilities: SpeechRuntimeModel.Capabilities(streamingSessions: true))]
        let service = makeService(fake)
        let status = await service.ensureRunning(model: "m")
        check("app-only install opens the app instead of launchctl",
              isReady(status)
                  && fake.openAppCalls == 1
                  && fake.launchCalls.filter { $0.first == "kickstart" }.isEmpty
                  && fake.launchCalls.filter { $0.first == "bootstrap" }.isEmpty)
    }

    static func nothingInstalledShortCircuits() async {
        let fake = FakeSpeechRuntimeTransport()
        let service = makeService(fake)
        let status = await service.ensureRunning(model: "m")
        let notInstalled: Bool
        switch status {
        case .notInstalled: notInstalled = true
        default: notInstalled = false
        }
        check("nothing installed reports notInstalled without side effects",
              notInstalled && fake.launchCalls.isEmpty
                  && fake.openAppCalls == 0 && fake.modelCalls == 0)
    }

    static func concurrentEnsureRunningIsCoalesced() async {
        let fake = FakeSpeechRuntimeTransport()
        fake.appInstalled = true
        fake.agentPlistPath = "/tmp/none/Library/LaunchAgents/com.speechruntime.agent.plist"
        fake.agentLoaded = true
        fake.launchDelay = .milliseconds(5)
        fake.models = [SpeechRuntimeModel(model: "m", loaded: true,
                                          capabilities: SpeechRuntimeModel.Capabilities(streamingSessions: true))]
        fake.onLaunch = { _ in fake.healthy = true }
        let service = makeService(fake)
        async let a = service.ensureRunning(model: "m")
        async let b = service.ensureRunning(model: "m")
        let statuses = await [a, b]
        check("concurrent ensureRunning calls both report ready",
              statuses.count == 2 && statuses.allSatisfy { isReady($0) })
        check("concurrent ensureRunning coalesces into one kickstart",
              fake.launchCalls.filter { $0.first == "kickstart" }.count == 1)
    }
    static func modelRequirements() async {
        let fake = FakeSpeechRuntimeTransport()
        fake.appInstalled = true
        fake.agentPlistPath = "/tmp/none/Library/LaunchAgents/com.speechruntime.agent.plist"
        fake.agentLoaded = true
        fake.tokenPresent = true
        fake.healthy = true
        fake.models = [SpeechRuntimeModel(model: "A", loaded: true,
                                          capabilities: SpeechRuntimeModel.Capabilities(streamingSessions: true))]
        let service = makeService(fake)
        let ready = await service.ensureRunning(model: "A")
        check("the loaded model reports ready", isReady(ready, models: ["A"]))
        let needsModel = await service.ensureRunning(model: "B")
        check("a missing model reports needsModel", isNeedsModel(needsModel))
        check("model checks never invoke launchctl", fake.launchCalls.isEmpty)
        check("no launchctl argument ever mentions load",
              fake.launchCalls.flatMap { $0 }.allSatisfy { !$0.contains("load") })
    }
}

@MainActor
final class FakeSpeechRuntimeTransport: SpeechRuntimeTransporting {
    var appInstalled = false
    var agentPlistPath: String?
    var tokenPresent = false
    var healthy = false
    var agentLoaded = false
    var models: [SpeechRuntimeModel] = []
    var modelsError: Error?
    var launchExit: Int32 = 0
    var openAppResult = true
    var launchDelay: Duration?
    var onHealth: (() -> Bool)?
    var onLaunch: (([String]) -> Void)?

    private(set) var healthCalls = 0
    private(set) var modelCalls = 0
    private(set) var launchCalls: [[String]] = []
    private(set) var openAppCalls = 0
    private(set) var sleepCalls = 0

    func health() async -> Bool {
        healthCalls += 1
        return onHealth?() ?? healthy
    }

    func models() async throws -> [SpeechRuntimeModel] {
        modelCalls += 1
        if let modelsError { throw modelsError }
        return models
    }

    func launchctl(_ arguments: [String]) async -> (exit: Int32, output: String) {
        launchCalls.append(arguments)
        onLaunch?(arguments)
        if let launchDelay {
            try? await Task.sleep(for: launchDelay)
        }
        if arguments.first == "print" {
            return (agentLoaded ? 0 : 1, "")
        }
        return (launchExit, "")
    }

    func openApp() -> Bool {
        openAppCalls += 1
        if openAppResult { healthy = true }
        return openAppResult
    }

    func sleep(for duration: Duration) async {
        sleepCalls += 1
    }
}
