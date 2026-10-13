import Foundation

/// One published release this build could install, reduced to the fields the updater needs.
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
    /// Where official builds come from when no release feed is stamped into the app.
    static let defaultRepository = "abue-ammar/tinycast"
    static let repositoryInfoKey = "TinycastUpdateRepository"

    /// Where releases come from, and what every `@handle` and `#304` in their notes points at.
    /// Fork release workflows stamp their own repository into Info.plist at build time.
    static var repository: String { repository(in: Bundle.main.infoDictionary) }

    static func repository(in info: [String: Any]?) -> String {
        guard let raw = info?[repositoryInfoKey] as? String else { return defaultRepository }
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = candidate.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
            candidate.unicodeScalars.allSatisfy({ repositoryCharacters.contains($0) })
        else { return defaultRepository }
        return candidate
    }

    static func endpoint(for repository: String) -> URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=20")!
    }

    static func acceptsRepository(in info: [String: Any]?, expected: String) -> Bool {
        repository(in: info) == expected
    }

    /// The asset address comes from feed JSON kept in a cache file, so it is not trusted blind.
    static func acceptsToken(_ url: URL) -> Bool {
        url.scheme == "https" && url.host() == "api.github.com"
    }

    /// What asking for the feed came to; each failure is kept apart because each has its own fix.
    enum Response: Sendable, Equatable {
        case body(Data)
        case refused
        case missing
        case limited
        case unreachable

        /// GitHub answers 404 for a private repository too, so only a sent token makes it a refusal.
        init(status: Int, data: Data, authorized: Bool) {
            switch status {
            case 200: self = .body(data)
            case 401: self = .refused
            case 404: self = authorized ? .refused : .missing
            case 403, 429: self = .limited
            default: self = .unreachable
            }
        }
    }

    private static let repositoryCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._/")

    /// The only artifact with an x86_64 slice, so the only one an Intel Mac can install.
    private static let universalMarker = "-Universal-"

    /// The newest release this channel accepts, ignoring drafts and anything without a usable zip.
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
            assetURL: asset.url,
            assetSize: asset.size,
            publishedAt: entry.publishedAt.flatMap { try? Date($0, strategy: .iso8601) })
    }

    /// Never the DMG: the updater expands an archive rather than mounting a volume.
    private static func asset(
        from assets: [Entry.Asset], for architecture: ReleaseArchitecture
    ) -> Entry.Asset? {
        let zips = assets.filter { $0.name.hasSuffix(".zip") }
        let universal = zips.first { $0.name.contains(universalMarker) }
        switch architecture {
        case .intel: return universal
        case .appleSilicon: return zips.first { !$0.name.contains(universalMarker) } ?? universal
        }
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
            /// The API address, not the browser one: only it serves a private repository's asset.
            let url: URL
        }
    }
}
