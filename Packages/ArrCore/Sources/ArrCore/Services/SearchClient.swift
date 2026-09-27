import Foundation
import MediaKit

/// Lookups and adds for one arr, through MediaKit; results keep ArrCore's `SearchResult` shape.
public actor SearchClient {
    private let config: ServiceConfig
    private let source: QueueItem.Source
    private let client: any ArrAPIClient

    init(config: ServiceConfig, source: QueueItem.Source) {
        self.config = config
        self.source = source
        self.client = ServiceHandles.arr(source, config: config)
    }

    func lookup(query: String) async throws -> [SearchResult] { try await lookup(input: .text(query)) }

    func lookup(input: SearchInput) async throws -> [SearchResult] {
        if case .ref(let ref) = input, !ref.compatibleSources.contains(source) { return [] }
        let query = input.arrTerm
        let baseURL = config.baseURL
        switch source {
        case .radarr:
            let records = try await client.read { $0.lookupMovies(term: query) }
            return records.enumerated().compactMap { SearchResult(radarr: $0.element, baseURL: baseURL, sourceRank: $0.offset) }
        case .sonarr:
            let records = try await client.read { $0.lookupSeries(term: query) }
            return records.enumerated().compactMap { SearchResult(sonarr: $0.element, baseURL: baseURL, sourceRank: $0.offset) }
        case .whisparr:
            let records = try await client.read { $0.lookupMovies(term: query) }
            return records.enumerated().compactMap { SearchResult(whisparr: $0.element, baseURL: baseURL, sourceRank: $0.offset) }
        case .lidarr:
            if input.isRef {
                let records = try await client.read { $0.lookupArtists(term: query) }
                return records.enumerated().compactMap { SearchResult(artist: $0.element, baseURL: baseURL, sourceRank: $0.offset) }
            }
            async let searchTask = client.read { $0.lidarrSearch(term: query) }
            async let artistTask = client.read { $0.lookupArtists(term: query) }
            let searchRecords = try await searchTask
            let artistRecords = (try? await artistTask) ?? []
            let albums = searchRecords.enumerated().compactMap { offset, rec in rec.album.flatMap { SearchResult(album: $0, baseURL: baseURL, sourceRank: offset) } }
            let artists = artistRecords.isEmpty
                ? searchRecords.enumerated().compactMap { offset, rec in rec.artist.flatMap { SearchResult(artist: $0, baseURL: baseURL, sourceRank: offset) } }
                : artistRecords.enumerated().compactMap { SearchResult(artist: $0.element, baseURL: baseURL, sourceRank: $0.offset) }
            return albums + artists
        }
    }

    func fetchLibraryOwnership() async throws -> [Int: LibraryOwnership] {
        guard config.isConfigured else { return [:] }
        switch source {
        case .radarr: return await ArrLibraryMaps.radarrByTMDBId(config: config)
        case .sonarr: return await ArrLibraryMaps.sonarrByTVDBId(config: config)
        case .lidarr: return await ArrLibraryMaps.lidarrByForeignArtistHash(config: config)
        case .whisparr: return await ArrLibraryMaps.whisparrByForeignId(config: config)
        }
    }

    nonisolated static func profileNameMap(config: ServiceConfig, source: QueueItem.Source) async -> [Int: String] {
        names((try? await SearchClient(config: config, source: source).fetchQualityProfiles()) ?? [])
    }

    /// Profiles already in the store, no request: the Library's first paint does not wait on garnish.
    nonisolated static func cachedProfileNameMap(config: ServiceConfig, source: QueueItem.Source) async -> [Int: String] {
        names(await SearchClient(config: config, source: source).cachedQualityProfiles())
    }

    nonisolated private static func names(_ profiles: [ArrQualityProfile]) -> [Int: String] {
        Dictionary(profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    func fetchQualityProfiles() async throws -> [ArrQualityProfile] { try await client.read { $0.qualityProfiles() } }
    func cachedQualityProfiles() async -> [ArrQualityProfile] { (try? await client.read(policy: .cacheOnly) { $0.qualityProfiles() }) ?? [] }
    func fetchMetadataProfiles() async throws -> [ArrMetadataProfile] { try await client.read { $0.metadataProfiles() } }
    /// The arr's root folder paths; the pickers need nothing else.
    func fetchRootFolders() async throws -> [String] { try await client.read { $0.rootFolders() }.compactMap(\.path) }

    private func ensureRefCompatible(_ result: SearchResult) throws {
        let ref = result.mediaRef
        guard ref.compatibleSources.contains(source) else {
            throw SearchAddError.wrongSource(serviceName: source.serviceKind.displayName)
        }
    }

    private func add(_ payload: ArrAddPayload) async throws -> Int? {
        try await client.run { $0.add(payload) }.trackingID
    }

    @discardableResult
    func addMovie(_ result: SearchResult, qualityProfileId: Int, rootFolderPath: String, monitor: RadarrMonitorMode, searchOnAdd: Bool) async throws -> Int? {
        try ensureRefCompatible(result)
        var payload = ArrAddPayload(qualityProfileId: qualityProfileId, rootFolderPath: rootFolderPath)
        payload.tmdbId = result.externalId
        payload.title = result.title
        payload.monitor = monitor.rawValue
        payload.addOptions = ArrAddOptions(searchForMovie: searchOnAdd)
        return try await add(payload)
    }

    @discardableResult
    func addSeries(_ result: SearchResult, qualityProfileId: Int, rootFolderPath: String, monitor: SonarrMonitorMode, seriesType: SonarrSeriesType,
                   seasonFolder: Bool, searchOnAdd: Bool) async throws -> Int? {
        try ensureRefCompatible(result)
        let tvdbId = result.externalId
        guard tvdbId > 0 else {
            throw SearchAddError.unresolvedSeries(title: result.title)
        }
        var payload = ArrAddPayload(qualityProfileId: qualityProfileId, rootFolderPath: rootFolderPath)
        payload.tvdbId = tvdbId
        payload.title = result.title
        payload.seriesType = seriesType.rawValue
        payload.seasonFolder = seasonFolder
        payload.addOptions = ArrAddOptions(searchForMissingEpisodes: searchOnAdd, monitor: monitor.apiValue)
        return try await add(payload)
    }

    @discardableResult
    func addScene(_ result: SearchResult, qualityProfileId: Int, rootFolderPath: String, monitor: RadarrMonitorMode = .movieOnly, searchOnAdd: Bool) async throws -> Int? {
        try ensureRefCompatible(result)
        var payload = ArrAddPayload(qualityProfileId: qualityProfileId, rootFolderPath: rootFolderPath)
        payload.title = result.title
        payload.monitor = monitor.rawValue
        payload.addOptions = ArrAddOptions(searchForMovie: searchOnAdd)
        if let tmdbId = Int(result.foreignId), tmdbId != 0 { payload.tmdbId = tmdbId } else { payload.foreignId = result.foreignId }
        return try await add(payload)
    }

    @discardableResult
    func addArtist(_ result: SearchResult, qualityProfileId: Int, metadataProfileId: Int, rootFolderPath: String, monitor: String = "all",
                   searchOnAdd: Bool) async throws -> Int? {
        try ensureRefCompatible(result)
        var payload = ArrAddPayload(qualityProfileId: qualityProfileId, rootFolderPath: rootFolderPath)
        payload.foreignArtistId = result.foreignId
        payload.artistName = result.title
        payload.metadataProfileId = metadataProfileId
        payload.addOptions = ArrAddOptions(searchForMissingAlbums: searchOnAdd, monitor: monitor)
        return try await add(payload)
    }

    @discardableResult
    func addAlbum(_ result: SearchResult, qualityProfileId: Int, metadataProfileId: Int, rootFolderPath: String, searchOnAdd: Bool) async throws -> Int? {
        try ensureRefCompatible(result)
        var payload = ArrAddPayload(qualityProfileId: qualityProfileId, rootFolderPath: rootFolderPath)
        payload.metadataProfileId = metadataProfileId
        payload.addOptions = ArrAddOptions(searchForMissingAlbums: searchOnAdd, monitor: "none")
        return try await client.run { $0.addAlbum(foreignAlbumID: result.foreignId, term: result.title, payload: payload) }.trackingID
    }

}

/// Adds refused before any request: the result can't go to this arr, or has no id the arr can add by.
nonisolated enum SearchAddError: LocalizedError {
    case wrongSource(serviceName: String)
    case unresolvedSeries(title: String)

    var errorDescription: String? {
        switch self {
        case let .wrongSource(serviceName): String(format: String(localized: "search.wrongSource.error", bundle: .module), serviceName)
        case let .unresolvedSeries(title): String(format: String(localized: "search.unresolvedSeries.error", bundle: .module), title)
        }
    }
}
