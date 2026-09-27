import Foundation
import Observation
import MediaKit

@Observable
public final class SearchViewModel {
    /// The one query. Every field on every surface binds straight to this, so
    /// there is nothing to mirror and nothing to keep in sync — the `didSet`
    /// IS the trigger that three separate `onChange` sites used to be.
    var query = "" {
        didSet {
            // A pasted multi-line clipboard (a title copied out of a list, a
            // log line) would otherwise put a line break INSIDE the field: the
            // capsule grows a second row and the query carries a character no
            // *arr lookup can match. Collapse line endings to spaces at the one
            // place every surface writes through.
            let flattened = Self.singleLine(query)
            if flattened != query {
                query = flattened   // re-enters once, then settles
                return
            }
            if query != oldValue { onQueryChange() }
        }
    }

    /// Line endings → single spaces. Nothing is trimmed: a trailing space
    /// while typing two words has to survive.
    private static func singleLine(_ raw: String) -> String {
        guard raw.contains(where: \.isNewline) else { return raw }
        return raw
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
    }

    /// True while a live query owns the surface. One definition, used by the
    /// tab-bar hide, the focus logic, the takeover host and both tabs.
    var isActive: Bool { !trimmedQuery.isEmpty }

    /// The query as every decision about it must read it. One definition
    /// because two disagreed: `isActive` trimmed newlines and `onQueryChange`
    /// did not, so a pasted line ending looked empty on screen while a lookup
    /// ran behind it.
    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How many times `onQueryChange` has run. Not UI state — it exists so the
    /// "an empty query resets the scope EXACTLY once" invariant is testable;
    /// the re-entry it guards against is invisible from the outside otherwise.
    @ObservationIgnored private(set) var queryChangePasses = 0

    /// Set while `onQueryChange` resets the scope itself, so `scope`'s own
    /// `didSet` doesn't bounce back in and run a second pass over the same
    /// (empty) query.
    @ObservationIgnored private var isResettingScope = false

    var radarrResults: [SearchResult] = []
    var sonarrResults: [SearchResult] = []
    var lidarrResults: [SearchResult] = []
    var whisparrResults: [SearchResult] = []
    /// People-scope (or `person:` prefix) results — ranked person rows that
    /// open the person view. Empty in every other mode.
    var peopleResults: [TMDBPerson] = []
    /// All-scope "Starring X" section: a confident person match plus their top
    /// filmography, rendered under the title results. nil when no strong match.
    var starring: StarringSection?

    /// A confident person match and their top titles for the all-scope
    /// "Starring X" section.
    public struct StarringSection: Identifiable, Equatable {
        public let person: TMDBPerson
        public let titles: [SearchResult]
        /// True when the query was a full name ("rhea seehorn") — the person is
        /// then the *answer*, not a footnote, so the host renders this section
        /// above the title results instead of under them. `titles` may be empty
        /// in this mode; the header row alone still routes to the person view.
        public var isPrimary: Bool = false
        public var id: Int { person.id }
    }
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

    /// Trimmed form of the query the previous `onQueryChange` saw. Lets us
    /// tell a refinement (`matr` → `matri`, plain typing/backspacing) from a
    /// brand-new term (`matrix` → `inception` — select-all-and-retype, or a
    /// paste). See `onQueryChange` for why that distinction matters.
    private var previousQuery = ""

    /// True while any arr lookup rows are on screen. Callers use it to place
    /// the loader: with rows up, a bottom-of-list spinner sits below the fold
    /// and is worthless — the loading state has to ride on the rows instead.
    var hasResults: Bool {
        !radarrResults.isEmpty || !sonarrResults.isEmpty
            || !lidarrResults.isEmpty || !whisparrResults.isEmpty
            || !peopleResults.isEmpty || starring != nil
    }

    // Add panel state
    var qualityProfiles: [ArrQualityProfile] = []
    var metadataProfiles: [ArrMetadataProfile] = []
    var rootFolders: [String] = []
    var isLoadingOptions = false
    var addError: String?
    var isAdding = false

    /// Which backends a search hits. `all` fires every configured arr (plus
    /// TMDB people); the others narrow to one so an album search never pings
    /// Radarr and a people search only hits TMDB. Set from the search field's
    /// scope chip; reset to `all` when the search surface closes.
    var scope: SearchScope = .all {
        didSet { if scope != oldValue, !isResettingScope { onQueryChange() } }
    }

    /// Library-only search: match the user's own library — the Library tab's
    /// alias-aware index — instead of asking the arrs and TMDB. Combines with
    /// `scope`; people are skipped. Kept for the session, unlike `scope`.
    var libraryOnly = false {
        didSet { if libraryOnly != oldValue { onQueryChange() } }
    }

    /// The Library tab's model: the cache library-only search reads. Set by the
    /// surface that owns both, so search and the tab never hold separate copies.
    @ObservationIgnored var library: LibraryViewModel?

    private var searchTask: Task<Void, Never>?
    private var radarrClient: SearchClient?
    private var sonarrClient: SearchClient?
    private var lidarrClient: SearchClient?
    private var whisparrClient: SearchClient?
    /// Per-source `ServiceConfig` kept so `loadOptions` can key the
    /// `SearchOptionsCache` without round-tripping through the client.
    private var configs: [QueueItem.Source: ServiceConfig] = [:]
    /// TMDB key for the person lookup (people scope / `person:` prefix / the
    /// all-scope "Starring X" section). Empty ⇒ people search is skipped.
    private var tmdbApiKey = ""

    func setup(radarrConfig: ServiceConfig, sonarrConfig: ServiceConfig,
               lidarrConfig: ServiceConfig = .empty, whisparrConfig: ServiceConfig = .empty,
               tmdbApiKey: String = "") {
        self.tmdbApiKey = tmdbApiKey
        if radarrConfig.isConfigured {
            radarrClient = ServiceHandles.search(.radarr, config: radarrConfig)
            configs[.radarr] = radarrConfig
        }
        if sonarrConfig.isConfigured {
            sonarrClient = ServiceHandles.search(.sonarr, config: sonarrConfig)
            configs[.sonarr] = sonarrConfig
        }
        if lidarrConfig.isConfigured {
            lidarrClient = ServiceHandles.search(.lidarr, config: lidarrConfig)
            configs[.lidarr] = lidarrConfig
        }
        if whisparrConfig.isConfigured {
            whisparrClient = ServiceHandles.search(.whisparr, config: whisparrConfig)
            configs[.whisparr] = whisparrConfig
        }
    }

    /// `setup` from the app's configuration — the one reading of what the
    /// search clients are built from, so macOS and iOS cannot drift.
    func setup(store: ConfigStore) {
        setup(radarrConfig: store.radarr, sonarrConfig: store.sonarr,
              lidarrConfig: store.lidarr, whisparrConfig: store.whisparr,
              tmdbApiKey: store.tmdbApiKey)
    }

    /// Identity of everything `setup` reads. The hosts observe this and re-run
    /// `setup` when it moves: the clients are built once from the config, so
    /// without it a server edited in Settings leaves every search talking to
    /// the old one for the rest of the session.
    static func configSignature(store: ConfigStore) -> String {
        [
            store.radarr.baseURL, store.radarr.apiKey, "\(store.radarr.enabled)",
            store.sonarr.baseURL, store.sonarr.apiKey, "\(store.sonarr.enabled)",
            store.lidarr.baseURL, store.lidarr.apiKey, "\(store.lidarr.enabled)",
            store.whisparr.baseURL, store.whisparr.apiKey, "\(store.whisparr.enabled)",
            store.tmdbApiKey,
        ].joined(separator: "|")
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
            // Ending the search drops any narrow scope: a scope that outlives
            // the query it was chosen for reads as a bug on the next search.
            // `libraryOnly` is deliberately sticky and stays.
            if scope != .all {
                isResettingScope = true
                scope = .all
                isResettingScope = false
            }
            // Empty query: kill the loader, clear results. Anything
            // mid-flight that hasn't returned will be ignored when it
            // does (its generation no longer matches).
            isSearching = false
            clearResults()
            return
        }

        // Library-only with the libraries already in memory is a filter, not a
        // fetch: answer on this keystroke — no debounce, no loader. The bumped
        // generation above already retires anything still in flight.
        if libraryOnly, let found = libraryMatches(scope: effectiveScope) {
            applyLibraryResults(found)
            return
        }

        // Sticky loader: set true here, leave it alone for the
        // duration of typing. Stale fetches return silently and
        // don't touch this flag. Only the matching-generation
        // fetch will clear it (in `search`).
        isSearching = true

        // A brand-new term invalidates whatever is on screen: those rows
        // answer a question the user has stopped asking, and leaving them
        // up means the second search looks *identical* to the settled
        // first one — no visible loading state at all. Drop them so the
        // loader owns the surface. Refinements keep their rows (one is a
        // prefix of the other), which is what the sticky-loader design
        // above is protecting: typing must never flicker list ↔ spinner.
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

    /// `person:`/`actor:` (and PL `osoba:`/`aktor:`) prefix → the bare name to
    /// search, or nil when there's no prefix. A prefix forces people-only mode
    /// regardless of the scope chip.
    private var peoplePrefixTerm: String? {
        let t = query.trimmingCharacters(in: .whitespaces)
        let lower = t.lowercased()
        for p in ["person:", "actor:", "osoba:", "aktor:"] where lower.hasPrefix(p) {
            return String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The scope actually applied — a `person:` prefix overrides the chip.
    private var effectiveScope: SearchScope {
        peoplePrefixTerm != nil ? .people : scope
    }

    /// True when `new` merely narrows or widens `old` — one is a prefix of
    /// the other, which is all that plain typing or backspacing can produce.
    /// Anything else (select-all-and-retype, paste, a second word swapped in
    /// front) is treated as a fresh search.
    private static func isRefinement(_ old: String, _ new: String) -> Bool {
        guard !old.isEmpty, !new.isEmpty else { return true }
        let a = old.lowercased(), b = new.lowercased()
        return a.hasPrefix(b) || b.hasPrefix(a)
    }

    private func search(generation: Int) async {
        let effective = effectiveScope
        if libraryOnly {
            // Only reached when a library wasn't in memory yet — see
            // `onQueryChange`. Same generation gate as the lookup path below.
            let found = await searchLibrary(scope: effective)
            guard searchGeneration == generation else { return }
            applyLibraryResults(found)
            return
        }
        // Scope gates which arr clients fire — a nil client short-circuits to
        // [] in `fetchOne`, so an out-of-scope source simply doesn't run.
        async let r = fetchOne(client: effective.allows(.radarr) ? radarrClient : nil, generation: generation)
        async let s = fetchOne(client: effective.allows(.sonarr) ? sonarrClient : nil, generation: generation)
        async let l = fetchOne(client: effective.allows(.lidarr) ? lidarrClient : nil, generation: generation)
        async let w = fetchOne(client: effective.allows(.whisparr) ? whisparrClient : nil, generation: generation)
        async let p = fetchPeople(scope: effective)
        let (rRes, sRes, lRes, wRes, pRes) = await (r, s, l, w, p)

        // Generation gate. If the user kept typing while we were
        // fetching, `onQueryChange` bumped `searchGeneration` past
        // ours — our results are stale, drop them on the floor and
        // let the newer task win. Critically we DO NOT flip
        // `isSearching` to false here either, so the loader stays
        // continuous through the keystroke storm.
        guard searchGeneration == generation else { return }
        radarrResults = rRes
        sonarrResults = sRes
        // Albums join the list only in the dedicated Music scope. In `all`,
        // soundtracks and self-titled albums exact-match movie/series
        // queries (same 10k tier) and shove the actual titles down — the
        // broad scope keeps its historical artists-only behaviour.
        lidarrResults = effective == .album ? lRes : lRes.filter { !$0.isLidarrAlbum }
        whisparrResults = wRes
        peopleResults = pRes.rows
        starring = pRes.starring
        isSearching = false
    }

    /// Library-only matches straight from memory: each in-scope arr's library
    /// filtered through the same `searchIndex` the Library tab's field uses —
    /// accents folded, alternate and translated titles included. Synchronous
    /// and cheap, so it runs per keystroke. `nil` when an in-scope library
    /// hasn't loaded yet; `searchLibrary` loads it and comes back here.
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

    /// First library-only search for a source: load its library (after this it
    /// is the cache the Library tab renders from), then filter it.
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

    /// Run the TMDB person lookup for the current mode. People scope → ranked
    /// person rows. All scope → a single confident headliner + their top
    /// filmography (the "Starring X" section), or nothing.
    private func fetchPeople(scope: SearchScope) async -> (rows: [TMDBPerson], starring: StarringSection?) {
        guard scope.searchesPeople, DemoMode.isActive || !tmdbApiKey.isEmpty else { return ([], nil) }
        let term = peoplePrefixTerm ?? query.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else { return ([], nil) }
        let raw = DemoMode.isActive
            ? DemoMocks.searchPeople(query: term)
            : (try? await ServiceHandles.tmdb(apiKey: tmdbApiKey).searchPerson(query: term)) ?? []
        let ranked = PersonRelevance.rank(raw, query: term)
        if scope == .people {
            return (ranked, nil)
        }
        // All scope: a full name is unambiguous and always earns a section; a
        // single token has to clear the popularity floor instead.
        guard let top = ranked.first else { return ([], nil) }
        let isFullName = PersonRelevance.isFullNameMatch(top, query: term)
        guard isFullName || PersonRelevance.isConfidentHeadliner(top, query: term) else {
            return ([], nil)
        }
        // Movies first, series as the fallback: a TV-only actor (Rhea Seehorn,
        // Bryan Cranston's Better Call Saul co-lead) has a thin-to-empty movie
        // list, and used to be dropped entirely for it.
        var titles = await PersonStore.shared.movieFilmography(
            personId: top.id, tmdbKey: tmdbApiKey, radarrConfig: configs[.radarr] ?? .empty)
        if titles.isEmpty {
            titles = await PersonStore.shared.seriesFilmography(
                personId: top.id, tmdbKey: tmdbApiKey, sonarrConfig: configs[.sonarr] ?? .empty)
        }
        // A named person stands on their own — the header row alone opens the
        // person view. Only the ambiguous single-token match still needs
        // filmography to justify hijacking a title search.
        guard isFullName || !titles.isEmpty else { return ([], nil) }
        return ([], StarringSection(person: top, titles: Array(titles.prefix(8)),
                                    isPrimary: isFullName))
    }

    /// One source's lookup. `generation` is the same gate `search` applies to
    /// the results: an error from a fetch the user has already typed past must
    /// not paint itself over the search that replaced it.
    private func fetchOne(client: SearchClient?, generation: Int) async -> [SearchResult] {
        guard let client else { return [] }
        do {
            // Ownership comes off the shared library read, whose in-flight
            // fetch belongs to every caller and isn't cancelled with this
            // search. As an `async let` child it held a failed lookup's error
            // hostage until the whole library had loaded; unstructured, the
            // lookup reports straight away and the fetch just runs on.
            let libraryFetch = Task { try await client.fetchLibraryOwnership() }
            defer { libraryFetch.cancel() }
            let raw = try await client.lookup(input: parsedInput)
            let map = try await libraryFetch.value
            // Used to be `raw.filter { !ids.contains($0.id) }` — hiding
            // library hits entirely. The "Search" tab now wants both
            // kinds in one list, so we keep them all and stamp
            // `inLibraryArrId` on the ones we own. The row + selection
            // routing diverge based on that field: in-library rows show
            // an "In library" pill + drill into DetailView; addable
            // rows flow into SearchAddPanel.
            return raw.map { result in
                map[result.externalId].map(result.withLibraryOwnership) ?? result
            }
        } catch {
            // A superseded keystroke cancelled this lookup — not a failure the
            // user should ever read. `HTTPClient.perform` rethrows
            // `CancellationError` bare and URLSession reports its own teardown
            // as `URLError.cancelled`; arr lookups take 1-3s, so typing hits
            // this constantly and the raw text ("The operation couldn't be
            // completed. (Swift.CancellationError error 1.)") used to land in
            // the search UI.
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                return []
            }
            if searchGeneration == generation { errorMessage = error.localizedDescription }
            return []
        }
    }

    /// Replace a TMDB-sourced "lean" SearchResult with the arr's own lookup
    /// hit so the SearchAddPanel hero card shows the full IMDB/RT/Metacritic
    /// + runtime + genre chips that the `+` path gets natively.
    ///
    /// Returns nil — caller keeps the lean row — whenever the swap can't be
    /// made on an id. Enrichment is cosmetic; identity is not, and a row
    /// enriched from a same-titled *different* show replaced the poster, the
    /// overview and (via the panel's id-keyed tasks) the cast. Every route
    /// here is now id-based: TMDB ids for movies, `SeriesIdentityResolver`
    /// for TMDB-sourced series.
    /// Every return here keeps the row's own artwork (`withArtwork(from:)`):
    /// the point is richer *metadata*, and swapping the poster mid-panel made
    /// a correct enrichment look exactly like the wrong-series bug.
    func enrich(_ result: SearchResult) async -> SearchResult? {
        switch result.source {
        case .radarr:
            guard let client = client(for: result.source), result.externalId > 0 else { return nil }
            return (try? await client.lookup(query: "tmdb:\(result.externalId)").first)?
                .withArtwork(from: result)
        case .sonarr:
            if result.externalId > 0 {
                guard let client = client(for: result.source) else { return nil }
                return (try? await client.lookup(query: "tvdb:\(result.externalId)").first)?
                    .withArtwork(from: result)
            }
            // A TMDB tv id is not a tvdbId. Resolve it properly (library
            // snapshot → verified `tmdb:N` → TMDB `/external_ids`) instead of
            // re-finding the show by name.
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
        let mp: [ArrMetadataProfile] = source == .lidarr
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
                  monitor: RadarrMonitorMode = .movieOnly, searchOnAdd: Bool) async {
        guard StoreManager.shared.requirePro(.addTitle) else { return }
        guard let client = whisparrClient else { return }
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
        guard let client = radarrClient else { return }
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
        guard let client = sonarrClient else { return }
        isAdding = true; addError = nil
        defer { isAdding = false }
        // A TMDB-sourced row carries a TMDB tv id, not the tvdbId Sonarr posts
        // against. Resolve it here, by id, before the write — the client
        // refuses an unresolved row rather than guessing at one by title.
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
        guard let client = lidarrClient else { return }
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

    /// Add a single album (Lidarr) — creates the artist alongside it with
    /// only this album monitored. See `SearchClient.addAlbum`.
    func addAlbum(_ result: SearchResult, qualityProfileId: Int, metadataProfileId: Int,
                  rootFolderPath: String, searchOnAdd: Bool) async {
        guard StoreManager.shared.requirePro(.addTitle) else { return }
        guard let client = lidarrClient else { return }
        isAdding = true; addError = nil
        defer { isAdding = false }
        do {
            let arrId = try await client.addAlbum(result, qualityProfileId: qualityProfileId,
                                                  metadataProfileId: metadataProfileId,
                                                  rootFolderPath: rootFolderPath,
                                                  searchOnAdd: searchOnAdd)
            lidarrResults.removeAll { $0.id == result.id }
            // The POST returns the ALBUM record — deep-link straight into the
            // album detail (unlike the artist add, which lands on the artist).
            guard let arrId else { return }
            DetailRequest.open(source: .lidarr, arrId: arrId, title: result.title,
                               posterURL: result.posterURL, isLidarrAlbum: true)
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
        DetailRequest.open(source: source, arrId: arrId, title: result.title,
                           posterURL: result.posterURL, posterRequiresAuth: false)
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
