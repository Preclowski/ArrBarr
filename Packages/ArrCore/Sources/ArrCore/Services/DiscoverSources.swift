import Foundation

public enum DiscoverSources {

    // MARK: - Radarr Library source

    /// Radarr library source. Caller supplies the async fetch so
    /// PopoverContentView can cache the list across sources.
    @MainActor
    public static func radarrLibrary(
        fetchAll: @escaping @MainActor () async throws -> [RadarrLibraryRecord]
    ) -> DiscoverViewModel.LibrarySource {
        return { filter in
            // Library records don't carry cast info — we'd have to fetch
            // per-movie credits which would be N extra TMDB calls. When
            // the user has a person filter active, skip the library
            // source entirely so the quiz deck only contains cards that
            // genuinely match. TMDB + LLM both honor `personIds`
            // server-side / via prompt.
            if !filter.personIds.isEmpty { return [] }

            let all = try await fetchAll()
            let filtered = all.filter { rec in
                // Already watched on the media server is the one exclusion the
                // arrs can't express: the deck is "what should I put on
                // tonight", and a film the user finished last week is the
                // wrong answer to that question.
                guard !MediaServerIndex.shared.isWatched(rec.mediaServerKeys) else { return false }
                return filter.matches(year: rec.year, monitored: rec.monitored,
                                      hasFile: rec.hasFile, genres: rec.genres,
                                      runtime: rec.runtime)
            }
            let shuffled = filtered.shuffled()
            return shuffled.compactMap { rec -> DiscoverItem? in
                guard let arrId = rec.id, let title = rec.title else { return nil }
                let poster: URL? = posterURL(from: rec.images)
                let result = SearchResult(
                    // `id` is the FOREIGN id for every other producer of a
                    // SearchResult (tmdbId here), and `mediaRef` reads it as
                    // one. Putting the arr-internal id here made every ref
                    // derived from a library card point at an unrelated title;
                    // the arr id has its own homes — `inLibraryArrId` and the
                    // card's `.openDetail(arrId:)` action.
                    externalId: rec.tmdbId ?? 0, foreignId: rec.tmdbId.map(String.init) ?? "",
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
            // TV series records don't carry cast info — bail when personIds
            // is active so only genuinely matching sources are shown.
            if !filter.personIds.isEmpty { return [] }

            let all = try await fetchAll()
            let filtered = all.filter { rec in
                // See the Radarr source: fully-watched series drop out of the
                // deck too.
                guard !MediaServerIndex.shared.isWatched(rec.mediaServerKeys) else { return false }
                // Use simple decade + monitored matching; SonarrLibraryRecord
                // has no `hasFile` or `genres` field.
                return filter.matches(year: rec.year, monitored: rec.monitored)
            }
            let shuffled = filtered.shuffled()
            return shuffled.compactMap { rec -> DiscoverItem? in
                guard let arrId = rec.id, let title = rec.title else { return nil }
                let poster: URL? = posterURL(from: rec.images)
                let result = SearchResult(
                    // The tvdbId, for the same reason as the movie source
                    // above — `id` names the title, not the arr record.
                    externalId: rec.tvdbId ?? 0, foreignId: rec.tvdbId.map(String.init) ?? "",
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

    /// LLM source. The LLM returns a list of title suggestions; we resolve
    /// each one to a Radarr/Sonarr lookup record (poster, ratings, runtime)
    /// and emit a `DiscoverItem`. `kindHint` controls the prompt style and
    /// which lookup backend is used.
    @MainActor
    public static func llm(
        provider: LLMProvider,
        radarrLookup: @escaping @MainActor (String) async throws -> [RadarrLookupRecord],
        sonarrLookup: @escaping @MainActor (String) async throws -> [SonarrLookupRecord],
        kindHint: DiscoverMediaSelection = .movie,
        count: Int = 20
    ) -> DiscoverViewModel.LLMSource {
        return { exclude, mood in
            // Watch history is the strongest signal the app has about taste,
            // and it costs one synchronous read — the index is already kept
            // warm by the queue's polling loop. Empty when no media server is
            // connected, which leaves the prompt exactly as it was.
            let watched = MediaServerIndex.shared.recentlyWatched().map { watch in
                watch.year.map { "\(watch.title) (\($0))" } ?? watch.title
            }
            let prompt = DiscoverLLMPrompt.build(
                mood: mood, count: count, exclude: exclude, kindHint: kindHint,
                watched: watched
            )
            let response = try await provider.respond(prompt: prompt, tools: [], history: [])
            let parsed: DiscoverLLMPrompt.Response
            do {
                parsed = try DiscoverLLMPrompt.parse(response.text)
            } catch {
                return []
            }
            // The lookups fan out (order-preserving, bounded) — done one by
            // one this was the Discover tab's slowest step by far.
            let out: [DiscoverItem] = await ParallelResolve.orderedMap(parsed.suggestions, width: 8) { s -> DiscoverItem? in
                let resolvedKind: DiscoverItemKind = s.kind ?? (kindHint == .show ? .show : .movie)
                let term = s.year.map { "\(s.title) \($0)" } ?? s.title
                switch resolvedKind {
                case .movie:
                    let hits = (try? await radarrLookup(term)) ?? []
                    guard let first = hits.first else { return nil }
                    let tmdbId = first.tmdbId ?? 0
                    let poster: URL? = posterURL(from: first.images)
                    let result = SearchResult(
                        externalId: tmdbId, foreignId: tmdbId == 0 ? "" : String(tmdbId),
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
                    return DiscoverItem(result: result, action: .addToRadarr,
                                        originLabel: .llm, kind: .movie)
                case .show:
                    let hits = (try? await sonarrLookup(term)) ?? []
                    guard let first = hits.first else { return nil }
                    let tvdbId = first.tvdbId ?? 0
                    let poster: URL? = posterURL(from: first.images)
                    let result = SearchResult(
                        externalId: tvdbId, foreignId: tvdbId == 0 ? "" : String(tvdbId),
                        title: first.title, subtitle: nil,
                        year: first.year,
                        rating: first.ratings?.value,
                        imdb: nil, rottenTomatoes: nil, metacritic: nil,
                        overview: first.overview, runtime: first.runtime,
                        genres: first.genres ?? [], network: first.network,
                        certification: nil,
                        posterURL: poster,
                        source: .sonarr,
                        inLibraryArrId: nil,
                        tmdbTVId: first.tmdbId
                    )
                    return DiscoverItem(result: result, action: .addToSonarr,
                                        originLabel: .llm, kind: .show)
                }
            }.compactMap { $0 }
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
