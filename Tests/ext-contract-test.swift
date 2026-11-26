import Foundation

@main
@MainActor
struct ExtensionContractTests {
    static var failures = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard !condition() else { return }
        failures += 1
        print("FAIL: \(message)")
    }

    static func manifest(contract: String? = nil) throws -> ExtensionManifest? {
        let metadata = contract.map { ",\"speechcast\":\($0)" } ?? ""
        let source = """
            {"name":"contract-example","commands":[
                {"name":"inspect","title":"Inspect","mode":"view"},
                {"name":"run","title":"Run","mode":"no-view"},
                {"name":"status","title":"Status","mode":"menu-bar"}
            ]\(metadata)}
            """
        guard let json = try JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any]
        else { return nil }
        return ExtensionManifest(json: json)
    }

    static func main() throws {
        let legacy = try manifest()
        expect(legacy != nil, "a Raycast manifest without SpeechCast metadata remains accepted")
        expect(legacy?.speechcast == nil, "absence remains distinct from a supported contract")

        let supported = try manifest(contract: #"{"schemaVersion":1,"apiVersion":1}"#)
        expect(supported?.speechcast?.schemaVersion == 1, "the schema version survives parsing")
        expect(supported?.speechcast?.apiVersion == 1, "the API version survives parsing")
        expect(supported?.commands == legacy?.commands, "metadata does not change command semantics")
        expect(supported?.supportsMacOS == true, "metadata keeps the legacy macOS default")

        let integral = try manifest(contract: #"{"schemaVersion":1.0,"apiVersion":1e0}"#)
        expect(integral?.speechcast == supported?.speechcast, "JSON numeric notation is not a version")

        let invalid: [(String, String)] = [
            ("null", "null metadata"),
            ("true", "boolean metadata"),
            ("[]", "array metadata"),
            (#""1""#, "string metadata"),
            ("{}", "missing versions"),
            (#"{"schemaVersion":1}"#, "missing API version"),
            (#"{"apiVersion":1}"#, "missing schema version"),
            (#"{"schemaVersion":true,"apiVersion":1}"#, "boolean schema version"),
            (#"{"schemaVersion":1,"apiVersion":true}"#, "boolean API version"),
            (#"{"schemaVersion":"1","apiVersion":1}"#, "string schema version"),
            (#"{"schemaVersion":1,"apiVersion":"1"}"#, "string API version"),
            (#"{"schemaVersion":2,"apiVersion":1}"#, "future schema version"),
            (#"{"schemaVersion":1,"apiVersion":2}"#, "future API version"),
            (#"{"schemaVersion":0,"apiVersion":1}"#, "zero schema version"),
            (#"{"schemaVersion":1,"apiVersion":-1}"#, "negative API version"),
            (#"{"schemaVersion":1.5,"apiVersion":1}"#, "fractional schema version"),
            (#"{"schemaVersion":1,"apiVersion":1.5}"#, "fractional API version"),
            (#"{"schemaVersion":1,"apiVersion":99999999999999999999}"#, "oversized API version"),
            (#"{"schemaVersion":1,"apiVersion":1,"permissions":[]}"#, "unimplemented permissions"),
            (#"{"schemaVersion":1,"apiVersion":1,"typo":1}"#, "unknown key")
        ]
        for (source, description) in invalid {
            let parsed = try manifest(contract: source)
            expect(parsed == nil, "reject \(description) without legacy fallback")
        }

        expect(
            ExtensionManifest(json: ["name": "empty", "speechcast": ["schemaVersion": 1, "apiVersion": 1]])
                == nil,
            "a valid contract does not make an empty package executable")
        print("Extension contract checks: \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
