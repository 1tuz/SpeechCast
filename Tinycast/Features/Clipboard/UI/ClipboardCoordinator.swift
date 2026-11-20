import AppKit

@MainActor
final class ClipboardCoordinator {
    private let clipboardStore: ClipboardStore
    private let clipboardManager: ClipboardManager
    private let settings: AppSettings
    private let appIndex: AppIndex
    private let palette: PaletteState
    private let windowController: PaletteWindowController
    private let paletteCoordinator: PaletteCoordinator
    private unowned let core: AppCore
    /// One Copy Text at a time: a newer trigger cancels the helper an older one is waiting on.
    private var textTask: Task<Void, Never>?
    private var pasteSequence: PasteSequence?
    private var isHistoryPastePending = false

    init(
        clipboardStore: ClipboardStore,
        clipboardManager: ClipboardManager,
        settings: AppSettings,
        appIndex: AppIndex,
        palette: PaletteState,
        windowController: PaletteWindowController,
        paletteCoordinator: PaletteCoordinator,
        core: AppCore
    ) {
        self.clipboardStore = clipboardStore
        self.clipboardManager = clipboardManager
        self.settings = settings
        self.appIndex = appIndex
        self.palette = palette
        self.windowController = windowController
        self.paletteCoordinator = paletteCoordinator
        self.core = core
    }

    /// Off means the poller stops, the database closes and nothing new is ever recorded.
    func applyEnabled() {
        appIndex.setCommandsVisible([.clipboardHistory, .pasteSequentially], settings.clipboardEnabled)
        guard settings.clipboardEnabled else {
            core.applyClipboardTextSearch()
            clipboardManager.stop()
            if palette.mode == .clipboard { palette.prepare(mode: .launcher) }
            clipboardStore.close()
            return
        }
        clipboardStore.open()
        clipboardStore.maxAge = settings.clipboardRetention.maxAge
        clipboardManager.start()
        core.applyClipboardTextSearch()
        // Deferred off the launch path: the palette fills in behind the SQLite read and prune.
        Task { clipboardStore.load() }
    }

    func followSearchResults(query: String, previous: [ClipboardItem], current: [ClipboardItem]) {
        guard palette.isVisible, palette.mode == .clipboard,
            palette.query.trimmingCharacters(in: .whitespaces) == query,
            previous.indices.contains(palette.selection)
        else { return }
        let selectedID = previous[palette.selection].id
        if let index = current.firstIndex(where: { $0.id == selectedID }) {
            palette.selection = index
        }
    }

    func applyRetention(_ retention: ClipboardRetention) {
        clipboardStore.maxAge = retention.maxAge
        clipboardStore.enforceLimits()
    }

    /// ↵ runs the configured default and the other chords follow it; false when `chord` has none.
    @discardableResult
    func activate(_ item: ClipboardItem, chord: ClipboardChord = .return) -> Bool {
        guard let action = settings.clipboardDefaultAction.action(for: chord, on: item) else {
            return false
        }
        perform(action, on: item)
        return true
    }

    func perform(_ action: ClipboardDefaultAction, on item: ClipboardItem) {
        switch action {
        case .paste: paste(item, plainText: false, keepingWindowOpen: false)
        case .copy: copyToClipboard(item)
        case .pastePlainText: paste(item, plainText: true, keepingWindowOpen: false)
        }
    }

    func pasteKeepingWindowOpen(_ item: ClipboardItem) {
        paste(item, plainText: false, keepingWindowOpen: true)
    }

    private func paste(_ item: ClipboardItem, plainText: Bool, keepingWindowOpen: Bool) {
        guard !isHistoryPastePending, !core.isShowingDialog else { return }
        do throws(Paster.HistoryPasteFailure) {
            let (target, changeCount) = try Paster.prepareHistoryPaste(
                item, store: clipboardStore, into: windowController.previousApp, plainText: plainText)
            if !keepingWindowOpen { try closePaletteForHistoryPaste(into: target) }
            scheduleHistoryPaste(into: target, changeCount: changeCount, keepingWindowOpen: keepingWindowOpen) {
                guard !keepingWindowOpen else { return }
                self.clipboardStore.promote(item)
                if self.palette.mode == .clipboard { self.selectClip(item) }
            }
        } catch {
            reportHistoryPasteFailure(error, item: item)
        }
    }

    /// Each press sends the next older entry to the app in front, without promoting it.
    func pasteNextInSequence() {
        let now = Date()
        // Dropped rather than queued, so a held shortcut cannot paste a burst of entries.
        guard !isHistoryPastePending, !core.isShowingDialog,
            pasteSequence?.isSettling(at: now) != true
        else { return }
        do throws(Paster.HistoryPasteFailure) {
            let target = try Paster.checkHistoryPasteTarget(paletteCoordinator.targetApp)
            // Capture a fresh copy before choosing the next entry or replacing the pasteboard.
            clipboardManager.prepareForTinycastPasteboardMutation()
            var sequence = continuingPasteSequence(at: now)
            while let item = sequence.next(in: clipboardStore.items) {
                do throws(Paster.HistoryPasteFailure) {
                    let (_, changeCount) = try Paster.prepareHistoryPaste(
                        item, store: clipboardStore, into: target, plainText: false)
                    if paletteCoordinator.isVisible { try closePaletteForHistoryPaste(into: target) }
                    scheduleHistoryPaste(into: target, changeCount: changeCount, keepingWindowOpen: false) {
                        sequence.recordPaste(changeCount: changeCount, at: Date())
                        self.pasteSequence = sequence
                    }
                    return
                } catch .unavailable {
                    // A vanished file or image writes nothing. Try the next entry on this press.
                    continue
                }
            }
            core.showMessage(String(localized: "Nothing left to paste"), tone: .neutral)
        } catch {
            reportHistoryPasteFailure(error)
        }
    }

    private func closePaletteForHistoryPaste(into target: NSRunningApplication)
        throws(Paster.HistoryPasteFailure)
    {
        paletteCoordinator.hidePalette(restoreFocus: false)
        // The non-activating panel can hold key while the target is still frontmost.
        // Hand key focus back now, never from the delayed post after the user can switch apps.
        _ = try Paster.checkHistoryPasteTarget(target)
        target.activate()
    }

    private func scheduleHistoryPaste(
        into target: NSRunningApplication, changeCount: Int, keepingWindowOpen: Bool,
        onPost: @escaping @MainActor () -> Void
    ) {
        isHistoryPastePending = true
        let focusToken = palette.focusToken
        // Give the focus handoff and pasteboard write time to settle before sending ⌘V.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            defer { self.isHistoryPastePending = false }
            do throws(Paster.HistoryPasteFailure) {
                guard self.paletteCoordinator.isVisible == keepingWindowOpen,
                    self.palette.focusToken == focusToken, !self.core.isShowingDialog
                else { throw .focusChanged }
                try Paster.postHistoryPaste(into: target, changeCount: changeCount)
                onPost()
            } catch {
                self.reportHistoryPasteFailure(error)
            }
        }
    }

    private func reportHistoryPasteFailure(
        _ failure: Paster.HistoryPasteFailure, item: ClipboardItem? = nil
    ) {
        switch failure {
        case .needsAccessibility:
            Task {
                let openSettings = await core.reportFailure(
                    title: String(localized: "Tinycast Needs Accessibility Access"),
                    message: String(localized: """
                        Allow Tinycast to paste into other apps. If it’s already listed, remove it and add it again. You can still copy from Clipboard History.
                        """),
                    symbol: PaletteMode.clipboard.systemImage, recovery: String(localized: "Open Settings"))
                if openSettings { Permissions.openAccessibilitySettings() }
            }
        case .noTarget:
            core.showMessage(String(localized: "Open an app to paste into first."), tone: .neutral)
        case .focusChanged:
            core.showMessage(String(localized: "Focus changed, nothing pasted."), tone: .neutral)
        case .clipboardChanged:
            core.showMessage(String(localized: "Clipboard changed, nothing pasted."), tone: .neutral)
        case .unavailable:
            if let item, item.kind == .file {
                reportUnavailable(item)
            } else {
                core.showMessage(String(localized: "That clipboard entry is no longer available."), tone: .danger)
            }
        case .eventCreationFailed:
            core.showMessage(String(localized: "Couldn’t send the paste shortcut. Try pressing ⌘V."), tone: .danger)
        }
    }

    /// A copy since the last press, or a long pause, starts the walk over from the newest entry.
    private func continuingPasteSequence(at now: Date) -> PasteSequence {
        let changeCount = NSPasteboard.general.changeCount
        if let pasteSequence, pasteSequence.continues(changeCount: changeCount, at: now) {
            return pasteSequence
        }
        return PasteSequence(history: clipboardStore.items, changeCount: changeCount, now: now)
    }

    /// A write only fails on a vanished file, and a palette that just closes explains nothing.
    private func reportUnavailable(_ item: ClipboardItem) {
        guard item.kind == .file else { return }
        core.showMessage(String(localized: "That file has moved or been deleted."), tone: .danger)
    }

    /// Both the ⌃⇧X chord and the menu row land here, so neither can skip the confirmation.
    func deleteAllClips() async {
        guard
            await core.confirm(
                title: String(localized: "Delete All Entries"),
                message: String(
                    localized: """
                        Are you sure you want to proceed with deleting all clipboard history entries?
                        """),
                symbol: PaletteMode.clipboard.systemImage, confirmTitle: String(localized: "Delete All"))
        else { return }
        clearHistory()
    }

    /// Reachable with the feature off, so what was kept before can still be erased afterwards.
    func clearHistory() {
        clipboardStore.open()
        clipboardStore.clearAll()
        if !settings.clipboardEnabled { clipboardStore.close() }
    }

    func copyToClipboard(_ item: ClipboardItem) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        if Paster.copy(item, store: clipboardStore) {
            selectClip(item)
        } else {
            reportUnavailable(item)
        }
    }

    /// Unmarked, so a converted colour enters history itself — it is one you meant to keep.
    func copyColor(_ color: ColorValue, as format: ColorFormat) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        Paster.copyPlainText(format.string(for: color))
    }

    func revealClip(_ item: ClipboardItem) {
        guard let url = clipURL(for: item) else { return }
        paletteCoordinator.hidePalette(restoreFocus: false)
        AppLauncher.showInFinder(url)
    }

    /// Nil only for a vanished file, which the HUD reports rather than hand over a dead path.
    func dragPayload(for item: ClipboardItem) -> ClipDragPayload? {
        let payload = item.dragPayload
        guard case .file = payload else { return payload }
        return clipURL(for: item).map(ClipDragPayload.file)
    }

    func openClip(_ item: ClipboardItem) {
        guard let url = clipURL(for: item) else { return }
        paletteCoordinator.hidePalette(restoreFocus: false)
        AppLauncher.open(url)
    }

    /// Unmarked, so the path enters history like any other copy the reader meant to make.
    func copyClipPath(_ item: ClipboardItem) {
        guard let path = item.filePath else { return }
        paletteCoordinator.hidePalette(restoreFocus: false)
        Paster.copyPlainText(path)
        core.showMessage(String(localized: "Copied path"))
    }

    func copyImageText(_ item: ClipboardItem) {
        guard let path = item.imagePath ?? item.filePath else { return }
        paletteCoordinator.hidePalette(restoreFocus: false)
        core.showProgress(String(localized: "Reading text…"))
        let changeCount = NSPasteboard.general.changeCount
        textTask?.cancel()
        textTask = Task {
            do {
                // A stat on an unmounted or network volume can stall, so it stays off-main.
                let exists = await Task.detached { FileManager.default.fileExists(atPath: path) }.value
                try Task.checkCancellation()
                guard exists else {
                    return item.kind == .file
                        ? reportUnavailable(item)
                        : core.showMessage(
                            String(localized: "That image is no longer available."), tone: .danger)
                }
                let text = try await ClipboardTextWorker.extract(item)
                guard !text.isEmpty else {
                    return core.showMessage(String(localized: "No text found"), tone: .neutral)
                }
                guard NSPasteboard.general.changeCount == changeCount else {
                    return core.showMessage(
                        String(localized: "Clipboard changed, text not copied"), tone: .neutral)
                }
                Paster.copyPlainText(text)
                core.showMessage(String(localized: "Copied text"))
            } catch is CancellationError {
            } catch {
                core.showMessage(String(localized: "Couldn’t read the text"), tone: .danger)
            }
        }
    }

    /// Nil once the file is gone, so every action reports rather than silently no-opping.
    private func clipURL(for item: ClipboardItem) -> URL? {
        let url = clipboardStore.imageURL(for: item) ?? clipboardStore.fileURL(for: item)
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            reportUnavailable(item)
            return nil
        }
        return url
    }

    func editClip(_ item: ClipboardItem) async {
        guard item.kind == .text else { return }
        guard let text = await core.editClipboardText(item.text ?? ""), !text.isEmpty else { return }
        do {
            guard let edited = try clipboardStore.updateText(text, of: item) else {
                Paster.copyPlainText(text)
                return
            }
            Paster.copy(edited, store: clipboardStore)
            guard palette.mode == .clipboard else { return }
            if !palette.clipboardFilter.matches(edited) { palette.clipboardFilter = .all }
            if clipboardStore.rowIndex(of: edited, in: palette.query, filter: palette.clipboardFilter) == nil
            {
                palette.query = ""
            }
            selectClip(edited)
            palette.preserveSelection()
            palette.followToken = UUID()
        } catch .tooLong {
            let limit = ClipboardStore.maxTextLength.formatted()
            core.showMessage(
                String(localized: "Too long to save. Keep it under \(limit) characters."), tone: .danger)
        } catch {
            core.showMessage(String(localized: "Couldn’t save the clipboard entry"), tone: .danger)
        }
    }

    /// Pin or unpin an entry; the selection and scroll follow the row as it moves.
    func togglePinnedClip(_ item: ClipboardItem) {
        clipboardStore.togglePinned(item)
        selectClip(item)
        palette.followToken = UUID()
    }

    /// Select `item`'s row as currently filtered; a moved row isn't always index 0.
    private func selectClip(_ item: ClipboardItem) {
        palette.selection =
            clipboardStore.rowIndex(
                of: item, in: palette.query, filter: palette.clipboardFilter) ?? 0
    }
}
