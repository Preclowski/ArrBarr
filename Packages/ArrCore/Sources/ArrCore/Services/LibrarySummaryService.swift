import Foundation
import os

/// Extension-safe: builds the arr clients directly rather than `LocalToolBackend`,
/// which is too heavy for a widget's memory budget.
public actor LibrarySummaryService {
    nonisolated private static let log = Logger(category: "Widget")
    public init() {}

    /// A service that errors is omitted; the caller renders it as a stale row.
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

    /// The demo library for `sources`, from the bundled fixtures (the widget's demo mode).
    public static func demo(sources: Set<LibrarySummary.Source>) async -> [LibrarySummary] {
        let gateway = await MainActor.run { ServiceGateway.demo(kinds: Set(sources.map(\.serviceKind))) }
        let configs = await MainActor.run { LibrarySummary.Source.allCases.map { gateway.configStore.config(for: $0.serviceKind) } }
        let summaries = await ServiceGateway.$override.withValue(gateway) {
            await LibrarySummaryService().summaries(radarr: configs[0], sonarr: configs[1], lidarr: configs[2], whisparr: configs[3])
        }
        await gateway.kit.stop()
        return summaries
    }

    nonisolated private static func fetch(
        _ config: ServiceConfig,
        _ body: @Sendable (ServiceConfig) async throws -> LibrarySummary
    ) async -> LibrarySummary? {
        // isVisible, not isConfigured: a keyless arr would 401 and leave a blank widget
        // instead of the "Set up a server" state.
        guard config.isVisible else { return nil }
        // The widget has no other diagnostics, so a failed source is kept at notice.
        return await log.attempt("library summary", level: .default) { try await body(config) }
    }
}
