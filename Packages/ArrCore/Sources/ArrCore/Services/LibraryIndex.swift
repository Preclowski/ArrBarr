import Foundation
import MediaKit
import os

/// The Radarr / Sonarr / Lidarr / Whisparr libraries every tool, the Library
/// grid and Spotlight read — through MediaKit's store, so there is one cache.
///
/// The store holds each list under its instance's library tag: a `warm` TTL
/// is the backstop, and imports (SignalR), adds and edits invalidate the tag,
/// so "I just grabbed it, do I have it?" is answered by an event rather than by
/// guessing a short TTL. Concurrent cold reads coalesce in the store.
///
/// A version is the store's revision of that tag: it moves on every commit
/// and invalidation, and it lives in the gateway, so two gateways (tests) never
/// see each other's.
nonisolated public struct LibraryIndex: Sendable {

    public static let shared = LibraryIndex()

    /// What one read produced. `failed` is the only thing that tells "the arr is
    /// unreachable" from "the library is genuinely empty" — the Library tab's
    /// error state depends on the difference; `stale` means the records are the
    /// store's old copy, so the caller should ask again.
    public struct Read<Record: Sendable>: Sendable {
        public let records: [Record]
        public let failed: Bool
        public let stale: Bool
    }

    /// Same value means the records behind it are the same, so re-unifying a
    /// 3000-title library would be pure waste.
    public struct Version: Equatable, Sendable {
        let store: ObjectIdentifier?
        let instance: InstanceID?
        let tick: UInt64
    }

    private static let log = Logger(category: "LibraryIndex")

    // MARK: - Versions

    public func version(for source: QueueItem.Source, config: ServiceConfig) async -> Version {
        guard config.isConfigured else { return Version(store: nil, instance: nil, tick: 0) }
        let (gateway, instance) = await Self.scope(source, config)
        let tick = gateway.store.revision.tick(for: .collection(.library, instance))
        return Version(store: ObjectIdentifier(gateway.store), instance: instance, tick: tick)
    }

    /// Mark a source's library changed, so the next read goes to the arr — and
    /// falls back to the stored records if that fails, instead of an empty library.
    public func invalidate(_ source: QueueItem.Source, config: ServiceConfig) async {
        guard config.isConfigured else { return }
        let (gateway, instance) = await Self.scope(source, config)
        await gateway.store.invalidate([.collection(.library, instance)], reason: .manual)
    }

    // MARK: - Reads

    /// `revalidate: false` takes whatever the store holds, however old, and says so in `stale`.
    public func moviesRead(config: ServiceConfig, revalidate: Bool = true) async -> Read<RadarrLibraryRecord> {
        let read = await Self.read(.radarr, config) { try await RadarrClient(config: config).fetchAllMoviesFetched(revalidate: revalidate) }
        if !read.failed { LibraryStats.shared.setMovieCount(read.records.count) }
        return read
    }

    public func seriesRead(config: ServiceConfig, revalidate: Bool = true) async -> Read<SonarrLibraryRecord> {
        let read = await Self.read(.sonarr, config) { try await SonarrClient(config: config).fetchAllSeriesFetched(revalidate: revalidate) }
        if !read.failed { LibraryStats.shared.setSeriesCount(read.records.count) }
        return read
    }

    public func artistsRead(config: ServiceConfig, revalidate: Bool = true) async -> Read<LidarrLibraryRecord> {
        await Self.read(.lidarr, config) { try await LidarrClient(config: config).fetchAllArtistsFetched(revalidate: revalidate) }
    }

    public func whisparrMoviesRead(config: ServiceConfig, revalidate: Bool = true) async -> Read<WhisparrLibraryRecord> {
        await Self.read(.whisparr, config) { try await WhisparrClient(config: config).fetchAllMoviesFetched(revalidate: revalidate) }
    }

    public func movies(config: ServiceConfig, revalidate: Bool = true) async -> [RadarrLibraryRecord] {
        await moviesRead(config: config, revalidate: revalidate).records
    }

    public func series(config: ServiceConfig, revalidate: Bool = true) async -> [SonarrLibraryRecord] {
        await seriesRead(config: config, revalidate: revalidate).records
    }

    public func artists(config: ServiceConfig, revalidate: Bool = true) async -> [LidarrLibraryRecord] {
        await artistsRead(config: config, revalidate: revalidate).records
    }

    public func whisparrMovies(config: ServiceConfig, revalidate: Bool = true) async -> [WhisparrLibraryRecord] {
        await whisparrMoviesRead(config: config, revalidate: revalidate).records
    }

    /// A throw leaves nothing to serve (the store already fell back to its stored
    /// row when it had one, and says so in `degraded`).
    private static func read<Record: Sendable>(_ source: QueueItem.Source, _ config: ServiceConfig,
                                               _ fetch: () async throws -> Fetched<[Record]>) async -> Read<Record> {
        guard config.isConfigured else { return Read(records: [], failed: false, stale: false) }
        do {
            let fetched = try await fetch()
            log.notice("\(source.rawValue, privacy: .public) records: \(fetched.value.count, privacy: .public) from \(String(describing: fetched.origin), privacy: .public), stale \(fetched.isStale, privacy: .public)")
            return Read(records: fetched.value, failed: fetched.degraded != nil, stale: fetched.isStale)
        } catch {
            log.debug("\(source.rawValue, privacy: .public) library read failed: \(error.localizedDescription, privacy: .public)")
            return Read(records: [], failed: true, stale: false)
        }
    }

    private static func scope(_ source: QueueItem.Source, _ config: ServiceConfig) async -> (ServiceGateway, InstanceID) {
        let gateway = await ServiceGateway.resolve()
        return (gateway, await gateway.adopt(config, for: source.serviceKind))
    }
}
