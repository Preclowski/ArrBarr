import Foundation

public enum DiscoverSources {

    // MARK: - TMDB Movie source

    /// TMDB Discover source for movies. Skips anything already in the local
    /// Radarr library. Each card is enriched via a Radarr tmdbId lookup to
    /// get IMDb/RT/MC ratings, runtime, certification, genres, and studio.
    @MainActor
    public static func tmdbMovies(
        apiKey: String,
        radarrClient: RadarrClient,
        libraryTmdbIds: @escaping @MainActor () -> Set<Int>
    ) -> DiscoverViewModel.TMDBSource {
        let client = TMDBClient(apiKey: apiKey)
        return { filter, _ in
            let range = filter.decade.range
            let genreIds = filter.genres.map(\.rawValue)
            let voteCount = filter.rating == .cultFavorite ? 500 : 50
            let summaries = try await client.discoverMovies(
                genreIds: genreIds,
                startYear: range?.lowerBound,
                endYear: range?.upperBound,
                sortBy: "popularity.desc",
                minVoteCount: voteCount,
                voteAverageGte: filter.rating.minRating,
                runtimeLte: filter.runtime.lessThan,
                runtimeGte: filter.runtime.greaterThan,
                personIds: filter.personIds
            )
            let owned = libraryTmdbIds()
            var out: [DiscoverItem] = []
            for s in summaries {
                if owned.contains(s.id) { continue }
                // Enrich with Radarr's tmdbId lookup — gives us IMDb, RT, MC,
                // runtime, certification, genres, studio. One extra HTTP call
                // per shown TMDB card. Library hits are unaffected.
                let term = s.year.map { "\(s.title) \($0)" } ?? s.title
                let hits = (try? await radarrClient.lookupMovies(term: term)) ?? []
                let enriched = hits.first(where: { $0.tmdbId == s.id }) ?? hits.first
                let enrichedPoster: URL? = enriched.flatMap { posterURL(from: $0.images) }
                    ?? TMDBClient.imageURL(path: s.posterPath)
                let result = SearchResult(
                    id: s.id, foreignId: String(s.id),
                    title: s.title, subtitle: nil,
                    year: s.year,
                    rating: enriched?.ratings?.tmdb?.value ?? s.voteAverage,
                    imdb: enriched?.ratings?.imdb?.value,
                    rottenTomatoes: enriched?.ratings?.rottenTomatoes?.value,
                    metacritic: enriched?.ratings?.metacritic?.value,
                    overview: enriched?.overview ?? s.overview,
                    runtime: enriched?.runtime,
                    genres: enriched?.genres ?? [],
                    network: enriched?.studio,
                    certification: enriched?.certification,
                    posterURL: enrichedPoster,
                    source: .radarr,
                    inLibraryArrId: nil
                )
                out.append(DiscoverItem(result: result, action: .addToRadarr,
                                        originLabel: .tmdb, kind: .movie))
            }
            return out
        }
    }

    // MARK: - TMDB TV source

    /// TMDB Discover source for TV shows. Skips anything already in the
    /// local Sonarr library (matched by TVDB id).
    @MainActor
    public static func tmdbShows(
        apiKey: String,
        libraryTvdbIds: @escaping @MainActor () -> Set<Int>
    ) -> DiscoverViewModel.TMDBSource {
        let client = TMDBClient(apiKey: apiKey)
        return { filter, _ in
            let range = filter.decade.range
            // TMDB TV genres use the same numeric IDs as movies for most
            // genres — we reuse DiscoverGenre.rawValue here.
            let genreIds = filter.genres.map(\.rawValue)
            let voteCount = filter.rating == .cultFavorite ? 500 : 20
            let summaries = try await client.discoverTV(
                genreIds: genreIds,
                startYear: range?.lowerBound,
                endYear: range?.upperBound,
                sortBy: "popularity.desc",
                minVoteCount: voteCount,
                voteAverageGte: filter.rating.minRating
            )
            let owned = libraryTvdbIds()
            return summaries.compactMap { s -> DiscoverItem? in
                // TMDB TV ids are not TVDB ids, so we can't filter owned
                // by id here — just surface all and let action handle it.
                _ = owned
                let result = SearchResult(
                    id: s.id, foreignId: String(s.id),
                    title: s.name, subtitle: nil,
                    year: s.year,
                    rating: s.voteAverage,
                    imdb: nil, rottenTomatoes: nil, metacritic: nil,
                    overview: s.overview, runtime: nil,
                    genres: [], network: nil, certification: nil,
                    posterURL: TMDBClient.imageURL(path: s.posterPath),
                    source: .sonarr, inLibraryArrId: nil
                )
                return DiscoverItem(result: result, action: .addToSonarr,
                                    originLabel: .tmdb, kind: .show)
            }
        }
    }

    // MARK: - Radarr Library source

    /// Radarr library source. Caller supplies the async fetch so
    /// PopoverContentView can cache the list across sources.
    @MainActor
    public static func radarrLibrary(
        fetchAll: @escaping @MainActor () async throws -> [RadarrLibraryRecord]
    ) -> DiscoverViewModel.LibrarySource {
        return { filter in
            let all = try await fetchAll()
            let filtered = all.filter { rec in
                filter.matches(year: rec.year, monitored: rec.monitored,
                               hasFile: rec.hasFile, genres: rec.genres,
                               runtime: rec.runtime)
            }
            let shuffled = filtered.shuffled()
            return shuffled.compactMap { rec -> DiscoverItem? in
                guard let arrId = rec.id, let title = rec.title else { return nil }
                let poster: URL? = posterURL(from: rec.images)
                let result = SearchResult(
                    id: arrId, foreignId: rec.tmdbId.map(String.init) ?? "",
                    title: title, subtitle: nil,
                    year: rec.year,
                    rating: rec.ratings?.tmdb?.value,
                    imdb: rec.ratings?.imdb?.value,
                    rottenTomatoes: rec.ratings?.rottenTomatoes?.value,
                    metacritic: rec.ratings?.metacritic?.value,
                    overview: rec.overview, runtime: rec.runtime,
                    genres: rec.genres ?? [],
                    network: rec.studio,
                    certification: rec.certification,
                    posterURL: poster, source: .radarr, inLibraryArrId: arrId
                )
                return DiscoverItem(
                    result: result,
                    action: .openDetail(source: .radarr, arrId: arrId),
                    originLabel: .library,
                    kind: .movie
                )
            }
        }
    }

    // MARK: - Sonarr Library source

    /// Sonarr library source. Filters by decade and monitored status.
    /// Genre filtering is skipped — Sonarr library records may not
    /// carry full genre metadata.
    @MainActor
    public static func sonarrLibrary(
        fetchAll: @escaping @MainActor () async throws -> [SonarrLibraryRecord]
    ) -> DiscoverViewModel.LibrarySource {
        return { filter in
            let all = try await fetchAll()
            let filtered = all.filter { rec in
                // Use simple decade + monitored matching; SonarrLibraryRecord
                // has no `hasFile` or `genres` field.
                filter.matches(year: rec.year, monitored: rec.monitored)
            }
            let shuffled = filtered.shuffled()
            return shuffled.compactMap { rec -> DiscoverItem? in
                guard let arrId = rec.id, let title = rec.title else { return nil }
                let poster: URL? = posterURL(from: rec.images)
                let result = SearchResult(
                    id: arrId, foreignId: rec.tvdbId.map(String.init) ?? "",
                    title: title, subtitle: nil,
                    year: rec.year, rating: nil, imdb: nil,
                    rottenTomatoes: nil, metacritic: nil,
                    overview: rec.overview, runtime: nil,
                    genres: [], network: nil, certification: nil,
                    posterURL: poster, source: .sonarr, inLibraryArrId: arrId
                )
                return DiscoverItem(
                    result: result,
                    action: .openDetail(source: .sonarr, arrId: arrId),
                    originLabel: .library,
                    kind: .show
                )
            }
        }
    }

    // MARK: - LLM source

    /// LLM source. `kindHint` controls the prompt style and the lookup
    /// backend used to enrich suggestions:
    ///   - `.movie` — Radarr lookup, all cards are movies.
    ///   - `.show`  — Sonarr lookup, all cards are shows.
    ///   - `.auto`  — LLM annotates each title; each suggestion's own
    ///                `kind` field routes the lookup.
    @MainActor
    public static func llm(
        provider: LLMProvider,
        tmdbClient: @escaping @MainActor () -> TMDBClient,
        radarrLookup: @escaping @MainActor (String) async throws -> [RadarrLookupRecord],
        sonarrLookup: @escaping @MainActor (String) async throws -> [SonarrLookupRecord],
        libraryTmdbIds: @escaping @MainActor () -> Set<Int>,
        decade: @escaping @MainActor () -> DiscoverDecade,
        kindHint: DiscoverMediaSelection = .movie,
        count: Int = 20
    ) -> DiscoverViewModel.LLMSource {
        return { exclude, mood in
            let prompt = DiscoverLLMPrompt.build(
                mood: mood, decade: decade(), count: count,
                exclude: exclude, kindHint: kindHint
            )
            let response = try await provider.respond(prompt: prompt, tools: [], history: [])
            let parsed: DiscoverLLMPrompt.Response
            do {
                parsed = try DiscoverLLMPrompt.parse(response.text)
            } catch {
                return DiscoverViewModel.LLMResult(items: [], suggestedFilters: nil)
            }
            let owned = libraryTmdbIds()
            var out: [DiscoverItem] = []
            for s in parsed.suggestions {
                // Resolve kind: use suggestion's own label in .auto mode,
                // otherwise fall back to the kindHint.
                let resolvedKind: DiscoverItemKind
                if let sugKind = s.kind {
                    resolvedKind = sugKind
                } else {
                    resolvedKind = kindHint == .show ? .show : .movie
                }

                let term = s.year.map { "\(s.title) \($0)" } ?? s.title

                switch resolvedKind {
                case .movie:
                    let hits = (try? await radarrLookup(term)) ?? []
                    guard let first = hits.first else { continue }
                    let tmdbId = first.tmdbId ?? 0
                    let poster: URL? = posterURL(from: first.images)
                    let result = SearchResult(
                        id: tmdbId, foreignId: tmdbId == 0 ? "" : String(tmdbId),
                        title: first.title, subtitle: nil,
                        year: first.year,
                        rating: first.ratings?.tmdb?.value,
                        imdb: first.ratings?.imdb?.value,
                        rottenTomatoes: first.ratings?.rottenTomatoes?.value,
                        metacritic: first.ratings?.metacritic?.value,
                        overview: first.overview, runtime: first.runtime,
                        genres: first.genres ?? [], network: first.studio,
                        certification: first.certification,
                        posterURL: poster,
                        source: .radarr,
                        inLibraryArrId: nil
                    )
                    _ = owned
                    out.append(DiscoverItem(result: result, action: .addToRadarr,
                                            originLabel: .llm, kind: .movie))

                case .show:
                    let hits = (try? await sonarrLookup(term)) ?? []
                    guard let first = hits.first else { continue }
                    let tvdbId = first.tvdbId ?? 0
                    let poster: URL? = posterURL(from: first.images)
                    let result = SearchResult(
                        id: tvdbId, foreignId: tvdbId == 0 ? "" : String(tvdbId),
                        title: first.title, subtitle: nil,
                        year: first.year,
                        rating: first.ratings?.value,
                        imdb: nil, rottenTomatoes: nil, metacritic: nil,
                        overview: first.overview, runtime: first.runtime,
                        genres: first.genres ?? [], network: first.network,
                        certification: nil,
                        posterURL: poster,
                        source: .sonarr,
                        inLibraryArrId: nil
                    )
                    out.append(DiscoverItem(result: result, action: .addToSonarr,
                                            originLabel: .llm, kind: .show))
                }
            }

            // Resolve people names to TMDB person ids (capped at 5).
            let tmdb = tmdbClient()
            var personIds: [Int] = []
            for name in parsed.filters.people.prefix(5) {
                if let person = (try? await tmdb.searchPerson(query: name))?.first {
                    personIds.append(person.id)
                }
            }

            let suggestedFilters = parsed.filters.genres.isEmpty
                && parsed.filters.decade == nil
                && parsed.filters.status == nil
                && parsed.filters.people.isEmpty
                ? nil
                : parsed.filters
            return DiscoverViewModel.LLMResult(items: out, suggestedFilters: suggestedFilters,
                                               resolvedPersonIds: personIds)
        }
    }

    // MARK: - Helpers

    /// First `poster`-coverType image URL from a raw ArrImage array.
    /// Prefers `remoteUrl` (no auth needed) — falls back to nil.
    private static func posterURL(from images: [ArrImage]?) -> URL? {
        guard let images else { return nil }
        for img in images {
            guard (img.coverType ?? "").lowercased() == "poster" else { continue }
            if let str = img.remoteUrl, let url = URL(string: str) { return url }
        }
        return nil
    }
}
