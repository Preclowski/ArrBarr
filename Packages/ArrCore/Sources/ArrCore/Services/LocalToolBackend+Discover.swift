import Foundation

// Ported from discover/llm-only-cleanup. Owns the `discover_in_quiz`
// chat tool — pre-resolves the model's picks server-side, then posts
// a notification so PopoverContentView can open the Discover overlay
// in quiz mode with the deck seeded synchronously.

extension LocalToolBackend {

    func discoverInQuiz(_ arguments: JSONValue) async throws -> ToolCallOutput {
        guard case .object(let dict) = arguments else {
            return ToolCallOutput(text: "ERROR: discover_in_quiz needs an object payload.")
        }
        guard case .string(let mood) = dict["mood"] else {
            return ToolCallOutput(text: "ERROR: missing required 'mood' string.")
        }
        let label = mood.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            return ToolCallOutput(text: "ERROR: 'mood' cannot be empty.")
        }
        let kind = Self.stringArg(arguments, key: "kind").lowercased()
        guard kind == "movie" || kind == "series" else {
            return ToolCallOutput(text: "ERROR: 'kind' must be 'movie' or 'series'.")
        }
        let items = Self.suggestItems(arguments)
        guard !items.isEmpty else {
            return ToolCallOutput(text: "ERROR: 'items' must be a non-empty array of {title, year?}.")
        }
        let capped = Array(items.prefix(25))
        let libraryMode: String = {
            if case .object(let dict) = arguments,
               case .string(let v) = dict["library_mode"] {
                let lowered = v.lowercased()
                if ["none", "few", "many"].contains(lowered) { return lowered }
            }
            return "few"
        }()

        let anchorIds: [Int] = {
            if case .object(let dict) = arguments,
               case .array(let arr) = dict["anchor_tmdb_ids"] {
                return arr.compactMap { v -> Int? in
                    if case .number(let n) = v { return Int(n) }
                    return nil
                }
            }
            return []
        }()

        // Resolve each pick through the appropriate arr lookup, mirroring
        // what DiscoverSources.llm does per-item — same SearchResult /
        // DiscoverItem shape so the overlay treats them identically.
        //
        // Library map fetched in parallel with the per-pick lookups (mirrors
        // suggest_titles). Owned picks get inLibraryArrId set and
        // originLabel=.library so the matched-list sections them under
        // "In library" with an openDetail tap instead of an add flow.
        async let libraryMapFetch: [Int: Int] = (kind == "series")
            ? sonarrLibraryByTVDBId()
            : radarrLibraryByTMDBId()

        let radarrClient = RadarrClient(config: radarr)
        let sonarrClient = SonarrClient(config: sonarr)
        var resolved: [DiscoverItem] = []
        for pick in capped {
            let term = pick.year.map { "\(pick.title) \($0)" } ?? pick.title
            switch kind {
            case "movie":
                guard radarr.isConfigured else { continue }
                let hits = (try? await radarrClient.lookupMovies(term: term)) ?? []
                guard let first = hits.first else { continue }
                let tmdbId = first.tmdbId ?? 0
                let poster = (first.images ?? []).posterURL(baseURL: radarr.baseURL).0
                let resultBase = SearchResult(
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
                let libraryMap = await libraryMapFetch
                if let arrId = libraryMap[tmdbId] {
                    let owned = resultBase.withInLibraryArrId(arrId)
                    resolved.append(DiscoverItem(result: owned,
                                                 action: .openDetail(source: .radarr, arrId: arrId),
                                                 originLabel: .library, kind: .movie))
                } else {
                    resolved.append(DiscoverItem(result: resultBase, action: .addToRadarr,
                                                 originLabel: .llm, kind: .movie))
                }
            case "series":
                guard sonarr.isConfigured else { continue }
                let hits = (try? await sonarrClient.lookupSeries(term: term)) ?? []
                guard let first = hits.first else { continue }
                let tvdbId = first.tvdbId ?? 0
                let poster = (first.images ?? []).posterURL(baseURL: sonarr.baseURL).0
                let resultBase = SearchResult(
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
                let libraryMap = await libraryMapFetch
                if let arrId = libraryMap[tvdbId] {
                    let owned = resultBase.withInLibraryArrId(arrId)
                    resolved.append(DiscoverItem(result: owned,
                                                 action: .openDetail(source: .sonarr, arrId: arrId),
                                                 originLabel: .library, kind: .show))
                } else {
                    resolved.append(DiscoverItem(result: resultBase, action: .addToSonarr,
                                                 originLabel: .llm, kind: .show))
                }
            default: break
            }
        }

        let filtered: [DiscoverItem]
        switch libraryMode {
        case "none":
            // Strict: drop everything the user already owns.
            filtered = resolved.filter { $0.result.inLibraryArrId == nil }
        default:
            // "few" and "many" both pass everything through for now.
            // "many" is reserved for future library injection.
            filtered = resolved
        }

        if filtered.isEmpty {
            if !resolved.isEmpty && libraryMode == "none" {
                return ToolCallOutput(text: "All resolved picks were already in your library. Try different titles or pass library_mode: 'few' to include owned items.")
            }
            return ToolCallOutput(text: "Couldn't resolve any of those picks through \(kind == "movie" ? "Radarr" : "Sonarr") lookup. Try other titles or check the service config.")
        }

        let append: Bool = {
            if case .object(let dict) = arguments,
               case .bool(let v) = dict["append"] {
                return v
            }
            return false
        }()

        // Fetch TMDB Similar results for any kept-item anchors in parallel,
        // then merge them with the agent's curated picks.
        var similarItems: [DiscoverItem] = []
        if !anchorIds.isEmpty && tmdbEnabled {
            let cappedAnchors = Array(anchorIds.prefix(5))
            similarItems = await fetchSimilarForAnchors(
                anchorIds: cappedAnchors,
                kind: kind,
                libraryMode: libraryMode
            )
        }

        // Curated agent picks lead; similar items extend the deck.
        // Dedupe similar against curated by dedupKey so we don't double-show.
        let curatedKeys = Set(filtered.map(\.dedupKey))
        let extraSimilars = similarItems.filter { !curatedKeys.contains($0.dedupKey) }
        let combined = filtered + extraSimilars

        let payload = combined
        await MainActor.run {
            NotificationCenter.default.post(
                name: .arrBarrOpenDiscoverQuiz,
                object: nil,
                userInfo: [
                    "mood": label,
                    "items": payload,
                    "append": append,
                ]
            )
        }
        let frontPosters = combined.prefix(3).compactMap { $0.result.posterURL }
        let summary = "Opened Discover quiz with \(payload.count) picks for: \(label) (\(filtered.count) curated + \(extraSimilars.count) similar)"
        return ToolCallOutput(text: summary, rich: .discoverSession(mood: label, posterURLs: Array(frontPosters)))
    }

    /// Fan out TMDB Similar fetches for each anchor in parallel, resolve
    /// each result through arr lookup, then dedupe across all anchors.
    /// Returns at most ~15 unique DiscoverItems — enough to add real
    /// variety without dwarfing the agent's curated set.
    func fetchSimilarForAnchors(
        anchorIds: [Int],
        kind: String,
        libraryMode: String
    ) async -> [DiscoverItem] {
        let tmdb = TMDBClient(apiKey: tmdbApiKey)
        let radarrClient = RadarrClient(config: radarr)
        let sonarrClient = SonarrClient(config: sonarr)

        // Library map for owned cross-ref (same pattern as suggestTitles).
        async let libraryMapFetch: [Int: Int] = (kind == "series")
            ? sonarrLibraryByTVDBId()
            : radarrLibraryByTMDBId()

        var perAnchor: [[DiscoverItem]] = Array(repeating: [], count: anchorIds.count)
        await withTaskGroup(of: (Int, [DiscoverItem]).self) { group in
            for (idx, anchorId) in anchorIds.enumerated() {
                group.addTask { [tmdb, radarrClient, sonarrClient] in
                    do {
                        if kind == "movie" {
                            let summaries = try await tmdb.similarMovies(movieId: anchorId)
                            var out: [DiscoverItem] = []
                            for s in summaries.prefix(5) {
                                let term = s.year.map { "\(s.title) \($0)" } ?? s.title
                                guard let first = (try? await radarrClient.lookupMovies(term: term))?.first else { continue }
                                let tmdbId = first.tmdbId ?? 0
                                let poster: URL? = (first.images ?? []).posterURL(baseURL: radarrClient.config.baseURL).0
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
                                out.append(DiscoverItem(result: result, action: .addToRadarr,
                                                        originLabel: .llm, kind: .movie))
                            }
                            return (idx, out)
                        } else {
                            let summaries = try await tmdb.similarTV(seriesId: anchorId)
                            var out: [DiscoverItem] = []
                            for s in summaries.prefix(5) {
                                let term = s.year.map { "\(s.name) \($0)" } ?? s.name
                                guard let first = (try? await sonarrClient.lookupSeries(term: term))?.first else { continue }
                                let tvdbId = first.tvdbId ?? 0
                                let poster: URL? = (first.images ?? []).posterURL(baseURL: sonarrClient.config.baseURL).0
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
                            return (idx, out)
                        }
                    } catch {
                        return (idx, [])
                    }
                }
            }
            for await (idx, items) in group {
                perAnchor[idx] = items
            }
        }

        // Library cross-ref for owned items
        let libraryMap = await libraryMapFetch

        // Dedupe across anchors by dedupKey; apply library_mode filter.
        var seen = Set<String>()
        var out: [DiscoverItem] = []
        for anchorList in perAnchor {
            for item in anchorList {
                guard seen.insert(item.dedupKey).inserted else { continue }
                let metadataId = item.result.id
                if let arrId = libraryMap[metadataId] {
                    if libraryMode == "none" { continue }
                    let owned = item.result.withInLibraryArrId(arrId)
                    let detailAction: DiscoverAction = (kind == "movie")
                        ? .openDetail(source: .radarr, arrId: arrId)
                        : .openDetail(source: .sonarr, arrId: arrId)
                    out.append(DiscoverItem(
                        result: owned,
                        action: detailAction,
                        originLabel: .library,
                        kind: item.kind
                    ))
                } else {
                    out.append(item)
                }
            }
        }
        return out
    }

}
