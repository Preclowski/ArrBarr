import Foundation
import MediaKit

extension LocalToolBackend {
    // MARK: - TMDB tools

    func tmdbSearchPerson(_ args: JSONValue) async throws -> ToolCallOutput {
        let wantedKind = CreditsKind(Self.stringArg(args, key: "credits").lowercased())

        // Straight to the filmography when the caller already resolved the person.
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
        let client = tmdbClient
        // TMDB's own order often puts namesakes above the obvious answer.
        let results = PersonRelevance.rank(try await client.searchPerson(query: query), query: query)
        guard !results.isEmpty else {
            return ToolCallOutput(text: "No people found on TMDB for '\(query)'.")
        }
        // Only on a confident match; answering "films with X" from the wrong X is worse than another round.
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
        // The tail of a person search is noise; the model still sees all eight in the text.
        return ToolCallOutput(text: out, rich: .people(top.prefix(4).map(ChatPerson.init)))
    }

    /// One kind per call: different TMDB endpoints and cards, and a merged rail would mix poster auth.
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

    /// Best effort: a filmography is still a good answer without the header.
    private func personCard(_ personId: Int) async -> ChatPerson? {
        let client = tmdbClient
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

    func movieCreditsOutput(personId: Int) async throws -> ToolCallOutput {
        let client = tmdbClient
        async let card = personCard(personId)
        let credits = try await client.personMovieCredits(personId: personId).cast
        // TMDB returns credits unordered; voteAverage favours niche cameos with a handful of votes.
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

    func tvCreditsOutput(personId: Int) async throws -> ToolCallOutput {
        let client = tmdbClient
        async let card = personCard(personId)
        let credits = try await client.personTVCredits(personId: personId).cast
        let ranked = PersonCreditMerge.byPopularity(credits)
        let libraryMap = await sonarrLibraryByTMDBId()
        let results = TMDBSearchMapping.series(ranked.prefix(25), libraryMap: libraryMap)
        guard !results.isEmpty else {
            return ToolCallOutput(text: "TMDB returned no TV credits for personId \(personId).")
        }
        let text = Self.formatTMDBSummary(results, kind: "series", origin: "personId \(personId)")
        return ToolCallOutput(text: text, rich: Self.creditsRich(person: await card, results: results))
    }

    nonisolated static func creditsRich(person: ChatPerson?, results: [SearchResult]) -> ChatRichContent {
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
        let client = tmdbClient
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
        let client = tmdbClient
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

    func radarrLibraryByTMDBId() async -> [Int: LibraryOwnership] {
        await ArrLibraryMaps.radarrByTMDBId(config: radarr)
    }

    func sonarrLibraryByTVDBId() async -> [Int: LibraryOwnership] {
        await ArrLibraryMaps.sonarrByTVDBId(config: sonarr)
    }

    /// An id join, not title + year, which could mistake a remake for the owned show.
    func sonarrLibraryByTMDBId() async -> [Int: LibraryOwnership] {
        await ArrLibraryMaps.sonarrByTMDBId(config: sonarr)
    }

    nonisolated static func formatTMDBSummary(_ results: [SearchResult], kind: String, origin: String) -> String {
        let ownedCount = results.filter { $0.inLibraryArrId != nil }.count
        var out = "TMDB returned \(results.count) \(kind) result\(results.count == 1 ? "" : "s") (\(origin))."
        if ownedCount > 0 {
            out += " \(ownedCount) already in the user's library (marked OWNED)."
        }
        out += " Top:"
        // Every result: the tail is where the model ran out of ids and started inventing them.
        for r in results {
            let year = r.year.map { " (\($0))" } ?? ""
            let rating = r.rating.map { String(format: " ★%.1f", $0) } ?? ""
            // WATCHED only on a positive: the index knows nothing about unowned titles.
            let watched = MediaServerIndex.shared.isWatched(r.mediaServerKeys) ? " [WATCHED]" : ""
            let owned = r.inLibraryArrId != nil ? " [OWNED]\(watched)" : ""
            // The ref scheme the search bar and deep links accept; TMDB series print `tmdbtv:N`.
            let ref = r.mediaRef.isAddressable ? r.mediaRef.urlString : "n/a"
            out += "\n- \(r.title)\(year)\(rating)\(owned) — \(ref)"
        }
        return out
    }

    nonisolated static func knownMovieGenres() -> String {
        ["action", "comedy", "crime", "documentary", "drama", "fantasy",
         "horror", "mystery", "romance", "science fiction", "thriller", "western"]
            .joined(separator: ", ")
    }

    nonisolated static func knownTVGenres() -> String {
        ["animation", "comedy", "crime", "documentary", "drama",
         "mystery", "reality", "sci-fi & fantasy", "war & politics", "western"]
            .joined(separator: ", ")
    }

}
