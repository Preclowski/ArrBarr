import Foundation

public enum DiscoverSources {

    // MARK: - TMDB source

    /// TMDB Discover source. Skips anything already in the local Radarr
    /// library — caller passes `libraryTmdbIds` so we don't repaint
    /// titles the user already owns. The closure is captured at
    /// `configure` time and re-reads the Set on every call.
    @MainActor
    public static func tmdb(
        apiKey: String,
        libraryTmdbIds: @escaping @MainActor () -> Set<Int>
    ) -> DiscoverViewModel.TMDBSource {
        let client = TMDBClient(apiKey: apiKey)
        return { filter, _ /* page — TMDB client doesn't currently page; reserved for future */ in
            let range = filter.decade.range
            let summaries = try await client.discoverMovies(
                startYear: range?.lowerBound,
                endYear: range?.upperBound,
                sortBy: "popularity.desc"
            )
            let owned = libraryTmdbIds()
            return summaries.compactMap { s -> DiscoverItem? in
                if owned.contains(s.id) { return nil }
                let result = SearchResult(
                    id: s.id, foreignId: String(s.id),
                    title: s.title, subtitle: nil,
                    year: s.year,
                    rating: s.voteAverage,
                    imdb: nil, rottenTomatoes: nil, metacritic: nil,
                    overview: s.overview, runtime: nil,
                    genres: [], network: nil, certification: nil,
                    posterURL: TMDBClient.imageURL(path: s.posterPath),
                    source: .radarr, inLibraryArrId: nil
                )
                return DiscoverItem(result: result, action: .addToRadarr, originLabel: .tmdb)
            }
        }
    }

    // MARK: - Library source

    /// Library source. Caller supplies the async fetch (so PopoverContentView
    /// can cache the library list across sources). Filter is applied locally.
    @MainActor
    public static func library(
        fetchAll: @escaping @MainActor () async throws -> [RadarrLibraryRecord]
    ) -> DiscoverViewModel.LibrarySource {
        return { filter in
            let all = try await fetchAll()
            let filtered = all.filter { rec in
                filter.matches(year: rec.year, monitored: rec.monitored)
            }
            let shuffled = filtered.shuffled()
            return shuffled.compactMap { rec -> DiscoverItem? in
                guard let arrId = rec.id, let title = rec.title else { return nil }
                let poster: URL? = posterURL(from: rec.images)
                let result = SearchResult(
                    id: arrId, foreignId: rec.tmdbId.map(String.init) ?? "",
                    title: title, subtitle: nil,
                    year: rec.year, rating: nil, imdb: nil,
                    rottenTomatoes: nil, metacritic: nil,
                    overview: nil, runtime: nil,
                    genres: [], network: nil, certification: nil,
                    posterURL: poster, source: .radarr, inLibraryArrId: arrId
                )
                return DiscoverItem(
                    result: result,
                    action: .openDetail(arrId: arrId),
                    originLabel: .library
                )
            }
        }
    }

    // MARK: - LLM source

    /// LLM source. Stateless: builds a prompt with the cumulative exclude
    /// list, parses titles, looks each one up in Radarr to enrich with
    /// poster/overview/year so the card UI is uniform with other sources.
    /// Returns empty when nothing parses — VM treats that as pool exhaustion.
    @MainActor
    public static func llm(
        provider: LLMProvider,
        radarrLookup: @escaping @MainActor (String) async throws -> [RadarrLookupRecord],
        libraryTmdbIds: @escaping @MainActor () -> Set<Int>,
        decade: @escaping @MainActor () -> DiscoverDecade,
        count: Int = 20
    ) -> DiscoverViewModel.LLMSource {
        return { exclude, mood in
            let prompt = DiscoverLLMPrompt.build(
                mood: mood, decade: decade(), count: count, exclude: exclude
            )
            let response = try await provider.respond(prompt: prompt, tools: [], history: [])
            let suggestions: [DiscoverLLMPrompt.Suggestion]
            do {
                suggestions = try DiscoverLLMPrompt.parse(response.text)
            } catch {
                return []
            }
            let owned = libraryTmdbIds()
            var out: [DiscoverItem] = []
            for s in suggestions {
                let term = s.year.map { "\(s.title) \($0)" } ?? s.title
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
                // Already-owned LLM suggestions still surface as addToRadarr —
                // the existing SearchAddPanel detects the dup and routes to
                // the right action surface.
                _ = owned
                out.append(DiscoverItem(result: result, action: .addToRadarr, originLabel: .llm))
            }
            return out
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
