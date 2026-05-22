import Foundation

public actor SearchClient {
    private let config: ServiceConfig
    private let source: QueueItem.Source
    private let http = HTTPClient()

    private var apiBase: String {
        source == .lidarr ? "/api/v1" : "/api/v3"
    }
    // .whisparr stays /api/v3 — no change needed since lidarr is the special case

    init(config: ServiceConfig, source: QueueItem.Source) {
        self.config = config
        self.source = source
    }

    private var headers: [String: String] { ["X-Api-Key": config.apiKey] }

    // MARK: - Lookup

    func lookup(query: String) async throws -> [SearchResult] {
        if DemoMode.isActive {
            // Simulate a brief network round-trip so the loading state is
            // visible. Real arr API responses to a typed query are
            // typically ~200-400 ms, so 350 ms feels right.
            try? await Task.sleep(nanoseconds: 350_000_000)
            return DemoMocks.searchResults(for: query, source: source)
        }
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        switch source {
        case .radarr:
            let url = try http.url(base: config.baseURL, path: "\(apiBase)/movie/lookup",
                                   query: [URLQueryItem(name: "term", value: query)])
            let data = try await http.get(url, headers: headers)
            let records = try JSONDecoder().decode([RadarrLookupRecord].self, from: data)
            return records.compactMap { Self.unifyRadarr($0, baseURL: config.baseURL) }
        case .sonarr:
            let url = try http.url(base: config.baseURL, path: "\(apiBase)/series/lookup",
                                   query: [URLQueryItem(name: "term", value: query)])
            let data = try await http.get(url, headers: headers)
            let records = try JSONDecoder().decode([SonarrLookupRecord].self, from: data)
            return records.compactMap { Self.unifySonarr($0, baseURL: config.baseURL) }
        case .lidarr:
            let url = try http.url(base: config.baseURL, path: "\(apiBase)/artist/lookup",
                                   query: [URLQueryItem(name: "term", value: query)])
            let data = try await http.get(url, headers: headers)
            let records = try JSONDecoder().decode([LidarrLookupRecord].self, from: data)
            return records.compactMap { Self.unifyLidarr($0, baseURL: config.baseURL) }
        case .whisparr:
            let url = try http.url(base: config.baseURL, path: "\(apiBase)/movie/lookup",
                                   query: [URLQueryItem(name: "term", value: query)])
            let data = try await http.get(url, headers: headers)
            let records = try JSONDecoder().decode([WhisparrLookupRecord].self, from: data)
            return records.compactMap { Self.unifyWhisparr($0, baseURL: config.baseURL) }
        }
    }

    // MARK: - Library filter

    func fetchLibraryIds() async throws -> Set<Int> {
        if DemoMode.isActive { return [] }
        guard config.isConfigured else { return [] }
        switch source {
        case .radarr:
            let url = try http.url(base: config.baseURL, path: "\(apiBase)/movie")
            let data = try await http.get(url, headers: headers)
            let records = (try? JSONDecoder().decode([RadarrLibraryRecord].self, from: data)) ?? []
            return Set(records.compactMap(\.tmdbId))
        case .sonarr:
            let url = try http.url(base: config.baseURL, path: "\(apiBase)/series")
            let data = try await http.get(url, headers: headers)
            let records = (try? JSONDecoder().decode([SonarrLibraryRecord].self, from: data)) ?? []
            return Set(records.compactMap(\.tvdbId))
        case .lidarr:
            let url = try http.url(base: config.baseURL, path: "\(apiBase)/artist")
            let data = try await http.get(url, headers: headers)
            let records = (try? JSONDecoder().decode([LidarrLibraryRecord].self, from: data)) ?? []
            return Set(records.compactMap { $0.foreignArtistId.map { abs($0.hashValue) & 0x7fffffff } })
        case .whisparr:
            let url = try http.url(base: config.baseURL, path: "\(apiBase)/movie")
            let data = try await http.get(url, headers: headers)
            let records = (try? JSONDecoder().decode([WhisparrLibraryRecord].self, from: data)) ?? []
            return Set(records.compactMap { rec -> Int? in
                if let tmdbId = rec.tmdbId, tmdbId != 0 { return tmdbId }
                if let fid = rec.foreignId { return abs(fid.hashValue) & 0x7fffffff }
                return nil
            })
        }
    }

    // MARK: - Profiles & folders

    func fetchQualityProfiles() async throws -> [QualityProfile] {
        if DemoMode.isActive {
            return [
                QualityProfile(id: 1, name: "Any"),
                QualityProfile(id: 2, name: "HD-1080p"),
                QualityProfile(id: 3, name: "Ultra-HD"),
            ]
        }
        guard config.isConfigured else { return [] }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/qualityprofile")
        let data = try await http.get(url, headers: headers)
        return (try? JSONDecoder().decode([QualityProfile].self, from: data)) ?? []
    }

    func fetchMetadataProfiles() async throws -> [MetadataProfile] {
        if DemoMode.isActive {
            return [MetadataProfile(id: 1, name: "Standard")]
        }
        guard config.isConfigured else { return [] }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/metadataprofile")
        let data = try await http.get(url, headers: headers)
        return (try? JSONDecoder().decode([MetadataProfile].self, from: data)) ?? []
    }

    func fetchRootFolders() async throws -> [RootFolder] {
        if DemoMode.isActive {
            return [
                RootFolder(id: 1, path: "/demo/Movies"),
                RootFolder(id: 2, path: "/demo/TV"),
            ]
        }
        guard config.isConfigured else { return [] }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/rootfolder")
        let data = try await http.get(url, headers: headers)
        return (try? JSONDecoder().decode([RootFolder].self, from: data)) ?? []
    }

    // MARK: - Add

    func addMovie(_ result: SearchResult, qualityProfileId: Int, rootFolderPath: String,
                  monitor: RadarrMonitorMode) async throws {
        if DemoMode.isActive {
            try? await Task.sleep(nanoseconds: 500_000_000)
            return
        }
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/movie")
        let body: [String: Any] = [
            "tmdbId": result.id,
            "title": result.title,
            "qualityProfileId": qualityProfileId,
            "rootFolderPath": rootFolderPath,
            "monitored": true,
            "monitor": monitor.rawValue,
            "addOptions": ["searchForMovie": true]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await http.post(url, headers: headers.merging(["Content-Type": "application/json"]) { $1 }, body: data)
    }

    func addSeries(_ result: SearchResult, qualityProfileId: Int, rootFolderPath: String,
                   monitor: SonarrMonitorMode, seriesType: SonarrSeriesType,
                   seasonFolder: Bool) async throws {
        if DemoMode.isActive {
            try? await Task.sleep(nanoseconds: 500_000_000)
            return
        }
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/series")
        let body: [String: Any] = [
            "tvdbId": result.id,
            "title": result.title,
            "qualityProfileId": qualityProfileId,
            "rootFolderPath": rootFolderPath,
            "monitored": true,
            "seriesType": seriesType.rawValue,
            "seasonFolder": seasonFolder,
            "addOptions": [
                "monitor": monitor.rawValue,
                "searchForMissingEpisodes": true
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await http.post(url, headers: headers.merging(["Content-Type": "application/json"]) { $1 }, body: data)
    }

    func addScene(_ result: SearchResult, qualityProfileId: Int, rootFolderPath: String,
                  monitor: RadarrMonitorMode = .movieOnly) async throws {
        if DemoMode.isActive {
            try? await Task.sleep(nanoseconds: 500_000_000)
            return
        }
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/movie")
        // Use tmdbId as integer if foreignId is all digits, otherwise use foreignId string
        var body: [String: Any] = [
            "title": result.title,
            "qualityProfileId": qualityProfileId,
            "rootFolderPath": rootFolderPath,
            "monitored": true,
            "monitor": monitor.rawValue,
            "addOptions": ["searchForMovie": true]
        ]
        let foreignId = result.foreignId
        if let tmdbId = Int(foreignId), tmdbId != 0 {
            body["tmdbId"] = tmdbId
        } else {
            body["foreignId"] = foreignId
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await http.post(url, headers: headers.merging(["Content-Type": "application/json"]) { $1 }, body: data)
    }

    func addArtist(_ result: SearchResult, qualityProfileId: Int, metadataProfileId: Int,
                   rootFolderPath: String, monitor: String = "all") async throws {
        if DemoMode.isActive {
            try? await Task.sleep(nanoseconds: 500_000_000)
            return
        }
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/artist")
        let body: [String: Any] = [
            "foreignArtistId": result.foreignId,
            "artistName": result.title,
            "qualityProfileId": qualityProfileId,
            "metadataProfileId": metadataProfileId,
            "rootFolderPath": rootFolderPath,
            "monitored": true,
            "addOptions": [
                "monitor": monitor,
                "searchForMissingAlbums": true
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await http.post(url, headers: headers.merging(["Content-Type": "application/json"]) { $1 }, body: data)
    }

    // MARK: - Unify

    private static func unifyRadarr(_ r: RadarrLookupRecord, baseURL: String) -> SearchResult? {
        guard let tmdbId = r.tmdbId else { return nil }
        let (poster, _) = (r.images?.posterURL(baseURL: baseURL) ?? (nil, false))
        return SearchResult(
            id: tmdbId, foreignId: String(tmdbId),
            title: r.title, subtitle: nil,
            year: r.year, rating: r.ratings?.tmdb?.value,
            imdb: r.ratings?.imdb?.value,
            rottenTomatoes: r.ratings?.rottenTomatoes?.value,
            metacritic: r.ratings?.metacritic?.value,
            overview: r.overview, runtime: r.runtime,
            genres: r.genres ?? [],
            network: r.studio,
            certification: r.certification,
            posterURL: poster, source: .radarr
        )
    }

    private static func unifySonarr(_ r: SonarrLookupRecord, baseURL: String) -> SearchResult? {
        guard let tvdbId = r.tvdbId else { return nil }
        let (poster, _) = (r.images?.posterURL(baseURL: baseURL) ?? (nil, false))
        let seasons = r.statistics?.seasonCount
        let subtitle = seasons.map { "\($0) season\($0 == 1 ? "" : "s")" }
        return SearchResult(
            id: tvdbId, foreignId: String(tvdbId),
            title: r.title, subtitle: subtitle,
            year: r.year, rating: r.ratings?.value,
            imdb: nil, rottenTomatoes: nil, metacritic: nil,
            overview: r.overview, runtime: r.runtime,
            genres: r.genres ?? [],
            network: r.network,
            certification: nil,
            posterURL: poster, source: .sonarr
        )
    }

    internal static func unifyWhisparr(_ r: WhisparrLookupRecord, baseURL: String) -> SearchResult? {
        let stableId: Int
        let foreign: String
        if let tmdb = r.tmdbId, tmdb != 0 {
            stableId = tmdb
            foreign = String(tmdb)
        } else if let fid = r.foreignId, !fid.isEmpty {
            stableId = abs(fid.hashValue) & 0x7fffffff
            foreign = fid
        } else {
            return nil
        }
        let poster = r.images?.posterURL(baseURL: baseURL) ?? (nil, false)
        return SearchResult(
            id: stableId,
            foreignId: foreign,
            title: r.title,
            subtitle: nil,
            year: r.year,
            rating: r.ratings?.tmdb?.value,
            imdb: nil,
            rottenTomatoes: nil,
            metacritic: nil,
            overview: r.overview,
            runtime: r.runtime,
            genres: r.genres ?? [],
            network: r.studio,
            certification: nil,
            posterURL: poster.0,
            source: .whisparr
        )
    }

    internal static func unifyLidarr(_ r: LidarrLookupRecord, baseURL: String) -> SearchResult? {
        guard let foreign = r.foreignArtistId, !foreign.isEmpty else { return nil }
        let (poster, _) = r.images?.posterURL(baseURL: baseURL, coverTypes: ["poster", "cover"]) ?? (nil, false)
        let stableId = abs(foreign.hashValue) & 0x7fffffff
        return SearchResult(
            id: stableId,
            foreignId: foreign,
            title: r.artistName,
            subtitle: r.disambiguation,
            year: nil,
            rating: r.ratings?.value,
            imdb: nil,
            rottenTomatoes: nil,
            metacritic: nil,
            overview: r.overview,
            runtime: nil,
            genres: r.genres ?? [],
            network: nil,
            certification: nil,
            posterURL: poster,
            source: .lidarr
        )
    }
}
