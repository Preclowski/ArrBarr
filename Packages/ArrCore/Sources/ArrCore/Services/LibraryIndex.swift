import Foundation
import MediaKit
import os

/// Arr libraries read through MediaKit's store: imports, adds and edits invalidate the library tag, with
/// a `warm` TTL as backstop. A version is the store's revision of that tag, per gateway.
nonisolated public struct LibraryIndex: Sendable {

    public static let shared = LibraryIndex()

    /// `failed` tells "unreachable" from "genuinely empty"; `stale` means the store's old copy, so ask again.
    public struct Read<Record: Sendable>: Sendable {
        public let records: [Record]
        public let failed: Bool
        public let stale: Bool
    }

    /// Same value means the same records, so there is nothing to re-unify.
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

    /// On failure the next read falls back to the stored records instead of an empty library.
    public func invalidate(_ source: QueueItem.Source, config: ServiceConfig) async {
        guard config.isConfigured else { return }
        let (gateway, instance) = await Self.scope(source, config)
        await gateway.store.invalidate([.collection(.library, instance)], reason: .manual)
    }

    // MARK: - Reads

    public func moviesRead(config: ServiceConfig, revalidate: Bool = true) async -> Read<ArrMovie> {
        let read = await Self.read(.radarr, config) { try await RadarrClient(config: config).fetchAllMoviesFetched(revalidate: revalidate) }
        if !read.failed { LibraryStats.shared.setMovieCount(read.records.count) }
        return read
    }

    public func seriesRead(config: ServiceConfig, revalidate: Bool = true) async -> Read<ArrSeries> {
        let read = await Self.read(.sonarr, config) { try await SonarrClient(config: config).fetchAllSeriesFetched(revalidate: revalidate) }
        if !read.failed { LibraryStats.shared.setSeriesCount(read.records.count) }
        return read
    }

    public func artistsRead(config: ServiceConfig, revalidate: Bool = true) async -> Read<ArrArtist> {
        await Self.read(.lidarr, config) { try await LidarrClient(config: config).fetchAllArtistsFetched(revalidate: revalidate) }
    }

    public func whisparrMoviesRead(config: ServiceConfig, revalidate: Bool = true) async -> Read<ArrMovie> {
        await Self.read(.whisparr, config) { try await WhisparrClient(config: config).fetchAllMoviesFetched(revalidate: revalidate) }
    }

    public func movies(config: ServiceConfig, revalidate: Bool = true) async -> [ArrMovie] {
        await moviesRead(config: config, revalidate: revalidate).records
    }

    public func series(config: ServiceConfig, revalidate: Bool = true) async -> [ArrSeries] {
        await seriesRead(config: config, revalidate: revalidate).records
    }

    public func artists(config: ServiceConfig, revalidate: Bool = true) async -> [ArrArtist] {
        await artistsRead(config: config, revalidate: revalidate).records
    }

    public func whisparrMovies(config: ServiceConfig, revalidate: Bool = true) async -> [ArrMovie] {
        await whisparrMoviesRead(config: config, revalidate: revalidate).records
    }

    /// The store already fell back to its stored row when it had one, and says so in `degraded`.
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
