import Foundation

struct UpdateInstaller: Sendable {
    enum Phase: Sendable, Equatable {
        case downloading(received: Int64, expected: Int64)
        case mounting
        case verifying
        case replacing

        var message: String {
            switch self {
            case .downloading(let received, let expected):
                return String(localized: "Downloading… \(Self.size(received)) of \(Self.size(expected))")
            case .mounting: return String(localized: "Mounting the update…")
            case .verifying: return String(localized: "Verifying…")
            case .replacing: return String(localized: "Replacing SpeechCast…")
            }
        }

        /// Only the download knows how far along it is; the rest are short, opaque steps.
        var fraction: Double? {
            guard case .downloading(let received, let expected) = self, expected > 0 else {
                return nil
            }
            return min(1, Double(received) / Double(expected))
        }

        private static func size(_ bytes: Int64) -> String {
            bytes.formatted(.byteCount(style: .file))
        }
    }

    let bundleURL: URL
    let stagingDirectory: URL

    func install(
        _ release: AvailableRelease, onProgress: @escaping @Sendable (Phase) -> Void
    ) async throws {
        try? FileManager.default.createDirectory(
            at: stagingDirectory, withIntermediateDirectories: true)
        // The tag names the download; a UUID keeps two installs from colliding.
        let image = stagingDirectory.appendingPathComponent(
            "download-\(UUID().uuidString).dmg")
        let expanded = stagingDirectory.appendingPathComponent(
            "expanded-\(UUID().uuidString)", isDirectory: true)

        onProgress(.downloading(received: 0, expected: release.assetSize))
        for try await event in UpdateDownloader.download(release, to: image) {
            guard case .progress(let received, let expected) = event else { continue }
            onProgress(.downloading(received: received, expected: expected))
        }

        // The signature is checked before anything is mounted: a forged image never reaches
        // hdiutil. The DMG's seal plus the pinned release certificate is the whole proof.
        guard BundleSignature.isTrustedImage(image) else {
            try? FileManager.default.removeItem(at: image)
            throw UpdateFailure.identityMismatch
        }

        onProgress(.mounting)
        let staged = try await DiskImage.stage(image, into: expanded)

        onProgress(.verifying)
        try verify(staged, is: release)

        onProgress(.replacing)
        try await replace(staged, as: release)

        try? FileManager.default.removeItem(at: expanded)
        try? FileManager.default.removeItem(at: image)
    }

    // MARK: - Replacement

    /// One transaction: copy the verified app beside the installed one, re-verify the copy,
    /// keep the old app as a sibling backup, swap, and restore the backup when the swap or the
    /// final check fails. The backup survives a successful install, so a broken launch still
    /// leaves the user a copy to fall back on by hand.
    private func replace(_ staged: URL, as release: AvailableRelease) async throws {
        let fm = FileManager.default
        let destination = destinationURL
        let parent = destination.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)

        let unique = UUID().uuidString
        // The transaction's staging point, on the destination volume so renames stay atomic.
        let pending = parent.appendingPathComponent(".SpeechCast.app.new.\(unique)")
        let backup = parent.appendingPathComponent(".SpeechCast.app.backup.\(unique)")

        // The running copy is replaced, whatever its folder name; a SpeechCast.app that this
        // process is not running from is someone else's install, never silently overwritten.
        guard destination == bundleURL || !fm.fileExists(atPath: destination.path) else {
            throw UpdateFailure.replaceFailed(
                String(localized: "Another app already occupies SpeechCast.app."))
        }

        // ditto carries the seal and extended attributes a cross-volume move would drop.
        guard try await Self.ditto(staged, to: pending) else {
            try? fm.removeItem(at: pending)
            throw UpdateFailure.replaceFailed(
                String(localized: "The verified copy could not be staged."))
        }
        // Re-verify what will actually be installed: the copy, not the DMG it came from.
        do {
            try verify(pending, is: release)
        } catch {
            try? fm.removeItem(at: pending)
            throw error
        }

        // The old copy is whichever the running process came from: destination itself, or the
        // legacy Tinycast/VoiceCast folder the migration is retiring. A foreign destination
        // was already rejected above, so this never displaces someone else's app.
        let displaced = fm.fileExists(atPath: bundleURL.path) ? bundleURL : nil
        do {
            if let displaced {
                try fm.moveItem(at: displaced, to: backup)
            }
            do {
                try fm.moveItem(at: pending, to: destination)
            } catch {
                // The swap failed: put the old copy back before surfacing the failure; a
                // half-swapped /Applications entry is worse than no update.
                if let displaced, !fm.fileExists(atPath: destination.path) {
                    try? fm.moveItem(at: backup, to: displaced)
                }
                throw error
            }
            // Quarantine only after trust, and only on the copy this install placed.
            do {
                try await Self.clearQuarantine(from: destination)
            } catch {
                // A quarantine failure makes the new copy unlaunchable, not the old one: undo.
                try? fm.removeItem(at: destination)
                if let displaced, !fm.fileExists(atPath: displaced.path) {
                    try? fm.moveItem(at: backup, to: displaced)
                }
                throw UpdateFailure.replaceFailed(error.localizedDescription)
            }
            // The final word: the installed copy itself, verified where it landed.
            guard BundleSignature.isTrusted(destination),
                Self.info(at: destination)?["CFBundleIdentifier"] as? String
                    == BundleSignature.expectedBundleIdentifier
            else {
                try? fm.removeItem(at: destination)
                if let displaced, !fm.fileExists(atPath: displaced.path) {
                    try? fm.moveItem(at: backup, to: displaced)
                }
                throw UpdateFailure.identityMismatch
            }
        } catch {
            try? fm.removeItem(at: pending)
            // If the restore failed the backup is kept on disk: deleting it would destroy the
            // only good copy, so it is left for the user to recover by hand.
            if let displaced, !fm.fileExists(atPath: displaced.path),
                fm.fileExists(atPath: backup.path)
            {
                try? fm.moveItem(at: backup, to: displaced)
            }
            if let failure = error as? UpdateFailure { throw failure }
            throw UpdateFailure.replaceFailed(error.localizedDescription)
        }
    }

    /// The installed location, migrating legacy Tinycast/VoiceCast folder names to the product's.
    private var destinationURL: URL {
        bundleURL.deletingLastPathComponent().appendingPathComponent("SpeechCast.app")
    }

    /// `ditto` through `ToolRunner`; `false` when the tool itself failed.
    private static func ditto(_ source: URL, to destination: URL) async throws -> Bool {
        let result = try await ToolRunner.run(
            URL(fileURLWithPath: "/usr/bin/ditto"), [source.path, destination.path])
        return result.succeeded
    }

    /// Quarantine is cleared recursively, but only from the copy this install placed — never
    /// globally, and never before verification passed. `removexattr` is the native call, walked
    /// by hand so a real failure surfaces instead of being swallowed by a tool's exit code;
    /// `/usr/bin/xattr -dr` is the fallback only for a filesystem whose enumerator hides
    /// attributes the syscall reports absent.
    private static func clearQuarantine(from root: URL) async throws {
        let fm = FileManager.default
        // `FileManager.DirectoryEnumerator` cannot be iterated from an async context, so the
        // walk happens up front; hidden members (dot-prefixed helpers) are included on purpose.
        let relativePaths = (try? fm.subpathsOfDirectory(atPath: root.path)) ?? []
        var targets = [root]
        for relative in relativePaths {
            let url = root.appendingPathComponent(relative)
            // A symlink is never followed: only members of the bundle itself are touched.
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true {
                targets.append(url)
            }
        }
        var syscallFailed = false
        for url in targets {
            let status = removexattr(url.path, "com.apple.quarantine", XATTR_NOFOLLOW)
            if status == 0 || errno == ENOATTR { continue }
            syscallFailed = true
        }
        if syscallFailed {
            // The definitive fallback: `-r` walks the tree, `-d` deletes the attribute.
            guard
                let result = try? await ToolRunner.run(
                    URL(fileURLWithPath: "/usr/bin/xattr"),
                    ["-dr", "com.apple.quarantine", root.path], timeout: 60),
                result.succeeded
            else {
                throw UpdateFailure.replaceFailed(
                    String(localized: "Could not clear the quarantine flag."))
            }
        }
    }

    // MARK: - Verification

    private func verify(_ staged: URL, is release: AvailableRelease) throws {
        let info = Self.info(at: staged)
        guard info?["CFBundleIdentifier"] as? String == BundleSignature.expectedBundleIdentifier
        else { throw UpdateFailure.bundleMismatch }
        let found = info?["CFBundleShortVersionString"] as? String
        // The version is compared as a semantic value, so a tag's leading `v` and a plist's
        // absence of one arrive at the same answer.
        guard AppVersion(found ?? "") == release.version else {
            throw UpdateFailure.versionMismatch(
                expected: release.version.description, found: found ?? String(localized: "unknown"))
        }
        // isTrusted here checks every architecture and every nested Mach-O, not just the
        // app's own seal: a helper swapped inside the bundle breaks the nested check.
        guard BundleSignature.isTrusted(staged) else { throw UpdateFailure.identityMismatch }
    }

    /// Off disk, not through `Bundle`, whose cache would answer for the old copy.
    private static func info(at bundleURL: URL) -> [String: Any]? {
        let url = bundleURL.appending(components: "Contents", "Info.plist")
        guard let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return nil }
        return plist as? [String: Any]
    }
}
