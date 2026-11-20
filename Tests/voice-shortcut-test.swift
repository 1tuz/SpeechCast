import Foundation

@main
@MainActor
struct VoiceShortcutTest {
    static var failures = 0
    static var passes = 0

    static func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        if actual == expected {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)\n  got  \(actual)\n  want \(expected)")
        }
    }

    static func main() {
        // The full truth table: keyDown.
        expect(VoiceShortcutGate.keyDown(mode: .smart, isActive: false), .start,
               "smart keyDown while idle starts")
        expect(VoiceShortcutGate.keyDown(mode: .smart, isActive: true), .finish,
               "smart keyDown while active finishes")
        expect(VoiceShortcutGate.keyDown(mode: .toggle, isActive: false), .start,
               "toggle keyDown while idle starts")
        expect(VoiceShortcutGate.keyDown(mode: .toggle, isActive: true), .finish,
               "toggle keyDown while active finishes")
        expect(VoiceShortcutGate.keyDown(mode: .hold, isActive: false), .start,
               "hold keyDown while idle starts")
        expect(VoiceShortcutGate.keyDown(mode: .hold, isActive: true), .ignore,
               "hold keyDown while active is ignored")

        // The full truth table: keyUp.
        expect(VoiceShortcutGate.keyUp(mode: .smart, held: .milliseconds(249)), .ignore,
               "smart keyUp below the threshold is ignored")
        expect(VoiceShortcutGate.keyUp(mode: .smart, held: .milliseconds(250)), .finish,
               "smart keyUp exactly at the threshold finishes")
        expect(VoiceShortcutGate.keyUp(mode: .smart, held: .milliseconds(251)), .finish,
               "smart keyUp above the threshold finishes")
        expect(VoiceShortcutGate.keyUp(mode: .smart, held: .milliseconds(0)), .ignore,
               "smart keyUp with no hold is ignored")
        expect(VoiceShortcutGate.keyUp(mode: .smart, held: .seconds(10)), .finish,
               "smart keyUp after a long hold finishes")
        expect(VoiceShortcutGate.keyUp(mode: .toggle, held: .milliseconds(249)), .ignore,
               "toggle keyUp is ignored below the threshold")
        expect(VoiceShortcutGate.keyUp(mode: .toggle, held: .milliseconds(250)), .ignore,
               "toggle keyUp is ignored at the threshold")
        expect(VoiceShortcutGate.keyUp(mode: .toggle, held: .seconds(5)), .ignore,
               "toggle keyUp is always ignored: keyDown is the whole gesture")
        expect(VoiceShortcutGate.keyUp(mode: .hold, held: .milliseconds(249)), .finish,
               "hold keyUp finishes regardless of duration")
        expect(VoiceShortcutGate.keyUp(mode: .hold, held: .milliseconds(250)), .finish,
               "hold keyUp at the threshold finishes")
        expect(VoiceShortcutGate.keyUp(mode: .hold, held: .seconds(3)), .finish,
               "hold keyUp after a long hold finishes")

        // The threshold itself.
        expect(VoiceShortcutGate.holdThreshold, .milliseconds(250),
               "the hold threshold is exactly 250 ms")

        let failSummary = failures == 0 ? "all \(passes) assertions passed" : "\(failures) FAILED"
        print("Voice shortcut gate: \(failSummary)")
        if failures > 0 { exit(1) }
    }
}
