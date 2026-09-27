import Foundation

public struct TMDBService: Sendable {
    public let instance: InstanceID
    private let capabilities: CapabilityIndex
    public static let imageBase = URL(string: "https://image.tmdb.org")!

    public init(instance: InstanceID = InstanceID(.tmdb), capabilities: CapabilityIndex) {
        self.instance = instance; self.capabilities = capabilities
    }

    /// Auth placement is decided per request from the credential material: `.bearer` for v4 tokens, `api_key` query for v3 keys.
    private func plan(_ operation: String, path: String, values: [String: String] = [:], query: [(String, String)] = []) -> RequestPlan {
        RequestPlan(instance: instance, operation: operation, pathTemplate: "/3" + path, pathValues: values,
                    query: query.map { .init($0.0, $0.1) }, auth: .bearer)
    }

    private func json<V: Codable & Sendable>(_ plan: RequestPlan, tags: Set<InvalidationTag>, freshness: FreshnessClass,
                                              harvest: (@Sendable (V) -> [Crosswalk])? = nil) -> Resource<V> {
        .json(plan, tags: tags, freshness: freshness, decoder: WireCodec.snakeCaseDecoder, harvest: harvest)
    }

    private func movieTag(_ id: Int) -> InvalidationTag { .identity(.tmdbMovie(id)) }
    private func tvTag(_ id: Int) -> InvalidationTag { .identity(.tmdbSeries(id)) }
    private func personTag(_ id: Int) -> InvalidationTag { .identity(.tmdbPerson(id)) }

    public func configuration() -> Resource<TMDBConfiguration> {
        json(plan("testConnection", path: "/configuration"), tags: [.capabilities(instance)], freshness: .reference)
    }

    public func searchPerson(query: String) -> Resource<TMDBPage<TMDBPerson>> {
        json(plan("searchPerson", path: "/search/person", query: [("query", query)]), tags: [.collection(.lookup, instance)], freshness: .live)
    }

    public func movie(id: Int) -> Resource<TMDBDetails> {
        json(plan("movieCountries", path: "/movie/{id}", values: ["id": String(id)]), tags: [movieTag(id)], freshness: .archival)
    }
    public func movieCredits(id: Int) -> Resource<TMDBCredits> {
        json(plan("movieCredits", path: "/movie/{id}/credits", values: ["id": String(id)]), tags: [movieTag(id)], freshness: .archival)
    }
    public func movieVideos(id: Int) -> Resource<TMDBVideos> {
        json(plan("movieVideos", path: "/movie/{id}/videos", values: ["id": String(id)]), tags: [movieTag(id)], freshness: .archival)
    }
    public func movieRecommendations(id: Int, page: Int = 1) -> Resource<TMDBPage<TMDBMovieSummary>> {
        json(plan("recommendedMovies", path: "/movie/{id}/recommendations", values: ["id": String(id)], query: [("page", String(page))]), tags: [movieTag(id)], freshness: .warm)
    }

    public func tv(id: Int) -> Resource<TMDBDetails> {
        json(plan("tvCountries", path: "/tv/{id}", values: ["id": String(id)]), tags: [tvTag(id)], freshness: .archival)
    }
    public func tvCredits(id: Int) -> Resource<TMDBCredits> {
        json(plan("tvCredits", path: "/tv/{id}/aggregate_credits", values: ["id": String(id)]), tags: [tvTag(id)], freshness: .archival)
    }
    /// One episode's record — the only place TMDB carries a per-EPISODE score
    /// (`vote_average`). The series' own rating says nothing about the episode
    /// on screen, and Sonarr/TVDB ship no episode rating at all.
    public func tvEpisode(id: Int, season: Int, episode: Int) -> Resource<TMDBEpisode> {
        json(plan("tvEpisode", path: "/tv/{id}/season/{season}/episode/{episode}",
                  values: ["id": String(id), "season": String(season), "episode": String(episode)]),
             tags: [tvTag(id)], freshness: .warm)
    }
    public func tvVideos(id: Int) -> Resource<TMDBVideos> {
        json(plan("tvVideos", path: "/tv/{id}/videos", values: ["id": String(id)]), tags: [tvTag(id)], freshness: .archival)
    }
    public func tvRecommendations(id: Int, page: Int = 1) -> Resource<TMDBPage<TMDBTVSummary>> {
        json(plan("recommendedTV", path: "/tv/{id}/recommendations", values: ["id": String(id)], query: [("page", String(page))]), tags: [tvTag(id)], freshness: .warm)
    }
    public func tvExternalIDs(id: Int) -> Resource<TMDBExternalIDs> {
        json(plan("tvdbIdFromTVId", path: "/tv/{id}/external_ids", values: ["id": String(id)]), tags: [tvTag(id)], freshness: .archival, harvest: { ids in
            ExternalIDParsing.tmdbExternalIDs(imdb: ids.imdbId, tvdb: ids.tvdbId)
                .map { Crosswalk(from: .tmdbSeries(id), to: $0, kind: .series, confidence: .asserted, source: .tmdbExternalIDs, fetchedAt: Date()) }
        })
    }
    public func find(tvdbID: Int) -> Resource<TMDBFind> {
        json(plan("tvIdFromTVDB", path: "/find/{id}", values: ["id": String(tvdbID)], query: [("external_source", "tvdb_id")]), tags: [.identity(.tvdb(tvdbID))], freshness: .archival, harvest: { found in
            found.tvResults.prefix(1).map { Crosswalk(from: .tvdb(tvdbID), to: .tmdbSeries($0.id), kind: .series, confidence: .asserted, source: .tmdbFind, fetchedAt: Date()) }
        })
    }

    /// `language` overrides the account's; an empty biography in the user's language is retried in English.
    public func person(id: Int, language: String? = nil) -> Resource<TMDBPersonDetails> {
        json(plan("personDetails", path: "/person/{id}", values: ["id": String(id)], query: language.map { [("language", $0)] } ?? []),
             tags: [personTag(id)], freshness: .archival)
    }
    public func personMovieCredits(id: Int) -> Resource<TMDBPersonCredits<TMDBMovieSummary>> {
        json(plan("personMovieCredits", path: "/person/{id}/movie_credits", values: ["id": String(id)]), tags: [personTag(id)], freshness: .archival)
    }
    public func personTVCredits(id: Int) -> Resource<TMDBPersonCredits<TMDBTVSummary>> {
        json(plan("personTVCredits", path: "/person/{id}/tv_credits", values: ["id": String(id)]), tags: [personTag(id)], freshness: .archival)
    }

    public func discoverMovies(sort: String = "popularity.desc", minVotes: Int = 100, page: Int = 1, extra: [(String, String)] = []) -> Resource<TMDBPage<TMDBMovieSummary>> {
        let query = [("include_adult", "false"), ("sort_by", sort), ("vote_count.gte", String(minVotes)), ("page", String(page))] + extra
        return json(plan("discoverMovies", path: "/discover/movie", query: query), tags: [.collection(.lookup, instance)], freshness: .warm)
    }
    public func discoverTV(sort: String = "popularity.desc", minVotes: Int = 100, page: Int = 1, extra: [(String, String)] = []) -> Resource<TMDBPage<TMDBTVSummary>> {
        let query = [("include_adult", "false"), ("sort_by", sort), ("vote_count.gte", String(minVotes)), ("page", String(page))] + extra
        return json(plan("discoverTV", path: "/discover/tv", query: query), tags: [.collection(.lookup, instance)], freshness: .warm)
    }

    /// `image.tmdb.org` never carries a credential.
    public func artwork(path: String?, kind: ArtworkReference.Kind) -> ArtworkReference? {
        guard let path, !path.isEmpty else { return nil }
        let normalized = path.hasPrefix("/") ? path : "/" + path
        return ArtworkReference(url: Self.imageBase.appendingPathComponent("t/p/original" + normalized), sizing: .tmdbCDN(path: normalized), kind: kind)
    }

    /// v4 read access tokens are JWTs; v3 keys are 32 hex characters.
    public static func isReadAccessToken(_ secret: String) -> Bool { secret.hasPrefix("eyJ") || secret.contains(".") }
}
