import Foundation

/// What the paste decision knows about one field, reduced to plain values so it stays testable.
struct DictationFocusSnapshot: Equatable, Sendable {
    let processIdentifier: Int32
    let bundleID: String?
    let capturedAt: Date
    /// False when the field could not be read at all — the user may not have granted Accessibility.
    let hasFocusedElement: Bool
}

enum DictationInsertionPolicy {
    static let maximumFocusAge: Duration = .seconds(180)

    /// Paste only into the element the user was in when dictation began; anything else is copied.
    /// `sameElement` is the caller's CFEqual of the two focused elements, meaningful when both exist.
    static func allowsPaste(
        original: DictationFocusSnapshot?, current: DictationFocusSnapshot?,
        frontmostBundleID: String?, sameElement: Bool, now: Date
    ) -> Bool {
        guard let original, let current, let bundleID = original.bundleID else { return false }
        guard current.processIdentifier == original.processIdentifier,
            current.bundleID == bundleID,
            frontmostBundleID == bundleID
        else { return false }
        let age = now.timeIntervalSince(original.capturedAt)
        guard age >= 0, age <= Double(maximumFocusAge.components.seconds) else { return false }

        // An unreadable element at capture and none now is the same field; a vanished one is not.
        switch (original.hasFocusedElement, current.hasFocusedElement) {
        case (true, true): return sameElement
        case (false, false): return true
        default: return false
        }
    }
}
