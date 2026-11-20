import Foundation

// The postprocess client contract: the Runtime is the ONLY text processor. This harness pins the
// wire shape (text + cleanup + effective rules, no field context), the {"text": ...} response
// decode, and the error surface — an older Runtime is an actionable update message, never a local
// fallback. processDictation's public overload routes through the same seam, so a pass here is a
// pass for the real request path SpeechRuntimeHTTP.request drives.
@main
@MainActor
struct SpeechRuntimePostprocessTest {
    static var failures = 0

    static func main() async {
        await roundTripAppliesRuntimeResult()
        await olderRuntimeSurfacesUpdateMessage()
        await transportErrorsPassThrough()
        await malformedResponseIsAFailure()
        await wireBodyCarriesOnlyTranscriptFacts()
        await emptyResultTextReturnsEmpty()
        await tokenFailureSurfacesAsSpeechVoiceFailure()
        print(failures == 0 ? "All speech runtime postprocess checks passed"
                            : "\(failures) speech runtime postprocess check(s) failed")
        if failures > 0 { exit(1) }
    }

    static func check(_ description: String, _ condition: Bool) {
        print((condition ? "PASS  " : "FAIL  ") + description)
        if !condition { failures += 1 }
    }

    /// Drives processDictation through the transport seam with a fixture Runtime response.
    static func run(
        _ text: String, cleanup: Bool, rules: [SpeechRuntimeRule],
        status: Int = 200, body: Data? = nil
    ) async throws -> String {
        let client = SpeechRuntimeHTTP()
        return try await client.processDictation(text: text, cleanup: cleanup, rules: rules) { _ in
            if status != 200 { throw SpeechVoiceFailure(detail: "Speech Runtime: HTTP \(status)") }
            return body ?? Data("null".utf8)
        }
    }

    static func roundTripAppliesRuntimeResult() async {
        let response = Data(#"{"text": "Hello World"}"#.utf8)
        let result = try? await run("hello world", cleanup: true,
                                    rules: [SpeechRuntimeRule(spoken: "world", replacement: "World")],
                                    body: response)
        check("the Runtime's processed text is returned verbatim", result == "Hello World")
        let cleanupOff = try? await run("untrimmed ", cleanup: false, rules: [],
                                        body: Data(#"{"text": "untrimmed "}"#.utf8))
        check("cleanup off returns the Runtime's text untouched", cleanupOff == "untrimmed ")
    }

    static func olderRuntimeSurfacesUpdateMessage() async {
        do {
            _ = try await run("hi", cleanup: true, rules: [], status: 404)
            check("an older Runtime throws instead of falling back", false)
        } catch let error as SpeechVoiceFailure {
            check("an older Runtime throws instead of falling back", true)
            check("the failure tells the user to update Speech Runtime",
                  error.errorDescription == "Speech Runtime does not support text post-processing. "
                      + "Update Speech Runtime to the latest version.")
        } catch {
            check("an older Runtime throws SpeechVoiceFailure, not another error", false)
        }
        // The daemon's verbatim 404 body for a missing route must also map to the update message.
        let verbatim = SpeechVoiceFailure(detail: "Speech Runtime: no route for POST /v1/text/postprocess")
        let client = SpeechRuntimeHTTP()
        check("the daemon's 'no route' 404 body maps to the update message",
              client.postprocessFailure(verbatim).errorDescription
                  == "Speech Runtime does not support text post-processing. "
                  + "Update Speech Runtime to the latest version.")
    }

    static func transportErrorsPassThrough() async {
        // A Runtime-level rejection (limits, bad rules) keeps its own message — no masking.
        let detail = "Speech Runtime: text exceeds 100000 characters"
        let client = SpeechRuntimeHTTP()
        check("non-404 HTTP errors keep their Runtime detail",
              client.postprocessFailure(SpeechVoiceFailure(detail: detail)).errorDescription == detail)
        let unreachable = SpeechVoiceFailure(
            detail: "Cannot reach Speech Runtime at 127.0.0.1:8477: connection refused")
        check("reachability errors keep their own detail",
              client.postprocessFailure(unreachable).errorDescription
                  == "Cannot reach Speech Runtime at 127.0.0.1:8477: connection refused")
    }

    static func malformedResponseIsAFailure() async {
        do {
            _ = try await run("hi", cleanup: true, rules: [], body: Data("garbage".utf8))
            check("a malformed response throws", false)
        } catch let error as SpeechVoiceFailure {
            check("a malformed response throws",
                  error.errorDescription == "Speech Runtime returned an invalid postprocess response")
        } catch {
            check("a malformed response throws SpeechVoiceFailure, not another error", false)
        }
        // A JSON object without "text" is equally broken — there is no silent empty-string path.
        do {
            _ = try await run("hi", cleanup: true, rules: [], body: Data("{}".utf8))
            check("a response without text throws", false)
        } catch { check("a response without text throws", true) }
    }

    static func wireBodyCarriesOnlyTranscriptFacts() async {
        let client = SpeechRuntimeHTTP()
        let body = try? client.postprocessBody(
            text: "comma  spaces", cleanup: true,
            rules: [SpeechRuntimeRule(spoken: "comma", replacement: ",")])
        let object = try? JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any]
        check("the body carries the transcript", object?["text"] as? String == "comma  spaces")
        check("the body carries the cleanup toggle", object?["cleanup"] as? Bool == true)
        let rules = object?["rules"] as? [[String: Any]]
        check("the body carries exactly the effective rules", rules?.count == 1)
        check("a rule carries spoken and replacement",
              rules?.first?["spoken"] as? String == "comma"
                  && rules?.first?["replacement"] as? String == ",")
        check("the body leaks no field or app context",
              ["bundle", "bundleID", "app", "application", "field", "caret", "candidates", "context"]
                  .allSatisfy { object?[$0] == nil })
    }

    static func emptyResultTextReturnsEmpty() async {
        let result = try? await run("", cleanup: true, rules: [],
                                    body: Data(#"{"text": ""}"#.utf8))
        check("the Runtime's empty text is returned as an empty string, not an error", result == "")
    }

    /// The seam path never touches the token, so this pins the real request path's token failure
    /// through the shared error type instead of a duplicated one.
    static func tokenFailureSurfacesAsSpeechVoiceFailure() async {
        let client = SpeechRuntimeHTTP()
        let failure = client.postprocessFailure(
            SpeechVoiceFailure(detail: "Speech Runtime token not found. Turn on Speech Runtime.app first."))
        check("token failures pass through unchanged",
              failure.errorDescription
                  == "Speech Runtime token not found. Turn on Speech Runtime.app first.")
    }
}
