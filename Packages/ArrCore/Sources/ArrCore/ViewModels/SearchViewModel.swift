import Foundation
import Combine

@MainActor
public final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published var radarrResults: [SearchResult] = []
    @Published var sonarrResults: [SearchResult] = []
    @Published var lidarrResults: [SearchResult] = []
    @Published var whisparrResults: [SearchResult] = []
    @Published var isSearching = false
    @Published var errorMessage: String?

    // Add panel state
    @Published var qualityProfiles: [QualityProfile] = []
    @Published var metadataProfiles: [MetadataProfile] = []
    @Published var rootFolders: [RootFolder] = []
    @Published var isLoadingOptions = false
    @Published var addError: String?
    @Published var isAdding = false

    private var searchTask: Task<Void, Never>?
    private var radarrClient: SearchClient?
    private var sonarrClient: SearchClient?
    private var lidarrClient: SearchClient?
    private var whisparrClient: SearchClient?
    /// Per-source `ServiceConfig` kept so `loadOptions` can key the
    /// `SearchOptionsCache` without round-tripping through the client.
    private var configs: [QueueItem.Source: ServiceConfig] = [:]

    func setup(radarrConfig: ServiceConfig, sonarrConfig: ServiceConfig,
               lidarrConfig: ServiceConfig = .empty, whisparrConfig: ServiceConfig = .empty) {
        if radarrConfig.isConfigured {
            radarrClient = SearchClient(config: radarrConfig, source: .radarr)
            configs[.radarr] = radarrConfig
        }
        if sonarrConfig.isConfigured {
            sonarrClient = SearchClient(config: sonarrConfig, source: .sonarr)
            configs[.sonarr] = sonarrConfig
        }
        if lidarrConfig.isConfigured {
            lidarrClient = SearchClient(config: lidarrConfig, source: .lidarr)
            configs[.lidarr] = lidarrConfig
        }
        if whisparrConfig.isConfigured {
            whisparrClient = SearchClient(config: whisparrConfig, source: .whisparr)
            configs[.whisparr] = whisparrConfig
        }
    }

    func onQueryChange() {
        searchTask?.cancel()
        radarrResults = []
        sonarrResults = []
        lidarrResults = []
        whisparrResults = []
        errorMessage = nil
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await search()
        }
    }

    public func reset() {
        searchTask?.cancel()
        query = ""
        radarrResults = []
        sonarrResults = []
        lidarrResults = []
        whisparrResults = []
        errorMessage = nil
    }

    private func search() async {
        isSearching = true
        defer { isSearching = false }
        async let radarr = fetchOne(client: radarrClient)
        async let sonarr = fetchOne(client: sonarrClient)
        async let lidarr = fetchOne(client: lidarrClient)
        async let whisparr = fetchOne(client: whisparrClient)
        let (rRes, sRes, lRes, wRes) = await (radarr, sonarr, lidarr, whisparr)
        radarrResults = rRes
        sonarrResults = sRes
        lidarrResults = lRes
        whisparrResults = wRes
    }

    private func fetchOne(client: SearchClient?) async -> [SearchResult] {
        guard let client else { return [] }
        do {
            async let fetchResults = client.lookup(query: query)
            async let fetchLibrary = client.fetchLibraryIds()
            let (raw, ids) = try await (fetchResults, fetchLibrary)
            return raw.filter { !ids.contains($0.id) }
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    /// Replace a TMDB-sourced "lean" SearchResult with the arr's own lookup
    /// hit so the SearchAddPanel hero card shows the full IMDB/RT/Metacritic
    /// + runtime + genre chips that the `+` path gets natively. Returns nil
    /// (caller keeps the lean version) when the arr can't enrich the row —
    /// Lidarr/Whisparr already come from their own lookups, and TMDB-TV
    /// items with no tvdbId fall back to a title match that may miss.
    func enrich(_ result: SearchResult) async -> SearchResult? {
        guard let client = client(for: result.source) else { return nil }
        let candidates: [SearchResult]
        do {
            switch result.source {
            case .radarr:
                guard result.id > 0 else { return nil }
                candidates = try await client.lookup(query: "tmdb:\(result.id)")
            case .sonarr:
                if result.id > 0 {
                    candidates = try await client.lookup(query: "tvdb:\(result.id)")
                } else {
                    // TMDB-TV ids aren't TVDB ids — fall back to title match
                    // and accept the first identical-title hit.
                    let raw = try await client.lookup(query: result.title)
                    candidates = raw.filter { $0.title.lowercased() == result.title.lowercased() }
                }
            case .lidarr, .whisparr:
                return nil
            }
        } catch {
            return nil
        }
        return candidates.first
    }

    func loadOptions(source: QueueItem.Source) async {
        let client = client(for: source)
        guard let client else { return }

        // Cache hit: paint instantly. Server-side profile/folder lists rarely
        // change; the 15-minute TTL covers the common "open SearchAddPanel
        // three times in a row" pattern without making the user wait for
        // identical results.
        let cacheKey = configs[source].map {
            SearchOptionsCache.key(source: source, config: $0)
        }
        if let key = cacheKey, let cached = SearchOptionsCache.shared.entry(for: key) {
            qualityProfiles = cached.profiles
            rootFolders = cached.folders
            metadataProfiles = cached.metadataProfiles
            return
        }

        isLoadingOptions = true
        defer { isLoadingOptions = false }
        async let profiles = client.fetchQualityProfiles()
        async let folders = client.fetchRootFolders()
        let q = (try? await profiles) ?? []
        let f = (try? await folders) ?? []
        let mp: [MetadataProfile] = source == .lidarr
            ? ((try? await client.fetchMetadataProfiles()) ?? [])
            : []
        qualityProfiles = q
        rootFolders = f
        metadataProfiles = mp
        if let key = cacheKey {
            SearchOptionsCache.shared.store(
                .init(profiles: q, folders: f, metadataProfiles: mp),
                for: key
            )
        }
    }

    func addScene(_ result: SearchResult, qualityProfileId: Int, rootFolderPath: String,
                  monitor: RadarrMonitorMode = .movieOnly) async {
        guard let client = whisparrClient else { return }
        isAdding = true; addError = nil
        defer { isAdding = false }
        do {
            try await client.addScene(result, qualityProfileId: qualityProfileId,
                                      rootFolderPath: rootFolderPath, monitor: monitor)
            whisparrResults.removeAll { $0.id == result.id }
        } catch {
            addError = error.localizedDescription
        }
    }

    func addMovie(_ result: SearchResult, qualityProfileId: Int, rootFolderPath: String,
                  monitor: RadarrMonitorMode) async {
        guard let client = radarrClient else { return }
        isAdding = true; addError = nil
        defer { isAdding = false }
        do {
            try await client.addMovie(result, qualityProfileId: qualityProfileId,
                                      rootFolderPath: rootFolderPath, monitor: monitor)
            radarrResults.removeAll { $0.id == result.id }
        } catch {
            addError = error.localizedDescription
        }
    }

    func addSeries(_ result: SearchResult, qualityProfileId: Int, rootFolderPath: String,
                   monitor: SonarrMonitorMode, seriesType: SonarrSeriesType,
                   seasonFolder: Bool) async {
        guard let client = sonarrClient else { return }
        isAdding = true; addError = nil
        defer { isAdding = false }
        do {
            try await client.addSeries(result, qualityProfileId: qualityProfileId,
                                       rootFolderPath: rootFolderPath, monitor: monitor,
                                       seriesType: seriesType, seasonFolder: seasonFolder)
            sonarrResults.removeAll { $0.id == result.id }
        } catch {
            addError = error.localizedDescription
        }
    }

    func addArtist(_ result: SearchResult, qualityProfileId: Int, metadataProfileId: Int,
                   rootFolderPath: String) async {
        guard let client = lidarrClient else { return }
        isAdding = true; addError = nil
        defer { isAdding = false }
        do {
            try await client.addArtist(result, qualityProfileId: qualityProfileId,
                                       metadataProfileId: metadataProfileId,
                                       rootFolderPath: rootFolderPath)
            lidarrResults.removeAll { $0.id == result.id }
        } catch {
            addError = error.localizedDescription
        }
    }

    private func client(for source: QueueItem.Source) -> SearchClient? {
        switch source {
        case .radarr: return radarrClient
        case .sonarr: return sonarrClient
        case .lidarr: return lidarrClient
        case .whisparr: return whisparrClient
        }
    }
}
