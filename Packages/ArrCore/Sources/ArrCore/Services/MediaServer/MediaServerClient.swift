import Foundation
import MediaKit

/// Reads and user-pressed maintenance only; no delete path on purpose.
nonisolated public protocol MediaServerClient: Sendable {
    var config: MediaServerConfig { get }

    /// Includes (Jellyfin / Emby) the user id whose play state is read.
    func testConnection() async throws -> MediaServerHandshake

    func libraries() async throws -> [MediaServerLibrary]

    func scanLibrary(id: String) async throws

    /// Plex only; the others throw `MediaServerError.trashUnsupported`.
    func emptyTrash(libraryId: String) async throws

    func nowPlaying() async throws -> [MediaServerSession]

    func recentlyWatched(limit: Int) async throws -> [MediaServerWatch]
}

nonisolated enum MediaServerClientFactory {
    static func make(config: MediaServerConfig) -> MediaServerClient? {
        guard config.isConfigured else { return nil }
        return MediaServerFacade(config: config)
    }
}

// MARK: - Shared helpers

nonisolated extension MediaServerClient {
    /// A double slash 404s behind some reverse proxies.
    var normalizedBaseURL: String {
        var base = config.baseURL
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    /// For `media_server_scan`, where the imported-into library isn't known.
    func scanLibraries() async throws {
        for library in try await libraries() {
            try await scanLibrary(id: library.id)
        }
    }
}
