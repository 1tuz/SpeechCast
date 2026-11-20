import Foundation

enum VoiceShortcutMode: String, Codable, Sendable, CaseIterable { case smart, toggle, hold }

enum VoiceShortcutGate {
    enum Outcome: Equatable, Sendable { case start, finish, ignore }
    static let holdThreshold: Duration = .milliseconds(250)

    static func keyDown(mode: VoiceShortcutMode, isActive: Bool) -> Outcome {
        switch mode {
        case .smart, .toggle:
            return isActive ? .finish : .start
        case .hold:
            return isActive ? .ignore : .start
        }
    }

    static func keyUp(mode: VoiceShortcutMode, held: Duration) -> Outcome {
        switch mode {
        case .smart:
            return held >= holdThreshold ? .finish : .ignore
        case .toggle:
            return .ignore
        case .hold:
            return .finish
        }
    }
}
