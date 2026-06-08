import Foundation

/// Thin, extension-safe entry point: given the four arr configs, fetch each
/// configured library and return per-source summaries. Constructs the arr
/// `actor` clients directly — deliberately avoids `LocalToolBackend` (TMDB,
/// custom formats, discover) which is too heavy for a widget's memory budget.
public actor LibrarySummaryService {
    public init() {}

    /// Fetch summaries for the given configs, in `LibrarySummary.Source` order,
    /// skipping unconfigured services. A service that errors is omitted (the
    /// caller renders it as a stale/"—" row).
    public func summaries(
        radarr: ServiceConfig,
        sonarr: ServiceConfig,
        lidarr: ServiceConfig,
        whisparr: ServiceConfig
    ) async -> [LibrarySummary] {
        async let r = Self.fetch(radarr) { LibrarySummary.radarr(from: try await RadarrClient(config: $0).fetchAllMovies()) }
        async let s = Self.fetch(sonarr) { LibrarySummary.sonarr(from: try await SonarrClient(config: $0).fetchAllSeries()) }
        async let l = Self.fetch(lidarr) { LibrarySummary.lidarr(from: try await LidarrClient(config: $0).fetchAllArtists()) }
        async let w = Self.fetch(whisparr) { LibrarySummary.whisparr(from: try await WhisparrClient(config: $0).fetchAllMovies()) }
        return await [r, s, l, w].compactMap { $0 }
    }

    private static func fetch(
        _ config: ServiceConfig,
        _ body: @Sendable (ServiceConfig) async throws -> LibrarySummary
    ) async -> LibrarySummary? {
        // isVisible (not isConfigured): an arr enabled with a URL but no API
        // key would 401 and be silently dropped, yielding a blank widget. Gate
        // it out so the "Set up a server" empty state shows instead.
        guard config.isVisible else { return nil }
        return try? await body(config)
    }
}
