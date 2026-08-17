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
        // Over-sending is the point: owned picks are dropped below (library_mode
        // "new"), so a big library eats most of a canonical list. The lookups
        // fan out through ParallelResolve — far cheaper than the round trip it
        // takes to notice the deck came back empty and guess again.
        let capped = Array(items.prefix(60))
        let libraryMode: String = {
            if case .object(let dict) = arguments,
               case .string(let v) = dict["library_mode"] {
                switch v.lowercased() {
                case "library", "many": return "library"   // "many" = legacy alias
                case "new", "none", "few": return "new"    // legacy aliases
                default: break
                }
            }
            return "new"
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
        let libraryMap = await libraryMapFetch
        let radarrConfigured = radarr.isConfigured
        let sonarrConfigured = sonarr.isConfigured
        let radarrBase = radarr.baseURL
        let sonarrBase = sonarr.baseURL
        let resolved: [DiscoverItem] = await ParallelResolve.orderedMap(capped, width: 8) { pick -> DiscoverItem? in
            let term = pick.year.map { "\(pick.title) \($0)" } ?? pick.title
            switch kind {
            case "movie":
                guard radarrConfigured else { return nil }
                let hits = (try? await radarrClient.lookupMovies(term: term)) ?? []
                guard let first = hits.first else { return nil }
                let tmdbId = first.tmdbId ?? 0
                let poster = (first.images ?? []).posterURL(baseURL: radarrBase).0
                let resultBase = SearchResult(
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
                if let arrId = libraryMap[tmdbId] {
                    let owned = resultBase.withInLibraryArrId(arrId)
                    return DiscoverItem(result: owned,
                                        action: .openDetail(source: .radarr, arrId: arrId),
                                        originLabel: .library, kind: .movie)
                }
                return DiscoverItem(result: resultBase, action: .addToRadarr,
                                    originLabel: .llm, kind: .movie)
            case "series":
                guard sonarrConfigured else { return nil }
                let hits = (try? await sonarrClient.lookupSeries(term: term)) ?? []
                guard let first = hits.first else { return nil }
                let tvdbId = first.tvdbId ?? 0
                let poster = (first.images ?? []).posterURL(baseURL: sonarrBase).0
                let resultBase = SearchResult(
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
                if let arrId = libraryMap[tvdbId] {
                    let owned = resultBase.withInLibraryArrId(arrId)
                    return DiscoverItem(result: owned,
                                        action: .openDetail(source: .sonarr, arrId: arrId),
                                        originLabel: .library, kind: .show)
                }
                return DiscoverItem(result: resultBase, action: .addToSonarr,
                                    originLabel: .llm, kind: .show)
            default: return nil
            }
        }.compactMap { $0 }

        let filtered: [DiscoverItem]
        switch libraryMode {
        case "library":
            // Rediscovery mode — owned picks are the point; pass everything.
            filtered = resolved
        default:
            // "new" (the default): strictly drop what the user already owns.
            filtered = resolved.filter { $0.result.inLibraryArrId == nil }
        }

        if filtered.isEmpty {
            if !resolved.isEmpty && libraryMode == "new" {
                return ToolCallOutput(text: "All \(resolved.count) picks are already in the user's library — a library this size owns the obvious choices. Do NOT retry by guessing another batch: call check_titles with 25-40 candidates (deeper cuts, not the canon) in ONE call, then seed the quiz with only the ones it reports as NOT in library. Or pass library_mode: 'library' if they want to rediscover what they own.")
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

        // Top-up rounds are deduped HERE, against the live deck, rather than
        // silently inside `DiscoverViewModel.extend`. A round the deck would
        // drop wholesale used to post anyway: the overlay saw no new cards,
        // stopped waiting and said "No more cards" — while the very same
        // request, fired again by hand, came back with fresh picks. Handing
        // the repeats back as the tool result keeps the model in its own loop
        // and lets it try different titles inside the same turn.
        let payload: [DiscoverItem]
        if append {
            let shown = await MainActor.run { DiscoverViewModel.shared.shownDedupKeys }
            let split = Self.splitAlreadyShown(combined, shown: shown)
            if split.fresh.isEmpty {
                let repeats = split.dropped.prefix(10).map(titleYearLabel).joined(separator: ", ")
                return ToolCallOutput(text: "All \(split.dropped.count) picks are already in this quiz session (\(repeats)). Widen the net before retrying — different decade, adjacent genre, or less canonical titles — and send the next round with append: true.")
            }
            payload = split.fresh
        } else {
            payload = combined
        }

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
        let frontPosters = payload.prefix(3).compactMap { $0.result.posterURL }
        let curatedCount = payload.filter { curatedKeys.contains($0.dedupKey) }.count
        let summary = "Opened Discover quiz with \(payload.count) picks for: \(label) (\(curatedCount) curated + \(payload.count - curatedCount) similar)"
        return ToolCallOutput(text: summary, rich: .discoverSession(mood: label, posterURLs: Array(frontPosters)))
    }

    /// Splits an appended round into what the deck hasn't shown yet and what
    /// it would drop. Pure so the dedup rule is testable without arr lookups.
    static func splitAlreadyShown(_ items: [DiscoverItem],
                                  shown: Set<String>) -> (fresh: [DiscoverItem], dropped: [DiscoverItem]) {
        var fresh: [DiscoverItem] = []
        var dropped: [DiscoverItem] = []
        for item in items {
            if shown.contains(item.dedupKey) { dropped.append(item) } else { fresh.append(item) }
        }
        return (fresh, dropped)
    }

    private func titleYearLabel(_ item: DiscoverItem) -> String {
        guard let year = item.result.year else { return item.result.title }
        return "\(item.result.title) (\(year))"
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
                            let summaries = try await tmdb.recommendedMovies(movieId: anchorId)
                            let out: [DiscoverItem] = await ParallelResolve.orderedMap(Array(summaries.prefix(5)), width: 5) { s -> DiscoverItem? in
                                let term = s.year.map { "\(s.title) \($0)" } ?? s.title
                                guard let first = (try? await radarrClient.lookupMovies(term: term))?.first else { return nil }
                                let tmdbId = first.tmdbId ?? 0
                                let poster: URL? = (first.images ?? []).posterURL(baseURL: radarrClient.config.baseURL).0
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
                            }.compactMap { $0 }
                            return (idx, out)
                        } else {
                            let summaries = try await tmdb.recommendedTV(seriesId: anchorId)
                            let out: [DiscoverItem] = await ParallelResolve.orderedMap(Array(summaries.prefix(5)), width: 5) { s -> DiscoverItem? in
                                let term = s.year.map { "\(s.name) \($0)" } ?? s.name
                                guard let first = (try? await sonarrClient.lookupSeries(term: term))?.first else { return nil }
                                let tvdbId = first.tvdbId ?? 0
                                let poster: URL? = (first.images ?? []).posterURL(baseURL: sonarrClient.config.baseURL).0
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
                                    tmdbTVId: s.id
                                )
                                return DiscoverItem(result: result, action: .addToSonarr,
                                                    originLabel: .llm, kind: .show)
                            }.compactMap { $0 }
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
                let metadataId = item.result.externalId
                if let arrId = libraryMap[metadataId] {
                    if libraryMode == "new" { continue }
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
