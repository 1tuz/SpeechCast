import Foundation

/// One exact substitution rule, already selected and enabled by the calling app's scope.
struct SpeechRuntimeRule: Equatable, Sendable {
    let spoken: String
    let replacement: String
}

extension SpeechRuntimeHTTP {
    /// Transcript-only cleanup and exact substitution, performed entirely by the Runtime.
    func processDictation(text: String, cleanup: Bool, rules: [SpeechRuntimeRule]) async throws -> String {
        try await processDictation(text: text, cleanup: cleanup, rules: rules) { body in
            try await self.request("POST", "/v1/text/postprocess", body: body,
                                   contentType: "application/json")
        }
    }

    /// `send` is the transport seam: it takes the built wire body and returns the response bytes.
    func processDictation(
        text: String, cleanup: Bool, rules: [SpeechRuntimeRule],
        send: (_ body: Data) async throws -> Data
    ) async throws -> String {
        // Even with no rules the Runtime owns cleanup; a local shortcut would be a second pipeline.
        let body = try postprocessBody(text: text, cleanup: cleanup, rules: rules)
        do {
            return try postprocessText(from: try await send(body))
        } catch let failure as SpeechVoiceFailure {
            throw postprocessFailure(failure)
        }
    }

    /// The wire body: transcript, toggle and effective rules — never field, caret or app context.
    func postprocessBody(text: String, cleanup: Bool, rules: [SpeechRuntimeRule]) throws -> Data {
        try json([
            "text": text,
            "cleanup": cleanup,
            "rules": rules.map { ["spoken": $0.spoken, "replacement": $0.replacement] },
        ])
    }

    private struct PostprocessResponse: Decodable {
        let text: String
    }

    /// Decodes the Runtime's `{"text": ...}`; anything else is a broken contract, not a fallback.
    func postprocessText(from data: Data) throws -> String {
        guard let decoded = try? JSONDecoder().decode(PostprocessResponse.self, from: data) else {
            throw SpeechVoiceFailure(detail: "Speech Runtime returned an invalid postprocess response")
        }
        return decoded.text
    }

    /// A 404 here means an older Runtime without the endpoint; the fix is an update, not a local pipeline.
    func postprocessFailure(_ failure: SpeechVoiceFailure) -> SpeechVoiceFailure {
        guard failure.detail.contains("404") || failure.detail.contains("no route") else { return failure }
        return SpeechVoiceFailure(
            detail: "Speech Runtime does not support text post-processing. "
                + "Update Speech Runtime to the latest version.")
    }
}
