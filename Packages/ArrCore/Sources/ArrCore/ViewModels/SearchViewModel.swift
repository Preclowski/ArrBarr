import Foundation
import Observation

@MainActor
@Observable
public final class SearchViewModel {
    var query = ""
    var radarrResults: [SearchResult] = []
    var sonarrResults: [SearchResult] = []
    var lidarrResults: [SearchResult] = []
    var whisparrResults: [SearchResult] = []
    /// Single sticky flag — true from the first keystroke until the
    /// final fetch (the one matching the latest query) returns. While
    /// the user keeps typing, in-flight fetches get superseded and
    /// their results are dropped via the generation check below, so
    /// this stays `true` continuously and the view shows ONE stable
    /// loader instead of flickering between partial results and
    /// spinner per keystroke.
    var isSearching = false
    var errorMessage: String?
    /// Parsed form of `query` — `.ref(_:)` when the user typed an
    /// external-id prefix (`tmdb:N`, `imdb:ttN`, …), `.text(_)`
    /// otherwise. Owned by the VM so the sorter and the per-source
    /// clients all see the same interpretation; parsed once per
    /// `onQueryChange`.
    private(set) var parsedInput: SearchInput = .text("")

    /// Bumped on every `onQueryChange`. The async search task carries
    /// the generation it was launched with; only the task whose
    /// generation still matches the current value is allowed to
    /// commit results + clear `isSearching`. Stale tasks return
    /// silently. Replaces the previous "set loading flag, cancel task,
    /// blink between states" pattern.
    private var searchGeneration: Int = 0

    // Add panel state
    var qualityProfiles: [QualityProfile] = []
    var metadataProfiles: [MetadataProfile] = []
    var rootFolders: [RootFolder] = []
    var isLoadingOptions = false
    var addError: String?
    var isAdding = false

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
        errorMessage = nil
        searchGeneration += 1
        let myGen = searchGeneration
        parsedInput = QueryParser.parse(query)

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            // Empty query: kill the loader, clear results. Anything
            // mid-flight that hasn't returned will be ignored when it
            // does (its generation no longer matches).
            isSearching = false
            radarrResults = []
            sonarrResults = []
            lidarrResults = []
            whisparrResults = []
            return
        }

        // Sticky loader: set true here, leave it alone for the
        // duration of typing. Stale fetches return silently and
        // don't touch this flag. Only the matching-generation
        // fetch will clear it (in `search`).
        isSearching = true

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await search(generation: myGen)
        }
    }

    public func reset() {
        searchTask?.cancel()
        query = ""
        radarrResults = []
        sonarrResults = []
        lidarrResults = []
        whisparrResults = []
        isSearching = false
        errorMessage = nil
    }

    private func search(generation: Int) async {
        async let r = fetchOne(client: radarrClient)
        async let s = fetchOne(client: sonarrClient)
        async let l = fetchOne(client: lidarrClient)
        async let w = fetchOne(client: whisparrClient)
        let (rRes, sRes, lRes, wRes) = await (r, s, l, w)

        // Generation gate. If the user kept typing while we were
        // fetching, `onQueryChange` bumped `searchGeneration` past
        // ours — our results are stale, drop them on the floor and
        // let the newer task win. Critically we DO NOT flip
        // `isSearching` to false here either, so the loader stays
        // continuous through the keystroke storm.
        guard searchGeneration == generation else { return }
        radarrResults = rRes
        sonarrResults = sRes
        lidarrResults = lRes
        whisparrResults = wRes
        isSearching = false
    }

    private func fetchOne(client: SearchClient?) async -> [SearchResult] {
        guard let client else { return [] }
        do {
            async let fetchResults = client.lookup(input: parsedInput)
            async let fetchLibrary = client.fetchLibraryArrIdMap()
            let (raw, map) = try await (fetchResults, fetchLibrary)
            // Used to be `raw.filter { !ids.contains($0.id) }` — hiding
            // library hits entirely. The "Search" tab now wants both
            // kinds in one list, so we keep them all and stamp
            // `inLibraryArrId` on the ones we own. The row + selection
            // routing diverge based on that field: in-library rows show
            // an "In library" pill + drill into DetailView; addable
            // rows keep the existing + flow into SearchAddPanel.
            return raw.map { result in
                if let arrId = map[result.id] {
                    return result.withInLibraryArrId(arrId)
                }
                return result
            }
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
        guard StoreManager.shared.requirePro(.addTitle) else { return }
        guard let client = whisparrClient else { return }
        isAdding = true; addError = nil
        defer { isAdding = false }
        do {
            let arrId = try await client.addScene(result, qualityProfileId: qualityProfileId,
                                                  rootFolderPath: rootFolderPath, monitor: monitor)
            whisparrResults.removeAll { $0.id == result.id }
            navigateToAdded(result, source: .whisparr, arrId: arrId)
        } catch {
            addError = error.localizedDescription
        }
    }

    func addMovie(_ result: SearchResult, qualityProfileId: Int, rootFolderPath: String,
                  monitor: RadarrMonitorMode) async {
        guard StoreManager.shared.requirePro(.addTitle) else { return }
        guard let client = radarrClient else { return }
        isAdding = true; addError = nil
        defer { isAdding = false }
        do {
            let arrId = try await client.addMovie(result, qualityProfileId: qualityProfileId,
                                                 rootFolderPath: rootFolderPath, monitor: monitor)
            radarrResults.removeAll { $0.id == result.id }
            navigateToAdded(result, source: .radarr, arrId: arrId)
        } catch {
            addError = error.localizedDescription
        }
    }

    func addSeries(_ result: SearchResult, qualityProfileId: Int, rootFolderPath: String,
                   monitor: SonarrMonitorMode, seriesType: SonarrSeriesType,
                   seasonFolder: Bool) async {
        guard StoreManager.shared.requirePro(.addTitle) else { return }
        guard let client = sonarrClient else { return }
        isAdding = true; addError = nil
        defer { isAdding = false }
        do {
            let arrId = try await client.addSeries(result, qualityProfileId: qualityProfileId,
                                                  rootFolderPath: rootFolderPath, monitor: monitor,
                                                  seriesType: seriesType, seasonFolder: seasonFolder)
            sonarrResults.removeAll { $0.id == result.id }
            navigateToAdded(result, source: .sonarr, arrId: arrId)
        } catch {
            addError = error.localizedDescription
        }
    }

    func addArtist(_ result: SearchResult, qualityProfileId: Int, metadataProfileId: Int,
                   rootFolderPath: String) async {
        guard StoreManager.shared.requirePro(.addTitle) else { return }
        guard let client = lidarrClient else { return }
        isAdding = true; addError = nil
        defer { isAdding = false }
        do {
            let arrId = try await client.addArtist(result, qualityProfileId: qualityProfileId,
                                                  metadataProfileId: metadataProfileId,
                                                  rootFolderPath: rootFolderPath)
            lidarrResults.removeAll { $0.id == result.id }
            navigateToAdded(result, source: .lidarr, arrId: arrId)
        } catch {
            addError = error.localizedDescription
        }
    }

    /// After a successful add, drop the user on the freshly-added item's
    /// detail card. Uses the arr-internal id returned by the POST (the only
    /// thing `DetailView` needs to refetch the full record). No-op when the
    /// arr didn't hand back an id (demo mode / unparseable response) — the
    /// add still succeeded, we just can't deep-link to it.
    private func navigateToAdded(_ result: SearchResult, source: QueueItem.Source, arrId: Int?) {
        guard let arrId else { return }
        DetailRequest.post(DetailRequest.syntheticItem(
            source: source,
            entityId: arrId,
            title: result.title,
            posterURL: result.posterURL,
            posterRequiresAuth: false
        ))
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
