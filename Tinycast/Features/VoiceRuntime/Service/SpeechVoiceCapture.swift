import AppKit
import Foundation

/// One microphone, one transcriber and one pill, shared by Voice Ask and Dictation.
///
/// Two live taps on one input device is not a state to reach, and neither feature may cancel the
/// other's session: a claim is refused while the other owner holds it, and a release only ever
/// stops what its own owner claimed.
@MainActor
final class SpeechVoiceCapture {
    enum Owner: Equatable {
        case voiceAsk, dictation
    }

    struct Handlers {
        let audio: (Data, Float) -> Void
        let deviceLost: () -> Void
        let final: (String) -> Void
    }

    let microphone = SpeechVoiceMicrophone()
    let transcriber = SpeechRuntimeTranscriber()
    let pill = SpeechVoicePillController()

    private(set) var owner: Owner?
    /// Independent of `owner`: a failure pill outlives the session it reports.
    private(set) var pillOwner: Owner?
    private var handlers: Handlers?

    init() {
        microphone.onAudio = { [weak self] data, level in self?.handlers?.audio(data, level) }
        microphone.onDeviceLost = { [weak self] in self?.handlers?.deviceLost() }
        transcriber.onFinal = { [weak self] phrase in self?.handlers?.final(phrase) }
    }

    /// False when the other feature holds the microphone. The caller then leaves that session be.
    func claim(_ owner: Owner, handlers: Handlers) -> Bool {
        guard self.owner == nil || self.owner == owner else { return false }
        self.owner = owner
        self.handlers = handlers
        return true
    }

    /// Stops the shared hardware for the owner that holds it, and drops its callbacks with it.
    func release(_ owner: Owner) {
        guard self.owner == owner else { return }
        self.owner = nil
        handlers = nil
        microphone.stop()
        transcriber.cancel()
        hidePill(for: owner)
    }

    /// A session shows while it owns capture; a failure report shows once capture is already gone.
    func showPill(_ model: SpeechVoicePillModel, for owner: Owner) {
        guard self.owner == nil || self.owner == owner else { return }
        pillOwner = owner
        pill.show(model)
    }

    func updatePill(_ model: SpeechVoicePillModel, for owner: Owner) {
        guard pillOwner == owner else { return }
        pill.update(model)
    }

    /// The other action's pill is not this one's to hide.
    func hidePill(for owner: Owner) {
        guard pillOwner == owner else { return }
        pillOwner = nil
        pill.hide()
    }
}
