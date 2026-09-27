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
        self.client = switch source {
        case .radarr: RadarrClient(config: config)
        case .sonarr: SonarrClient(config: config)
        case .lidarr: LidarrClient(config: config)
        case .whisparr: WhisparrClient(config: config)
        }
    }

    func lookup(query: String) async throws -> [SearchResult] { try await lookup(input: .text(query)) }

    func lookup(input: SearchInput) async throws -> [SearchResult] {
        if case .ref(let ref) = input, !ref.compatibleSources.contains(source) { return [] }
        let query = input.arrTerm
        let baseURL = config.baseURL
        switch source {
        case .radarr:
            let records = try await client.read { $0.lookupMovies(term: query) }
            return records.enumerated().compactMap { Self.unifyRadarr($0.element, baseURL: baseURL, sourceRank: $0.offset) }
        case .sonarr:
            let records = try await client.read { $0.lookupSeries(term: query) }
            return records.enumerated().compactMap { Self.unifySonarr($0.element, baseURL: baseURL, sourceRank: $0.offset) }
        case .whisparr:
            let records = try await client.read { $0.lookupMovies(term: query) }
            return records.enumerated().compactMap { Self.unifyWhisparr($0.element, baseURL: baseURL, sourceRank: $0.offset) }
        case .lidarr:
            if input.isRef {
                let records = try await client.read { $0.lookupArtists(term: query) }
                return records.enumerated().compactMap { Self.unifyLidarr($0.element, baseURL: baseURL, sourceRank: $0.offset) }
            }
            async let searchTask = client.read { $0.lidarrSearch(term: query) }
            async let artistTask = client.read { $0.lookupArtists(term: query) }
            let searchRecords = try await searchTask
            let artistRecords = (try? await artistTask) ?? []
            let albums = searchRecords.enumerated().compactMap { offset, rec in rec.album.flatMap { Self.unifyLidarrAlbum($0, baseURL: baseURL, sourceRank: offset) } }
            let artists = artistRecords.isEmpty
                ? searchRecords.enumerated().compactMap { offset, rec in rec.artist.flatMap { Self.unifyLidarr($0, baseURL: baseURL, sourceRank: offset) } }
                : artistRecords.enumerated().compactMap { Self.unifyLidarr($0.element, baseURL: baseURL, sourceRank: $0.offset) }
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
        let profiles = await SearchOptionsCache.shared.qualityProfiles(config: config, source: source) {
            (try? await SearchClient(config: config, source: source).fetchQualityProfiles()) ?? []
        }
        return Dictionary(profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    /// Profiles already in hand, no request. See `cachedQualityProfiles`.
    nonisolated static func cachedProfileNameMap(config: ServiceConfig, source: QueueItem.Source) async -> [Int: String] {
        let profiles = await SearchOptionsCache.shared.cachedQualityProfiles(config: config, source: source)
        return Dictionary(profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    func fetchQualityProfiles() async throws -> [ArrQualityProfile] { (try? await client.read { $0.qualityProfiles() }) ?? [] }
    func fetchMetadataProfiles() async throws -> [ArrMetadataProfile] { (try? await client.read { $0.metadataProfiles() }) ?? [] }
    /// The arr's root folder paths; the pickers need nothing else.
    func fetchRootFolders() async throws -> [String] { ((try? await client.read { $0.rootFolders() }) ?? []).compactMap(\.path) }

    private func ensureRefCompatible(_ result: SearchResult) throws {
        let ref = result.mediaRef
        guard ref.compatibleSources.contains(source) else {
            throw SearchAddError.wrongSource(serviceName: client.serviceName)
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

    // MARK: - Result mapping

    nonisolated private static func poster(_ images: [ArrImage]?, baseURL: String, coverTypes: [String] = ["poster"],
                                           keys: [MediaServerExternalKey] = []) -> URL? {
        images?.posterURL(baseURL: baseURL, coverTypes: coverTypes, mediaServerKeys: keys).0
    }

    nonisolated private static func unifyRadarr(_ r: ArrMovie, baseURL: String, sourceRank: Int = 0) -> SearchResult? {
        guard let tmdbId = r.tmdbId else { return nil }
        return SearchResult(
            externalId: tmdbId, foreignId: String(tmdbId), title: r.title, subtitle: nil, year: r.year, rating: r.ratings?.tmdb?.value,
            votes: r.ratings?.tmdb?.votes ?? r.ratings?.imdb?.votes, imdb: r.ratings?.imdb?.value, rottenTomatoes: r.ratings?.rottenTomatoes?.value,
            metacritic: r.ratings?.metacritic?.value, overview: r.overview, runtime: r.runtime, genres: r.genres ?? [], network: r.studio,
            certification: r.certification, posterURL: poster(r.images, baseURL: baseURL, keys: [.tmdbMovie(tmdbId)]), source: .radarr,
            inLibraryArrId: (r.id ?? 0) != 0 ? r.id : nil, imdbId: r.imdbId, sourceRank: sourceRank)
    }

    nonisolated private static func unifySonarr(_ r: ArrSeries, baseURL: String, sourceRank: Int = 0) -> SearchResult? {
        guard let tvdbId = r.tvdbId else { return nil }
        let seasons = r.statistics?.seasonCount
        return SearchResult(
            externalId: tvdbId, foreignId: String(tvdbId), title: r.title, subtitle: seasons.map { "\($0) season\($0 == 1 ? "" : "s")" },
            year: r.year, rating: r.ratings?.value, votes: r.ratings?.votes, imdb: nil, rottenTomatoes: nil, metacritic: nil,
            overview: r.overview, runtime: r.runtime, genres: r.genres ?? [], network: r.network, certification: nil,
            posterURL: poster(r.images, baseURL: baseURL, keys: [.tvdb(tvdbId)] + ((r.tmdbId ?? 0) != 0 ? [.tmdbSeries(r.tmdbId!)] : [])),
            source: .sonarr, inLibraryArrId: (r.id ?? 0) != 0 ? r.id : nil,
            imdbId: r.imdbId, sourceRank: sourceRank, tmdbTVId: (r.tmdbId ?? 0) != 0 ? r.tmdbId : nil)
    }

    nonisolated static func unifyWhisparr(_ r: ArrMovie, baseURL: String, sourceRank: Int = 0) -> SearchResult? {
        let stableId: Int, foreign: String
        if let tmdb = r.tmdbId, tmdb != 0 { stableId = tmdb; foreign = String(tmdb) }
        else if let fid = r.foreignId, !fid.isEmpty { stableId = ArrLibraryMaps.foreignHashKey(fid); foreign = fid }
        else { return nil }
        return SearchResult(
            externalId: stableId, foreignId: foreign, title: r.title, subtitle: nil, year: r.year, rating: r.ratings?.tmdb?.value,
            votes: r.ratings?.tmdb?.votes ?? r.ratings?.imdb?.votes, imdb: nil, rottenTomatoes: nil, metacritic: nil, overview: r.overview,
            runtime: r.runtime, genres: r.genres ?? [], network: r.studio, certification: nil, posterURL: poster(r.images, baseURL: baseURL),
            source: .whisparr, sourceRank: sourceRank)
    }

    nonisolated static func unifyLidarrAlbum(_ r: ArrAlbum, baseURL: String, sourceRank: Int = 0) -> SearchResult? {
        guard let foreign = r.foreignAlbumId, !foreign.isEmpty else { return nil }
        let year = r.releaseDate.flatMap { parseArrDate($0) }.map { Calendar.current.component(.year, from: $0) }
        let subtitle = [r.artist?.artistName, r.albumType].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return SearchResult(
            externalId: ArrLibraryMaps.foreignHashKey(foreign), foreignId: foreign, title: r.title, subtitle: subtitle.isEmpty ? r.disambiguation : subtitle,
            year: year, rating: r.ratings?.value, votes: r.ratings?.votes, imdb: nil, rottenTomatoes: nil, metacritic: nil, overview: r.overview,
            runtime: nil, genres: r.genres ?? [], network: nil, certification: nil, posterURL: poster(r.images, baseURL: baseURL, coverTypes: ["cover", "poster"]),
            source: .lidarr, inLibraryArrId: (r.id ?? 0) != 0 ? r.id : nil, sourceRank: sourceRank, isLidarrAlbum: true)
    }

    nonisolated static func unifyLidarr(_ r: ArrArtist, baseURL: String, sourceRank: Int = 0) -> SearchResult? {
        guard let foreign = r.foreignArtistId, !foreign.isEmpty, let name = r.artistName, !name.isEmpty else { return nil }
        return SearchResult(
            externalId: ArrLibraryMaps.foreignHashKey(foreign), foreignId: foreign, title: name, subtitle: r.disambiguation, year: nil,
            rating: r.ratings?.value, votes: r.ratings?.votes, imdb: nil, rottenTomatoes: nil, metacritic: nil, overview: r.overview, runtime: nil,
            genres: r.genres ?? [], network: nil, certification: nil, posterURL: poster(r.images, baseURL: baseURL, coverTypes: ["poster", "cover"]),
            source: .lidarr, sourceRank: sourceRank)
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
