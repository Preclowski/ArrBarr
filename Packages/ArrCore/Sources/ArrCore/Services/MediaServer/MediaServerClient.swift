import Foundation

/// What ArrBarr's settings and tools ask of a media server (the index reads
/// through `MediaServerFacade` directly). Six calls, all of them either reads or
/// maintenance the user explicitly pressed — nothing here writes library
/// content, and there is no delete path on purpose.
nonisolated public protocol MediaServerClient: Sendable {
    var config: MediaServerConfig { get }

    /// Reachability + version, and (Jellyfin / Emby) the user id whose play
    /// state we will read. Throws on anything the user needs to fix.
    func testConnection() async throws -> MediaServerHandshake

    /// The server's libraries, in the order the server lists them.
    func libraries() async throws -> [MediaServerLibrary]

    /// Ask the server to rescan one library (`MediaServerLibrary.id`).
    func scanLibrary(id: String) async throws

    /// Purge one library's entries whose files are gone. Plex only — the
    /// others throw `MediaServerError.trashUnsupported`.
    func emptyTrash(libraryId: String) async throws

    func nowPlaying() async throws -> [MediaServerSession]

    func recentlyWatched(limit: Int) async throws -> [MediaServerWatch]
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
