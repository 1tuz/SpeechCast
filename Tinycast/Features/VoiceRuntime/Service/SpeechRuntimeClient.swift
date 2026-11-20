import Foundation

struct SpeechRuntimeModel: Decodable, Equatable {
    let model: String
    let loaded: Bool?
    let capabilities: Capabilities?

    struct Capabilities: Decodable, Equatable {
        let streamingSessions: Bool?
        enum CodingKeys: String, CodingKey { case streamingSessions = "streaming_sessions" }
    }
}

struct SpeechRuntimeModels: Decodable {
    let models: [SpeechRuntimeModel]
}

struct SpeechRuntimeStream: Decodable {
    let stream: String
}

struct SpeechRuntimeEvents: Decodable {
    let next: Int
    let ended: Bool
    let events: [SpeechRuntimeEvent]
}

struct SpeechRuntimeEvent: Decodable {
    let event: String
    let data: DataPayload

    struct DataPayload: Decodable {
        let text: String?
        let message: String?
    }
}

struct SpeechRuntimeErrorBody: Decodable {
    let error: String?
}

/// The API is intentionally local and fixed. The client never starts or terminates the daemon.
@MainActor
final class SpeechRuntimeHTTP {
    private let url = URL(string: "http://127.0.0.1:8477")!
    private let session: URLSession
    private let decoder = JSONDecoder()

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 180
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    private func token() throws -> String {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SpeechRuntime/token")
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else {
            throw SpeechVoiceFailure(detail: "Speech Runtime token not found. Turn on Speech Runtime.app first.")
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw SpeechVoiceFailure(detail: "Speech Runtime token is empty") }
        return token
    }

    func request(
        _ method: String, _ path: String, query: [URLQueryItem] = [],
        body: Data? = nil, contentType: String? = nil,
        extraHeaders: [String: String] = [:], timeout: TimeInterval = 12
    ) async throws -> Data {
        var components = URLComponents(url: url.appendingPathComponent(String(path.dropFirst())),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer " + (try token()), forHTTPHeaderField: "Authorization")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let body { request.httpBody = body }
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SpeechVoiceFailure(detail: "Cannot reach Speech Runtime at 127.0.0.1:8477: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw SpeechVoiceFailure(detail: "Speech Runtime returned an invalid HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? decoder.decode(SpeechRuntimeErrorBody.self, from: data).error)
                ?? "HTTP \(http.statusCode)"
            throw SpeechVoiceFailure(detail: "Speech Runtime: \(message)")
        }
        return data
    }

    func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    func models() async throws -> [SpeechRuntimeModel] {
        try decoder.decode(SpeechRuntimeModels.self, from: await request("GET", "/v1/models")).models
    }

    func load(_ model: String) async throws {
        // Cold ANE compilation can take tens of seconds on first use.
        _ = try await request("POST", "/v1/models/load", body: json(["model": model]),
                              contentType: "application/json", timeout: 170)
    }

    func open(_ model: String) async throws -> String {
        let data = try await request("POST", "/v1/streams", body: json(["model": model]),
                                     contentType: "application/json")
        return try decoder.decode(SpeechRuntimeStream.self, from: data).stream
    }

    func audio(_ stream: String, pcm: Data) async throws {
        // Speech Runtime requires explicit sample format, not an implicit raw-PCM guess.
        _ = try await request("POST", "/v1/streams/audio",
                              query: [URLQueryItem(name: "stream", value: stream)],
                              body: pcm, contentType: "application/octet-stream",
                              extraHeaders: ["X-Sample-Format": "f32le", "X-Sample-Rate": "16000"])
    }

    func events(_ stream: String, since: Int) async throws -> SpeechRuntimeEvents {
        let data = try await request("GET", "/v1/streams/events", query: [
            URLQueryItem(name: "stream", value: stream),
            URLQueryItem(name: "since", value: String(since)),
            URLQueryItem(name: "wait", value: "0.75")
        ])
        return try decoder.decode(SpeechRuntimeEvents.self, from: data)
    }

    func end(_ stream: String) async throws {
        _ = try await request("POST", "/v1/streams/end",
                              query: [URLQueryItem(name: "stream", value: stream)], timeout: 30)
    }

    func cancel(_ stream: String) async {
        _ = try? await request("DELETE", "/v1/streams",
                               query: [URLQueryItem(name: "stream", value: stream)])
    }
}
