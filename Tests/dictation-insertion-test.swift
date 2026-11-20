import AppKit
@preconcurrency import ApplicationServices
import Foundation

/// DictationInserter is outside the harness build, so the target its context reads from is here.
struct DictationInsertionTarget {
    let focusedElement: AXUIElement?
}

/// A synthetic field the scripted reader answers from: one process, one thread, no real AX calls.
final class ScriptedField: @unchecked Sendable {
    var text = NSMutableString()
    var caret = NSRange(location: 0, length: 0)
    var role: String? = "AXTextField"
    var secure = false
    var processIdentifier: pid_t = 42
    var frontmost: String? = "com.example.Editor"
    var focused: AXUIElement?
    var countUnreadable = false
    var caretUnreadable = false
    /// Every closure call in order, so a test can prove nothing was read before identity.
    var order: [String] = []
    /// Every requested range, so a test can prove the document was never walked.
    var reads: [NSRange] = []

    var maxReadLength: Int { reads.map(\.length).max() ?? 0 }
}

final class ClockBox: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000_000)
    /// The opt-in toggle, held so a closure can read what the test flips.
    var on = true
}

final class Recorder: @unchecked Sendable {
    var decisions: [AutoLearnDecision] = []
    var observations: [ObservedCorrection] = []
}

@main
@MainActor
struct DictationInsertionTest {
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

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        formatter()
        shortcutGate()
        insertionPolicy()
        monitor()
        insertionContext()

        let failSummary = failures == 0 ? "all \(passes) assertions passed" : "\(failures) FAILED"
        print("Dictation insertion: \(failSummary)")
        if failures > 0 { exit(1) }
    }

    static func format(
        _ text: String, before: String = "", after: String = "",
        options: DictationCleanupOptions = .conservative
    ) -> String {
        DictationTextFormatter.format(
            text, context: .init(before: Substring(before), after: Substring(after)), options: options)
    }

    static func spacing(_ text: String, before: String = "", after: String = "") -> String {
        format(text, before: before, after: after,
               options: DictationCleanupOptions(spacing: true, capitalization: false, punctuation: false))
    }

    static func formatter() {
        // Nothing known about the field: trim, never invent spacing or case.
        expect(DictationTextFormatter.format("  привет мир \n", context: nil, options: .conservative),
               "привет мир", "a nil context trims only")
        expect(format("  привет  ", before: "конец", options: .off), "привет",
               "cleanup off trims only, no spacing")

        // Capitalization follows the field's own punctuation.
        expect(format("привет мир", before: ""), "Привет мир", "an empty field starts a sentence")
        expect(format("привет", before: "конец. "), "Привет", "a sentence end capitalizes")
        expect(format("привет", before: "конец! "), "Привет", "an exclamation mark capitalizes")
        expect(format("привет", before: "конец "), "привет", "mid-sentence stays lowercase")
        expect(format("Привет", before: "конец "), "привет", "mid-sentence lowercases a leading capital")
        expect(format("привет", before: "строка\n"), "Привет", "a new paragraph capitalizes")
        expect(format("привет", before: "строка\n\n  "), "Привет", "a blank line capitalizes")
        expect(format("привет", before: "конец ", options: DictationCleanupOptions(
            spacing: true, capitalization: false, punctuation: false)), "привет",
               "capitalization off leaves case alone")
        expect(format("123abc", before: ""), "123abc", "a non-letter first character is untouched")

        // Spacing: one space between words, none against punctuation or brackets.
        expect(spacing("мир", before: "привет"), " мир", "a missing leading space is added")
        expect(spacing("мир", before: "привет "), "мир", "an existing leading space is kept")
        expect(spacing("мир", before: "привет\n"), "мир", "a newline is already a separator")
        expect(spacing("мир", before: "привет ("), "мир", "an opening bracket needs no space")
        expect(spacing(", мир", before: "привет"), ", мир", "leading punctuation needs no space")
        expect(spacing("мир", after: "конец"), "мир ", "a missing trailing space is added")
        expect(spacing("мир", after: " конец"), "мир", "an existing trailing space is kept")
        expect(spacing("мир", after: "."), "мир", "a following full stop needs no space")
        expect(spacing("мир", after: ","), "мир", "a following comma needs no space")
        expect(spacing("мир.", after: "конец"), "мир. ",
               "a space still separates our punctuation from the next word")

        // Punctuation is opt-in: never invented by the conservative default.
        expect(format("привет", before: "конец "), "привет", "conservative adds no full stop")
        expect(format("привет", before: "конец ", options: DictationCleanupOptions(
            spacing: true, capitalization: true, punctuation: true)), "привет.",
               "punctuation on adds a full stop")
        expect(format("привет!", before: "конец ", options: DictationCleanupOptions(
            spacing: true, capitalization: true, punctuation: true)), "привет!",
               "punctuation on keeps existing terminal punctuation")
        expect(format("", before: "конец"), "", "empty text stays empty")
        expect(format("   ", before: "конец"), "", "whitespace-only text stays empty")
        expect(format("joined", before: "Word", after: "follows", options: .off), "joined",
               "spacing off adds neither a leading nor a trailing space")
        expect(format("on 12 Monkeys", before: "Some text"), " on 12 Monkeys",
               "a digit-starting text is not capitalized")
        expect(format("iPhone case", before: "Some text"), " iPhone case",
               "the inside of a word is never changed")
        expect(format("ready", before: "Что дальше? ", options: DictationCleanupOptions(
            spacing: true, capitalization: true, punctuation: false)), "Ready",
               "a question mark ends a sentence like a full stop")
        expect(format("ready", before: "Что дальше? ", options: DictationCleanupOptions(
            spacing: true, capitalization: true, punctuation: true)), "Ready.",
               "punctuation on still terminates a sentence that had no mark")

        // The context is derived from the field's own characters, not given.
        let derived = DictationTextFormatter.Context(before: "Trailing spaces   ", after: "  leading")
        expect(derived.trailing, " ", "trailing is the field's last character")
        expect(derived.following, " ", "following is the field's first character after the caret")
        expect(derived.lastNonWhitespace, "s", "lastNonWhitespace skips trailing whitespace")
        expect(derived.newParagraph, false, "spaces alone are not a new paragraph")
        expect(DictationTextFormatter.Context(before: "End.\n", after: "").newParagraph, true,
               "a newline is a new paragraph")
        expect(DictationTextFormatter.Context(before: "End.\n", after: "").lastNonWhitespace, ".",
               "lastNonWhitespace stops at the sentence end")
    }

    static func shortcutGate() {
        expect(VoiceShortcutGate.keyDown(mode: .smart, isActive: false), .start,
               "smart starts on the first press")
        expect(VoiceShortcutGate.keyDown(mode: .smart, isActive: true), .finish,
               "smart finishes on the second press")
        expect(VoiceShortcutGate.keyDown(mode: .toggle, isActive: false), .start,
               "toggle starts")
        expect(VoiceShortcutGate.keyDown(mode: .toggle, isActive: true), .finish,
               "toggle stops")
        expect(VoiceShortcutGate.keyDown(mode: .hold, isActive: false), .start,
               "hold starts on key down")
        expect(VoiceShortcutGate.keyDown(mode: .hold, isActive: true), .ignore,
               "hold ignores a repeat while active")

        expect(VoiceShortcutGate.keyUp(mode: .hold, held: .milliseconds(40)), .finish,
               "hold finishes on key up however brief")
        expect(VoiceShortcutGate.keyUp(mode: .toggle, held: .milliseconds(400)), .ignore,
               "toggle ignores key up")
        expect(VoiceShortcutGate.keyUp(mode: .smart, held: .milliseconds(100)), .ignore,
               "a smart tap is not a dictation")
        expect(VoiceShortcutGate.keyUp(mode: .smart, held: .milliseconds(249)), .ignore,
               "a smart press below the threshold is a tap")
        expect(VoiceShortcutGate.keyUp(mode: .smart, held: VoiceShortcutGate.holdThreshold), .finish,
               "a smart press at the threshold finishes")
        expect(VoiceShortcutGate.keyUp(mode: .smart, held: .milliseconds(600)), .finish,
               "a smart hold finishes on release")
    }

    static func insertionPolicy() {
        let now = Date(timeIntervalSince1970: 10_000)
        let original = DictationFocusSnapshot(
            processIdentifier: 42, bundleID: "com.apple.TextEdit", capturedAt: now,
            hasFocusedElement: true)
        let current = DictationFocusSnapshot(
            processIdentifier: 42, bundleID: "com.apple.TextEdit", capturedAt: now,
            hasFocusedElement: true)

        expect(DictationInsertionPolicy.allowsPaste(
            original: original, current: current, frontmostBundleID: "com.apple.TextEdit",
            sameElement: true, now: now), true,
               "the same focused element in the same app pastes")
        expect(DictationInsertionPolicy.allowsPaste(
            original: original, current: current, frontmostBundleID: "com.apple.TextEdit",
            sameElement: false, now: now), false,
               "a different element in the same app does not paste")
        expect(DictationInsertionPolicy.allowsPaste(
            original: original, current: current, frontmostBundleID: "com.apple.Safari",
            sameElement: true, now: now), false,
               "another frontmost app does not paste")
        expect(DictationInsertionPolicy.allowsPaste(
            original: original,
            current: DictationFocusSnapshot(processIdentifier: 43, bundleID: "com.apple.TextEdit",
                                            capturedAt: now, hasFocusedElement: true),
            frontmostBundleID: "com.apple.TextEdit", sameElement: true, now: now), false,
               "a relaunched app is a different target")

        expect(DictationInsertionPolicy.allowsPaste(
            original: original, current: current, frontmostBundleID: "com.apple.TextEdit",
            sameElement: true, now: now.addingTimeInterval(180)), true,
               "focus exactly at the maximum age still pastes")
        expect(DictationInsertionPolicy.allowsPaste(
            original: original, current: current, frontmostBundleID: "com.apple.TextEdit",
            sameElement: true, now: now.addingTimeInterval(181)), false,
               "stale focus does not paste")
        expect(DictationInsertionPolicy.allowsPaste(
            original: original, current: current, frontmostBundleID: "com.apple.TextEdit",
            sameElement: true, now: now.addingTimeInterval(-1)), false,
               "a future capture time is not trusted")

        // Without Accessibility both reads fail: same pid, bundle and frontmost is the only evidence.
        let blindOriginal = DictationFocusSnapshot(
            processIdentifier: 42, bundleID: "com.apple.TextEdit", capturedAt: now,
            hasFocusedElement: false)
        let blindCurrent = DictationFocusSnapshot(
            processIdentifier: 42, bundleID: "com.apple.TextEdit", capturedAt: now,
            hasFocusedElement: false)
        expect(DictationInsertionPolicy.allowsPaste(
            original: blindOriginal, current: blindCurrent,
            frontmostBundleID: "com.apple.TextEdit", sameElement: false, now: now), true,
               "an unreadable element before and after is the same field")
        expect(DictationInsertionPolicy.allowsPaste(
            original: original, current: blindCurrent, frontmostBundleID: "com.apple.TextEdit",
            sameElement: true, now: now), false,
               "an element that became unreadable does not paste")
        expect(DictationInsertionPolicy.allowsPaste(
            original: blindOriginal, current: current, frontmostBundleID: "com.apple.TextEdit",
            sameElement: true, now: now), false,
               "an element that became readable does not paste")

        // A field with no bundle identity can never be verified.
        let anonymous = DictationFocusSnapshot(
            processIdentifier: 42, bundleID: nil, capturedAt: now, hasFocusedElement: true)
        expect(DictationInsertionPolicy.allowsPaste(
            original: anonymous, current: anonymous, frontmostBundleID: nil,
            sameElement: true, now: now), false,
               "no bundle identifier never pastes")
        expect(DictationInsertionPolicy.allowsPaste(
            original: nil, current: current, frontmostBundleID: "com.apple.TextEdit",
            sameElement: true, now: now), false,
               "a capture that never happened does not paste")
        expect(DictationInsertionPolicy.allowsPaste(
            original: original, current: nil, frontmostBundleID: "com.apple.TextEdit",
            sameElement: true, now: now), false,
               "a lost element does not paste")
        expect(DictationInsertionPolicy.maximumFocusAge == .seconds(180),
               "focus older than three minutes is not trusted")
    }

    // MARK: - Auto Learn

    static let fieldElement = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
    static let otherElement = AXUIElementCreateSystemWide()
    static let bundle = "com.example.Editor"

    static func scriptedReader(_ field: ScriptedField) -> AutoLearnFieldReader {
        AutoLearnFieldReader(
            role: { _ in field.order.append("role"); return field.role },
            isSecure: { _ in field.order.append("secure"); return field.secure },
            numberOfCharacters: { _ in
                field.order.append("count")
                return field.countUnreadable ? nil : field.text.length
            },
            selectedRange: { _ in
                field.order.append("caret")
                return field.caretUnreadable ? nil : field.caret
            },
            string: { _, range in
                field.order.append("string")
                field.reads.append(range)
                guard range.location >= 0, range.length >= 0,
                      NSMaxRange(range) <= field.text.length
                else { return nil }
                return field.text.substring(with: range)
            },
            focusedElement: { _ in field.order.append("focused"); return field.focused },
            processIdentifier: { _ in field.order.append("pid"); return field.processIdentifier },
            frontmostBundleID: { field.order.append("frontmost"); return field.frontmost })
    }

    static func scriptedField(_ text: String, caret: Int, role: String = "AXTextField")
        -> ScriptedField
    {
        let field = ScriptedField()
        field.text = NSMutableString(string: text)
        field.caret = NSRange(location: caret, length: 0)
        field.role = role
        field.focused = fieldElement
        return field
    }

    static func makeMonitor(
        _ field: ScriptedField, clock: ClockBox, recorder: Recorder,
        enabled: @escaping @MainActor () -> Bool = { true }
    ) -> AutoLearnMonitor {
        AutoLearnMonitor(
            reader: scriptedReader(field),
            isEnabled: enabled,
            dictionary: { DictationDictionary() },
            prior: { _ in [] },
            clock: { clock.now },
            onDecision: { decision, observation in
                recorder.decisions.append(decision)
                recorder.observations.append(observation)
            })
    }

    static func replace(
        _ field: ScriptedField, _ range: NSRange, with text: String, caret: Int? = nil
    ) {
        field.text.replaceCharacters(in: range, with: text)
        if let caret { field.caret = NSRange(location: caret, length: 0) }
    }

    static func started(
        inserted: String = "hello world", prefix: String = "say ", suffix: String = " now"
    ) -> (field: ScriptedField, clock: ClockBox, recorder: Recorder, monitor: AutoLearnMonitor) {
        let field = scriptedField(prefix + inserted + suffix, caret: 0)
        let anchor = NSRange(location: (prefix as NSString).length, length: (inserted as NSString).length)
        field.caret = NSRange(location: anchor.upperBound, length: 0)
        let clock = ClockBox()
        let recorder = Recorder()
        let monitor = makeMonitor(field, clock: clock, recorder: recorder)
        monitor.begin(
            afterInsertion: inserted, element: fieldElement, bundleID: bundle, anchor: anchor)
        return (field, clock, recorder, monitor)
    }

    static func monitor() {
        // 1. Every identity check precedes any content read, and any failure starts no session.
        func rejected(
            _ label: String, readsText: Bool = false, _ breakIt: (ScriptedField) -> Void
        ) {
            let field = scriptedField("say hello world now", caret: 15)
            breakIt(field)
            let recorder = Recorder()
            let monitor = makeMonitor(field, clock: ClockBox(), recorder: recorder)
            monitor.begin(
                afterInsertion: "hello world", element: fieldElement, bundleID: bundle,
                anchor: NSRange(location: 4, length: 11))
            expect(monitor.isMonitoring, false, "\(label) starts no session")
            expect(recorder.observations.count, 0, "\(label) publishes nothing")
            // Identity is always settled before a character is read, and only the anchor is read.
            let firstRead = field.order.firstIndex(of: "string") ?? field.order.count
            expect(Set(field.order[..<firstRead]).isSuperset(of: ["pid", "role"]), true,
                   "\(label) is identified before any text is read")
            expect(field.order.contains("string"), readsText, "\(label) reads only what it must")
        }
        rejected("a mismatched anchor", readsText: true) {
            $0.text = NSMutableString(string: "say hello there now")
        }
        rejected("a non-text role") { $0.role = "AXButton" }
        rejected("a secure field") { $0.secure = true }
        rejected("a lost focus") { $0.focused = otherElement }
        rejected("another frontmost app") { $0.frontmost = "com.example.Other" }
        rejected("an unreadable caret", readsText: true) { $0.caretUnreadable = true }
        rejected("an unreadable length", readsText: true) { $0.countUnreadable = true }

        // 2. An untouched field publishes what was inserted, and the window never grows past it.
        do {
            let (field, clock, recorder, monitor) = started()
            monitor.step()
            expect(monitor.isMonitoring, true, "an untouched field keeps monitoring")
            expect(recorder.observations.count, 0, "nothing is published before the quiet period")
            clock.now = clock.now.addingTimeInterval(11)
            monitor.step()
            expect(recorder.observations.count, 1, "the quiet period publishes one observation")
            expect(recorder.observations.first?.observed, "hello world",
                   "the observation is the span as it stands")
            expect(recorder.decisions.first, .rejected(.notCorrection),
                   "an unchanged span is not a correction")
            expect(monitor.isMonitoring, false, "publishing ends the session")
            expect(field.maxReadLength <= 13, "reads stay within the span plus a unit either side")
        }

        // 3. A same-length rewrite inside the span is attributed when both margins are intact.
        do {
            let (field, clock, recorder, monitor) = started()
            replace(field, NSRange(location: 4, length: 5), with: "hallo")
            monitor.step()
            expect(recorder.observations.count, 0, "a correction is held until the quiet period")
            expect(field.maxReadLength <= 13, "a same-length edit is read within the window")
            clock.now = clock.now.addingTimeInterval(11)
            monitor.step()
            expect(recorder.observations.first?.observed, "hallo world",
                   "a same-length in-span rewrite is the observation")
        }

        // Appending at the boundary is not proof of a correction.
        do {
            let (field, clock, recorder, monitor) = started()
            replace(field, NSRange(location: 15, length: 0), with: "!!", caret: 17)
            monitor.step()
            expect(field.maxReadLength <= 13,
                   "a growing span is read at its old length plus margins only")
            clock.now = clock.now.addingTimeInterval(11)
            monitor.step()
            expect(recorder.observations.isEmpty, true, "an unproven append publishes nothing")
        }

        // 5. Text deleted from the span's far edge shortens it by the proven delta.
        do {
            let (field, clock, recorder, monitor) = started()
            replace(field, NSRange(location: 13, length: 2), with: "", caret: 13)
            monitor.step()
            clock.now = clock.now.addingTimeInterval(11)
            monitor.step()
            expect(recorder.observations.first?.observed, "hello wor",
                   "a deletion at the span edge shortens the observation")
        }

        // 6. An edit before the span moves it: attribution is lost, nothing is published.
        do {
            let (field, clock, recorder, monitor) = started()
            replace(field, NSRange(location: 0, length: 0), with: "X", caret: 16)
            monitor.step()
            expect(monitor.isMonitoring, false, "an out-of-span edit ends the session")
            clock.now = clock.now.addingTimeInterval(11)
            monitor.step()
            expect(recorder.observations.count, 0, "an out-of-span edit publishes nothing")
        }

        // 7. The same text earlier in the field is never searched for or read.
        do {
            let field = scriptedField("hello world and say hello world now", caret: 27)
            let anchor = NSRange(location: 20, length: 11)
            let recorder = Recorder()
            let clock = ClockBox()
            let monitor = makeMonitor(field, clock: clock, recorder: recorder)
            monitor.begin(
                afterInsertion: "hello world", element: fieldElement, bundleID: bundle,
                anchor: anchor)
            expect(monitor.isMonitoring, true, "a repeated phrase does not confuse the anchor")
            replace(field, NSRange(location: 20, length: 5), with: "Howdy")
            monitor.step()
            clock.now = clock.now.addingTimeInterval(11)
            monitor.step()
            expect(recorder.observations.first?.observed, "Howdy world",
                   "the span is positional, so the earlier occurrence is irrelevant")
            expect(field.reads.allSatisfy({ $0.location >= 19 }), true,
                   "no read ever covers the earlier occurrence")
        }

        // 8. Losing focus ends the session before anything is read.
        do {
            let (field, clock, recorder, monitor) = started()
            field.focused = otherElement
            let mark = field.order.count
            monitor.step()
            expect(monitor.isMonitoring, false, "losing focus ends the session")
            expect(field.order[mark...].contains("string"), false, "no text is read after focus loss")
            clock.now = clock.now.addingTimeInterval(11)
            monitor.step()
            expect(recorder.observations.count, 0, "a lost field publishes nothing")
        }

        // 9. A secure field stops the session before any text is read.
        do {
            let (field, _, recorder, monitor) = started()
            field.secure = true
            let mark = field.order.count
            monitor.step()
            expect(monitor.isMonitoring, false, "a secure field ends the session")
            expect(field.order[mark...].contains("string"), false, "a secure field is never read")
            expect(recorder.observations.count, 0, "a secure field publishes nothing")
        }

        // 10. Turning Auto Learn off between samples stops monitoring without publishing.
        do {
            let field = scriptedField("say hello world now", caret: 15)
            let recorder = Recorder()
            let enabled = ClockBox()
            let monitor = makeMonitor(
                field, clock: ClockBox(), recorder: recorder, enabled: { enabled.on })
            monitor.begin(
                afterInsertion: "hello world", element: fieldElement, bundleID: bundle,
                anchor: NSRange(location: 4, length: 11))
            enabled.on = false
            monitor.step()
            expect(monitor.isMonitoring, false, "opting out ends the session")
            expect(recorder.observations.count, 0, "opting out publishes nothing")
        }

        // 11. The window closes with whatever was seen.
        do {
            let (_, clock, recorder, monitor) = started()
            monitor.step()
            clock.now = clock.now.addingTimeInterval(61)
            monitor.step()
            expect(recorder.observations.count, 1, "window expiry publishes the span")
            expect(monitor.isMonitoring, false, "window expiry ends the session")
        }

        // 12. A new begin replaces the old session, which publishes nothing.
        do {
            let field = scriptedField("say hello world now", caret: 15)
            let recorder = Recorder()
            let clock = ClockBox()
            let monitor = makeMonitor(field, clock: clock, recorder: recorder)
            monitor.begin(
                afterInsertion: "hello world", element: fieldElement, bundleID: bundle,
                anchor: NSRange(location: 4, length: 11))
            replace(field, NSRange(location: 4, length: 5), with: "hallo")
            monitor.step()
            field.text = NSMutableString(string: "and goodbye now")
            field.caret = NSRange(location: 11, length: 0)
            monitor.begin(
                afterInsertion: "goodbye", element: fieldElement, bundleID: bundle,
                anchor: NSRange(location: 4, length: 7))
            expect(recorder.observations.count, 0, "the replaced session publishes nothing")
            expect(monitor.isMonitoring, true, "the second begin monitors")
            monitor.step()
            clock.now = clock.now.addingTimeInterval(11)
            monitor.step()
            expect(recorder.observations.count, 1, "the second session publishes its own span")
            expect(recorder.observations.last?.observed, "goodbye",
                   "the second session observes its own text")
        }

        // 13. A 100k-character paste elsewhere reads nothing at all: the session dies first.
        do {
            let (field, clock, recorder, monitor) = started()
            let mark = field.reads.count
            field.text.replaceCharacters(
                in: NSRange(location: 0, length: 4), with: String(repeating: "x", count: 100_000))
            field.caret = NSRange(location: 0, length: 0)
            monitor.step()
            expect(monitor.isMonitoring, false, "an off-span mega-paste ends the session")
            expect(field.reads.count - mark, 0,
                   "an off-span mega-paste performs zero AX string reads")
            clock.now = clock.now.addingTimeInterval(11)
            monitor.step()
            expect(recorder.observations.count, 0,
                   "an off-span mega-paste publishes nothing")
        }

        // 14. A span starting at zero, in a field that is exactly the pasted span, is monitored.
        do {
            let field = scriptedField("hello world", caret: 11)
            let clock = ClockBox()
            let recorder = Recorder()
            let monitor = makeMonitor(field, clock: clock, recorder: recorder)
            monitor.begin(
                afterInsertion: "hello world", element: fieldElement, bundleID: bundle,
                anchor: NSRange(location: 0, length: 11))
            expect(monitor.isMonitoring, true, "an isolated span at field start is monitored")
            replace(field, NSRange(location: 0, length: 5), with: "Howdy")
            monitor.step()
            clock.now = clock.now.addingTimeInterval(11)
            monitor.step()
            expect(recorder.observations.first?.observed, "Howdy world",
                   "an isolated field attributes a same-length rewrite by count alone")
        }
        do {
            let original = "проверить кубер нетис сейчас"
            let (field, clock, recorder, monitor) = started(inserted: original, prefix: "", suffix: "")
            let range = (original as NSString).range(of: "кубер нетис")
            replace(field, range, with: "Kubernetes", caret: range.location + "Kubernetes".utf16.count)
            monitor.step()
            clock.now = clock.now.addingTimeInterval(11)
            monitor.step()
            expect(recorder.observations.first?.observed, "проверить Kubernetes сейчас",
                   "a shorter term within a sentence preserves both sides of the pasted fragment")
        }


        // 15. The same start-zero span in a field that held more is not provable: no session.
        do {
            let field = scriptedField("hello world now", caret: 11)
            let recorder = Recorder()
            let monitor = makeMonitor(field, clock: ClockBox(), recorder: recorder)
            monitor.begin(
                afterInsertion: "hello world", element: fieldElement, bundleID: bundle,
                anchor: NSRange(location: 0, length: 11))
            expect(monitor.isMonitoring, false, "a start-zero span without count proof is refused")
            expect(recorder.observations.count, 0, "nothing is observed without position proof")
        }

        // 16. Cancelling discards: nothing seen before a cancel is ever published.
        do {
            let (field, _, recorder, monitor) = started()
            replace(field, NSRange(location: 4, length: 5), with: "hallo")
            monitor.step()
            monitor.cancel()
            expect(recorder.observations.count, 0, "a cancelled session publishes nothing")
            expect(monitor.isMonitoring, false, "a cancelled session is over")
        }

        // 17. The correction-only initializer forwards the observation, not the decision.
        do {
            let field = scriptedField("say hello world now", caret: 15)
            var seen: [ObservedCorrection] = []
            let monitor = AutoLearnMonitor(
                reader: scriptedReader(field),
                clock: { Date(timeIntervalSince1970: 2_000_000) },
                onCorrection: { seen.append($0) })
            monitor.begin(
                afterInsertion: "hello world", element: fieldElement, bundleID: bundle,
                anchor: NSRange(location: 4, length: 11))
            monitor.step()
            expect(seen.count, 0, "the quiet period has not passed, nothing is forwarded yet")
            monitor.cancel()
            expect(seen.count, 0, "a cancelled session forwards nothing")
        }
    }

    static func insertionContext() {
        // A caret mid-field gives the formatter the seam it joins into.
        do {
            let field = scriptedField("привет мир конец", caret: 10)
            let context = DictationInsertionContext.read(
                in: DictationInsertionTarget(focusedElement: fieldElement),
                reader: scriptedReader(field))
            expect(context?.trailing, "р", "the context ends at the caret")
            expect(context?.following, " ", "the context starts after the caret")
            expect(field.maxReadLength <= 64, "the context reads at most 64 units each way")
        }
        // A long field still yields the seam without walking the document.
        do {
            let field = scriptedField(String(repeating: "a", count: 200) + "мир" + " конец", caret: 203)
            let context = DictationInsertionContext.read(
                in: DictationInsertionTarget(focusedElement: fieldElement),
                reader: scriptedReader(field))
            expect(context?.trailing, "р", "a long field still yields the trailing character")
            expect(context?.following, " ", "a long field still yields the following character")
            expect(field.maxReadLength <= 64, "a long field is never read whole")
        }
        // An empty field is known and empty, not unknown.
        do {
            let field = scriptedField("", caret: 0)
            let context = DictationInsertionContext.read(
                in: DictationInsertionTarget(focusedElement: fieldElement),
                reader: scriptedReader(field))
            expect(context != nil, true, "an empty field still yields a context")
            expect(context?.trailing, nil, "an empty field has no trailing character")
            expect(context?.following, nil, "an empty field has no following character")
            expect(context?.lastNonWhitespace, nil, "an empty field has no word before the caret")
        }
        // No caret, no context: the formatter trims only.
        do {
            let field = scriptedField("привет", caret: 6)
            field.caretUnreadable = true
            let context = DictationInsertionContext.read(
                in: DictationInsertionTarget(focusedElement: fieldElement),
                reader: scriptedReader(field))
            expect(context == nil, true, "an unreadable caret yields no context")
        }
        // No focused element, no context.
        expect(DictationInsertionContext.read(in: nil, reader: scriptedReader(ScriptedField())) == nil,
               true, "a target without a field yields no context")
    }
}
