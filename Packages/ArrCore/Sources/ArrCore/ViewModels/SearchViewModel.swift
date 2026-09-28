import os
import Foundation
import Observation
import MediaKit

@Observable
public final class SearchViewModel {
    /// Every search field on every surface binds straight to this; `didSet` is the trigger.
    var query = "" {
        didSet {
            // A pasted multi-line clipboard would grow the capsule a second row and
            // carry a character no arr lookup can match.
            let flattened = Self.singleLine(query)
            if flattened != query {
                query = flattened   // re-enters once, then settles
                return
            }
            if query != oldValue { onQueryChange() }
        }
    }

    /// Nothing is trimmed: a trailing space while typing two words has to survive.
    private static func singleLine(_ raw: String) -> String {
        guard raw.contains(where: \.isNewline) else { return raw }
        return raw
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
    }

    var isActive: Bool { !trimmedQuery.isEmpty }

    /// The one trimming rule: a pasted line ending must not look empty while a lookup runs.
    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Exists only so "an empty query resets the scope exactly once" is testable.
    @ObservationIgnored private(set) var queryChangePasses = 0

    /// Keeps `scope.didSet` from running a second pass over the same empty query.
    @ObservationIgnored private var isResettingScope = false

    var radarrResults: [SearchResult] = []
    var sonarrResults: [SearchResult] = []
    var lidarrResults: [SearchResult] = []
    var whisparrResults: [SearchResult] = []
    var peopleResults: [TMDBPerson] = []
    var starring: StarringSection?

    public struct StarringSection: Identifiable, Equatable {
        public let person: TMDBPerson
        public let titles: [SearchResult]
        /// A full-name query: the person is the answer, so the section renders above
        /// the titles, and `titles` may be empty.
        public var isPrimary: Bool = false
        public var id: Int { person.id }
    }
    /// Stays true from the first keystroke until the latest query's fetch returns,
    /// so typing shows one stable loader instead of flickering per keystroke.
    var isSearching = false
    var errorMessage: String?
    private(set) var parsedInput: SearchInput = .text("")

    /// Only the task whose generation still matches may commit results and clear `isSearching`.
    private var searchGeneration: Int = 0

    /// Tells a refinement (plain typing) from a brand-new term; see `onQueryChange`.
    private var previousQuery = ""

    /// With rows up, a bottom spinner sits below the fold, so loading rides on the rows.
    var hasResults: Bool {
        !radarrResults.isEmpty || !sonarrResults.isEmpty
            || !lidarrResults.isEmpty || !whisparrResults.isEmpty
            || !peopleResults.isEmpty || starring != nil
    }

    var qualityProfiles: [ArrQualityProfile] = []
    var metadataProfiles: [ArrMetadataProfile] = []
    var rootFolders: [String] = []
    var isLoadingOptions = false
    var addError: String?
    var isAdding = false

    /// Narrows which backends a search hits; reset to `all` when the search surface closes.
    var scope: SearchScope = .all {
        didSet { if scope != oldValue, !isResettingScope { onQueryChange() } }
    }

    /// Match the user's own library instead of the arrs and TMDB. Sticky for the session.
    var libraryOnly = false {
        didSet { if libraryOnly != oldValue { onQueryChange() } }
    }

    @ObservationIgnored var library: LibraryViewModel?

    private var searchTask: Task<Void, Never>?
    /// Read on every use so a server edited in Settings is the one the next search asks.
    @ObservationIgnored private var settings: () -> (configs: [QueueItem.Source: ServiceConfig], tmdbApiKey: String) = { ([:], "") }
    private var configs: [QueueItem.Source: ServiceConfig] { settings().configs }
    /// Empty ⇒ people search is skipped.
    private var tmdbApiKey: String { settings().tmdbApiKey }

    func setup(radarrConfig: ServiceConfig, sonarrConfig: ServiceConfig,
               lidarrConfig: ServiceConfig = .empty, whisparrConfig: ServiceConfig = .empty,
               tmdbApiKey: String = "") {
        let configs = Self.configured([.radarr: radarrConfig, .sonarr: sonarrConfig, .lidarr: lidarrConfig, .whisparr: whisparrConfig])
        settings = { (configs, tmdbApiKey) }
    }

    func setup(store: ConfigStore) {
        settings = { [weak store] in
            guard let store else { return ([:], "") }
            return (Self.configured([.radarr: store.radarr, .sonarr: store.sonarr, .lidarr: store.lidarr, .whisparr: store.whisparr]),
                    store.tmdbApiKey)
        }
    }

    private static func configured(_ all: [QueueItem.Source: ServiceConfig]) -> [QueueItem.Source: ServiceConfig] {
        all.filter { $0.value.isConfigured }
    }

    func onQueryChange() {
        queryChangePasses += 1
        searchTask?.cancel()
        errorMessage = nil
        searchGeneration += 1
        let myGen = searchGeneration
        parsedInput = QueryParser.parse(query)

        let trimmed = trimmedQuery
        let previous = previousQuery
        previousQuery = trimmed
        guard !trimmed.isEmpty else {
            // A scope that outlives its query reads as a bug; `libraryOnly` is deliberately sticky.
            if scope != .all {
                isResettingScope = true
                scope = .all
                isResettingScope = false
            }
            isSearching = false
            clearResults()
            return
        }

        // Libraries in memory: a filter, not a fetch, so no debounce and no loader.
        if libraryOnly, let found = libraryMatches(scope: effectiveScope) {
            applyLibraryResults(found)
            return
        }

        isSearching = true

        // A new term drops the old rows, or the second search looks identical to the settled
        // first one. Refinements keep theirs so typing never flickers list ↔ spinner.
        if !Self.isRefinement(previous, trimmed) { clearResults() }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await search(generation: myGen)
        }
    }

    private func clearResults() {
        radarrResults = []
        sonarrResults = []
        lidarrResults = []
        whisparrResults = []
        peopleResults = []
        starring = nil
    }

    /// A prefix forces people-only mode regardless of the scope chip.
    private var peoplePrefixTerm: String? {
        let t = query.trimmingCharacters(in: .whitespaces)
        let lower = t.lowercased()
        for p in ["person:", "actor:", "osoba:", "aktor:"] where lower.hasPrefix(p) {
            return String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private var effectiveScope: SearchScope {
        peoplePrefixTerm != nil ? .people : scope
    }

    private static func isRefinement(_ old: String, _ new: String) -> Bool {
        guard !old.isEmpty, !new.isEmpty else { return true }
        let a = old.lowercased(), b = new.lowercased()
        return a.hasPrefix(b) || b.hasPrefix(a)
    }

    private func search(generation: Int) async {
        let effective = effectiveScope
        if libraryOnly {
            let found = await searchLibrary(scope: effective)
            guard searchGeneration == generation else { return }
            applyLibraryResults(found)
            return
        }
        async let r = fetchOne(client: effective.allows(.radarr) ? client(for: .radarr) : nil, generation: generation)
        async let s = fetchOne(client: effective.allows(.sonarr) ? client(for: .sonarr) : nil, generation: generation)
        async let l = fetchOne(client: effective.allows(.lidarr) ? client(for: .lidarr) : nil, generation: generation)
        async let w = fetchOne(client: effective.allows(.whisparr) ? client(for: .whisparr) : nil, generation: generation)
        async let p = fetchPeople(scope: effective, generation: generation)
        let (rRes, sRes, lRes, wRes, pRes) = await (r, s, l, w, p)

        // Superseded: drop the results but leave `isSearching` on, so the loader stays continuous.
        guard searchGeneration == generation else { return }
        radarrResults = rRes
        sonarrResults = sRes
        // Albums only in the Music scope: in `all`, soundtracks and self-titled albums
        // exact-match movie/series queries and push the real titles down.
        lidarrResults = effective == .album ? lRes : lRes.filter { !$0.isLidarrAlbum }
        whisparrResults = wRes
        peopleResults = pRes.rows
        starring = pRes.starring
        isSearching = false
    }

    /// Synchronous and cheap, so it runs per keystroke. `nil` when an in-scope
    /// library hasn't loaded yet.
    private func libraryMatches(scope: SearchScope) -> [QueueItem.Source: [SearchResult]]? {
        guard let library else { return [:] }
        let term = query.trimmingCharacters(in: .whitespaces)
        var out: [QueueItem.Source: [SearchResult]] = [:]
        for source in QueueItem.Source.allCases where scope.allows(source) && configs[source] != nil {
            guard let entries = library.entries[source] else { return nil }
            out[source] = TitleMatch.indexedFilter(entries, query: term, index: \.searchIndex)
                .map(SearchResult.init(libraryEntry:))
        }
        return out
    }

    private func searchLibrary(scope: SearchScope) async -> [QueueItem.Source: [SearchResult]] {
        guard let library else { return [:] }
        for source in QueueItem.Source.allCases where scope.allows(source) {
            guard let config = configs[source] else { continue }
            await library.loadIfNeeded(source: source, config: config)
        }
        return libraryMatches(scope: scope) ?? [:]
    }

    private func applyLibraryResults(_ found: [QueueItem.Source: [SearchResult]]) {
        radarrResults = found[.radarr] ?? []
        sonarrResults = found[.sonarr] ?? []
        lidarrResults = found[.lidarr] ?? []
        whisparrResults = found[.whisparr] ?? []
        peopleResults = []
        starring = nil
        isSearching = false
    }

    private func fetchPeople(scope: SearchScope, generation: Int) async -> (rows: [TMDBPerson], starring: StarringSection?) {
        guard scope.searchesPeople, !tmdbApiKey.isEmpty else { return ([], nil) }
        let term = peoplePrefixTerm ?? query.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else { return ([], nil) }
        let raw: [TMDBPerson]
        if DemoMode.isActive {
            raw = DemoMocks.searchPeople(query: term)
        } else {
            do { raw = try await ServiceHandles.tmdb(apiKey: tmdbApiKey).searchPerson(query: term) } catch {
                // In the people scope the list is the whole screen; elsewhere it is only the Starring extra.
                if scope == .people, searchGeneration == generation { errorMessage = error.userFacingMessage }
                return ([], nil)
            }
        }
        let ranked = PersonRelevance.rank(raw, query: term)
        if scope == .people {
            return (ranked, nil)
        }
        // A full name always earns a section; a single token must clear the popularity floor.
        guard let top = ranked.first else { return ([], nil) }
        let isFullName = PersonRelevance.isFullNameMatch(top, query: term)
        guard isFullName || PersonRelevance.isConfidentHeadliner(top, query: term) else {
            return ([], nil)
        }
        // Series as the fallback: a TV-only actor has a thin-to-empty movie list.
        var titles = (await Logger.extras.attempt("starring movies") { try await People.movieFilmography(
            personId: top.id, tmdbKey: tmdbApiKey, radarrConfig: configs[.radarr] ?? .empty) }) ?? []
        if titles.isEmpty {
            titles = (await Logger.extras.attempt("starring series") { try await People.seriesFilmography(
                personId: top.id, tmdbKey: tmdbApiKey, sonarrConfig: configs[.sonarr] ?? .empty) }) ?? []
        }
        guard isFullName || !titles.isEmpty else { return ([], nil) }
        return ([], StarringSection(person: top, titles: Array(titles.prefix(8)),
                                    isPrimary: isFullName))
    }

    /// An error from a fetch the user already typed past must not paint over its replacement.
    private func fetchOne(client: SearchClient?, generation: Int) async -> [SearchResult] {
        guard let client else { return [] }
        do {
            // Unstructured on purpose: the shared library fetch isn't cancelled with this search,
            // and as an `async let` it held a failed lookup's error until the library loaded.
            let libraryFetch = Task { try await client.fetchLibraryOwnership() }
            defer { libraryFetch.cancel() }
            let raw = try await client.lookup(input: parsedInput)
            let map = try await libraryFetch.value
            return raw.map { result in
                map[result.externalId].map(result.withLibraryOwnership) ?? result
            }
        } catch {
            // A superseded keystroke cancelled this lookup.
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                return []
            }
            if searchGeneration == generation { errorMessage = error.userFacingMessage }
            return []
        }
    }

    /// Swap a lean TMDB row for the arr's own lookup hit (full ratings and chips).
    /// Id-based only, nil otherwise; keeps the row's artwork so a swap never looks like a wrong match.
    func enrich(_ result: SearchResult) async -> SearchResult? {
        switch result.source {
        case .radarr:
            guard let client = client(for: result.source), result.externalId > 0 else { return nil }
            return (await Logger.extras.attempt("enrich by tmdb") { try await client.lookup(query: "tmdb:\(result.externalId)") })?.first?
                .withArtwork(from: result)
        case .sonarr:
            if result.externalId > 0 {
                guard let client = client(for: result.source) else { return nil }
                return (await Logger.extras.attempt("enrich by tvdb") { try await client.lookup(query: "tvdb:\(result.externalId)") })?.first?
                    .withArtwork(from: result)
            }
            // A TMDB tv id is not a tvdbId; resolve by id, never by name.
            guard let tmdbTVId = result.tmdbTVId else { return nil }
            return await SeriesIdentityResolver.sonarrRecord(
                tmdbTVId: tmdbTVId, sonarrConfig: configs[.sonarr] ?? .empty,
                tmdbKey: tmdbApiKey)?.withArtwork(from: result)
        case .lidarr, .whisparr:
            return nil
        }
    }

    func loadOptions(source: QueueItem.Source) async {
        let client = client(for: source)
        guard let client else { return }

        isLoadingOptions = true
        defer { isLoadingOptions = false }
        do {
            async let profiles = client.fetchQualityProfiles()
            async let folders = client.fetchRootFolders()
            async let metadata = source == .lidarr ? client.fetchMetadataProfiles() : []
            (qualityProfiles, rootFolders, metadataProfiles) = try await (profiles, folders, metadata)
        } catch {
            // Empty pickers would read as "this arr has no profiles"; the reason is what the user can act on.
            addError = error.userFacingMessage
        }
    }

    func addScene(_ result: SearchResult, qualityProfileId: Int, rootFolderPath: String,
                  monitor: RadarrMonitorMode = .movieOnly, searchOnAdd: Bool) async {
        guard StoreManager.shared.requirePro(.addTitle) else { return }
        guard let client = client(for: .whisparr) else { return }
        isAdding = true; addError = nil
        defer { isAdding = false }
        do {
            let arrId = try await client.addScene(result, qualityProfileId: qualityProfileId,
                                                  rootFolderPath: rootFolderPath, monitor: monitor,
                                                  searchOnAdd: searchOnAdd)
            whisparrResults.removeAll { $0.id == result.id }
            navigateToAdded(result, source: .whisparr, arrId: arrId)
        } catch {
            addError = error.localizedDescription
        }
    }

    func addMovie(_ result: SearchResult, qualityProfileId: Int, rootFolderPath: String,
                  monitor: RadarrMonitorMode, searchOnAdd: Bool) async {
        guard StoreManager.shared.requirePro(.addTitle) else { return }
        guard let client = client(for: .radarr) else { return }
        isAdding = true; addError = nil
        defer { isAdding = false }
        do {
            let arrId = try await client.addMovie(result, qualityProfileId: qualityProfileId,
                                                 rootFolderPath: rootFolderPath, monitor: monitor,
                                                 searchOnAdd: searchOnAdd)
            radarrResults.removeAll { $0.id == result.id }
            navigateToAdded(result, source: .radarr, arrId: arrId)
        } catch {
            addError = error.localizedDescription
        }
    }

    func addSeries(_ result: SearchResult, qualityProfileId: Int, rootFolderPath: String,
                   monitor: SonarrMonitorMode, seriesType: SonarrSeriesType,
                   seasonFolder: Bool, searchOnAdd: Bool) async {
        guard StoreManager.shared.requirePro(.addTitle) else { return }
        guard let client = client(for: .sonarr) else { return }
        isAdding = true; addError = nil
        defer { isAdding = false }
        // Sonarr posts against a tvdbId; the client refuses an unresolved row rather than guess by title.
        var result = result
        if result.externalId <= 0, let tmdbTVId = result.tmdbTVId,
           let tvdbId = await SeriesIdentityResolver.tvdbId(
               tmdbTVId: tmdbTVId, sonarrConfig: configs[.sonarr] ?? .empty,
               tmdbKey: tmdbApiKey) {
            result = result.withTVDBId(tvdbId)
        }
        do {
            let arrId = try await client.addSeries(result, qualityProfileId: qualityProfileId,
                                                  rootFolderPath: rootFolderPath, monitor: monitor,
                                                  seriesType: seriesType, seasonFolder: seasonFolder,
                                                  searchOnAdd: searchOnAdd)
            sonarrResults.removeAll { $0.id == result.id }
            navigateToAdded(result, source: .sonarr, arrId: arrId)
        } catch {
            addError = error.localizedDescription
        }
    }

    func addArtist(_ result: SearchResult, qualityProfileId: Int, metadataProfileId: Int,
                   rootFolderPath: String, monitor: LidarrMonitorMode = .all,
                   searchOnAdd: Bool) async {
        guard StoreManager.shared.requirePro(.addTitle) else { return }
        guard let client = client(for: .lidarr) else { return }
        isAdding = true; addError = nil
        defer { isAdding = false }
        do {
            let arrId = try await client.addArtist(result, qualityProfileId: qualityProfileId,
                                                  metadataProfileId: metadataProfileId,
                                                  rootFolderPath: rootFolderPath,
                                                  monitor: monitor.rawValue,
                                                  searchOnAdd: searchOnAdd)
            lidarrResults.removeAll { $0.id == result.id }
            navigateToAdded(result, source: .lidarr, arrId: arrId)
        } catch {
            addError = error.localizedDescription
        }
    }

    func addAlbum(_ result: SearchResult, qualityProfileId: Int, metadataProfileId: Int,
                  rootFolderPath: String, searchOnAdd: Bool) async {
        guard StoreManager.shared.requirePro(.addTitle) else { return }
        guard let client = client(for: .lidarr) else { return }
        isAdding = true; addError = nil
        defer { isAdding = false }
        do {
            let arrId = try await client.addAlbum(result, qualityProfileId: qualityProfileId,
                                                  metadataProfileId: metadataProfileId,
                                                  rootFolderPath: rootFolderPath,
                                                  searchOnAdd: searchOnAdd)
            lidarrResults.removeAll { $0.id == result.id }
            guard let arrId else { return }
            DetailRequest.open(source: .lidarr, arrId: arrId, title: result.title,
                               posterURL: result.posterURL, isLidarrAlbum: true)
        } catch {
            addError = error.localizedDescription
        }
    }

    /// No-op when the arr returned no id (demo mode, unparseable response); the add still succeeded.
    private func navigateToAdded(_ result: SearchResult, source: QueueItem.Source, arrId: Int?) {
        guard let arrId else { return }
        DetailRequest.open(source: source, arrId: arrId, title: result.title,
                           posterURL: result.posterURL, posterRequiresAuth: false)
    }

    private func client(for source: QueueItem.Source) -> SearchClient? {
        configs[source].map { ServiceHandles.search(source, config: $0) }
    }
}
