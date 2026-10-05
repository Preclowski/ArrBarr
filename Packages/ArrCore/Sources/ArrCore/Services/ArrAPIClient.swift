import os
import Foundation
import MediaKit


/// What the four arr clients share. Every request goes through MediaKit; a client is a value that names its arr
/// and carries the config it was built with (the saved one, a Settings draft, or a test's).
public protocol ArrAPIClient: Sendable {
    var config: ServiceConfig { get }
    var source: QueueItem.Source { get }
}

/// Radarr and Whisparr v3 share the movie vocabulary.
protocol MovieArrClient: ArrAPIClient {}

extension MovieArrClient {
    func fetchMovieDetails(id: Int) async throws -> ArrMovie { try await read { $0.movie(id: id) } }
    func fetchMovieFile(movieId: Int) async throws -> ArrFile? { try await read { $0.movieFiles([movieId]) }.first }
    /// Returns the arr command id, for `QueueViewModel.watchSearch`.
    @discardableResult
    func searchMovie(movieId: Int) async throws -> Int? { try await run { $0.search(.movies([movieId])) }.trackingID }
    /// `revalidate: false` serves the stored rows, flags `isStale` and refreshes behind the caller.
    func fetchAllMovies(revalidate: Bool = true) async throws -> [ArrMovie] {
        try await fetchAllMoviesFetched(revalidate: revalidate).value
    }
    func fetchAllMoviesFetched(revalidate: Bool = true) async throws -> Fetched<[ArrMovie]> {
        try await readCacheFirst(revalidate: revalidate) { $0.movies() }
    }
}

/// The gateway plus the service bound to this client's instance: the saved profile's, or the draft's own ordinal.
struct ArrContext {
    let gateway: ServiceGateway
    let service: ServarrService
    var store: ResourceStore { gateway.store }
}

extension ArrAPIClient {
    var serviceName: String { source.serviceKind.displayName }

    func fetchQueue() async throws -> [QueueItem] {
        let c = try await context()
        return try await ArrQueueLoader.items(source: source, gateway: c.gateway, service: c.service, baseURL: config.baseURL)
    }
    func fetchCalendar() async throws -> [UpcomingItem] {
        let c = try await context()
        return try await ArrQueueLoader.upcoming(source: source, gateway: c.gateway, service: c.service, baseURL: config.baseURL)
    }

    func context() async throws -> ArrContext {
        let gateway = await ServiceGateway.resolve()
        let instance = await gateway.adopt(config, for: source.serviceKind)
        await gateway.ready()
        guard gateway.isConfigured(instance), let service = gateway.kit.servarr(instance) else { throw MediaKitError.notConfigured(instance) }
        return ArrContext(gateway: gateway, service: service)
    }

    /// Reads a MediaKit resource as is: its own type, and its harvest records the ids it carries.
    func read<V>(policy: ReadPolicy = .cacheFirst, maxAge: Duration? = nil, priority: RequestPriority = .interactive,
                 _ make: (ServarrService) -> Resource<V>) async throws -> V {
        try await readFetched(policy: policy, maxAge: maxAge, priority: priority, make).value
    }

    func readFetched<V>(policy: ReadPolicy = .cacheFirst, maxAge: Duration? = nil, priority: RequestPriority = .interactive,
                        _ make: (ServarrService) -> Resource<V>) async throws -> Fetched<V> {
        let context = try await context()
        return try await context.store.read(make(context.service), policy: policy, maxAge: maxAge, priority: priority)
    }

    /// `.cacheOnly`, not SWR: after an import marks the library tag stale, SWR refuses exactly these rows.
    /// Safe only because the caller follows a stale answer with a real fetch (`LibraryViewModel.loadIfNeeded`).
    func readCacheFirst<V>(revalidate: Bool, _ make: (ServarrService) -> Resource<V>) async throws -> Fetched<V> {
        if !revalidate, let cached = try? await readFetched(policy: .cacheOnly, make) { return cached }
        return try await readFetched(policy: .cacheFirst, make)
    }

    @discardableResult
    func run(_ make: (ServarrService) -> Command) async throws -> CommandReceipt {
        let context = try await context()
        return try await context.gateway.run(make(context.service))
    }

    // MARK: - Shared reads

    func fetchCustomFormats() async throws -> [ArrCustomFormatDetail] { try await read { $0.customFormats() } }
    func fetchIndexers() async throws -> [MediaKit.ArrIndexerDefinition] { try await read { $0.indexers() } }
    func fetchQualityProfiles() async throws -> [ArrQualityProfile] { try await read { $0.qualityProfiles() } }
    func fetchHealth() async throws -> [ArrHealth] { try await read(policy: .mustRevalidate) { $0.health() } }
    func fetchDiskSpace() async throws -> [ArrDiskSpace] { try await read { $0.diskSpace() } }

    func fetchReleases(_ target: ReleaseTarget) async throws -> [ArrRelease] { try await read { $0.releases(target) } }

    func testConnection() async throws -> String {
        let status = try await read(policy: .mustRevalidate) { $0.status() }
        return status.version.map { "\(serviceName) \($0)" } ?? String(localized: "common.ok.label", bundle: .module)
    }

    /// nil when the poll failed, so a blip never reads as "the search finished".
    func fetchCommands() async -> [ArrCommand]? {
        await Logger.extras.attempt("command poll") { try await read(policy: .mustRevalidate) { $0.commands() } }
    }

    func isSearchRunning(entityId: Int) async -> Bool {
        (await fetchCommands() ?? []).contains { $0.isSearch(for: entityId) }
    }

    // MARK: - Shared writes

    func setMovieMonitored(movieId: Int, monitored: Bool) async throws {
        try await run { $0.setMonitored(entityID: movieId, monitored) }
    }

    func deleteLibraryRecord(entityId: Int, deleteFiles: Bool, addImportExclusion: Bool) async throws {
        try await run { $0.delete(entityID: entityId, deleteFiles: deleteFiles, addImportExclusion: addImportExclusion) }
    }

    func grabRelease(guid: String, indexerId: Int) async throws { try await run { $0.grabRelease(guid: guid, indexerID: indexerId) } }
}
