import Foundation

struct AvailableRelease: Codable, Hashable, Sendable {
    let version: AppVersion
    let tag: String
    let notes: String
    let assetURL: URL
    let assetSize: Int64
    let publishedAt: Date?
}

/// Nothing throws: an unusable body means nothing to install, and the pump retries.
enum ReleaseFeed {
    /// Where releases come from, and what every `@handle` and `#304` in their notes points at.
    static let repository = "1tuz/SpeechCast"

    /// The newest release this channel accepts, ignoring drafts and anything without a usable DMG.
    static func newest(
        from data: Data, channel: ReleaseChannel, architecture: ReleaseArchitecture
    ) -> AvailableRelease? {
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return nil }
        return
            entries
            .compactMap { release(from: $0, channel: channel, architecture: architecture) }
            .max { $0.version < $1.version }
    }

    /// The release worth offering: strictly newer than what runs, and not skipped.
    static func offer(
        _ release: AvailableRelease?, running: AppVersion, skipped: AppVersion?
    ) -> AvailableRelease? {
        guard let release, release.version > running else { return nil }
        if let skipped, release.version <= skipped { return nil }
        return release
    }

    private static func release(
        from entry: Entry, channel: ReleaseChannel, architecture: ReleaseArchitecture
    ) -> AvailableRelease? {
        guard !entry.draft, channel.accepts(prerelease: entry.prerelease),
            let version = AppVersion(entry.tagName),
            // A tag disagreeing with the prerelease flag is a mis-published release, not an update.
            version.isPrerelease == entry.prerelease,
            let asset = asset(from: entry.assets, for: architecture)
        else { return nil }
        return AvailableRelease(
            version: version,
            tag: entry.tagName,
            notes: ReleaseNotes.summary(of: entry.body ?? ""),
            assetURL: asset.browserDownloadURL,
            assetSize: asset.size,
            publishedAt: entry.publishedAt.flatMap { try? Date($0, strategy: .iso8601) })
    }

    /// The DMG, always: it is the one artifact the cask, a hand download and the updater all read.
    /// One DMG ships per release and its build is arm64-only, so Intel is offered nothing.
    private static func asset(
        from assets: [Entry.Asset], for architecture: ReleaseArchitecture
    ) -> Entry.Asset? {
        guard case .appleSilicon = architecture else { return nil }
        return assets.first { $0.name.hasSuffix(".dmg") }
    }

    /// The download targets the release host only. `browser_download_url` is a direct
    /// `github.com/<repository>/releases/download/...` link; the session may follow GitHub's own
    /// redirect to the CDN, but the feed is the one place a foreign URL could enter, so it is
    /// filtered here, before anything is downloaded.
    static func acceptsAssetURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        guard url.scheme == "https" else { return false }
        if host == "github.com" {
            // The direct download path; the API never emits any other github.com form here.
            return url.path.hasPrefix("/\(repository)/releases/download/")
        }
        // GitHub's release CDN: a redirect lands here, and a feed entry carries it directly.
        return host == "objects.githubusercontent.com" || host == "release-assets.githubusercontent.com"
    }

    private struct Entry: Decodable {
        let tagName: String
        let prerelease: Bool
        let draft: Bool
        let body: String?
        let publishedAt: String?
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case prerelease, draft, body, assets
            case publishedAt = "published_at"
        }

        struct Asset: Decodable {
            let name: String
            let size: Int64
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name, size
                case browserDownloadURL = "browser_download_url"
            }
        }
    }
}
