import Foundation

actor SearchClient {
    private let config: ServiceConfig
    private let source: QueueItem.Source
    private let http = HTTPClient()

    private var apiBase: String {
        source == .lidarr ? "/api/v1" : "/api/v3"
    }

    init(config: ServiceConfig, source: QueueItem.Source) {
        self.config = config
        self.source = source
    }

    private var headers: [String: String] { ["X-Api-Key": config.apiKey] }

    // MARK: - Lookup

    func lookup(query: String) async throws -> [SearchResult] {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        switch source {
        case .radarr:
            let url = try http.url(base: config.baseURL, path: "\(apiBase)/movie/lookup",
                                   query: [URLQueryItem(name: "term", value: encoded)])
            let data = try await http.get(url, headers: headers)
            let records = try JSONDecoder().decode([RadarrLookupRecord].self, from: data)
            return records.compactMap { Self.unifyRadarr($0, baseURL: config.baseURL) }
        case .sonarr:
            let url = try http.url(base: config.baseURL, path: "\(apiBase)/series/lookup",
                                   query: [URLQueryItem(name: "term", value: encoded)])
            let data = try await http.get(url, headers: headers)
            let records = try JSONDecoder().decode([SonarrLookupRecord].self, from: data)
            return records.compactMap { Self.unifySonarr($0, baseURL: config.baseURL) }
        case .lidarr:
            return [] // future
        }
    }

    // MARK: - Library filter

    func fetchLibraryIds() async throws -> Set<Int> {
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
            return []
        }
    }

    // MARK: - Profiles & folders

    func fetchQualityProfiles() async throws -> [QualityProfile] {
        guard config.isConfigured else { return [] }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/qualityprofile")
        let data = try await http.get(url, headers: headers)
        return (try? JSONDecoder().decode([QualityProfile].self, from: data)) ?? []
    }

    func fetchRootFolders() async throws -> [RootFolder] {
        guard config.isConfigured else { return [] }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/rootfolder")
        let data = try await http.get(url, headers: headers)
        return (try? JSONDecoder().decode([RootFolder].self, from: data)) ?? []
    }

    // MARK: - Add

    func addMovie(_ result: SearchResult, qualityProfileId: Int, rootFolderPath: String,
                  monitor: RadarrMonitorMode) async throws {
        guard config.isConfigured else { throw HTTPError.notConfigured }
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
        guard config.isConfigured else { throw HTTPError.notConfigured }
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

    // MARK: - Unify

    private static func unifyRadarr(_ r: RadarrLookupRecord, baseURL: String) -> SearchResult? {
        guard let tmdbId = r.tmdbId else { return nil }
        let (poster, _) = pickPosterURL(from: r.images, coverTypes: ["poster"], baseURL: baseURL)
        return SearchResult(
            id: tmdbId, foreignId: String(tmdbId),
            title: r.title, subtitle: nil,
            year: r.year, rating: r.ratings?.tmdb?.value,
            overview: r.overview, runtime: r.runtime,
            posterURL: poster, source: .radarr
        )
    }

    private static func unifySonarr(_ r: SonarrLookupRecord, baseURL: String) -> SearchResult? {
        guard let tvdbId = r.tvdbId else { return nil }
        let (poster, _) = pickPosterURL(from: r.images, coverTypes: ["poster"], baseURL: baseURL)
        let seasons = r.statistics?.seasonCount
        let subtitle = seasons.map { "\($0) season\($0 == 1 ? "" : "s")" }
        return SearchResult(
            id: tvdbId, foreignId: String(tvdbId),
            title: r.title, subtitle: subtitle,
            year: r.year, rating: r.ratings?.value,
            overview: r.overview, runtime: nil,
            posterURL: poster, source: .sonarr
        )
    }
}
