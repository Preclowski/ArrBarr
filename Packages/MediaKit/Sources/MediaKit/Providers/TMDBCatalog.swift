import Foundation

/// TMDB answering "which titles".
///
/// Every intent it can serve maps to one endpoint and one page of results, and
/// the summaries those endpoints return already carry title, artwork and
/// score — so a browse costs one request, not one plus twenty. Fields the
/// summary lacks (credits, streaming, what the user owns) are the graph's job
/// afterwards.
extension TMDBProvider: MediaCatalogProviding {
    public func canServe(_ query: MediaCatalogQuery) -> Bool {
        guard isConfigured else { return false }
        switch query.intent {
        case .library:
            // TMDB has no idea what the user owns, and guessing would be
            // worse than not answering.
            return false
        case .curated(let shelf):
            return shelf != .recentlyAdded
        case .trending, .discover, .search, .similar, .recommendations, .list, .credits:
            return kindIsSupported(query.kind)
        }
    }

    private func kindIsSupported(_ kind: MediaKind?) -> Bool {
        switch kind {
        case nil, .movie, .series: true
        // Seasons and episodes are per-title questions; music is Lidarr's.
        case .season, .episode, .artist, .album: false
        }
    }

    public func catalog(_ query: MediaCatalogQuery) async throws -> MediaCatalogPage {
        guard canServe(query) else {
            throw MediaError.noSource("TMDB cannot serve \(query.intent)")
        }
        let plan = try endpoint(for: query)
        let started = Date()
        guard let request = auth.request(path: plan.path, query: plan.query) else {
            throw MediaError.notConfigured(id)
        }
        await telemetry?.record(.init(kind: .request, provider: id,
                                      identity: plan.telemetryKey,
                                      fields: [.title, .artwork, .ratings]))
        let response = try await transport.send(request)
        await telemetry?.record(.init(kind: response.isSuccess ? .response : .failure,
                                      provider: id, identity: plan.telemetryKey,
                                      fields: [.title, .artwork, .ratings],
                                      duration: Date().timeIntervalSince(started),
                                      bytes: response.data.count,
                                      note: "HTTP \(response.status)"))
        switch response.status {
        case 200..<300: break
        case 401, 403: throw MediaError.unauthorized(id)
        case 404: throw MediaError.notFound(id)
        case 429: throw MediaError.rateLimited(id, retryAfter: nil)
        default: throw MediaError.unreachable(id)
        }

        let page: Page
        do {
            page = try JSONDecoder().decode(Page.self, from: response.data)
        } catch {
            throw MediaError.decoding(id, "\(error)")
        }
        let provenance = Provenance(provider: id, fetchedAt: Date(), fromCache: false)
        let items = (page.results ?? []).compactMap {
            $0.snapshot(defaultKind: plan.defaultKind, provenance: provenance)
        }
        return MediaCatalogPage(items: items,
                                page: page.page ?? query.page,
                                totalPages: page.totalPages,
                                totalResults: page.totalResults,
                                provenance: provenance,
                                unappliedFilters: plan.unapplied)
    }

    // MARK: - Intent → endpoint

    private struct Plan {
        let path: String
        let query: [URLQueryItem]
        /// What a result without a `media_type` must be.
        let defaultKind: MediaKind
        let unapplied: [String]
        let telemetryKey: String
    }

    private func endpoint(for query: MediaCatalogQuery) throws -> Plan {
        let kind = query.kind ?? .movie
        let path = kind == .series ? "tv" : "movie"
        var items = [URLQueryItem(name: "page", value: String(query.page))]
        if let language = query.language { items.append(.init(name: "language", value: language)) }

        switch query.intent {
        case .trending(let window):
            let scope = query.kind == nil ? "all" : path
            return Plan(path: "/trending/\(scope)/\(window.rawValue)", query: items,
                        defaultKind: kind, unapplied: filterNames(query.filter),
                        telemetryKey: "trending/\(scope)")

        case .curated(let shelf):
            guard let name = Self.curatedPath(shelf, kind: kind) else {
                throw MediaError.noSource("TMDB has no \(shelf.rawValue) shelf for \(kind.rawValue)")
            }
            if let region = query.region { items.append(.init(name: "region", value: region)) }
            return Plan(path: "/\(path)/\(name)", query: items,
                        defaultKind: kind, unapplied: filterNames(query.filter),
                        telemetryKey: "\(path)/\(name)")

        case .discover:
            items += discoverItems(query)
            return Plan(path: "/discover/\(path)", query: items,
                        defaultKind: kind, unapplied: [],
                        telemetryKey: "discover/\(path)")

        case .search(let term):
            let scope = query.kind == nil ? "multi" : path
            items.append(.init(name: "query", value: term))
            items.append(.init(name: "include_adult", value: query.filter.includeAdult ? "true" : "false"))
            return Plan(path: "/search/\(scope)", query: items,
                        defaultKind: kind, unapplied: filterNames(query.filter, ignoring: ["adult"]),
                        telemetryKey: "search/\(scope)")

        case .similar(let identity), .recommendations(let identity):
            guard let tmdbID = identity.tmdbID else { throw MediaError.notFound(id) }
            let relation: String = if case .similar = query.intent { "similar" } else { "recommendations" }
            let subject = identity.kind == .series ? "tv" : "movie"
            return Plan(path: "/\(subject)/\(tmdbID)/\(relation)", query: items,
                        defaultKind: identity.kind, unapplied: filterNames(query.filter),
                        telemetryKey: "\(subject)/\(relation)")

        case .list(let ref):
            guard ref.provider == .tmdb else {
                throw MediaError.noSource("list from \(ref.provider.rawValue)")
            }
            return Plan(path: "/list/\(ref.id)", query: items,
                        defaultKind: .movie, unapplied: filterNames(query.filter),
                        telemetryKey: "list")

        case .credits(let person):
            // One call covers both halves of a filmography; the caller splits
            // by kind.
            return Plan(path: "/person/\(person)/combined_credits", query: items,
                        defaultKind: .movie, unapplied: filterNames(query.filter),
                        telemetryKey: "person/credits")

        case .library:
            throw MediaError.unsupported(.availability)
        }
    }

    static func curatedPath(_ shelf: MediaCatalogIntent.CuratedShelf, kind: MediaKind) -> String? {
        switch (shelf, kind) {
        case (.popular, _): "popular"
        case (.topRated, _): "top_rated"
        case (.upcoming, .movie): "upcoming"
        case (.nowPlaying, .movie): "now_playing"
        case (.airingToday, .series): "airing_today"
        case (.onTheAir, .series): "on_the_air"
        // A shelf a media server owns, or one asked for the wrong kind.
        default: nil
        }
    }

    private func discoverItems(_ query: MediaCatalogQuery) -> [URLQueryItem] {
        let filter = query.filter
        let isSeries = query.kind == .series
        var items: [URLQueryItem] = [
            .init(name: "sort_by", value: Self.sortParameter(query.sort, isSeries: isSeries)),
            .init(name: "include_adult", value: filter.includeAdult ? "true" : "false"),
        ]
        if !filter.genreIDs.isEmpty {
            items.append(.init(name: "with_genres",
                               value: filter.genreIDs.sorted().map(String.init).joined(separator: ",")))
        }
        if let years = filter.yearRange {
            let gte = isSeries ? "first_air_date.gte" : "primary_release_date.gte"
            let lte = isSeries ? "first_air_date.lte" : "primary_release_date.lte"
            items.append(.init(name: gte, value: "\(years.lowerBound)-01-01"))
            items.append(.init(name: lte, value: "\(years.upperBound)-12-31"))
        }
        if let rating = filter.minRating {
            items.append(.init(name: "vote_average.gte", value: String(rating)))
        }
        if let votes = filter.minVotes {
            items.append(.init(name: "vote_count.gte", value: String(votes)))
        }
        if let runtime = filter.maxRuntimeMinutes {
            items.append(.init(name: "with_runtime.lte", value: String(runtime)))
        }
        if !filter.streamingProviderIDs.isEmpty {
            items.append(.init(name: "with_watch_providers",
                               value: filter.streamingProviderIDs.sorted()
                                   .map(String.init).joined(separator: "|")))
            // A provider list without a region means nothing to TMDB.
            items.append(.init(name: "watch_region", value: query.region ?? "US"))
        } else if let region = query.region {
            items.append(.init(name: "watch_region", value: region))
        }
        if let language = filter.originalLanguage {
            items.append(.init(name: "with_original_language", value: language))
        }
        return items
    }

    static func sortParameter(_ sort: MediaSort, isSeries: Bool) -> String {
        let dateField = isSeries ? "first_air_date" : "primary_release_date"
        return switch sort {
        case .popularity, .natural: "popularity.desc"
        case .rating: "vote_average.desc"
        case .newest: "\(dateField).desc"
        case .oldest: "\(dateField).asc"
        case .mostVoted: "vote_count.desc"
        case .title: "title.asc"
        }
    }

    /// Filters this endpoint silently ignores. Reported rather than dropped:
    /// a "only what I don't own, rated 8+" browse that quietly returns
    /// everything is worse than one that says it couldn't.
    private func filterNames(_ filter: MediaFilter, ignoring: [String] = []) -> [String] {
        var names: [String] = []
        if !filter.genreIDs.isEmpty { names.append("genres") }
        if filter.yearRange != nil { names.append("years") }
        if filter.minRating != nil { names.append("rating") }
        if filter.minVotes != nil { names.append("votes") }
        if filter.maxRuntimeMinutes != nil { names.append("runtime") }
        if !filter.streamingProviderIDs.isEmpty { names.append("streaming") }
        if filter.originalLanguage != nil { names.append("language") }
        // `presence` is never TMDB's to apply — the graph owns that one, so it
        // is not reported as a failure here.
        return names.filter { !ignoring.contains($0) }
    }

    // MARK: - Wire

    private struct Page: Decodable {
        let page: Int?
        let results: [Summary]?
        let totalPages: Int?
        let totalResults: Int?
        /// A TMDB list answers with `items`, not `results`.
        let items: [Summary]?

        enum CodingKeys: String, CodingKey {
            case page, results, items
            case totalPages = "total_pages"
            case totalResults = "total_results"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            page = try container.decodeIfPresent(Int.self, forKey: .page)
            totalPages = try container.decodeIfPresent(Int.self, forKey: .totalPages)
            totalResults = try container.decodeIfPresent(Int.self, forKey: .totalResults)
            items = try container.decodeIfPresent([Summary].self, forKey: .items)
            let listed = try container.decodeIfPresent([Summary].self, forKey: .results)
            // `cast`/`crew` for a filmography, `items` for a list, `results`
            // for everything else — one shape out.
            if let listed {
                results = listed
            } else if let items {
                results = items
            } else {
                let credits = try? CombinedCredits(from: decoder)
                results = credits.map { ($0.cast ?? []) + ($0.crew ?? []) }
            }
        }
    }

    private struct CombinedCredits: Decodable {
        let cast: [Summary]?
        let crew: [Summary]?
    }

    struct Summary: Decodable {
        let id: Int
        let mediaType: String?
        let title: String?
        let name: String?
        let originalTitle: String?
        let originalName: String?
        let overview: String?
        let releaseDate: String?
        let firstAirDate: String?
        let posterPath: String?
        let backdropPath: String?
        let voteAverage: Double?
        let voteCount: Int?
        let genreIDs: [Int]?

        enum CodingKeys: String, CodingKey {
            case id, title, name, overview
            case mediaType = "media_type"
            case originalTitle = "original_title"
            case originalName = "original_name"
            case releaseDate = "release_date"
            case firstAirDate = "first_air_date"
            case posterPath = "poster_path"
            case backdropPath = "backdrop_path"
            case voteAverage = "vote_average"
            case voteCount = "vote_count"
            case genreIDs = "genre_ids"
        }

        func snapshot(defaultKind: MediaKind, provenance: Provenance) -> MediaSnapshot? {
            // A person in a multi-search is not a title.
            if mediaType == "person" { return nil }
            let kind: MediaKind = switch mediaType {
            case "movie": .movie
            case "tv": .series
            default: defaultKind
            }
            guard let name = (kind == .movie ? title : name) ?? title ?? name else { return nil }
            let date = kind == .movie ? releaseDate : firstAirDate
            var fragment = MediaFragment(identity: MediaIdentity(
                kind == .series ? .tmdbSeries(id) : .tmdbMovie(id)))
            fragment.title = TitleFacts(
                title: name,
                originalTitle: originalTitle ?? originalName,
                year: (date?.count ?? 0) >= 4 ? Int(date!.prefix(4)) : nil,
                overview: (overview?.isEmpty ?? true) ? nil : overview)
            fragment.artwork = Artwork(poster: TMDBProvider.imageURL(posterPath, size: "w500"),
                                       backdrop: TMDBProvider.imageURL(backdropPath, size: "w1280"))
            if let score = voteAverage, score > 0 {
                fragment.ratings = Ratings(scores: [
                    ServiceRating(service: .tmdb, value: score, voteCount: voteCount),
                ])
            }
            var snapshot = MediaSnapshot(identity: fragment.identity)
            snapshot.apply(fragment, from: provenance)
            return snapshot
        }
    }
}
