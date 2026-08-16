import Foundation

// TMDB-backed discovery tools (person search, person credits, discover-by-genre)
// plus the TMDB → SearchResult adapters and the genre fallback lists.

extension LocalToolBackend {
    // MARK: - TMDB tools

    func tmdbSearchPerson(_ args: JSONValue) async throws -> ToolCallOutput {
        let wantedKind = CreditsKind(Self.stringArg(args, key: "credits").lowercased())

        // Straight to the filmography when the caller already resolved the
        // person. This is the disambiguation follow-up — and the reason there
        // is one person tool instead of three.
        let givenId = Self.intArg(args, key: "personId")
        if givenId > 0 {
            guard let kind = wantedKind else {
                return ToolCallOutput(text: "personId given without `credits` — say 'movies' or 'series', or drop personId and pass a name in `query`.")
            }
            return try await personCredits(kind: kind, personId: givenId)
        }

        let query = Self.stringArg(args, key: "query")
        guard !query.isEmpty else {
            return ToolCallOutput(text: "Please provide a person name to search for.")
        }
        let client = TMDBClient(apiKey: tmdbApiKey)
        // TMDB's own result order puts namesakes above the obvious answer often
        // enough to matter; `PersonRelevance` is the ranking the search surface
        // already trusts for "which person did they mean".
        let results = PersonRelevance.rank(try await client.searchPerson(query: query), query: query)
        guard !results.isEmpty else {
            return ToolCallOutput(text: "No people found on TMDB for '\(query)'.")
        }
        // Name → filmography in one call. Gated on `isConfidentHeadliner`: every
        // query token covered by the name and a popularity that rules out an
        // incidental namesake. Anything less and we hand back the candidate list
        // instead — answering "films with X" from the wrong X is worse than
        // costing the model one more round.
        if let kind = wantedKind, let best = results.first,
           PersonRelevance.isConfidentHeadliner(best, query: query) {
            let credits = try await personCredits(kind: kind, personId: best.id)
            var head = "Resolved '\(query)' → \(best.name) (personId: \(best.id))."
            let others = results.dropFirst().prefix(3)
            if !others.isEmpty {
                head += " Other people share this name: "
                head += others.map { "\($0.name) (personId: \($0.id))" }.joined(separator: ", ")
                head += ". If the user meant one of them, call the credits tool with that id."
            }
            return ToolCallOutput(text: head + "\n" + credits.text, rich: credits.rich)
        }

        let top = results.prefix(8)
        var out = "Top \(top.count) match\(top.count == 1 ? "" : "es") for '\(query)' (call again with personId + credits for the one they meant):"
        for p in top {
            let dept = p.knownForDepartment.map { " (\($0))" } ?? ""
            out += "\n- \(p.name)\(dept) — personId: \(p.id)"
        }
        if wantedKind != nil {
            out += "\nThe name did not resolve to one obvious person, so no credits were fetched — call this tool again with personId + credits for the one the user meant, or ask them which."
        }
        // Cards for the top few only: the tail of a person search is noise
        // (same name, no photo, popularity ~0) and the model still sees all
        // eight in the text.
        return ToolCallOutput(text: out, rich: .people(top.prefix(4).map(ChatPerson.init)))
    }

    /// Which filmography the `credits` argument asks for. Deliberately one kind
    /// per call — the two live behind different TMDB endpoints and render as
    /// different cards, and a merged rail would have to pick one arr's poster
    /// auth for both.
    enum CreditsKind {
        case movies, series

        init?(_ raw: String) {
            switch raw {
            case "movies", "movie", "films", "film": self = .movies
            case "series", "tv", "shows", "show":    self = .series
            default: return nil
            }
        }
    }

    func personCredits(kind: CreditsKind, personId: Int) async throws -> ToolCallOutput {
        switch kind {
        case .movies: return try await movieCreditsOutput(personId: personId)
        case .series: return try await tvCreditsOutput(personId: personId)
        }
    }

    /// The person behind a credits call, for the card above the carousel. Best
    /// effort: `/person/{id}` is a second request, and a filmography is still a
    /// perfectly good answer without the header, so a failure here degrades to
    /// the plain carousel rather than failing the tool.
    private func personCard(_ personId: Int) async -> ChatPerson? {
        let client = TMDBClient(apiKey: tmdbApiKey)
        guard let details = try? await client.personDetails(personId: personId) else { return nil }
        return ChatPerson(details)
    }

    func tmdbPersonMovieCredits(_ args: JSONValue) async throws -> ToolCallOutput {
        let personId = Self.intArg(args, key: "personId")
        guard personId != 0 else {
            return ToolCallOutput(text: "Need a personId — run tmdb_search_person first.")
        }
        return try await movieCreditsOutput(personId: personId)
    }

    /// The movie filmography itself, reachable both as its own tool and as
    /// `tmdb_search_person(credits:)`'s second half.
    func movieCreditsOutput(personId: Int) async throws -> ToolCallOutput {
        let client = TMDBClient(apiKey: tmdbApiKey)
        // Person details and credits are independent — fetch them together so
        // the card costs latency only if TMDB is slow on that one endpoint.
        async let card = personCard(personId)
        let credits = try await client.personMovieCredits(personId: personId).cast
        // TMDB returns credits unordered. Rank by `popularity` (TMDB's own
        // "what people are searching/watching" metric) descending — voteAverage
        // is misleading here because Sandler's best-rated entries are 7.5+
        // niche cameos with a handful of votes, not Happy Gilmore (6.0, 4k
        // votes). Tie-break on year desc so recent stuff floats.
        let ranked = PersonCreditMerge.byPopularity(credits)
        let libraryMap = await radarrLibraryByTMDBId()
        let results = TMDBSearchMapping.movies(ranked.prefix(25), libraryMap: libraryMap)
        guard !results.isEmpty else {
            return ToolCallOutput(text: "TMDB returned no movie credits for personId \(personId).")
        }
        let text = Self.formatTMDBSummary(results, kind: "movie", origin: "personId \(personId)")
        return ToolCallOutput(text: text, rich: Self.creditsRich(person: await card, results: results))
    }

    func tmdbPersonTVCredits(_ args: JSONValue) async throws -> ToolCallOutput {
        let personId = Self.intArg(args, key: "personId")
        guard personId != 0 else {
            return ToolCallOutput(text: "Need a personId — run tmdb_search_person first.")
        }
        return try await tvCreditsOutput(personId: personId)
    }

    /// The TV filmography — see `movieCreditsOutput` for the shared shape.
    func tvCreditsOutput(personId: Int) async throws -> ToolCallOutput {
        let client = TMDBClient(apiKey: tmdbApiKey)
        async let card = personCard(personId)
        let credits = try await client.personTVCredits(personId: personId).cast
        // Same popularity-desc ranking rationale as the movie path — see
        // tmdbPersonMovieCredits for why voteAverage is the wrong key here.
        let ranked = PersonCreditMerge.byPopularity(credits)
        let libraryMap = await sonarrLibraryByTMDBId()
        let results = TMDBSearchMapping.series(ranked.prefix(25), libraryMap: libraryMap)
        guard !results.isEmpty else {
            return ToolCallOutput(text: "TMDB returned no TV credits for personId \(personId).")
        }
        let text = Self.formatTMDBSummary(results, kind: "series", origin: "personId \(personId)")
        return ToolCallOutput(text: text, rich: Self.creditsRich(person: await card, results: results))
    }

    /// Credits payload: with the person when TMDB details came back, the plain
    /// carousel when they didn't. Thin alias over the model's own factory, which
    /// the card de-duplicator reuses.
    static func creditsRich(person: ChatPerson?, results: [SearchResult]) -> ChatRichContent {
        .credits(person: person, results: results)
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
        let results = TMDBSearchMapping.movies(movies.prefix(25), libraryMap: libraryMap)
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
        let libraryMap = await sonarrLibraryByTMDBId()
        let results = TMDBSearchMapping.series(shows.prefix(25), libraryMap: libraryMap)
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

    // MARK: - Library ownership maps
    //
    // The TMDB summary → SearchResult mapping itself lives in
    // `TMDBSearchMapping` (shared with the person view); these build the
    // library maps that mapping consumes to tag owned results.

    /// `tmdbId → movie.id` for the Radarr library — tags owned TMDB results.
    /// Thin wrapper over the shared `ArrLibraryMaps` (also used by the person
    /// view) so the two build the map identically.
    func radarrLibraryByTMDBId() async -> [Int: Int] {
        await ArrLibraryMaps.radarrByTMDBId(config: radarr)
    }

    /// `tvdbId → series.id` for the Sonarr library. See `ArrLibraryMaps`.
    func sonarrLibraryByTVDBId() async -> [Int: Int] {
        await ArrLibraryMaps.sonarrByTVDBId(config: sonarr)
    }

    /// `tmdbId → series.id` for the Sonarr library — what tags TMDB-sourced
    /// series as owned. The id route is open now that `SonarrLibraryRecord`
    /// decodes `tmdbId`; this replaced a normalized title + year join that
    /// could mistake a remake for the show the user actually has.
    func sonarrLibraryByTMDBId() async -> [Int: Int] {
        await ArrLibraryMaps.sonarrByTMDBId(config: sonarr)
    }

    static func formatTMDBSummary(_ results: [SearchResult], kind: String, origin: String) -> String {
        let ownedCount = results.filter { $0.inLibraryArrId != nil }.count
        var out = "TMDB returned \(results.count) \(kind) result\(results.count == 1 ? "" : "s") (\(origin))."
        if ownedCount > 0 {
            out += " \(ownedCount) already in the user's library (marked OWNED)."
        }
        out += " Top:"
        // Every result, not the first 15: the tail of the list is exactly where
        // the model used to run out of ids and start inventing them.
        for r in results {
            let year = r.year.map { " (\($0))" } ?? ""
            let rating = r.rating.map { String(format: " ★%.1f", $0) } ?? ""
            // WATCHED only ever appears on a positive: the index knows nothing
            // about titles the user doesn't own, and an absent marker must not
            // be read as "not seen".
            let watched = MediaServerIndex.shared.isWatched(r.mediaServerKeys) ? " [WATCHED]" : ""
            let owned = r.inLibraryArrId != nil ? " [OWNED]\(watched)" : ""
            // MediaRef url form ("tmdb:12345") matches what the user
            // can type into the search bar verbatim, and what the
            // deep-link layer expects — one canonical string scheme
            // for external IDs across read and write paths.
            // TMDB series print `tmdbtv:N` — their own id space, resolved to a
            // tvdbId only when something opens them. Before that case existed
            // they printed "n/a", which meant the model had nothing to link a
            // series with. Still "n/a" for a row that can't identify itself at
            // all, rather than a `tvdb:0` that names nothing.
            let ref = r.mediaRef.isAddressable ? r.mediaRef.urlString : "n/a"
            out += "\n- \(r.title)\(year)\(rating)\(owned) — \(ref)"
        }
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
