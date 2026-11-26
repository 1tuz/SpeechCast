import Foundation

@main
@MainActor
struct ExtensionInstallTransactionTests {
    static func main() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temp) }
        let source = temp.appendingPathComponent("source")
        let root = temp.appendingPathComponent("installed")
        try fm.createDirectory(at: source, withIntermediateDirectories: false)
        let manifest = source.appendingPathComponent("package.json")
        let js = source.appendingPathComponent("run.js")
        func prepare(_ name: String = "test-package", _ body: String, commands: String = "", contract: String = "") throws {
            let content = """
            {"name":"\(name)","commands":[{"name":"run","title":"Run","mode":"no-view"}\(commands)]\(contract)}
            """
            try Data(content.utf8).write(to: manifest)
            try Data(body.utf8).write(to: js)
        }
        func expectFailure(_ operation: () throws -> Void) {
            do { try operation() } catch { return }
            fatalError("Expected installation failure")
        }
        try prepare("test-package", "first")
        let installed = try ExtensionCatalog.install(from: source, in: root)
        let installedJS = installed.directory.appendingPathComponent("run.js")
        func verify(_ expected: String) throws {
            let actual = try String(contentsOf: installedJS, encoding: .utf8)
            precondition(actual == expected, "Installed extension changed unexpectedly")
        }
        try verify("first")
        try prepare("test-package", "second")
        _ = try ExtensionCatalog.install(from: source, in: root)
        try verify("second")
        try prepare("test-package", "bad", contract: ",\"speechcast\":{\"schemaVersion\":999}")
        expectFailure { _ = try ExtensionCatalog.install(from: source, in: root) }
        try verify("second")
        try prepare(
            "test-package", "bad",
            commands: ", {\"name\":\"missing\",\"title\":\"Missing\",\"mode\":\"no-view\"}",
            contract: ",\"speechcast\":{\"schemaVersion\":1,\"apiVersion\":1}")
        expectFailure { _ = try ExtensionCatalog.install(from: source, in: root) }
        try verify("second")
        try prepare("test-package", "bad")
        try fm.removeItem(at: js)
        try fm.createSymbolicLink(at: js, withDestinationURL: installedJS)
        expectFailure { _ = try ExtensionCatalog.install(from: source, in: root) }
        try verify("second")
        try fm.removeItem(at: js)
        try prepare("test/package", "collision")
        expectFailure { _ = try ExtensionCatalog.install(from: source, in: root) }
        try verify("second")
        try prepare("../escape", "bad")
        expectFailure { _ = try ExtensionCatalog.install(from: source, in: root) }
        try verify("second")
        let dirs = try fm.contentsOfDirectory(atPath: root.path)
        precondition(dirs == ["test-package"], "Unexpected staging residue: \(dirs)")
        print("Extension install transaction: passed")
    }
}
