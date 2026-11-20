import Foundation

/// Serialises audio uploads and reads completed utterances while capture continues.
@MainActor
final class SpeechRuntimeTranscriber {
    var onFinal: ((String) -> Void)?
    private let http = SpeechRuntimeHTTP()
    private var stream: String?
    private var upload = Data()
    private var pendingBytes = 0
    private var uploadTail: Task<Void, Error>?
    private var polling: Task<Void, Error>?
    private var completed: [String] = []
    private var generation = 0
    private var isFinishing = false
    private var uploadFailure: Error?

    func checkModels() async throws -> [SpeechRuntimeModel] { try await http.models() }

    func start(model: String) async throws {
        cancel()
        let generation = self.generation
        let models = try await http.models()
        guard let selected = models.first(where: { $0.model == model }) else {
            throw SpeechVoiceFailure(detail: "Model '\(model)' is not configured in Speech Runtime.app")
        }
        guard selected.capabilities?.streamingSessions == true else {
            throw SpeechVoiceFailure(detail: "Model '\(model)' does not support streaming sessions")
        }
        if selected.loaded != true { try await http.load(model) }
        guard generation == self.generation else { throw CancellationError() }
        let stream = try await http.open(model)
        guard generation == self.generation else {
            await http.cancel(stream)
            throw CancellationError()
        }
        self.stream = stream
        polling = Task { [weak self] in
            guard let self else { return }
            try await self.pollEvents(stream: stream, generation: generation)
        }
    }

    func appendAudio(_ data: Data) {
        guard stream != nil, !isFinishing, uploadFailure == nil, !data.isEmpty else { return }
        // Do not drop packets on a slow server: fail explicitly instead of corrupting the transcript.
        if pendingBytes + upload.count + data.count > 4 * 16_000 * 4 {
            uploadFailure = SpeechVoiceFailure(detail: "Speech Runtime audio upload fell behind by four seconds")
            return
        }
        upload.append(data)
        if upload.count >= 100 * 16 * 4 { flush() }
    }

    private func flush() {
        guard let stream, !upload.isEmpty else { return }
        let data = upload
        upload.removeAll(keepingCapacity: true)
        pendingBytes += data.count
        let previous = uploadTail
        let generation = self.generation
        uploadTail = Task { [weak self] in
            try await previous?.value
            guard !Task.isCancelled, let self, generation == self.generation else {
                throw CancellationError()
            }
            try await self.http.audio(stream, pcm: data)
            guard generation == self.generation else { throw CancellationError() }
            self.pendingBytes -= data.count
        }
    }

    private func pollEvents(stream: String, generation: Int) async throws {
        var since = 0
        while !Task.isCancelled, generation == self.generation {
            let next = try await http.events(stream, since: since)
            since = next.next
            for event in next.events {
                if event.event == "final", let text = event.data.text {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        completed.append(trimmed)
                        onFinal?(trimmed)
                    }
                } else if event.event == "error" {
                    throw SpeechVoiceFailure(detail: event.data.message ?? "Speech Runtime streaming error")
                }
            }
            if next.ended { return }
        }
        throw CancellationError()
    }

    func finish() async throws -> String {
        guard let stream else { throw SpeechVoiceFailure(detail: "Speech Runtime stream is not open") }
        isFinishing = true
        flush()
        if let uploadFailure { throw uploadFailure }
        try await uploadTail?.value
        try await http.end(stream)
        // The server retains ended-session events briefly so clients can drain them.
        try await polling?.value
        let text = completed.joined(separator: " ")
        reset()
        return text
    }

    func cancel() {
        generation &+= 1
        uploadTail?.cancel()
        polling?.cancel()
        if let stream {
            Task { [http] in await http.cancel(stream) }
        }
        reset()
    }

    private func reset() {
        stream = nil
        upload = Data()
        pendingBytes = 0
        uploadTail = nil
        polling = nil
        completed = []
        isFinishing = false
        uploadFailure = nil
    }
}
