import Foundation

// TMDB-backed discovery tools (person search, person credits, discover-by-genre)
// plus the TMDB → SearchResult adapters and the genre fallback lists.

extension LocalToolBackend {
    // MARK: - TMDB tools

    func tmdbSearchPerson(_ args: JSONValue) async throws -> ToolCallOutput {
        let query = Self.stringArg(args, key: "query")
        guard !query.isEmpty else {
            return ToolCallOutput(text: "Please provide a person name to search for.")
        }
        let client = TMDBClient(apiKey: tmdbApiKey)
        let results = try await client.searchPerson(query: query)
        guard !results.isEmpty else {
            return ToolCallOutput(text: "No people found on TMDB for '\(query)'.")
        }
        let top = results.prefix(8)
        var out = "Top \(top.count) match\(top.count == 1 ? "" : "es") for '\(query)' (pass personId to tmdb_person_movie_credits or tmdb_person_tv_credits):"
        for p in top {
            let dept = p.knownForDepartment.map { " (\($0))" } ?? ""
            out += "\n- \(p.name)\(dept) — personId: \(p.id)"
        }
        return ToolCallOutput(text: out)
    }

    func tmdbPersonMovieCredits(_ args: JSONValue) async throws -> ToolCallOutput {
        let personId = Self.intArg(args, key: "personId")
        guard personId != 0 else {
            return ToolCallOutput(text: "Need a personId — run tmdb_search_person first.")
        }
        let client = TMDBClient(apiKey: tmdbApiKey)
        let credits = try await client.personMovieCredits(personId: personId)
        // TMDB returns credits unordered. Rank by `popularity` (TMDB's own
        // "what people are searching/watching" metric) descending — voteAverage
        // is misleading here because Sandler's best-rated entries are 7.5+
        // niche cameos with a handful of votes, not Happy Gilmore (6.0, 4k
        // votes). Tie-break on year desc so recent stuff floats.
        let ranked = credits.sorted { lhs, rhs in
            let lp = lhs.popularity ?? 0
            let rp = rhs.popularity ?? 0
            if lp != rp { return lp > rp }
            return (lhs.year ?? 0) > (rhs.year ?? 0)
        }
        let libraryMap = await radarrLibraryByTMDBId()
        let results = Self.tmdbMoviesToSearchResults(ranked.prefix(25), libraryMap: libraryMap)
        guard !results.isEmpty else {
            return ToolCallOutput(text: "TMDB returned no movie credits for personId \(personId).")
        }
        let text = Self.formatTMDBSummary(results, kind: "movie", origin: "personId \(personId)")
        return ToolCallOutput(text: text, rich: .searchMovieResults(results))
    }

    func tmdbPersonTVCredits(_ args: JSONValue) async throws -> ToolCallOutput {
        let personId = Self.intArg(args, key: "personId")
        guard personId != 0 else {
            return ToolCallOutput(text: "Need a personId — run tmdb_search_person first.")
        }
        let client = TMDBClient(apiKey: tmdbApiKey)
        let credits = try await client.personTVCredits(personId: personId)
        // Same popularity-desc ranking rationale as the movie path — see
        // tmdbPersonMovieCredits for why voteAverage is the wrong key here.
        let ranked = credits.sorted { lhs, rhs in
            let lp = lhs.popularity ?? 0
            let rp = rhs.popularity ?? 0
            if lp != rp { return lp > rp }
            return (lhs.year ?? 0) > (rhs.year ?? 0)
        }
        let results = Self.tmdbTVToSearchResults(ranked.prefix(25))
        guard !results.isEmpty else {
            return ToolCallOutput(text: "TMDB returned no TV credits for personId \(personId).")
        }
        let text = Self.formatTMDBSummary(results, kind: "series", origin: "personId \(personId)")
        return ToolCallOutput(text: text, rich: .searchSeriesResults(results))
    }

    func tmdbDiscoverMovies(_ args: JSONValue) async throws -> ToolCallOutput {
        let genreToken = Self.stringArg(args, key: "genre")
        let startYear = Self.optionalIntArg(args, key: "startYear")
        let endYear = Self.optionalIntArg(args, key: "endYear")
        let sortBy = Self.stringArg(args, key: "sortBy")
        let resolvedSort = sortBy.isEmpty ? "popularity.desc" : sortBy
        var genreIds: [Int] = []
        if !genreToken.isEmpty {
            if let id = TMDBGenres.movieId(for: genreToken) {
                genreIds = [id]
            } else {
                return ToolCallOutput(text: "Unknown movie genre '\(genreToken)'. Try: \(Self.knownMovieGenres()).")
            }
        }
        let client = TMDBClient(apiKey: tmdbApiKey)
        let movies = try await client.discoverMovies(
            genreIds: genreIds, startYear: startYear, endYear: endYear, sortBy: resolvedSort
        )
        let libraryMap = await radarrLibraryByTMDBId()
        let results = Self.tmdbMoviesToSearchResults(movies.prefix(25), libraryMap: libraryMap)
        guard !results.isEmpty else {
            return ToolCallOutput(text: "TMDB returned no movies matching that filter.")
        }
        let descParts = [
            genreToken.isEmpty ? nil : "genre=\(genreToken)",
            startYear.map { "from \($0)" },
            endYear.map { "to \($0)" },
        ].compactMap { $0 }
        let origin = descParts.isEmpty ? "discover" : descParts.joined(separator: ", ")
        let text = Self.formatTMDBSummary(results, kind: "movie", origin: origin)
        return ToolCallOutput(text: text, rich: .searchMovieResults(results))
    }

    func tmdbDiscoverSeries(_ args: JSONValue) async throws -> ToolCallOutput {
        let genreToken = Self.stringArg(args, key: "genre")
        let startYear = Self.optionalIntArg(args, key: "startYear")
        let endYear = Self.optionalIntArg(args, key: "endYear")
        let sortBy = Self.stringArg(args, key: "sortBy")
        let resolvedSort = sortBy.isEmpty ? "popularity.desc" : sortBy
        var genreIds: [Int] = []
        if !genreToken.isEmpty {
            if let id = TMDBGenres.tvId(for: genreToken) {
                genreIds = [id]
            } else {
                return ToolCallOutput(text: "Unknown TV genre '\(genreToken)'. Try: \(Self.knownTVGenres()).")
            }
        }
        let client = TMDBClient(apiKey: tmdbApiKey)
        let shows = try await client.discoverTV(
            genreIds: genreIds, startYear: startYear, endYear: endYear, sortBy: resolvedSort
        )
        let results = Self.tmdbTVToSearchResults(shows.prefix(25))
        guard !results.isEmpty else {
            return ToolCallOutput(text: "TMDB returned no series matching that filter.")
        }
        let descParts = [
            genreToken.isEmpty ? nil : "genre=\(genreToken)",
            startYear.map { "from \($0)" },
            endYear.map { "to \($0)" },
        ].compactMap { $0 }
        let origin = descParts.isEmpty ? "discover" : descParts.joined(separator: ", ")
        let text = Self.formatTMDBSummary(results, kind: "series", origin: origin)
        return ToolCallOutput(text: text, rich: .searchSeriesResults(results))
    }

    // MARK: - TMDB → SearchResult adapters

    /// Build `SearchResult`s the rest of the UI already knows how to render
    /// (poster carousel, tap → SearchAddPanel for adds). Movie `id` carries
    /// the tmdbId — Radarr's add path takes it as-is. `libraryMap` maps
    /// tmdbId → Radarr movie id so already-owned results get tagged with
    /// `inLibraryArrId` — the UI then routes the tap to DetailView instead
    /// of the add flow.
    static func tmdbMoviesToSearchResults(
        _ movies: some Sequence<TMDBMovieSummary>,
        libraryMap: [Int: Int] = [:]
    ) -> [SearchResult] {
        movies.map { m in
            SearchResult(
                id: m.id,
                foreignId: String(m.id),
                title: m.title,
                subtitle: nil,
                year: m.year,
                rating: m.voteAverage,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: m.overview,
                runtime: nil,
                genres: TMDBGenres.movieNames(for: m.genreIds ?? []),
                network: nil,
                certification: nil,
                posterURL: TMDBClient.imageURL(path: m.posterPath),
                source: .radarr,
                inLibraryArrId: libraryMap[m.id]
            )
        }
    }

    /// Build a `tmdbId → movie.id` map of the Radarr library so TMDB-sourced
    /// results can be tagged as "owned" without each result paying for its
    /// own lookup. Returns an empty map if Radarr isn't configured or the
    /// fetch fails — callers should still proceed (owned status just won't be
    /// shown). Demo mode handled by RadarrClient.fetchAllMovies.
    func radarrLibraryByTMDBId() async -> [Int: Int] {
        guard radarr.isConfigured else { return [:] }
        let client = RadarrClient(config: radarr)
        guard let library = try? await client.fetchAllMovies() else { return [:] }
        var map: [Int: Int] = [:]
        for rec in library {
            if let tmdb = rec.tmdbId, let arrId = rec.id {
                map[tmdb] = arrId
            }
        }
        return map
    }

    /// Sonarr equivalent: `tvdbId → series.id`. Used by `suggest_titles`
    /// to tag series the user already has, so card taps route to
    /// DetailView instead of trying to add a duplicate. TMDB-discover
    /// series can't use this directly because TMDB-TV ids aren't TVDB
    /// ids — only flows that resolved through Sonarr's own lookup (with
    /// real tvdbIds) can cross-reference here.
    func sonarrLibraryByTVDBId() async -> [Int: Int] {
        guard sonarr.isConfigured else { return [:] }
        let client = SonarrClient(config: sonarr)
        guard let library = try? await client.fetchAllSeries() else { return [:] }
        var map: [Int: Int] = [:]
        for rec in library {
            if let tvdb = rec.tvdbId, let arrId = rec.id {
                map[tvdb] = arrId
            }
        }
        return map
    }

    /// TV path is fuzzier: Sonarr indexes by tvdbId, but TMDB exposes its own
    /// tv id. We stash 0 in `id` so the add-tap path falls back to a title
    /// lookup — Sonarr resolves the right tvdbId at add-time. Good enough for
    /// popular titles; ambiguous ones surface in SearchAddPanel for review.
    static func tmdbTVToSearchResults(_ shows: some Sequence<TMDBTVSummary>) -> [SearchResult] {
        shows.map { s in
            SearchResult(
                id: 0,
                foreignId: "",
                title: s.name,
                subtitle: nil,
                year: s.year,
                rating: s.voteAverage,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: s.overview,
                runtime: nil,
                genres: TMDBGenres.tvNames(for: s.genreIds ?? []),
                network: nil,
                certification: nil,
                posterURL: TMDBClient.imageURL(path: s.posterPath),
                source: .sonarr
            )
        }
    }

    static func formatTMDBSummary(_ results: [SearchResult], kind: String, origin: String) -> String {
        let ownedCount = results.filter { $0.inLibraryArrId != nil }.count
        var out = "TMDB returned \(results.count) \(kind) result\(results.count == 1 ? "" : "s") (\(origin))."
        if ownedCount > 0 {
            out += " \(ownedCount) already in the user's library (marked OWNED)."
        }
        out += " Top:"
        for r in results.prefix(15) {
            let year = r.year.map { " (\($0))" } ?? ""
            let rating = r.rating.map { String(format: " ★%.1f", $0) } ?? ""
            let owned = r.inLibraryArrId != nil ? " [OWNED]" : ""
            // MediaRef url form ("tmdb:12345") matches what the user
            // can type into the search bar verbatim, and what the
            // deep-link layer expects — one canonical string scheme
            // for external IDs across read and write paths.
            let ref = r.id == 0 ? "n/a" : r.mediaRef.urlString
            out += "\n- \(r.title)\(year)\(rating)\(owned) — \(ref)"
        }
        if results.count > 15 { out += "\n…and \(results.count - 15) more." }
        return out
    }

    static func knownMovieGenres() -> String {
        ["action", "comedy", "crime", "documentary", "drama", "fantasy",
         "horror", "mystery", "romance", "science fiction", "thriller", "western"]
            .joined(separator: ", ")
    }

    static func knownTVGenres() -> String {
        ["animation", "comedy", "crime", "documentary", "drama",
         "mystery", "reality", "sci-fi & fantasy", "war & politics", "western"]
            .joined(separator: ", ")
    }

}
