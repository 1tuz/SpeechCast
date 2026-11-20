import AppKit
@preconcurrency import ApplicationServices

/// What Auto Learn may ask of a field: identity, a caret and a short range — never the document.
/// The harness scripts this so a session is decidable without a real Accessibility server.
@MainActor
struct AutoLearnFieldReader {
    var role: (AXUIElement) -> String?
    var isSecure: (AXUIElement) -> Bool
    var numberOfCharacters: (AXUIElement) -> Int?
    var selectedRange: (AXUIElement) -> NSRange?
    var string: (AXUIElement, NSRange) -> String?
    var focusedElement: (pid_t) -> AXUIElement?
    var processIdentifier: (AXUIElement) -> pid_t?
    var frontmostBundleID: () -> String?

    static let accessibility = AutoLearnFieldReader(
        role: AccessibilityText.role(of:),
        isSecure: AccessibilityText.isSecure(_:),
        numberOfCharacters: AccessibilityText.numberOfCharacters(of:),
        selectedRange: AccessibilityText.selectedRange(of:),
        string: { AccessibilityText.string(of: $0, range: $1) },
        focusedElement: AccessibilityText.focusedElement(processIdentifier:),
        processIdentifier: { element in
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success else { return nil }
            return pid
        },
        frontmostBundleID: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier })
}

/// Bounded, opt-in observation of the one span a dictation inserted; publishes at most one
/// correction per session, and nothing at all unless Accessibility can prove attribution.
@MainActor
final class AutoLearnMonitor {
    /// Fields whose contents a correction may belong to; anything else is not a dictation target.
    static let textRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea",
    ]
    /// Long enough for a reader to fix a word, short enough that a forgotten window ends itself.
    static let quietPeriod: TimeInterval = 10
    /// A change larger than any correction we would learn is a paste we cannot attribute.
    static let maximumProvenDelta = 24

    private let reader: AutoLearnFieldReader
    private let isEnabled: @MainActor () -> Bool
    private let dictionary: @MainActor () -> DictationDictionary
    private let prior: @MainActor (ObservedCorrection) -> [ObservedCorrection]
    private let clock: @MainActor () -> Date
    private let onDecision: @MainActor (AutoLearnDecision, ObservedCorrection) -> Void

    private struct Session {
        let id: UUID
        let element: AXUIElement
        let bundleID: String?
        let inserted: String
        let deadline: Date
        /// The inserted range, moved only when an edit is provably at one edge of it.
        var span: NSRange
        /// Bumped on every accepted change, so tests can count reattributions.
        var spanVersion: Int
        /// What the span held when last read.
        var observed: String
        /// One unit either side of the span, stored so a shift is visible. Never whole content.
        var before: String?
        var after: String?
        var lastChangeAt: Date
        /// Character count at the last sample: the delta places an edit at a span edge.
        var lastCount: Int
    }

    private var session: Session?
    private var pollTask: Task<Void, Never>?

    init(
        reader: AutoLearnFieldReader = .accessibility,
        isEnabled: @escaping @MainActor () -> Bool = { true },
        dictionary: @escaping @MainActor () -> DictationDictionary,
        prior: @escaping @MainActor (ObservedCorrection) -> [ObservedCorrection] = { _ in [] },
        clock: @escaping @MainActor () -> Date = Date.init,
        onDecision: @escaping @MainActor (AutoLearnDecision, ObservedCorrection) -> Void
    ) {
        self.reader = reader
        self.isEnabled = isEnabled
        self.dictionary = dictionary
        self.prior = prior
        self.clock = clock
        self.onDecision = onDecision
    }

    /// Simplified wiring for callers that only want the final correction, not the decision.
    init(
        reader: AutoLearnFieldReader = .accessibility,
        isEnabled: @escaping @MainActor () -> Bool = { true },
        clock: @escaping @MainActor () -> Date = Date.init,
        onCorrection: @escaping @MainActor (ObservedCorrection) -> Void
    ) {
        self.reader = reader
        self.isEnabled = isEnabled
        self.dictionary = { DictationDictionary() }
        self.prior = { _ in [] }
        self.clock = clock
        self.onDecision = { _, observation in onCorrection(observation) }
    }

    var isMonitoring: Bool { session != nil }

    /// No-op unless the insertion point is readable, the field is a plain text role, it is still
    /// focused in the app we pasted into, and it holds exactly what was inserted — nothing less.
    func begin(
        afterInsertion insertedText: String, element: AXUIElement?, bundleID: String?, anchor: NSRange?
    ) {
        stop(publish: false)
        guard !insertedText.isEmpty, let element, let anchor, isEnabled() else { return }
        guard let pid = reader.processIdentifier(element), pid != 0 else { return }
        guard let role = reader.role(element), Self.textRoles.contains(role) else { return }
        guard !reader.isSecure(element) else { return }
        guard let focused = reader.focusedElement(pid), CFEqual(focused, element) else { return }
        if let bundleID, reader.frontmostBundleID() != bundleID { return }
        let length = (insertedText as NSString).length
        guard anchor.location >= 0, anchor.length == length,
              let spanText = reader.string(
                element, NSRange(location: anchor.location, length: length)),
              spanText == insertedText
        else { return }
        guard let caret = reader.selectedRange(element),
              caret.location >= anchor.location, caret.location <= anchor.upperBound
        else { return }
        // Two single-unit reads: the margin is what later proves an edit's position.
        let before =
            anchor.location > 0
            ? Self.unit(reader.string(element, NSRange(location: anchor.location - 1, length: 1)))
            : nil
        let after = Self.unit(
            reader.string(element, NSRange(location: anchor.upperBound, length: 1)))
        guard let count = reader.numberOfCharacters(element) else { return }
        // A span at field start has no before-margin: only count equality proves position.
        if anchor.location == 0, count != length, count != length + 1 { return }
        let now = clock()
        session = Session(
            id: UUID(),
            element: element,
            bundleID: bundleID,
            inserted: insertedText,
            deadline: now.addingTimeInterval(
                TimeInterval(AutoLearnPolicy.maximumWindow.components.seconds)),
            span: NSRange(location: anchor.location, length: length),
            spanVersion: 0,
            observed: insertedText,
            before: before,
            after: after,
            lastChangeAt: now,
            lastCount: count)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.isMonitoring else { return }
                self.step()
            }
        }
    }

    /// Cancelling is the caller withdrawing consent mid-observation: everything seen is dropped.
    func cancel() { stop(publish: false) }

    deinit {
        pollTask?.cancel()
    }

    /// One observation round, internal so the harness can drive it without the 500 ms poll.
    func step() {
        // A toggle turned off between samples ends the session at once, and publishes nothing.
        guard isEnabled() else { return stop(publish: false) }
        guard var current = session else { return }
        guard clock() < current.deadline else { return stop(publish: true) }
        guard let pid = reader.processIdentifier(current.element), pid != 0,
              let focused = reader.focusedElement(pid), CFEqual(focused, current.element)
        else { return stop(publish: false) }
        guard let role = reader.role(current.element), Self.textRoles.contains(role) else {
            return stop(publish: false)
        }
        guard !reader.isSecure(current.element) else { return stop(publish: false) }
        if let bundleID = current.bundleID, reader.frontmostBundleID() != bundleID {
            return stop(publish: false)
        }
        guard let count = reader.numberOfCharacters(current.element) else {
            return stop(publish: false)
        }
        guard let caret = reader.selectedRange(current.element) else { return stop(publish: false) }
        let delta = count - current.lastCount
        // A caret that left the neighborhood means we can no longer prove attribution.
        let lowerBound = max(0, current.span.location - 1)
        let upperBound = min(count, current.span.upperBound + 1)
        guard caret.location >= lowerBound, caret.location <= upperBound else {
            return stop(publish: false)
        }
        // Reads stay bounded by the span's known length: a whole-field delta is not proven to
        // be ours, so a large one ends the session before a single character is read.
        guard abs(delta) <= Self.maximumProvenDelta else { return stop(publish: false) }
        let newLength = current.span.length + delta
        let newEnd = current.span.location + newLength
        guard newLength >= 0, newEnd <= count else { return stop(publish: false) }
        if delta != 0 {
            guard caret.length == 0, caret.location > current.span.location, caret.location <= newEnd else {
                return stop(publish: false)
            }
            let afterUnit = newEnd < count
                ? Self.unit(reader.string(current.element, NSRange(location: newEnd, length: 1))) : nil
            guard afterUnit == current.after else { return stop(publish: false) }
        }
        if current.span.location > 0,
           Self.unit(reader.string(
            current.element, NSRange(location: current.span.location - 1, length: 1)))
               != current.before
        { return stop(publish: false) }
        let range = NSRange(location: current.span.location, length: newLength)
        guard let candidate = reader.string(current.element, range), candidate.utf16.count == newLength else {
            return stop(publish: false)
        }
        let now = clock()
        let accepted = candidate != current.observed
        if accepted {
            let tail = newEnd < count
                ? Self.unit(reader.string(current.element, NSRange(location: newEnd, length: 1))) : nil
            guard tail == current.after else { return stop(publish: false) }
            // Typing beside the dictation is not a replacement inside it.
            if delta > 0 && (candidate.hasPrefix(current.observed) || candidate.hasSuffix(current.observed)) {
                return stop(publish: false)
            }
            current.span = range
            current.observed = candidate
        }

        if accepted {
            current.lastCount = count
            current.spanVersion += 1
            current.lastChangeAt = now
            // Margins are the next sample's proof of position, re-read at the new span.
            current.before = current.span.location > 0
                ? Self.unit(reader.string(
                    current.element, NSRange(location: current.span.location - 1, length: 1)))
                : nil
            current.after = Self.unit(reader.string(
                current.element, NSRange(location: current.span.upperBound, length: 1)))
        }
        session = current
        if now.timeIntervalSince(current.lastChangeAt) >= Self.quietPeriod { stop(publish: true) }
    }

    /// A margin at the very end of a field reads back as "", which is no margin at all.
    private static func unit(_ read: String?) -> String? {
        guard let read, !read.isEmpty else { return nil }
        return read
    }

    private func stop(publish: Bool) {
        pollTask?.cancel()
        pollTask = nil
        guard let finished = session else { return }
        session = nil
        guard publish else { return }
        let observation = ObservedCorrection(
            inserted: finished.inserted,
            observed: finished.observed,
            bundleID: finished.bundleID,
            at: clock(),
            sessionID: finished.id
        )
        let decision = AutoLearnPolicy.decide(
            observation,
            prior: prior(observation),
            existing: dictionary().entries
        )
        onDecision(decision, observation)
    }
}
