import Foundation

/// What ArrBarr asks of a media server. Six calls, all of them either reads or
/// maintenance the user explicitly pressed — nothing here writes library
/// content, and there is no delete path on purpose.
public protocol MediaServerClient: Sendable {
    var config: MediaServerConfig { get }

    /// Reachability + version, and (Jellyfin / Emby) the user id whose play
    /// state we will read. Throws on anything the user needs to fix.
    func testConnection() async throws -> MediaServerHandshake

    /// Every movie and series in the server's libraries, with provider ids and
    /// play state. One pass — this is what `MediaServerIndex` is built from.
    func libraryIndex() async throws -> [MediaServerEntry]

    /// Ask the server to rescan its libraries.
    func scanLibraries() async throws

    /// Purge entries whose files are gone. Plex only — the others throw
    /// `MediaServerError.trashUnsupported`.
    func emptyTrash() async throws

    func nowPlaying() async throws -> [MediaServerSession]

    func recentlyWatched(limit: Int) async throws -> [MediaServerWatch]
}

public enum MediaServerClientFactory {
    /// The client for the currently selected server, or nil when the feature is
    /// off / half-configured. Callers treat nil as "no media server", which is
    /// the same path they take when a fetch fails.
    public static func make(config: MediaServerConfig) -> MediaServerClient? {
        guard config.isConfigured else { return nil }
        switch config.kind {
        case .plex:
            return PlexClient(config: config)
        case .jellyfin, .emby:
            // One implementation for both: Jellyfin is Emby's fork and the
            // endpoints ArrBarr touches (`/System/Info`, `/Users`, `/Items`,
            // `/Sessions`, `/Library/Refresh`) never diverged. Only the auth
            // header differs, and that already lives on `MediaServerKind`.
            return JellyfinClient(config: config)
        }
    }
}

// MARK: - Shared helpers

extension MediaServerClient {
    /// Base URL with any trailing slashes removed, so path joining can't
    /// produce a double slash (which some reverse proxies 404).
    var normalizedBaseURL: String {
        var base = config.baseURL
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

}

/// Parses the provider-id strings the servers hand out.
///
/// Plex ships several generations of them side by side: the modern
/// `tmdb://157336`, the legacy agent form
/// `com.plexapp.agents.themoviedb://157336?lang=en`, and TVDB's
/// `com.plexapp.agents.thetvdb://121361/2/1`. Jellyfin and Emby use a plain
/// `ProviderIds` dictionary and need only the numeric parsing.
public enum MediaServerGuidParser {

    /// Every external key encoded in one guid string, or none.
    public static func key(from guid: String) -> MediaServerExternalKey? {
        let lower = guid.lowercased()
        guard let schemeEnd = lower.range(of: "://") else { return nil }
        let scheme = String(lower[lower.startIndex..<schemeEnd.lowerBound])
        // Everything after "://" up to the first "/", "?" or "#" is the id —
        // TVDB guids carry season/episode as extra path components, and the
        // legacy agents append a `?lang=` query.
        let rest = lower[schemeEnd.upperBound...]
        let idSlice = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        let id = String(idSlice)
        guard !id.isEmpty else { return nil }

        if scheme.contains("tmdb") || scheme.contains("themoviedb") {
            return Int(id).map { .tmdb($0) }
        }
        if scheme.contains("tvdb") {
            return Int(id).map { .tvdb($0) }
        }
        if scheme.contains("imdb") {
            // Keep imdb ids in their canonical lowercase "tt…" form so both
            // sides of the join agree.
            return id.hasPrefix("tt") ? .imdb(id) : nil
        }
        return nil
    }

    /// Jellyfin / Emby `ProviderIds`: `{"Tmdb": "157336", "Imdb": "tt0816692"}`.
    /// Keys are matched case-insensitively — the two servers disagree on
    /// capitalisation across versions.
    public static func keys(fromProviderIds ids: [String: String]) -> [MediaServerExternalKey] {
        var out: [MediaServerExternalKey] = []
        for (rawName, rawValue) in ids {
            let name = rawName.lowercased()
            let value = rawValue.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch name {
            case "tmdb", "themoviedb":
                if let n = Int(value) { out.append(.tmdb(n)) }
            case "tvdb", "thetvdb":
                if let n = Int(value) { out.append(.tvdb(n)) }
            case "imdb":
                let lower = value.lowercased()
                if lower.hasPrefix("tt") { out.append(.imdb(lower)) }
            default:
                continue
            }
        }
        return out
    }
}
