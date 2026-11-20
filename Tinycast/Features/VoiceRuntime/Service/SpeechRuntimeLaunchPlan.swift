import Foundation

/// Facts the launch decision needs, injected so the pure logic stays harness-testable.
struct SpeechRuntimeEnvironment: Equatable, Sendable {
    var appInstalled: Bool
    var agentPlistInstalled: Bool
    var agentLoaded: Bool
    var tokenPresent: Bool

    /// No app, no agent, no token: the user never installed Speech Runtime.
    var isInstalled: Bool { appInstalled || agentPlistInstalled || tokenPresent }
}

enum SpeechRuntimeLaunchAction: Equatable, Sendable {
    /// Agent is loaded in the gui domain: restart it through its own registered job.
    case kickstart
    /// Plist exists but the job is not loaded: register it with `launchctl bootstrap`.
    case bootstrap
    /// Only the app bundle exists: the app's own UI is the only thing that can start it.
    case openApp
    /// Nothing on disk answers to the runtime: there is nothing we can start.
    case nothingInstalled
    /// An environment a `kickstart`/`bootstrap` cannot fix; no mechanism should be attempted.
    case unavailable(reason: String)
}

enum SpeechRuntimeLaunchPlan {
    static let agentLabel = "com.speechruntime.agent"
    static let launchctlPath = "/bin/launchctl"
    static let baseURL = URL(string: "http://127.0.0.1:8477")!

    /// `gui/<uid>/<label>` — the per-login-session target launchctl addresses the job by.
    static func agentTarget(userID: uid_t, label: String = agentLabel) -> String {
        "gui/\(userID)/\(label)"
    }

    static func action(for environment: SpeechRuntimeEnvironment) -> SpeechRuntimeLaunchAction {
        guard environment.isInstalled else { return .nothingInstalled }
        if environment.agentLoaded { return .kickstart }
        if environment.agentPlistInstalled { return .bootstrap }
        if environment.appInstalled { return .openApp }
        return .unavailable(reason: "Speech Runtime is not fully installed")
    }

    /// Explicit launchctl arguments; never a shell string.
    static func kickstartArguments(userID: uid_t, label: String = agentLabel) -> [String] {
        ["kickstart", "-k", agentTarget(userID: userID, label: label)]
    }

    static func bootstrapArguments(plistPath: String, userID: uid_t) -> [String] {
        ["bootstrap", "gui/\(userID)", plistPath]
    }

    /// `launchctl print` answers 0 only when the label is loaded in the domain.
    static func isAgentLoaded(printExitStatus: Int32) -> Bool { printExitStatus == 0 }

    /// "com.speechruntime.agent" is the authoritative label, but a foreign plist that
    /// names a different label must be bootstrapped by that label, not ours.
    static func label(fromPlistData data: Data) -> String? {
        guard let object = (try? PropertyListSerialization.propertyList(from: data, format: nil)),
              let dictionary = object as? [String: Any],
              let label = dictionary["Label"] as? String, !label.isEmpty
        else { return nil }
        return label
    }
}
