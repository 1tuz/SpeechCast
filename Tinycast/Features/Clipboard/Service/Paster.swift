import AppKit
import Carbon.HIToolbox

enum Paster {
    /// Stamped on Tinycast's own synthetic keystrokes so the snippet keyword tap can skip them.
    static let tinycastEventTag: Int64 = 0x54494E59

    /// Covers the gap between `activate()` returning and the target app accepting a keystroke.
    private static let activationDelay: TimeInterval = 0.08

    /// Shorter: no activation to wait on, only the pasteboard write reaching the target's process.
    private static let directPostDelay: TimeInterval = 0.05

    enum HistoryPasteFailure: Error {
        case needsAccessibility, noTarget, focusChanged, unavailable, clipboardChanged, eventCreationFailed
    }

    @MainActor
    static func checkHistoryPasteTarget(_ app: NSRunningApplication?) throws(HistoryPasteFailure)
        -> NSRunningApplication
    {
        guard Permissions.ensureAccessibility() else { throw .needsAccessibility }
        return try validateHistoryPasteTarget(app)
    }

    @MainActor
    private static func validateHistoryPasteTarget(_ app: NSRunningApplication?) throws(HistoryPasteFailure)
        -> NSRunningApplication
    {
        guard let app, !app.isTerminated,
            app.processIdentifier != NSRunningApplication.current.processIdentifier
        else { throw .noTarget }
        // The non-activating palette leaves its external target frontmost.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw .focusChanged
        }
        return app
    }

    @MainActor
    static func prepareHistoryPaste(
        _ item: ClipboardItem, store: ClipboardStore, into app: NSRunningApplication?,
        plainText: Bool, on pb: NSPasteboard = .general
    ) throws(HistoryPasteFailure) -> (target: NSRunningApplication, changeCount: Int) {
        let target = try checkHistoryPasteTarget(app)
        if plainText {
            guard let text = item.plainText, writeString(text, to: pb) else { throw .unavailable }
        } else {
            guard write(item, store: store, to: pb) else { throw .unavailable }
        }
        return (target, pb.changeCount)
    }

    /// Throw if the shortcut cannot be posted. Posting does not confirm that the receiver pasted.
    @MainActor
    static func postHistoryPaste(into app: NSRunningApplication, changeCount: Int)
        throws(HistoryPasteFailure)
    {
        guard Permissions.isAccessibilityTrusted() else { throw .needsAccessibility }
        _ = try validateHistoryPasteTarget(app)
        guard NSPasteboard.general.changeCount == changeCount else { throw .clipboardChanged }
        guard sendCommand(key: CGKeyCode(kVK_ANSI_V), toPid: app.processIdentifier) else {
            throw .eventCreationFailed
        }
    }

    /// Put the item on the pasteboard without pasting; the marker stops re-capture.
    @MainActor @discardableResult
    static func copy(_ item: ClipboardItem, store: ClipboardStore, to pb: NSPasteboard = .general) -> Bool {
        guard write(item, store: store, to: pb) else { return false }
        store.promote(item)
        return true
    }

    /// Put a string on the pasteboard unmarked, so it enters history like any other copy.
    @MainActor @discardableResult
    static func copyPlainText(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string], owner: nil)
        return pb.setString(text, forType: .string)
    }

    /// Marker-stamped so the text doesn't re-enter history.
    @MainActor
    static func pasteString(_ text: String, previousApp: NSRunningApplication?) {
        writeString(text)
        previousApp?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay) {
            postCommandV()
        }
    }

    @MainActor
    static func pasteFile(_ url: URL, previousApp: NSRunningApplication?) {
        PasteboardFiles.write(url, to: .general)
        previousApp?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay) {
            postCommandV()
        }
    }

    @MainActor
    static func copyString(_ text: String) {
        writeString(text)
    }

    /// Paste a string directly into the target while the palette stays frontmost.
    @MainActor
    static func pasteStringInPlace(_ text: String, into app: NSRunningApplication?) {
        writeString(text)
        guard let pid = app?.processIdentifier else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + directPostDelay) {
            postCommandV(toPid: pid)
        }
    }

    @MainActor @discardableResult
    private static func writeString(_ text: String, to pb: NSPasteboard = .general) -> Bool {
        pb.clearContents()
        pb.declareTypes([.string, ClipboardManager.internalType], owner: nil)
        let written = pb.setString(text, forType: .string)
        pb.setData(Data(), forType: ClipboardManager.internalType)
        return written
    }

    /// Whether anything was written; a vanished item leaves the pasteboard untouched.
    @MainActor @discardableResult
    static func write(
        _ item: ClipboardItem, store: ClipboardStore, to pb: NSPasteboard = .general
    ) -> Bool {
        switch item.kind {
        case .text:
            guard let text = item.text else { return false }
            pb.clearContents()
            pb.declareTypes([.string, ClipboardManager.internalType], owner: nil)
            pb.setString(text, forType: .string)
        case .image:
            guard let url = store.imageURL(for: item),
                let data = try? Data(contentsOf: url, options: .mappedIfSafe)
            else {
                return false
            }
            pb.clearContents()
            pb.declareTypes([.png, .fileURL, ClipboardManager.internalType], owner: nil)
            pb.setData(data, forType: .png)
            // A text-only receiver ignores image data but pastes a file URL as its path.
            pb.setData(url.dataRepresentation, forType: .fileURL)
        case .file:
            guard let url = store.fileURL(for: item),
                FileManager.default.fileExists(atPath: url.path)
            else { return false }
            pb.clearContents()
            pb.declareTypes([.fileURL, .string, ClipboardManager.internalType], owner: nil)
            pb.setData(url.dataRepresentation, forType: .fileURL)
            // Both types: a file-taking app receives the file, a text field receives the path.
            pb.setString(url.path, forType: .string)
        }
        pb.setData(Data(), forType: ClipboardManager.internalType)
        return true
    }

    @MainActor
    static func postCommandV(toPid pid: pid_t? = nil) {
        postCommand(key: CGKeyCode(kVK_ANSI_V), toPid: pid)
    }

    /// Synthesize ⌘C, for reading a selection an app will not surface over Accessibility.
    @MainActor
    static func postCommandC(toPid pid: pid_t? = nil) {
        postCommand(key: CGKeyCode(kVK_ANSI_C), toPid: pid)
    }

    @MainActor
    private static func postCommand(key: CGKeyCode, toPid pid: pid_t?) {
        guard Permissions.ensureAccessibility() else { return }
        _ = sendCommand(key: key, toPid: pid)
    }

    @MainActor
    private static func sendCommand(key: CGKeyCode, toPid pid: pid_t?) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return false }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: tinycastEventTag)
        up.setIntegerValueField(.eventSourceUserData, value: tinycastEventTag)

        if let pid {
            down.postToPid(pid)
            up.postToPid(pid)
        } else {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return true
    }
}
