import Foundation

/// The production update-installation harness. Compiles the real installer sources and drives
/// `UpdateInstaller.install` end to end against a real signed DMG: download (URLSession, http or
/// file URL), pre-mount DMG signature check (Security, pinned certificate), hdiutil mount, ditto
/// extraction, app verification (bundle id, semantic version, nested code), transactional replace
/// with backup and rollback, and post-trust quarantine clearing.
///
/// Usage:
///   update-installation-test <installed-bundle.app> <dmg-url> <version> [expected-outcome]
///
/// <dmg-url> is the URL the updater downloads: an http(s) URL served locally, or a file:/// URL.
/// <version> accepts a tag form ("v0.11.1-beta.1") or a plist form ("0.11.1-beta.1").
/// [expected-outcome] is "success" (default), "failure", or "failure:<UpdateFailure case>",
/// e.g. failure:identityMismatch, failure:versionMismatch, failure:bundleMismatch.
@main
struct UpdateInstallationTest {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 3 else {
            FileHandle.standardError.write(
                Data(
                    "usage: update-installation-test <bundle.app> <dmg-url> <version> [outcome]\n"
                        .utf8))
            exit(64)
        }
        guard let bundleURL = URL(fileURLWithPath: String(arguments[0]), isDirectory: true)
            .resolvingSymlinksInPath().absoluteURL as URL?,
            let dmgURL = URL(string: String(arguments[1]))
        else {
            FileHandle.standardError.write(Data("invalid URLs\n".utf8))
            exit(64)
        }
        guard let version = AppVersion(String(arguments[2])) else {
            FileHandle.standardError.write(Data("unparseable version \(arguments[2])\n".utf8))
            exit(64)
        }
        let expected = arguments.count > 3 ? String(arguments[3]) : "success"

        // The measured file size when the URL is local; a server URL reports its own size.
        let assetSize: Int64 =
            dmgURL.isFileURL
            ? (try? FileManager.default.attributesOfItem(atPath: dmgURL.path)[.size] as? Int64)
                ?? 0
            : 0
        let release = AvailableRelease(
            version: version,
            tag: "v\(version.description)",
            notes: "",
            assetURL: dmgURL,
            assetSize: assetSize,
            publishedAt: nil)

        // A staging tree of its own: the real app's caches are never touched.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-installation-\(UUID().uuidString)", isDirectory: true)
        let installer = UpdateInstaller(bundleURL: bundleURL, stagingDirectory: staging)

        do {
            try await installer.install(release) { _ in }
            try? FileManager.default.removeItem(at: staging)
            switch expected {
            case "success":
                print("ok   installed \(version) at \(bundleURL.path)")
                exit(0)
            case let failure where failure.hasPrefix("failure"):
                print("FAIL expected \(expected), install succeeded")
                exit(2)
            default:
                print("FAIL unknown outcome \(expected)")
                exit(64)
            }
        } catch let failure as UpdateFailure {
            try? FileManager.default.removeItem(at: staging)
            let actual = "failure:\(caseName(failure))"
            if expected == "failure" || expected == actual {
                print("ok   \(actual): \(failure.errorDescription ?? "")")
                exit(0)
            }
            print("FAIL expected \(expected), got \(actual)")
            exit(2)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            print("FAIL unexpected error: \(error.localizedDescription)")
            exit(2)
        }
    }


    private static func caseName(_ failure: UpdateFailure) -> String {
        switch failure {
        case .downloadFailed: return "downloadFailed"
        case .mountFailed: return "mountFailed"
        case .noAppInImage: return "noAppInImage"
        case .copyFailed: return "copyFailed"
        case .bundleMismatch: return "bundleMismatch"
        case .identityMismatch: return "identityMismatch"
        case .versionMismatch: return "versionMismatch"
        case .replaceFailed: return "replaceFailed"
        }
    }
}
