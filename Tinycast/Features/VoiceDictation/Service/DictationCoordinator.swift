import AppKit
import Foundation
import Observation

/// Dictation is the same client of Speech Runtime as Voice Ask: it shares capture, the pill and
/// the runtime adapter, and only its destination differs — the field the user was already in.
@MainActor
@Observable
final class DictationCoordinator {
    enum Phase: Equatable {
        case idle, connecting, listening, finishing, failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var transcript = ""
    private(set) var level: Float = 0
    private(set) var dictionary: DictationDictionary
    /// The last thing Auto Learn decided, so the pane can say why a rule did not appear.
    private(set) var lastAutoLearn: AutoLearnDecision?

    @ObservationIgnored private unowned let core: AppCore
    @ObservationIgnored private var capture: SpeechVoiceCapture { core.speechVoiceCapture }
    @ObservationIgnored private var microphone: SpeechVoiceMicrophone { capture.microphone }
    @ObservationIgnored private var transcription: SpeechRuntimeTranscriber { capture.transcriber }
    @ObservationIgnored private let store: DictationDictionaryStore
    @ObservationIgnored private var inserter: DictationInserter?
    @ObservationIgnored private var monitor: AutoLearnMonitor?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    @ObservationIgnored private var pendingFinishCaptureTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// Bumped when a session ends, so a callback queued by the last one cannot reach the next.
    @ObservationIgnored private var sessionToken = 0
    @ObservationIgnored private var earlyAudio = Data()
    @ObservationIgnored private var stopWhenReady = false
    @ObservationIgnored private var hotKeyDownAt: ContinuousClock.Instant?
    @ObservationIgnored private var capturedTarget: DictationInsertionTarget?

    private static let fallbackModel = "parakeet-ultra"
    /// Voice Ask's key, the middle link of the model fallback chain; no typed accessor exists.
    private static let voiceModelKey = "speechVoice.model"

    var isActive: Bool {
        switch phase {
        case .connecting, .listening, .finishing: true
        case .idle, .failed: false
        }
    }

    var phaseTitle: String {
        switch phase {
        case .idle: String(localized: "Ready")
        case .connecting: String(localized: "Connecting to Speech Runtime…")
        case .listening: String(localized: "Listening…")
        case .finishing: String(localized: "Recognizing…")
        case .failed(let message): message
        }
    }

    var suggestions: [DictationEntry] {
        dictionary.entries
            .filter { $0.approval == .suggested }
            .sorted { $0.createdAt > $1.createdAt }
    }

    init(core: AppCore) {
        self.core = core
        store = DictationDictionaryStore(directory: AppPaths.applicationSupport())
        dictionary = store.load()
    }

    /// Every callback the shared capture makes while this action owns it, and only then.
    private func handlers() -> SpeechVoiceCapture.Handlers {
        let token = sessionToken
        return SpeechVoiceCapture.Handlers(
            audio: { [weak self] data, level in
                self?.receiveAudio(data, level: level, token: token)
            },
            deviceLost: { [weak self] in self?.microphoneWentAway(token: token) },
            final: { [weak self] phrase in self?.receiveFinal(phrase, token: token) })
    }

    private func releaseCapture() {
        sessionToken &+= 1
        capture.release(.dictation)
    }

    // MARK: - Session

    func hotKeyDown() {
        switch VoiceShortcutGate.keyDown(
            mode: core.settings.dictationShortcutMode, isActive: isActive)
        {
        case .start:
            hotKeyDownAt = .now
            start()
        case .finish:
            requestFinish()
        case .ignore:
            break
        }
    }

    func hotKeyUp() {
        guard let down = hotKeyDownAt else { return }
        hotKeyDownAt = nil
        let held = down.duration(to: .now)
        if VoiceShortcutGate.keyUp(mode: core.settings.dictationShortcutMode, held: held) == .finish {
            requestFinish()
        }
    }

    func toggle() {
        if isActive { requestFinish() } else { start() }
    }

    func cancel() {
        generation &+= 1
        runTask?.cancel()
        runTask = nil
        finishTask?.cancel()
        finishTask = nil
        pendingFinishCaptureTask?.cancel()
        pendingFinishCaptureTask = nil
        releaseCapture()
        stopAutoLearn()
        earlyAudio.removeAll(keepingCapacity: false)
        stopWhenReady = false
        hotKeyDownAt = nil
        capturedTarget = nil
        level = 0
        transcript = ""
        phase = .idle
        capture.hidePill(for: .dictation)
    }

    private func start() {
        guard core.settings.dictationEnabled else { return }
        guard !isActive else { return }
        // Voice Ask may hold the microphone: one tap stays live, and its session is not interrupted.
        guard capture.claim(.dictation, handlers: handlers()) else { return }
        // A new capture ends the previous insertion's observation window.
        stopAutoLearn()
        generation &+= 1
        let id = generation
        capturedTarget = inserterOrMake().captureTarget()
        phase = .connecting
        transcript = ""
        earlyAudio = Data()
        stopWhenReady = false
        level = 0
        capture.showPill(pillModel, for: .dictation)
        runTask = Task { [weak self] in
            await self?.runSession(generation: id)
        }
    }

    private func runSession(generation id: Int) async {
        do {
            // Capture first: a short hold must not lose its first words while the model loads.
            try await microphone.start()
            guard id == generation, !Task.isCancelled else { return }
            let model = selectedModel
            let status = await core.speechRuntime.ensureRunning(model: model)
            guard id == generation, !Task.isCancelled else { return }
            guard case .ready = status else {
                fail(status.summary)
                return
            }
            try await transcription.start(model: model)
            guard id == generation, !Task.isCancelled else {
                transcription.cancel()
                return
            }
            if !earlyAudio.isEmpty { transcription.appendAudio(earlyAudio) }
            earlyAudio.removeAll(keepingCapacity: false)
            phase = .listening
            refreshPill()
            if stopWhenReady { requestFinish() }
        } catch {
            guard id == generation, !(error is CancellationError) else { return }
            fail(error.localizedDescription)
        }
    }

    private func receiveAudio(_ data: Data, level: Float, token: Int) {
        guard token == sessionToken else { return }
        guard core.settings.dictationEnabled else {
            cancel()
            return
        }
        guard !data.isEmpty else { return }
        self.level = level
        refreshPill()
        switch phase {
        case .connecting:
            // 30 seconds of mono/16 kHz/f32 audio is only 1.92 MiB.
            if earlyAudio.count + data.count > 30 * 16_000 * 4 {
                fail(String(localized: "Speech Runtime did not become ready in time"))
            } else {
                earlyAudio.append(data)
            }
        case .listening, .finishing:
            transcription.appendAudio(data)
        case .idle, .failed:
            break
        }
    }

    private func receiveFinal(_ phrase: String, token: Int) {
        guard token == sessionToken, isActive else { return }
        let cleaned = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        transcript = transcript.isEmpty ? cleaned : transcript + " " + cleaned
        refreshPill()
    }

    /// The headset left mid-dictation: keep what was said, finish without more audio.
    private func microphoneWentAway(token: Int) {
        guard token == sessionToken, isActive else { return }
        switch phase {
        case .connecting:
            fail(String(localized: "No microphone available"))
        case .listening:
            requestFinish()
        case .finishing, .idle, .failed:
            break
        }
    }

    private func requestFinish() {
        guard finishTask == nil else { return }
        switch phase {
        case .connecting:
            stopWhenReady = true
            // Never dictate while the model is loading: stop capture after its short tail.
            let id = generation
            pendingFinishCaptureTask?.cancel()
            pendingFinishCaptureTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(280))
                guard let self, id == self.generation, !Task.isCancelled else { return }
                self.microphone.stop()
                self.pendingFinishCaptureTask = nil
            }
        case .listening:
            phase = .finishing
            refreshPill()
            let id = generation
            finishTask = Task { [weak self] in
                await self?.finish(generation: id)
            }
        case .idle, .finishing, .failed:
            break
        }
    }

    private func finish(generation id: Int) async {
        // Release after the audio tap had time to deliver its last frame.
        try? await Task.sleep(for: .milliseconds(280))
        guard id == generation, !Task.isCancelled else { return }
        pendingFinishCaptureTask?.cancel()
        pendingFinishCaptureTask = nil
        microphone.stop()
        let recognized: String
        do {
            recognized = try await transcription.finish()
        } catch {
            guard id == generation, !(error is CancellationError) else { return }
            fail(error.localizedDescription)
            return
        }
        guard id == generation, !Task.isCancelled else { return }
        let trimmed = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            fail(String(localized: "No speech detected"))
            return
        }
        await deliver(trimmed, generation: id)
    }

    /// Spacing join → runtime cleanup and rules → insert, in that order, and never twice.
    private func deliver(_ recognized: String, generation id: Int) async {
        // The user may have switched dictation off while the model was still finishing.
        guard core.settings.dictationEnabled else {
            cancel()
            return
        }
        guard let target = capturedTarget else {
            copyInstead(recognized, generation: id)
            return
        }
        let cleanup = core.settings.dictationCleanupEnabled
        let rules = dictionary.active(for: target.bundleID).map {
            SpeechRuntimeRule(spoken: $0.spoken, replacement: $0.replacement)
        }
        // The runtime trims edges: boundary spacing is decided against the field after it answers.
        let processed: String
        do {
            processed = try await SpeechRuntimeHTTP().processDictation(
                text: recognized, cleanup: cleanup, rules: rules)
        } catch {
            guard id == generation, !Task.isCancelled, !(error is CancellationError),
                core.settings.dictationEnabled
            else { return }
            fail(error.localizedDescription)
            return
        }
        guard id == generation, !Task.isCancelled, core.settings.dictationEnabled,
            capturedTarget == target
        else { return }
        // Caret-only join of the runtime's result: never another trim or word change.
        let text = DictationTextFormatter.format(
            processed,
            context: cleanup ? DictationInsertionContext.read(in: target) : nil,
            options: DictationCleanupOptions(
                spacing: cleanup, capitalization: false, punctuation: false))
        guard !text.isEmpty else {
            fail(String(localized: "Nothing was recognized"))
            return
        }
        inserterOrMake().insert(text, into: target, isCurrent: { [weak self] in
            guard let self else { return false }
            return id == self.generation && self.core.settings.dictationEnabled && self.capturedTarget == target
        }) { [weak self] result in
            guard let self, id == self.generation else { return }
            self.releaseCapture()
            self.phase = .idle
            self.finishTask = nil
            self.hotKeyDownAt = nil
            self.capturedTarget = nil
            switch result {
            case .inserted(_, let anchor):
                self.core.showMessage(String(localized: "Dictated"))
                self.beginAutoLearnIfEnabled(inserted: text, target: target, anchor: anchor)
            case .copiedToClipboard:
                self.core.showMessage(
                    String(localized: "Copied — the field had moved"), tone: .neutral)
            case .failed(let message):
                self.fail(message)
            }
        }
    }

    private func copyInstead(_ text: String, generation id: Int) {
        guard id == generation else { return }
        guard Paster.copyPlainText(text) else {
            fail(String(localized: "Could not copy the dictation"))
            return
        }
        core.clipboardManager.synchronizeAfterTinycastPasteboardMutation(
            changeCount: NSPasteboard.general.changeCount)
        releaseCapture()
        phase = .idle
        finishTask = nil
        hotKeyDownAt = nil
        core.showMessage(String(localized: "Copied — the field had moved"), tone: .neutral)
    }

    private func fail(_ message: String) {
        generation &+= 1
        runTask?.cancel()
        runTask = nil
        finishTask?.cancel()
        finishTask = nil
        pendingFinishCaptureTask?.cancel()
        pendingFinishCaptureTask = nil
        releaseCapture()
        stopAutoLearn()
        earlyAudio.removeAll(keepingCapacity: false)
        stopWhenReady = false
        hotKeyDownAt = nil
        capturedTarget = nil
        phase = .failed(message)
        capture.showPill(pillModel, for: .dictation)
        let id = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            // Another action's pill is not ours to hide.
            guard let self, id == self.generation else { return }
            self.capture.hidePill(for: .dictation)
            self.phase = .idle
        }
    }

    private var pillModel: SpeechVoicePillModel {
        SpeechVoicePillModel(
            title: phaseTitle, detail: transcript, level: level,
            isListening: phase == .listening,
            onCancel: { [weak self] in self?.cancel() })
    }

    private func refreshPill() { capture.updatePill(pillModel, for: .dictation) }

    // MARK: - Auto Learn

    private func beginAutoLearnIfEnabled(
        inserted: String, target: DictationInsertionTarget, anchor: NSRange?
    ) {
        guard core.settings.dictationAutoLearnEnabled else { return }
        monitorOrMake().begin(
            afterInsertion: inserted, element: target.focusedElement, bundleID: target.bundleID,
            anchor: anchor)
    }

    private func stopAutoLearn() {
        guard let monitor else { return }
        // A revoked capability ends observation without publishing what it saw.
        if core.settings.dictationAutoLearnEnabled { monitor.cancel() }
        self.monitor = nil
    }

    private func monitorOrMake() -> AutoLearnMonitor {
        if let monitor { return monitor }
        let monitor = AutoLearnMonitor(
            // The setting is read every sample: turning Auto Learn off ends monitoring at once.
            isEnabled: { [weak self] in self?.core.settings.dictationAutoLearnEnabled ?? false },
            onCorrection: { [weak self] observation in self?.learn(from: observation) })
        self.monitor = monitor
        return monitor
    }

    /// The dictionary runs the policy and keeps only the pair it accepts; this keeps no history.
    private func learn(from observation: ObservedCorrection) {
        let before = dictionary
        let decision = dictionary.observe(observation)
        lastAutoLearn = decision
        switch decision {
        case .rejected:
            return
        case .suggest, .autoApply:
            save()
        }
        guard case .autoApply(let candidate) = decision else { return }
        let wasApproved =
            before.entry(
                matchingSpoken: candidate.spoken, replacement: candidate.replacement,
                scopeBundleID: candidate.scopeBundleID)?.approval == .approved
        guard !wasApproved else { return }
        core.showMessage(String(localized: "Added to the dictionary: \(candidate.replacement)"))
    }

    // MARK: - Dictionary

    @discardableResult
    func addEntry(spoken: String, replacement: String, kind: DictationEntry.Kind = .term,
                  scopeBundleID: String? = nil) -> DictationEntry? {
        guard
            let entry = persist(
                DictationEntry(
                    spoken: spoken, replacement: replacement, kind: kind,
                    scopeBundleID: scopeBundleID))
        else { return nil }
        return entry
    }

    func update(_ entry: DictationEntry) {
        guard dictionary.upsert(entry) != nil else { return }
        save()
    }

    func remove(id: UUID) {
        dictionary.remove(id: id)
        save()
    }

    func approve(id: UUID) {
        guard dictionary.approve(id: id) != nil else { return }
        dictionary.setEnabled(true, id: id)
        save()
    }

    func reject(id: UUID) {
        dictionary.remove(id: id)
        save()
    }

    func setEnabled(_ isEnabled: Bool, id: UUID) {
        guard dictionary.setEnabled(isEnabled, id: id) != nil else { return }
        save()
    }

    @discardableResult
    private func persist(_ entry: DictationEntry) -> DictationEntry? {
        guard let stored = dictionary.upsert(entry) else { return nil }
        save()
        return stored
    }

    private func save() {
        do {
            try store.save(dictionary)
        } catch {
            core.showMessage(
                String(localized: "Could not save the dictionary"), tone: .danger)
        }
    }

    // MARK: - Runtime

    private var selectedModel: String {
        let chosen = core.settings.dictationModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !chosen.isEmpty { return chosen }
        // The fallback chain lets one Speech Runtime serve both actions by default.
        let voice = UserDefaults.standard.string(forKey: Self.voiceModelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return voice.isEmpty ? Self.fallbackModel : voice
    }

    private func inserterOrMake() -> DictationInserter {
        if let inserter { return inserter }
        let inserter = DictationInserter(
            injector: core.textInjector, clipboard: core.clipboardManager)
        self.inserter = inserter
        return inserter
    }
}
