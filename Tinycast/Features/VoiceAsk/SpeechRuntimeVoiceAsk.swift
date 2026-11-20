import AppKit
@preconcurrency import AVFoundation
import Foundation
import Observation

/// Voice input is a client of Speech Runtime, not an additional model host.
/// The user controls the daemon and model downloads in Speech Runtime.app.
@MainActor
@Observable
final class SpeechRuntimeVoiceAsk {
    enum Phase: Equatable {
        case idle, connecting, listening, finishing, failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var transcript = ""
    private(set) var level: Float = 0
    private(set) var availability = "Not checked"

    @ObservationIgnored private unowned let core: AppCore
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    @ObservationIgnored private var pendingFinishCaptureTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// Bumped when a session ends, so a callback queued by the last one cannot reach the next.
    @ObservationIgnored private var sessionToken = 0
    @ObservationIgnored private var fromPalette = false
    @ObservationIgnored private var savedQuery: String?
    @ObservationIgnored private var earlyAudio = Data()
    @ObservationIgnored private var stopWhenReady = false
    @ObservationIgnored private var hyperHold = false
    @ObservationIgnored private var hotKeyDownAt: ContinuousClock.Instant?

    var isActive: Bool {
        switch phase {
        case .connecting, .listening, .finishing: true
        case .idle, .failed: false
        }
    }

    var phaseTitle: String {
        switch phase {
        case .idle: "Ready"
        case .connecting: "Connecting to Speech Runtime…"
        case .listening: "Listening…"
        case .finishing: "Recognizing…"
        case .failed(let message): message
        }
    }

    /// The shared capture: Dictation drives the same instance, so a claim is what keeps one tap live.
    private var capture: SpeechVoiceCapture { core.speechVoiceCapture }
    private var microphone: SpeechVoiceMicrophone { capture.microphone }
    private var transcription: SpeechRuntimeTranscriber { capture.transcriber }

    init(core: AppCore) {
        self.core = core
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
        capture.release(.voiceAsk)
    }

    func toggleFromPalette() {
        if isActive {
            requestFinish()
        } else {
            start(fromPalette: true)
        }
    }

    /// The mode is the user's per action: "smart" reads a short tap as toggle and a hold as talk.
    func hotKeyDown() {
        switch VoiceShortcutGate.keyDown(mode: core.settings.voiceShortcutMode, isActive: isActive) {
        case .start:
            hotKeyDownAt = .now
            start(fromPalette: core.paletteCoordinator.isVisible)
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
        if VoiceShortcutGate.keyUp(mode: core.settings.voiceShortcutMode, held: held) == .finish {
            requestFinish()
        }
    }

    private var pillModel: SpeechVoicePillModel {
        SpeechVoicePillModel(
            title: phaseTitle, detail: transcript, level: level,
            isListening: phase == .listening,
            onCancel: { [weak self] in self?.cancel() })
    }

    private func refreshPill() { capture.updatePill(pillModel, for: .voiceAsk) }

    /// This is called only after an unused Hyper key has been held for 250 ms.
    func beginHyperHold() {
        guard !isActive else { return }
        hyperHold = true
        start(fromPalette: core.paletteCoordinator.isVisible)
    }

    func endHyperHold() {
        guard hyperHold else { return }
        hyperHold = false
        requestFinish()
    }

    func cancelHyperHold() {
        guard hyperHold else { return }
        cancel()
    }

    func checkAvailability() {
        Task {
            do {
                let models = try await transcription.checkModels()
                let names = models.map(\.model).joined(separator: ", ")
                availability = "Connected" + (names.isEmpty ? "" : " · " + names)
            } catch {
                availability = error.localizedDescription
            }
        }
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
        earlyAudio.removeAll(keepingCapacity: false)
        level = 0
        stopWhenReady = false
        hotKeyDownAt = nil
        hyperHold = false
        if let savedQuery { core.palette.query = savedQuery }
        savedQuery = nil
        transcript = ""
        phase = .idle
        capture.hidePill(for: .voiceAsk)
    }

    private func start(fromPalette: Bool) {
        guard UserDefaults.standard.bool(forKey: "speechVoice.enabled") else { return }
        guard core.settings.aiEnabled else { return }
        guard !isActive else { return }
        // Dictation may hold the microphone: the other action's session is never interrupted.
        guard capture.claim(.voiceAsk, handlers: handlers()) else { return }
        generation &+= 1
        let id = generation
        self.fromPalette = fromPalette
        phase = .connecting
        transcript = ""
        earlyAudio = Data()
        stopWhenReady = false
        level = 0
        if fromPalette {
            savedQuery = core.palette.query
            core.palette.query = ""
        } else {
            savedQuery = nil
            capture.showPill(pillModel, for: .voiceAsk)
        }
        runTask = Task { [weak self] in
            await self?.runSession(generation: id)
        }
    }

    private func runSession(generation id: Int) async {
        do {
            // Capture first: a short Hyper hold must not lose its first words during model load.
            try await microphone.start()
            guard id == generation, !Task.isCancelled else { return }
            let model = UserDefaults.standard.string(forKey: "speechVoice.model")
                .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                ?? "parakeet-ultra"
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
        guard !data.isEmpty else { return }
        self.level = level
        refreshPill()
        switch phase {
        case .connecting:
            // 30 seconds of mono/16 kHz/f32 audio is only 1.92 MiB.
            // Never silently discard the start of a dictation when ANE is cold.
            if earlyAudio.count + data.count > 30 * 16_000 * 4 {
                fail("Speech Runtime did not become ready within 30 seconds of audio")
            } else {
                earlyAudio.append(data)
            }
        case .listening, .finishing:
            transcription.appendAudio(data)
        case .idle, .failed:
            break
        }
    }

    /// The headset left mid-dictation: keep what was said, finish without more audio.
    private func microphoneWentAway(token: Int) {
        guard token == sessionToken, isActive else { return }
        switch phase {
        case .connecting:
            fail("No microphone available")
        case .listening:
            requestFinish()
        case .finishing, .idle, .failed:
            break
        }
    }

    private func receiveFinal(_ phrase: String, token: Int) {
        guard token == sessionToken, isActive else { return }
        let cleaned = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        transcript = transcript.isEmpty ? cleaned : transcript + " " + cleaned
        refreshPill()
        if fromPalette { core.palette.query = transcript }
    }

    private func requestFinish() {
        guard finishTask == nil else { return }
        switch phase {
        case .connecting:
            stopWhenReady = true
            // Do not keep recording while the model is downloading or compiling.
            // A released Hyper hold ends capture after its short tail, regardless
            // of the Speech Runtime connection latency.
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
        do {
            let text = try await transcription.finish()
            guard id == generation, !Task.isCancelled else { return }
            let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty else {
                fail("No speech detected")
                return
            }
            let previousQuery = savedQuery
            savedQuery = nil
            releaseCapture()
            phase = .idle
            hotKeyDownAt = nil
            hyperHold = false
            finishTask = nil
            // Restore a draft before dispatching an action that may close the palette.
            // Recognition and command matching remain entirely local.
            let commandsEnabled = UserDefaults.standard.object(forKey: "speechVoice.commandsEnabled") == nil
                || UserDefaults.standard.bool(forKey: "speechVoice.commandsEnabled")
            if commandsEnabled {
                if let previousQuery { core.palette.query = previousQuery }
                if SpeechVoiceCommandRouter.route(result, core: core) { return }
            }
            // Non-command speech still uses the existing Quick AI delivery policy.
            if UserDefaults.standard.bool(forKey: "speechVoice.autoSend") {
                core.quickAICoordinator.sendVoicePrompt(result)
            } else {
                core.quickAICoordinator.composeVoicePrompt(result)
            }
        } catch {
            guard id == generation, !(error is CancellationError) else { return }
            fail(error.localizedDescription)
        }
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
        earlyAudio.removeAll(keepingCapacity: false)
        stopWhenReady = false
        hotKeyDownAt = nil
        hyperHold = false
        if let savedQuery { core.palette.query = savedQuery }
        savedQuery = nil
        phase = .failed(message)
        capture.showPill(pillModel, for: .voiceAsk)
        let id = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            // Another action's pill is not ours to hide.
            guard let self, id == self.generation else { return }
            self.capture.hidePill(for: .voiceAsk)
            self.phase = .idle
        }
    }
}
