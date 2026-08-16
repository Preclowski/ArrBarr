import Foundation

public actor SearchClient {
    private let config: ServiceConfig
    private let source: QueueItem.Source
    // Indexer searches via the arr go out to trackers/Usenet and routinely
    // take longer than the short refresh budget — give them headroom so chat
    // "search" tools don't time out at 15s.
    private let http: HTTPClient

    private var apiBase: String {
        source == .lidarr ? "/api/v1" : "/api/v3"
    }
    // .whisparr stays /api/v3 — no change needed since lidarr is the special case

    /// `session` exists for tests: several suites register process-wide
    /// `URLProtocol` stubs that answer *every* request, so a test that needs
    /// its own traffic back hands in an ephemeral session carrying only its
    /// own stub. Production callers take the default.
    init(config: ServiceConfig, source: QueueItem.Source, session: URLSession = .shared) {
        self.config = config
        self.source = source
        self.http = HTTPClient(session: session, timeout: 60)
    }

    private var headers: [String: String] { ["X-Api-Key": config.apiKey] }

    // MARK: - Lookup

    /// Plain-text lookup. Preserved as a convenience wrapper so chat
    /// tools and tests that pass a String don't need to wrap manually.
    func lookup(query: String) async throws -> [SearchResult] {
        try await lookup(input: .text(query))
    }

    /// Structured lookup. `.ref(_:)` inputs short-circuit on sources
    /// that can't resolve the ref's scheme (e.g. a `tmdb:N` query
    /// against Sonarr returns empty without a round-trip — Sonarr's
    /// endpoint would otherwise search the literal "tmdb:N" string
    /// in titles and yield garbage).
    func lookup(input: SearchInput) async throws -> [SearchResult] {
        if case .ref(let ref) = input, !ref.compatibleSources.contains(source) {
            return []
        }
        let query = input.arrTerm
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
            return records.enumerated().compactMap { Self.unifyRadarr($0.element, baseURL: config.baseURL, sourceRank: $0.offset) }
        case .sonarr:
            let url = try http.url(base: config.baseURL, path: "\(apiBase)/series/lookup",
                                   query: [URLQueryItem(name: "term", value: query)])
            let data = try await http.get(url, headers: headers)
            let records = try JSONDecoder().decode([SonarrLookupRecord].self, from: data)
            return records.enumerated().compactMap { Self.unifySonarr($0.element, baseURL: config.baseURL, sourceRank: $0.offset) }
        case .lidarr:
            // Music search covers BOTH entities — artists and albums. Text
            // terms go through `/search` (the mixed endpoint Lidarr's own UI
            // uses; `/artist/lookup` and `/album/lookup` only resolve
            // foreign-id / prefixed terms, so a title query returns artists
            // at best). Album rows are stamped `isLidarrAlbum` for the
            // divergent tap routing. An MBID ref query keeps the dedicated
            // artist endpoint — it resolves a bare GUID directly.
            if input.isRef {
                let url = try http.url(base: config.baseURL, path: "\(apiBase)/artist/lookup",
                                       query: [URLQueryItem(name: "term", value: query)])
                let data = try await http.get(url, headers: headers)
                let records = try JSONDecoder().decode([LidarrLookupRecord].self, from: data)
                return records.enumerated().compactMap {
                    Self.unifyLidarr($0.element, baseURL: config.baseURL, sourceRank: $0.offset)
                }
            }
            // Hybrid fetch: `/search` is the only endpoint that returns
            // albums for a text term, but its artist entries come back with
            // EMPTY `images` (Lidarr quirk — `/artist/lookup` for the same
            // term has them). So albums come from `/search` and artists from
            // `/artist/lookup`, concurrently; `SearchRelevance` re-ranks the
            // merged list anyway, so the split costs no ordering.
            let searchUrl = try http.url(base: config.baseURL, path: "\(apiBase)/search",
                                         query: [URLQueryItem(name: "term", value: query)])
            async let searchData = http.get(searchUrl, headers: headers)
            let lookupUrl = try http.url(base: config.baseURL, path: "\(apiBase)/artist/lookup",
                                         query: [URLQueryItem(name: "term", value: query)])
            // Artist leg is best-effort — the mixed endpoint alone still
            // yields a usable (if imageless-artist) list.
            async let lookupData: Data? = try? http.get(lookupUrl, headers: headers)
            let searchRecords = try JSONDecoder().decode([LidarrSearchRecord].self, from: await searchData)
            let artistRecords: [LidarrLookupRecord] = await lookupData.flatMap {
                try? JSONDecoder().decode([LidarrLookupRecord].self, from: $0)
            } ?? []
            let albums = searchRecords.enumerated().compactMap { offset, rec in
                rec.album.flatMap {
                    Self.unifyLidarrAlbum($0, baseURL: config.baseURL, sourceRank: offset)
                }
            }
            let artists: [SearchResult]
            if artistRecords.isEmpty {
                // Fallback: imageless artists straight from `/search`.
                artists = searchRecords.enumerated().compactMap { offset, rec in
                    rec.artist.flatMap {
                        Self.unifyLidarr($0, baseURL: config.baseURL, sourceRank: offset)
                    }
                }
            } else {
                // Each endpoint keeps its own natural 0-based order — they
                // rank different entity kinds, and offsetting artists by the
                // /search length handed every artist a flat upstream-rank
                // penalty (~2 pt/position) against same-band titles from
                // OTHER arrs for no reason.
                artists = artistRecords.enumerated().compactMap {
                    Self.unifyLidarr($0.element, baseURL: config.baseURL, sourceRank: $0.offset)
                }
            }
            return albums + artists
        case .whisparr:
            let url = try http.url(base: config.baseURL, path: "\(apiBase)/movie/lookup",
                                   query: [URLQueryItem(name: "term", value: query)])
            let data = try await http.get(url, headers: headers)
            let records = try JSONDecoder().decode([WhisparrLookupRecord].self, from: data)
            return records.enumerated().compactMap { Self.unifyWhisparr($0.element, baseURL: config.baseURL, sourceRank: $0.offset) }
        }
    }

    // MARK: - Library filter

    /// Returns a map of `foreignId → arr internal id` for everything in
    /// the user's library. Used to be `Set<Int>` (foreign-id only) when
    /// search just hid library items; the new "Search" tab shows them
    /// with an "In library" pill, so we also need the arr-side id to
    /// deep-link into DetailView when tapped. The foreign-id key matches
    /// what `SearchResult.id` carries for each source.
    func fetchLibraryArrIdMap() async throws -> [Int: Int] {
        if DemoMode.isActive { return [:] }
        guard config.isConfigured else { return [:] }
        switch source {
        case .radarr:
            let url = try http.url(base: config.baseURL, path: "\(apiBase)/movie")
            let data = try await http.get(url, headers: headers)
            let records = (try? JSONDecoder().decode([RadarrLibraryRecord].self, from: data)) ?? []
            var map: [Int: Int] = [:]
            for r in records { if let f = r.tmdbId, let a = r.id { map[f] = a } }
            return map
        case .sonarr:
            let url = try http.url(base: config.baseURL, path: "\(apiBase)/series")
            let data = try await http.get(url, headers: headers)
            let records = (try? JSONDecoder().decode([SonarrLibraryRecord].self, from: data)) ?? []
            var map: [Int: Int] = [:]
            for r in records { if let f = r.tvdbId, let a = r.id { map[f] = a } }
            return map
        case .lidarr:
            let url = try http.url(base: config.baseURL, path: "\(apiBase)/artist")
            let data = try await http.get(url, headers: headers)
            let records = (try? JSONDecoder().decode([LidarrLibraryRecord].self, from: data)) ?? []
            var map: [Int: Int] = [:]
            for r in records {
                if let fid = r.foreignArtistId, let a = r.id {
                    map[abs(fid.hashValue) & 0x7fffffff] = a
                }
            }
            return map
        case .whisparr:
            let url = try http.url(base: config.baseURL, path: "\(apiBase)/movie")
            let data = try await http.get(url, headers: headers)
            let records = (try? JSONDecoder().decode([WhisparrLibraryRecord].self, from: data)) ?? []
            var map: [Int: Int] = [:]
            for rec in records {
                let foreign: Int? = {
                    if let tmdbId = rec.tmdbId, tmdbId != 0 { return tmdbId }
                    if let fid = rec.foreignId { return abs(fid.hashValue) & 0x7fffffff }
                    return nil
                }()
                if let f = foreign, let a = rec.id { map[f] = a }
            }
            return map
        }
    }

    // MARK: - Profiles & folders

    /// `/qualityprofile` reduced to id → name; failures collapse to an
    /// empty map. The ONE profile-name lookup — the Library view-model,
    /// DetailView's hero chip and the Upcoming tooltip all resolve through
    /// this instead of three hand-rolled copies.
    ///
    /// Reads through `SearchOptionsCache`, which already holds this exact
    /// payload for the add panel. Before that, every detail open and every
    /// Upcoming row refetched the whole profile list to resolve one id.
    static func profileNameMap(config: ServiceConfig, source: QueueItem.Source) async -> [Int: String] {
        let profiles = await SearchOptionsCache.shared.qualityProfiles(config: config, source: source) {
            (try? await SearchClient(config: config, source: source).fetchQualityProfiles()) ?? []
        }
        return Dictionary(profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

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

    /// Boundary check: the caller's SearchResult must carry a MediaRef
    /// this client can resolve. Centralised so the per-arr addX
    /// methods all enforce the same invariant without each one
    /// re-deriving it from `source` + `id`.
    private func ensureRefCompatible(_ result: SearchResult) throws {
        let ref = result.mediaRef
        guard ref.compatibleSources.contains(source) else {
            throw HTTPError.wrongSource(
                refKind: String(describing: ref).split(separator: "(").first.map(String.init) ?? "ref",
                clientSource: source.rawValue
            )
        }
    }

    /// The arr returns the freshly-created record — including its
    /// internal `id` — in the POST response. Pull that id so the caller
    /// can navigate straight to the new item's detail without a second
    /// round-trip or a racy library-map refresh. Best-effort: nil if the
    /// body isn't the expected object.
    private static func newRecordId(from data: Data) -> Int? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? Int
    }

    /// Returns the new Radarr movie id on success (nil in demo mode or if
    /// the response can't be parsed).
    @discardableResult
    /// - Parameter searchOnAdd: hands the arr `addOptions.searchForMovie`, i.e.
    ///   whether it should start hunting indexers the moment the record lands.
    ///   No default on purpose — every caller states its intent, because this is
    ///   the difference between "added, sitting there" and "added, already
    ///   downloading", and it used to be an invisible hardcoded `true`.
    func addMovie(_ result: SearchResult, qualityProfileId: Int, rootFolderPath: String,
                  monitor: RadarrMonitorMode, searchOnAdd: Bool) async throws -> Int? {
        try ensureRefCompatible(result)
        if DemoMode.isActive {
            try? await Task.sleep(nanoseconds: 500_000_000)
            return nil
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
            "addOptions": ["searchForMovie": searchOnAdd]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = try await http.post(url, headers: headers.merging(["Content-Type": "application/json"]) { $1 }, body: data)
        return Self.newRecordId(from: response)
    }

    /// Returns the new Sonarr series id on success (nil in demo mode or if
    /// the response can't be parsed).
    @discardableResult
    /// - Parameter searchOnAdd: see `addMovie` — Sonarr spells it
    ///   `searchForMissingEpisodes`.
    func addSeries(_ result: SearchResult, qualityProfileId: Int, rootFolderPath: String,
                   monitor: SonarrMonitorMode, seriesType: SonarrSeriesType,
                   seasonFolder: Bool, searchOnAdd: Bool) async throws -> Int? {
        try ensureRefCompatible(result)
        if DemoMode.isActive {
            try? await Task.sleep(nanoseconds: 500_000_000)
            return nil
        }
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }

        // The caller resolves identity (`SeriesIdentityResolver`, via
        // `SearchViewModel.addSeries`); this only posts. A row that still has
        // no tvdbId here is one whose show could not be *proven*, and the
        // write path is the last place to start guessing: this used to fall
        // back to a title lookup and take the first hit, which quietly added
        // a different series with the same name to the user's library.
        let tvdbId = result.externalId
        guard tvdbId > 0 else {
            throw HTTPError.decoding(NSError(
                domain: "ArrBarr.SonarrAdd",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey:
                    String(format: String(localized: "search.unresolvedSeries.error", bundle: .module),
                           result.title)]
            ))
        }

        let url = try http.url(base: config.baseURL, path: "\(apiBase)/series")
        let body: [String: Any] = [
            "tvdbId": tvdbId,
            "title": result.title,
            "qualityProfileId": qualityProfileId,
            "rootFolderPath": rootFolderPath,
            "monitored": true,
            "seriesType": seriesType.rawValue,
            "seasonFolder": seasonFolder,
            "addOptions": [
                "monitor": monitor.apiValue,
                "searchForMissingEpisodes": searchOnAdd
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = try await http.post(url, headers: headers.merging(["Content-Type": "application/json"]) { $1 }, body: data)
        return Self.newRecordId(from: response)
    }

    /// Returns the new Whisparr movie id on success (nil in demo mode or if
    /// the response can't be parsed).
    @discardableResult
    /// - Parameter searchOnAdd: see `addMovie` — Whisparr shares Radarr's
    ///   `searchForMovie` spelling.
    func addScene(_ result: SearchResult, qualityProfileId: Int, rootFolderPath: String,
                  monitor: RadarrMonitorMode = .movieOnly, searchOnAdd: Bool) async throws -> Int? {
        try ensureRefCompatible(result)
        if DemoMode.isActive {
            try? await Task.sleep(nanoseconds: 500_000_000)
            return nil
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
            "addOptions": ["searchForMovie": searchOnAdd]
        ]
        let foreignId = result.foreignId
        if let tmdbId = Int(foreignId), tmdbId != 0 {
            body["tmdbId"] = tmdbId
        } else {
            body["foreignId"] = foreignId
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = try await http.post(url, headers: headers.merging(["Content-Type": "application/json"]) { $1 }, body: data)
        return Self.newRecordId(from: response)
    }

    /// Returns the new Lidarr artist id on success (nil in demo mode or if
    /// the response can't be parsed).
    @discardableResult
    /// - Parameter searchOnAdd: see `addMovie` — Lidarr spells it
    ///   `searchForMissingAlbums`.
    func addArtist(_ result: SearchResult, qualityProfileId: Int, metadataProfileId: Int,
                   rootFolderPath: String, monitor: String = "all",
                   searchOnAdd: Bool) async throws -> Int? {
        try ensureRefCompatible(result)
        if DemoMode.isActive {
            try? await Task.sleep(nanoseconds: 500_000_000)
            return nil
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
                "searchForMissingAlbums": searchOnAdd
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = try await http.post(url, headers: headers.merging(["Content-Type": "application/json"]) { $1 }, body: data)
        return Self.newRecordId(from: response)
    }

    /// Add a single ALBUM (Lidarr) — what its own UI's "Add new album" does:
    /// re-fetch the album from `/album/lookup` by MBID (POST `/album` wants
    /// the full lookup resource, and round-tripping it as raw JSON keeps
    /// every field Lidarr expects), graft the artist's add parameters onto
    /// the embedded artist, and POST. The artist is created monitored with
    /// `monitor: "none"` so ONLY this album ends up monitored.
    /// Returns the new album's arr id (the album-detail deep link).
    @discardableResult
    func addAlbum(_ result: SearchResult, qualityProfileId: Int, metadataProfileId: Int,
                  rootFolderPath: String, searchOnAdd: Bool) async throws -> Int? {
        try ensureRefCompatible(result)
        if DemoMode.isActive {
            try? await Task.sleep(nanoseconds: 500_000_000)
            return nil
        }
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        // Re-search by the TITLE the user just searched (guaranteed to
        // return this album again) and pick the record by MBID. Same
        // `/search` endpoint the row came from — the dedicated lookup
        // endpoints don't do text search.
        let lookupUrl = try http.url(
            base: config.baseURL, path: "\(apiBase)/search",
            query: [URLQueryItem(name: "term", value: result.title)])
        let lookupData = try await http.get(lookupUrl, headers: headers)
        let records = (try? JSONSerialization.jsonObject(with: lookupData)) as? [[String: Any]] ?? []
        guard var album = records
                .compactMap({ $0["album"] as? [String: Any] })
                .first(where: { ($0["foreignAlbumId"] as? String) == result.foreignId }) else {
            throw HTTPError.decoding(NSError(domain: "lidarr", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Album not found in Lidarr lookup"]))
        }
        album["monitored"] = true
        var artist = album["artist"] as? [String: Any] ?? [:]
        artist["qualityProfileId"] = qualityProfileId
        artist["metadataProfileId"] = metadataProfileId
        artist["rootFolderPath"] = rootFolderPath
        artist["monitored"] = true
        artist["addOptions"] = ["monitor": "none", "searchForMissingAlbums": false]
        album["artist"] = artist
        album["addOptions"] = ["searchForNewAlbum": searchOnAdd]
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/album")
        let body = try JSONSerialization.data(withJSONObject: album)
        let response = try await http.post(url, headers: headers.merging(["Content-Type": "application/json"]) { $1 }, body: body)
        return Self.newRecordId(from: response)
    }

    // MARK: - Unify

    private static func unifyRadarr(_ r: RadarrLookupRecord, baseURL: String, sourceRank: Int = 0) -> SearchResult? {
        guard let tmdbId = r.tmdbId else { return nil }
        let (poster, _) = (r.images?.posterURL(baseURL: baseURL) ?? (nil, false))
        return SearchResult(
            externalId: tmdbId, foreignId: String(tmdbId),
            title: r.title, subtitle: nil,
            year: r.year, rating: r.ratings?.tmdb?.value,
            // TMDB vote_count — feeds the Bayesian tie-breaker in
            // SearchRelevance so a 9.9 with 5 votes doesn't outrank
            // an 8.0 with 20 000. Falls back to IMDB votes when TMDB
            // is missing (rare).
            votes: r.ratings?.tmdb?.votes ?? r.ratings?.imdb?.votes,
            imdb: r.ratings?.imdb?.value,
            rottenTomatoes: r.ratings?.rottenTomatoes?.value,
            metacritic: r.ratings?.metacritic?.value,
            overview: r.overview, runtime: r.runtime,
            genres: r.genres ?? [],
            network: r.studio,
            certification: r.certification,
            posterURL: poster, source: .radarr,
            inLibraryArrId: (r.id ?? 0) != 0 ? r.id : nil,
            imdbId: r.imdbId, sourceRank: sourceRank
        )
    }

    private static func unifySonarr(_ r: SonarrLookupRecord, baseURL: String, sourceRank: Int = 0) -> SearchResult? {
        guard let tvdbId = r.tvdbId else { return nil }
        let (poster, _) = (r.images?.posterURL(baseURL: baseURL) ?? (nil, false))
        let seasons = r.statistics?.seasonCount
        let subtitle = seasons.map { "\($0) season\($0 == 1 ? "" : "s")" }
        return SearchResult(
            externalId: tvdbId, foreignId: String(tvdbId),
            title: r.title, subtitle: subtitle,
            year: r.year, rating: r.ratings?.value,
            // TVDB vote count — was never passed, so the Bayesian shrinkage
            // silently never applied to series.
            votes: r.ratings?.votes,
            imdb: nil, rottenTomatoes: nil, metacritic: nil,
            overview: r.overview, runtime: r.runtime,
            genres: r.genres ?? [],
            network: r.network,
            certification: nil,
            posterURL: poster, source: .sonarr,
            inLibraryArrId: (r.id ?? 0) != 0 ? r.id : nil,
            imdbId: r.imdbId, sourceRank: sourceRank,
            // SkyHook ships TMDB's id alongside TVDB's. Carrying it is what
            // lets `SeriesIdentityResolver` prove a `tmdb:N` lookup answered
            // about the show it was asked about.
            tmdbTVId: (r.tmdbId ?? 0) != 0 ? r.tmdbId : nil
        )
    }

    internal static func unifyWhisparr(_ r: WhisparrLookupRecord, baseURL: String, sourceRank: Int = 0) -> SearchResult? {
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
            externalId: stableId,
            foreignId: foreign,
            title: r.title,
            subtitle: nil,
            year: r.year,
            rating: r.ratings?.tmdb?.value,
            votes: r.ratings?.tmdb?.votes ?? r.ratings?.imdb?.votes,
            imdb: nil,
            rottenTomatoes: nil,
            metacritic: nil,
            overview: r.overview,
            runtime: r.runtime,
            genres: r.genres ?? [],
            network: r.studio,
            certification: nil,
            posterURL: poster.0,
            source: .whisparr,
            sourceRank: sourceRank
        )
    }

    internal static func unifyLidarrAlbum(_ r: LidarrAlbumLookupRecord, baseURL: String, sourceRank: Int = 0) -> SearchResult? {
        guard let foreign = r.foreignAlbumId, !foreign.isEmpty else { return nil }
        let (poster, _) = r.images?.posterURL(baseURL: baseURL, coverTypes: ["cover", "poster"]) ?? (nil, false)
        let stableId = abs(foreign.hashValue) & 0x7fffffff
        let year = r.releaseDate.flatMap { parseArrDate($0) }.map {
            Calendar.current.component(.year, from: $0)
        }
        // Subtitle: the artist — the row's disambiguator, same slot the
        // artist rows use for MusicBrainz's own disambiguation string.
        let subtitle = [r.artist?.artistName, r.albumType]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return SearchResult(
            externalId: stableId,
            foreignId: foreign,
            title: r.title,
            subtitle: subtitle.isEmpty ? r.disambiguation : subtitle,
            year: year,
            rating: r.ratings?.value,
            votes: r.ratings?.votes,
            imdb: nil,
            rottenTomatoes: nil,
            metacritic: nil,
            overview: r.overview,
            runtime: nil,
            genres: r.genres ?? [],
            network: nil,
            certification: nil,
            posterURL: poster,
            source: .lidarr,
            // Lookup stamps the arr record id on in-library albums — that's
            // the deep-link into the album DetailView. The artist-keyed
            // library map in `fetchOne` can't match these rows (disjoint
            // hash spaces), so this is the only in-library signal they get.
            inLibraryArrId: (r.id ?? 0) != 0 ? r.id : nil,
            sourceRank: sourceRank,
            isLidarrAlbum: true
        )
    }

    internal static func unifyLidarr(_ r: LidarrLookupRecord, baseURL: String, sourceRank: Int = 0) -> SearchResult? {
        guard let foreign = r.foreignArtistId, !foreign.isEmpty else { return nil }
        let (poster, _) = r.images?.posterURL(baseURL: baseURL, coverTypes: ["poster", "cover"]) ?? (nil, false)
        let stableId = abs(foreign.hashValue) & 0x7fffffff
        return SearchResult(
            externalId: stableId,
            foreignId: foreign,
            title: r.artistName,
            subtitle: r.disambiguation,
            year: nil,
            rating: r.ratings?.value,
            votes: r.ratings?.votes,
            imdb: nil,
            rottenTomatoes: nil,
            metacritic: nil,
            overview: r.overview,
            runtime: nil,
            genres: r.genres ?? [],
            network: nil,
            certification: nil,
            posterURL: poster,
            source: .lidarr,
            sourceRank: sourceRank
        )
    }
}
