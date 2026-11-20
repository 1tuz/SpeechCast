import AppKit
@preconcurrency import ApplicationServices

/// Where dictation was aimed when the user pressed the key: the app, and the field inside it.
struct DictationInsertionTarget: Equatable {
    let processIdentifier: pid_t
    let bundleID: String?
    let application: NSRunningApplication?
    let focusedElement: AXUIElement?
    let capturedAt: Date

    /// The decision's plain inputs; the AX element becomes a pair of booleans the policy can read.
    var focusSnapshot: DictationFocusSnapshot {
        DictationFocusSnapshot(
            processIdentifier: processIdentifier,
            bundleID: bundleID,
            capturedAt: capturedAt,
            hasFocusedElement: focusedElement != nil)
    }

    /// CFEqual is the only reliable identity for a field that may have been replaced in place.
    func sharesElement(with other: DictationInsertionTarget) -> Bool {
        switch (focusedElement, other.focusedElement) {
        case let (lhs?, rhs?): CFEqual(lhs, rhs)
        default: false
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.processIdentifier == rhs.processIdentifier
            && lhs.bundleID == rhs.bundleID
            && lhs.capturedAt == rhs.capturedAt
            && (lhs.focusedElement == nil && rhs.focusedElement == nil
                || lhs.sharesElement(with: rhs))
    }
}

enum DictationInsertionResult: Equatable {
    /// `anchor` is the range the paste replaced, read before it landed; Auto Learn needs it to
    /// find the inserted span without searching a document it must never walk.
    case inserted(characters: Int, anchor: NSRange?)
    case copiedToClipboard
    case failed(String)
}

/// Its own shape for the caller's report, so the injector stays owned by no one feature.
@MainActor
final class DictationInserter {
    private let injector: TextInjector
    private let clipboard: ClipboardManager

    init(injector: TextInjector, clipboard: ClipboardManager) {
        self.injector = injector
        self.clipboard = clipboard
    }

    /// Read before capture starts: by the time text arrives the field may already have moved.
    func captureTarget() -> DictationInsertionTarget? { frontmostTarget() }

    func currentTarget() -> DictationInsertionTarget? { frontmostTarget() }

    /// The injector owns the pasteboard lease and the focus restore; on refusal nothing is lost.
    func insert(
        _ text: String, into original: DictationInsertionTarget,
        isCurrent: @escaping @MainActor () -> Bool,
        completion: @escaping @MainActor (DictationInsertionResult) -> Void
    ) {
        guard !text.isEmpty else {
            completion(.failed(String(localized: "Nothing was recognized")))
            return
        }
        guard let app = original.application, !app.isTerminated, isPasteAllowed(original) else {
            copyInstead(text, completion: completion)
            return
        }
        let characters = text.count
        // Read the caret the paste is about to replace: the only trustworthy location for the span.
        let anchor = original.focusedElement.flatMap { AccessibilityText.selectedRange(of: $0) }.map {
            NSRange(location: $0.location, length: text.utf16.count)
        }
        injector.deliver(
            InjectedText(text), target: .external(app),
            expectedKeyword: nil, keywordLength: 0,
            automaticGeneration: nil,
            isValid: { [weak self] in isCurrent() && self?.isPasteAllowed(original) == true },
            onDelivered: { completion(.inserted(characters: characters, anchor: anchor)) },
            onFailed: { [weak self] in
                guard isCurrent() else { return }
                self?.copyInstead(text, completion: completion)
            })
    }

    private func isPasteAllowed(_ original: DictationInsertionTarget) -> Bool {
        guard let current = currentTarget() else {
            return DictationInsertionPolicy.allowsPaste(
                original: original.focusSnapshot, current: nil,
                frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                sameElement: false, now: Date())
        }
        return DictationInsertionPolicy.allowsPaste(
            original: original.focusSnapshot, current: current.focusSnapshot,
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            sameElement: original.sharesElement(with: current), now: Date())
    }

    private func frontmostTarget() -> DictationInsertionTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
            !app.isTerminated,
            app.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return nil }
        let element =
            Permissions.isAccessibilityTrusted()
            ? AccessibilityText.focusedElement(in: app) : nil
        return DictationInsertionTarget(
            processIdentifier: app.processIdentifier,
            bundleID: app.bundleIdentifier,
            application: app,
            focusedElement: element,
            capturedAt: Date())
    }

    /// Never type into someone else's field: the text goes to the pasteboard instead.
    private func copyInstead(
        _ text: String, completion: @escaping @MainActor (DictationInsertionResult) -> Void
    ) {
        guard Paster.copyPlainText(text) else {
            completion(.failed(String(localized: "Could not copy the dictation")))
            return
        }
        clipboard.synchronizeAfterTinycastPasteboardMutation(
            changeCount: NSPasteboard.general.changeCount)
        completion(.copiedToClipboard)
    }
}
