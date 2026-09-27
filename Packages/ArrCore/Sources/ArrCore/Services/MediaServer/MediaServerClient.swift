import Foundation

/// What ArrBarr asks of a media server. Eight calls, all of them either reads or
/// maintenance the user explicitly pressed — nothing here writes library
/// content, and there is no delete path on purpose.
nonisolated public protocol MediaServerClient: Sendable {
    var config: MediaServerConfig { get }

    /// Reachability + version, and (Jellyfin / Emby) the user id whose play
    /// state we will read. Throws on anything the user needs to fix.
    func testConnection() async throws -> MediaServerHandshake

    /// Every movie and series in the server's libraries, with provider ids and
    /// play state. One pass — this is what `MediaServerIndex` is built from.
    func libraryIndex() async throws -> [MediaServerEntry]

    /// The server's libraries, in the order the server lists them.
    func libraries() async throws -> [MediaServerLibrary]

    /// Ask the server to rescan one library (`MediaServerLibrary.id`).
    func scanLibrary(id: String) async throws

    /// Purge one library's entries whose files are gone. Plex only — the
    /// others throw `MediaServerError.trashUnsupported`.
    func emptyTrash(libraryId: String) async throws

    func nowPlaying() async throws -> [MediaServerSession]

    func recentlyWatched(limit: Int) async throws -> [MediaServerWatch]

    /// Season number → season poster, for one series item on the server.
    /// Seasons the server has no artwork of its own for are simply absent —
    /// the caller falls back to the series poster.
    func seasonPosters(seriesItemId: String) async throws -> [Int: URL]
}

nonisolated public enum MediaServerClientFactory {
    public static func make(config: MediaServerConfig) -> MediaServerClient? {
        guard config.isConfigured else { return nil }
        return MediaServerFacade(config: config)
    }
}

// MARK: - Shared helpers

nonisolated extension MediaServerClient {
    /// Base URL with any trailing slashes removed, so path joining can't
    /// produce a double slash (which some reverse proxies 404).
    var normalizedBaseURL: String {
        var base = config.baseURL
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    /// Rescan every library — what the `media_server_scan` tool asks for,
    /// where "the one an arr just imported into" isn't known.
    func scanLibraries() async throws {
        for library in try await libraries() {
            try await scanLibrary(id: library.id)
        }
    }
}
