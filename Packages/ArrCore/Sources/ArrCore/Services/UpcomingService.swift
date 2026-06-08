import Foundation

/// Thin, extension-safe entry point for the Up Next widget: fetches each
/// configured arr's calendar (now → +30 days), merges, keeps future-ish
/// entries, sorts soonest-first, and trims to a limit. Builds the arr `actor`
/// clients directly — deliberately avoids `LocalToolBackend`.
public actor UpcomingService {
    public init() {}

    public func upcoming(
        radarr: ServiceConfig,
        sonarr: ServiceConfig,
        lidarr: ServiceConfig,
        whisparr: ServiceConfig,
        limit: Int = 8
    ) async -> [UpcomingItem] {
        async let r = Self.fetch(radarr) { try await RadarrClient(config: $0).fetchCalendar() }
        async let s = Self.fetch(sonarr) { try await SonarrClient(config: $0).fetchCalendar() }
        async let l = Self.fetch(lidarr) { try await LidarrClient(config: $0).fetchCalendar() }
        async let w = Self.fetch(whisparr) { try await WhisparrClient(config: $0).fetchCalendar() }
        let all = await r + s + l + w
        return Self.curate(all, limit: limit)
    }

    /// Future-ish (drop entries that aired more than a day ago), soonest-first,
    /// trimmed to `limit`. Exposed for demo reuse.
    public static func curate(_ items: [UpcomingItem], limit: Int) -> [UpcomingItem] {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        return items
            .filter { $0.airDate >= cutoff }
            .sorted { $0.airDate < $1.airDate }
            .prefix(limit)
            .map { $0 }
    }

    private static func fetch(
        _ config: ServiceConfig,
        _ body: @Sendable (ServiceConfig) async throws -> [UpcomingItem]
    ) async -> [UpcomingItem] {
        guard config.isVisible else { return [] }
        return (try? await body(config)) ?? []
    }
}
