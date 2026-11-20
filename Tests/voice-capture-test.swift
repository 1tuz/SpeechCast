import AppKit
import Foundation

@main
@MainActor
struct VoiceCaptureTest {
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

    /// One session's callback tally, so a callback that reaches the wrong owner is visible.
    final class Ear {
        var audio = 0
        var lost = 0
        var finals: [String] = []
        var handlers: SpeechVoiceCapture.Handlers {
            SpeechVoiceCapture.Handlers(
                audio: { [self] _, _ in audio += 1 },
                deviceLost: { [self] in lost += 1 },
                final: { [self] phrase in finals.append(phrase) })
        }
    }

    static func model(_ title: String) -> SpeechVoicePillModel {
        SpeechVoicePillModel(
            title: title, detail: "", level: 0, isListening: false, onCancel: {})
    }

    static func main() {
        let capture = SpeechVoiceCapture()
        let first = Ear()
        let second = Ear()

        expect(capture.owner, nil as SpeechVoiceCapture.Owner?, "a new capture has no owner")
        expect(capture.pillOwner, nil as SpeechVoiceCapture.Owner?, "a new capture shows no pill")
        expect(capture.microphone.onAudio != nil, true, "the capture owns the microphone callbacks")

        // Claim: one owner at a time, and the other action is refused, not queued.
        expect(capture.claim(.dictation, handlers: first.handlers), true, "an idle capture is claimable")
        expect(capture.owner, .dictation, "the claim records its owner")
        expect(capture.claim(.voiceAsk, handlers: second.handlers), false,
               "the other action's claim is refused while dictation holds capture")
        expect(capture.owner, .dictation, "a refused claim does not change the owner")
        expect(capture.claim(.dictation, handlers: first.handlers), true,
               "the holder may refresh its own handlers")

        // Routing: only the holder's handlers see the shared hardware.
        capture.microphone.onAudio?(Data([1]), 0.5)
        capture.transcriber.onFinal?("hello")
        capture.microphone.onDeviceLost?()
        expect(first.audio, 1, "audio reaches the holding owner")
        expect(first.finals, ["hello"], "a final phrase reaches the holding owner")
        expect(first.lost, 1, "a lost device reaches the holding owner")
        expect(second.audio, 0, "the refused owner hears no audio")
        expect(second.finals, [], "the refused owner hears no final phrase")

        // A release only ever stops what its own owner claimed.
        capture.release(.voiceAsk)
        expect(capture.owner, .dictation, "the other action's release leaves dictation alone")
        capture.microphone.onAudio?(Data([2]), 0.2)
        expect(first.audio, 2, "a foreign release does not drop the holder's callbacks")

        // Pill ownership: the holder's pill, never the other action's.
        capture.showPill(model("dictation"), for: .voiceAsk)
        expect(capture.pillOwner, nil as SpeechVoiceCapture.Owner?, "the other action cannot show a pill over the holder")
        capture.showPill(model("dictation"), for: .dictation)
        expect(capture.pillOwner, .dictation, "the holder shows its own pill")
        capture.updatePill(model("later"), for: .voiceAsk)
        expect(capture.pillOwner, .dictation, "the other action cannot update the holder's pill")
        capture.hidePill(for: .voiceAsk)
        expect(capture.pillOwner, .dictation, "the other action cannot hide the holder's pill")
        capture.hidePill(for: .dictation)
        expect(capture.pillOwner, nil as SpeechVoiceCapture.Owner?, "the holder hides its own pill")

        // Release drops the callbacks with the owner.
        capture.release(.dictation)
        expect(capture.owner, nil as SpeechVoiceCapture.Owner?, "release clears the owner")
        capture.microphone.onAudio?(Data([3]), 0.9)
        capture.transcriber.onFinal?("stale")
        expect(first.audio, 2, "a released owner hears nothing more")
        expect(first.finals, ["hello"], "a released owner hears no late final phrase")

        // A failure pill outlives capture, and the next session's pill wins the panel.
        capture.showPill(model("failed"), for: .dictation)
        expect(capture.pillOwner, .dictation, "a failure pill shows with no live capture")
        expect(capture.claim(.voiceAsk, handlers: second.handlers), true,
               "the idle capture is claimable after a failure")
        capture.showPill(model("voice ask"), for: .voiceAsk)
        expect(capture.pillOwner, .voiceAsk, "the new session takes the pill from the failure")
        capture.hidePill(for: .dictation)
        expect(capture.pillOwner, .voiceAsk, "the failure's delayed hide cannot hide the new pill")
        capture.release(.voiceAsk)
        expect(capture.owner, nil as SpeechVoiceCapture.Owner?, "the voice ask release clears its owner")
        expect(capture.pillOwner, nil as SpeechVoiceCapture.Owner?, "release hides only the owner's own pill")

        let failSummary = failures == 0 ? "all \(passes) assertions passed" : "\(failures) FAILED"
        print("Shared voice capture: \(failSummary)")
        if failures > 0 { exit(1) }
    }
}
