import Foundation
import Darwin

struct InstalledExtension: Sendable, Hashable, Identifiable {
    let manifest: ExtensionManifest
    let directory: URL
    /// Read by `scan`, off the main actor, so publishing launcher rows never touches the disk.
    var installedAt: Date?

    var id: String { manifest.name }
    var title: String { manifest.title }

    /// Assets usually live in `assets/`, but a few manifests point at the extension root.
    var iconPath: String? {
        guard let icon = manifest.icon else { return nil }
        let candidates = [
            directory.appendingPathComponent("assets").appendingPathComponent(icon),
            directory.appendingPathComponent(icon)
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }?.path
    }

    var assetsPath: String { directory.appendingPathComponent("assets").path }

    func bundleURL(for command: ExtensionCommand) -> URL? {
        let url = directory.appendingPathComponent("\(command.name).js")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func command(named name: String) -> ExtensionCommand? {
        manifest.commands.first { $0.name == name }
    }
}

struct ExtensionCommandRef: Sendable, Hashable {
    let extensionName: String
    let commandName: String

    /// The `AppEntry.id` an extension command is surfaced under.
    var entryID: String { "extension:\(extensionName)/\(commandName)" }

    init(extensionName: String, commandName: String) {
        self.extensionName = extensionName
        self.commandName = commandName
    }

    init?(entryID: String) {
        guard entryID.hasPrefix("extension:") else { return nil }
        let body = entryID.dropFirst("extension:".count)
        guard let slash = body.lastIndex(of: "/") else { return nil }
        extensionName = String(body[body.startIndex..<slash])
        commandName = String(body[body.index(after: slash)...])
    }
}

/// Finds and installs extensions, stored in Raycast's own layout so a built one imports as-is.
enum ExtensionCatalog {
    /// Keyed by bundle id, so a Debug build never shares installs with a release channel.
    static func extensionsDirectory() -> URL {
        supportDirectory().appendingPathComponent("extensions", isDirectory: true)
    }

    static func storageDirectory() -> URL {
        supportDirectory().appendingPathComponent("extension-data", isDirectory: true)
    }

    /// Outside `extension-data`, whose every file the cleanup sweep reads as one extension's own.
    static func commandMetadataFile() -> URL {
        supportDirectory().appendingPathComponent("extension-commands.json", isDirectory: false)
    }

    /// Outside the directories the cleanup sweep reads, like `commandMetadataFile`.
    static func storeVersionsFile() -> URL {
        supportDirectory().appendingPathComponent("extension-versions.json", isDirectory: false)
    }

    /// Per-extension `environment.supportPath` — an extension's own scratch directory.
    static func supportPath(for name: String) -> URL {
        supportRoot().appendingPathComponent(safeName(name), isDirectory: true)
    }

    static func supportRoot() -> URL {
        supportDirectory().appendingPathComponent("extension-support", isDirectory: true)
    }

    /// npm-style names flattened to one path segment; a second copy that drifts orphans every file.
    static func safeName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "@", with: "")
    }

    private static func supportDirectory() -> URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        let bundleID = Bundle.main.bundleIdentifier ?? "com.tinycast.app"
        return base.appendingPathComponent(bundleID, isDirectory: true)
    }

    /// `raycast-x` is Beta v2; both roots can exist, and switching leaves the other one empty.
    static func raycastExtensionRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["raycast", "raycast-x"].map {
            home.appendingPathComponent(".config/\($0)/extensions", isDirectory: true)
        }
    }

    /// The first root holding anything, so an empty channel never reads as not installed.
    static func raycastExtensionsDirectory() -> URL? {
        raycastExtensionRoots().first { root in
            let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            return !(entries ?? []).isEmpty
        }
    }

    /// An unreadable or half-written directory is skipped rather than failing the whole scan.
    nonisolated static func scan() -> [InstalledExtension] {
        let root = extensionsDirectory()
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .addedToDirectoryDateKey],
                options: [.skipsHiddenFiles])) ?? []
        return
            entries
            .compactMap { directory -> InstalledExtension? in
                try? restoreExecutablePermissions(in: directory)
                guard let manifest = try? ExtensionManifest.load(directory: directory),
                    manifest.supportsMacOS
                else { return nil }
                let added = try? directory.resourceValues(forKeys: [.addedToDirectoryDateKey])
                return InstalledExtension(
                    manifest: manifest, directory: directory, installedAt: added?.addedToDirectoryDate)
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// GitHub's raw-file downloads lose mode bits, so restore runnable helper assets by content.
    nonisolated static func restoreExecutablePermissions(in directory: URL) throws {
        let fileManager = FileManager.default
        let assets = directory.appendingPathComponent("assets", isDirectory: true)
        guard
            let enumerator = fileManager.enumerator(
                at: assets,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])
        else { return }

        while let file = enumerator.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                !fileManager.isExecutableFile(atPath: file.path), isExecutablePayload(file)
            else { continue }
            let attributes = try fileManager.attributesOfItem(atPath: file.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            let executeBits = (permissions & 0o444) >> 2
            try fileManager.setAttributes(
                [.posixPermissions: permissions | executeBits], ofItemAtPath: file.path)
        }
    }

    private nonisolated static func isExecutablePayload(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4) else { return false }
        let bytes = Array(data)
        if bytes.starts(with: [0x23, 0x21]) { return true }
        return [
            [0xCA, 0xFE, 0xBA, 0xBE], [0xBE, 0xBA, 0xFE, 0xCA],
            [0xCA, 0xFE, 0xBA, 0xBF], [0xBF, 0xBA, 0xFE, 0xCA],
            [0xCE, 0xFA, 0xED, 0xFE], [0xCF, 0xFA, 0xED, 0xFE],
            [0xFE, 0xED, 0xFA, 0xCE], [0xFE, 0xED, 0xFA, 0xCF]
        ].contains(bytes)
    }

    // MARK: - Install

    enum InstallError: LocalizedError {
        case notAnExtension(URL)
        case noBuiltCommands(String)
        case wrongPlatform(String)
        case copyFailed(String)
        case unsafePackage(String)

        var errorDescription: String? {
            switch self {
            case .notAnExtension(let url):
                return String(
                    localized: """
                        \(url.lastPathComponent) doesn't contain a Raycast extension (no package.json \
                        with commands).
                        """)
            case .noBuiltCommands(let name):
                return String(
                    localized: """
                        \(name) has no built command bundles. Tinycast installs prebuilt extensions — run \
                        `ray build` in the extension folder first, or import one from an installed Raycast.
                        """)
            case .wrongPlatform(let name):
                return String(localized: "\(name) doesn't support macOS.")
            case .copyFailed(let reason):
                return String(localized: "Couldn't install the extension: \(reason)")
            case .unsafePackage(let reason):
                return String(localized: "Invalid extension package: \(reason)")
            }
        }
    }

    /// Manifest, built commands, `assets/` and any bundled `node_modules` — never `.js.map`s.
    @discardableResult
    static func install(
        from source: URL, in directory: URL = ExtensionCatalog.extensionsDirectory()
    ) throws -> InstalledExtension {
        let fm = FileManager.default
        // Reject a linked manifest before reading it. Keep existing Raycast naming and IDs.
        try validatePayload(source.appendingPathComponent("package.json"), expectDirectory: false)
        guard let manifest = try? ExtensionManifest.load(directory: source) else {
            throw InstallError.notAnExtension(source)
        }
        guard manifest.supportsMacOS else { throw InstallError.wrongPlatform(manifest.title) }
        guard safeRelativeName(manifest.name), !manifest.name.hasPrefix("."),
              manifest.commands.allSatisfy({ safeRelativeName($0.name) && !$0.name.contains("/") }),
              Set(manifest.commands.map(\.name)).count == manifest.commands.count else {
            throw InstallError.unsafePackage("Unsafe or duplicate package/command name")
        }
        for icon in [manifest.icon] + manifest.commands.map(\.icon) {
            if let icon, !safeRelativeName(icon) { throw InstallError.unsafePackage("Unsafe icon path") }
        }
        let built = manifest.commands.filter {
            fm.fileExists(atPath: source.appendingPathComponent("\($0.name).js").path)
        }
        guard !built.isEmpty else { throw InstallError.noBuiltCommands(manifest.title) }
        if manifest.speechcast != nil && built.count != manifest.commands.count {
            throw InstallError.unsafePackage("Every versioned SpeechCast command needs a built bundle")
        }
        let destination = directory.appendingPathComponent(
            manifest.name.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // Hidden sibling on the same volume. scan() already ignores hidden directories.
        let stage = directory.appendingPathComponent(".speechcast-install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        do {
            func copy(_ name: String, isDirectory: Bool) throws {
                let item = source.appendingPathComponent(name)
                try validatePayload(item, expectDirectory: isDirectory)
                try fm.copyItem(at: item, to: stage.appendingPathComponent(name))
                try validatePayload(stage.appendingPathComponent(name), expectDirectory: isDirectory)
            }
            try copy("package.json", isDirectory: false)
            for command in built { try copy("\(command.name).js", isDirectory: false) }
            for folder in ["assets", "node_modules"] {
                let item = source.appendingPathComponent(folder)
                // A dangling symlink must not be treated as an absent optional folder.
                if fm.fileExists(atPath: item.path) || (try? fm.destinationOfSymbolicLink(atPath: item.path)) != nil {
                    try copy(folder, isDirectory: true)
                }
            }
            try restoreExecutablePermissions(in: stage)
            let stagedManifest = try ExtensionManifest.load(directory: stage)
            guard stagedManifest == manifest else {
                throw InstallError.unsafePackage("Manifest changed during installation")
            }

            // Refuse to replace a different package with a colliding flattened name. A broken
            // or linked destination is not ours to delete automatically.
            let existing = fm.fileExists(atPath: destination.path)
            if (try? fm.destinationOfSymbolicLink(atPath: destination.path)) != nil {
                throw InstallError.unsafePackage("Install destination is a symbolic link")
            }
            if existing {
                let old = try ExtensionManifest.load(directory: destination)
                guard old.name == manifest.name else {
                    throw InstallError.unsafePackage("Install destination belongs to another extension")
                }
            }
            // RENAME_SWAP exchanges two directory entries atomically; even a process crash
            // leaves one complete package at destination. On unsupported filesystems fail
            // closed, rather than deleting the working directory and attempting a second move.
            let flags = UInt32(existing ? RENAME_SWAP : RENAME_EXCL)
            let result = stage.path.withCString { from in
                destination.path.withCString { to in
                    renameatx_np(AT_FDCWD, from, AT_FDCWD, to, flags)
                }
            }
            guard result == 0 else {
                let code = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            // After a swap, stage contains the previous package. The defer removes only that
            // hidden directory, not the new package or extension-data/preferences.
            return InstalledExtension(manifest: stagedManifest, directory: destination)
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.copyFailed(error.localizedDescription)
        }
    }

    /// A package-relative path, never an absolute path, traversal, hidden staging name or control byte.
    private static func safeRelativeName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("\\") && !name.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        } && name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    /// This iteration accepts self-contained prebuilt payloads, not symlinks or special files.
    /// Check both source and staged copy before restoring executable bits or swapping directories.
    private static func validatePayload(_ item: URL, expectDirectory: Bool) throws {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        func check(_ url: URL, directory: Bool? = nil) throws {
            let value = try url.resourceValues(forKeys: keys)
            guard value.isSymbolicLink != true,
                  value.isDirectory == true || value.isRegularFile == true,
                  directory == nil || value.isDirectory == directory else {
                throw InstallError.unsafePackage("Unsupported payload item: \(url.lastPathComponent)")
            }
        }
        try check(item, directory: expectDirectory)
        guard expectDirectory else { return }
        var pending = [item]
        while let directory = pending.popLast() {
            let entries = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
            for entry in entries {
                try check(entry)
                if try entry.resourceValues(forKeys: keys).isDirectory == true {
                    pending.append(entry)
                }
            }
        }
    }

    /// Both paths it owns: nothing else collects the scratch dir, and the dialog promises it goes.
    static func uninstall(_ installed: InstalledExtension) throws {
        try? FileManager.default.removeItem(at: supportPath(for: installed.manifest.name))
        try FileManager.default.removeItem(at: installed.directory)
    }

    /// Raycast keys installs by UUID, so only the manifest says what a directory holds.
    nonisolated static func importableFromRaycast() -> [InstalledExtension] {
        let fm = FileManager.default
        let entries = raycastExtensionRoots().flatMap { root in
            (try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        }
        return
            entries
            .compactMap { directory -> InstalledExtension? in
                guard let manifest = try? ExtensionManifest.load(directory: directory),
                    manifest.supportsMacOS,
                    // Skip half-installed or source-only directories.
                    manifest.commands.contains(where: {
                        fm.fileExists(atPath: directory.appendingPathComponent("\($0.name).js").path)
                    })
                else { return nil }
                return InstalledExtension(manifest: manifest, directory: directory)
            }
            // Both channels can hold one extension; the earlier root wins, so it is offered once.
            .reduce(into: [InstalledExtension]()) { unique, candidate in
                guard !unique.contains(where: { $0.manifest.name == candidate.manifest.name }) else {
                    return
                }
                unique.append(candidate)
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}
