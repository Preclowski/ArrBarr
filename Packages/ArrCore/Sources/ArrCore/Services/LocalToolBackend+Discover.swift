import os
import Foundation
import MediaKit

extension LocalToolBackend {

    func discoverInQuiz(_ arguments: JSONValue) async throws -> ToolCallOutput {
        let signpost = AppSignpost.quiz
        let state = signpost.beginInterval("discover_in_quiz")
        defer { signpost.endInterval("discover_in_quiz", state) }
        let early = quizEarlyPipeline
        quizEarlyPipeline = nil
        let output = try await buildQuizDeck(arguments, early: early)
        if !headlessSurface {
            await MainActor.run { DiscoverViewModel.shared.endLoading() }
        }
        return output
    }

    /// Fed the partial `discover_in_quiz` arguments so lookups start before the call completes.
    public func quizArgumentsStreamed(_ text: String) async {
        guard !headlessSurface else { return }
        let closes = text.utf8.reduce(0) { $1 == UInt8(ascii: "}") ? $0 + 1 : $0 }
        guard closes > quizStreamCloses else { return }
        quizStreamCloses = closes

        let partial = QuizArgumentsScanner.scan(text)
        guard let kind = partial.string("kind")?.lowercased(), kind == "movie" || kind == "series",
              partial.string("mood")?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
        let libraryMode = Self.quizLibraryMode(partial.string("library_mode"))
        let append = partial.bool("append") ?? false
        // A TMDB deck needs nothing more from the model.
        let fromTMDB = partial.string("source")?.lowercased() == "now"
        let picks = fromTMDB ? [] : Self.suggestItems(.object(["items": .array(partial.items)]))
        guard fromTMDB ? tmdbEnabled : !picks.isEmpty else { return }

        if quizEarlyPipeline == nil {
            // A fresh deck replaces the session, so start early only when that is certain.
            let safe = await MainActor.run {
                append || DiscoverViewModel.shared.loadPhase != nil || !DiscoverViewModel.shared.hasSession
            }
            guard safe else { return }
            let pipeline = await makeQuizPipeline(kind: kind, libraryMode: libraryMode, append: append)
            if quizEarlyPipeline == nil {
                quizEarlyPipeline = pipeline
                if fromTMDB {
                    // The tool call below reports a TMDB failure; the early pipeline just starts empty.
                    await pipeline.feed((await Logger.extras.attempt("quiz now deck") { try await nowPicks(kind: kind) }) ?? [], isFinal: true)
                    return
                }
            }
        }
        guard !fromTMDB, let pipeline = quizEarlyPipeline,
              pipeline.setup.kind == kind, pipeline.setup.libraryMode == libraryMode,
              pipeline.setup.append == append else { return }
        await pipeline.feed(picks)
    }

    /// A streamed deck the tool never claimed is dead.
    public func chatTurnEnded() async {
        quizStreamCloses = 0
        await quizEarlyPipeline?.cancel()
        quizEarlyPipeline = nil
    }

    nonisolated static func quizLibraryMode(_ raw: String?) -> String {
        switch raw?.lowercased() {
        case "library", "many": return "library"   // "many" = legacy alias
        default: return "new"
        }
    }

    private func makeQuizPipeline(kind: String, libraryMode: String, append: Bool) async -> QuizDeckPipeline {
        let (shown, suppressed) = await MainActor.run {
            (append ? DiscoverViewModel.shared.shownDedupKeys : [],
             SwipeSignalStore.shared.suppressedKeys(media: Self.swipeMedia(kind)))
        }
        let setup = QuizDeckPipeline.Setup(kind: kind, libraryMode: libraryMode, append: append,
                                           shown: shown, suppressed: suppressed, delivers: !headlessSurface)
        return QuizDeckPipeline(setup: setup, resolve: curatedPickResolver(kind: kind))
    }

    private func buildQuizDeck(_ arguments: JSONValue, early: QuizDeckPipeline?) async throws -> ToolCallOutput {
        defer { Task { await early?.cancel() } }
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
        let libraryMode = Self.quizLibraryMode(Self.stringArg(arguments, key: "library_mode"))
        let append: Bool = {
            if case .bool(let v) = dict["append"] { return v }
            return false
        }()
        var items = Self.suggestItems(arguments)
        if Self.stringArg(arguments, key: "source").lowercased() == "now" {
            guard tmdbEnabled else {
                return ToolCallOutput(text: "ERROR: source 'now' needs TMDB, which isn't configured. Tell the user you can't see what is in cinemas or airing today — do NOT build this deck from memory, your training data predates it.")
            }
            do { items = try await nowPicks(kind: kind) } catch {
                return ToolCallOutput(text: "ERROR: couldn't reach TMDB (\(error.userFacingMessage)). Tell the user; do NOT build this deck from memory.")
            }
            guard !items.isEmpty else {
                return ToolCallOutput(text: "TMDB lists nothing \(kind == "movie" ? "in cinemas" : "airing") right now. Tell the user; do not substitute older titles.")
            }
        }
        guard !items.isEmpty || libraryMode == "library" else {
            return ToolCallOutput(text: "ERROR: 'items' must be a non-empty array of {title, year?} (it may be [] only with library_mode: 'library', where the deck fills from the library, or with source: 'now').")
        }
        // Over-send: owned picks get dropped, and lookups are cheaper than another model round.
        let capped = Array(items.prefix(60))

        let explicitAnchors: [Int] = {
            if case .object(let dict) = arguments,
               case .array(let arr) = dict["anchor_tmdb_ids"] {
                return arr.compactMap { v -> Int? in
                    if case .number(let n) = v { return Int(n) }
                    return nil
                }
            }
            return []
        }()
        // The model never has to relay ids it may not hold.
        let anchorIds = explicitAnchors.isEmpty && append
            ? await MainActor.run { DiscoverViewModel.shared.keptTMDBIds(kind: kind == "series" ? .show : .movie) }
            : explicitAnchors

        let resolved: [DiscoverItem]
        var shown: Set<String> = []
        var suppressed: Set<String>?
        var delivered: Set<String> = []
        var unresolved: [String] = []
        if capped.isEmpty && libraryMode == "library" {
            if append { shown = await MainActor.run { DiscoverViewModel.shared.shownDedupKeys } }
            resolved = await libraryDeckItems(kind: kind, arguments: arguments)
            if resolved.isEmpty {
                return ToolCallOutput(text: "No library titles match that filter (or everything matching was already watched). Loosen the genre/year filter, or pass explicit items.")
            }
        } else {
            let pipeline: QuizDeckPipeline
            if let early, early.setup.kind == kind, early.setup.libraryMode == libraryMode,
               early.setup.append == append {
                pipeline = early
            } else {
                await early?.cancel()
                if !append && !headlessSurface {
                    await MainActor.run { DiscoverViewModel.shared.beginLoading() }
                }
                pipeline = await makeQuizPipeline(kind: kind, libraryMode: libraryMode, append: append)
            }
            await pipeline.feed(capped, isFinal: true)
            let outcome = await pipeline.finish()
            resolved = outcome.resolved
            delivered = outcome.delivered
            unresolved = outcome.unresolved
            shown = pipeline.setup.shown
            suppressed = pipeline.setup.suppressed
        }

        let filtered: [DiscoverItem]
        switch libraryMode {
        case "library":
            filtered = resolved
        default:
            filtered = resolved.filter { $0.result.inLibraryArrId == nil }
        }

        if filtered.isEmpty {
            if !resolved.isEmpty && libraryMode == "new" {
                let size = [LibraryStats.shared.movieCount.map { "\($0) movies" },
                            LibraryStats.shared.seriesCount.map { "\($0) series" }]
                    .compactMap { $0 }.joined(separator: ", ")
                let sizeNote = size.isEmpty ? "" : " (the library holds \(size))"
                return ToolCallOutput(text: "All \(resolved.count) picks are already in the user's library\(sizeNote) — a library this size owns the obvious choices. You get AT MOST ONE corrective call: run check_titles with 25-40 candidates (deeper cuts, not the canon) in ONE call, then seed the quiz once with only the ones it reports as NOT in library. If that deck comes back small, it stays small — never a third attempt. Or pass library_mode: 'library' if they want to rediscover what they own.")
            }
            return ToolCallOutput(text: "None of those picks matched a \(kind == "movie" ? "Radarr" : "Sonarr") title\(Self.unresolvedNote(unresolved)) Check titles and years — or the kind — before retrying.")
        }
        return try await assembleDeck(label: label, kind: kind, append: append,
                                      libraryMode: libraryMode, anchorIds: anchorIds,
                                      filtered: filtered, shown: shown,
                                      suppressed: suppressed, delivered: delivered,
                                      unresolved: unresolved)
    }

    private func curatedPickResolver(kind: String) -> @Sendable (QuizDeckPipeline.Pick) async -> DiscoverItem? {
        let libraryMapFetch = Task { [self] () -> [Int: LibraryOwnership] in
            kind == "series" ? await sonarrLibraryByTVDBId() : await radarrLibraryByTMDBId()
        }
        let radarrClient = radarrClient
        let sonarrClient = sonarrClient
        let radarrConfigured = radarr.isConfigured
        let sonarrConfigured = sonarr.isConfigured
        let radarrBase = radarr.baseURL
        let sonarrBase = sonarr.baseURL
        return { pick -> DiscoverItem? in
            switch kind {
            case "movie":
                guard radarrConfigured,
                      let first = await Self.matchedMovie(pick, client: radarrClient) else { return nil }
                let libraryMap = await libraryMapFetch.value
                guard let result = SearchResult(radarr: first, baseURL: radarrBase) else { return nil }
                return DiscoverItem(result: result.withLibraryOwnership(libraryMap[result.externalId]), kind: .movie)
            case "series":
                guard sonarrConfigured,
                      let first = await Self.matchedSeries(pick, client: sonarrClient) else { return nil }
                let libraryMap = await libraryMapFetch.value
                guard let result = SearchResult(sonarr: first, baseURL: sonarrBase) else { return nil }
                return DiscoverItem(result: result.withLibraryOwnership(libraryMap[result.externalId]), kind: .show)
            default: return nil
            }
        }
    }

    /// Draws from a 3× pool so repeat sessions differ. Watched titles drop out:
    /// the deck answers "what to watch tonight".
    private func libraryDeckItems(kind: String, arguments: JSONValue) async -> [DiscoverItem] {
        let query = LibraryQuery(
            genre: Self.stringArg(arguments, key: "genre"),
            startYear: Self.optionalIntArg(arguments, key: "startYear"),
            endYear: Self.optionalIntArg(arguments, key: "endYear"),
            unwatchedOnly: true,
            sort: LibrarySort(field: .rating, ascending: false)
        )
        if kind == "movie" {
            guard radarr.isConfigured else { return [] }
            let all = await LibraryIndex.shared.movies(config: radarr)
            let ranked = LibraryFilter.apply(all, query: query) { isWatched($0.mediaServerKeys) }
            return Self.poolThenDraw(ranked, pool: 60, deck: 20).compactMap { rec -> DiscoverItem? in
                guard rec.id != nil, let result = SearchResult(radarr: rec, baseURL: radarr.baseURL)?.withLibraryOwnership(rec.ownership) else { return nil }
                return DiscoverItem(result: result, kind: .movie,
                                    reason: String(localized: "Top-rated on your shelf", bundle: .module))
            }
        }
        guard sonarr.isConfigured else { return [] }
        let all = await LibraryIndex.shared.series(config: sonarr)
        let ranked = LibraryFilter.apply(all, query: query) { isWatched($0.mediaServerKeys) }
        return Self.poolThenDraw(ranked, pool: 60, deck: 20).compactMap { rec -> DiscoverItem? in
            guard rec.id != nil, let result = SearchResult(sonarr: rec, baseURL: sonarr.baseURL)?.withLibraryOwnership(rec.ownership) else { return nil }
            return DiscoverItem(result: result, kind: .show,
                                reason: String(localized: "Top-rated on your shelf", bundle: .module))
        }
    }

    /// Pure so the variety rule is testable.
    nonisolated static func poolThenDraw<T>(_ ranked: [T], pool: Int, deck: Int) -> [T] {
        Array(ranked.prefix(pool).shuffled().prefix(deck))
    }

    /// `shown` must predate the pipeline's cards, or an appended round counts its own cards as repeats.
    private func assembleDeck(label: String, kind: String, append: Bool,
                              libraryMode: String, anchorIds: [Int],
                              filtered: [DiscoverItem], shown: Set<String>,
                              suppressed: Set<String>?,
                              delivered: Set<String>,
                              unresolved: [String]) async throws -> ToolCallOutput {
        var thinRoundNote = unresolved.isEmpty ? "" : " \(unresolved.count) pick\(unresolved.count == 1 ? "" : "s") matched no \(kind == "movie" ? "Radarr" : "Sonarr") title and were left out\(Self.unresolvedNote(unresolved))"

        var similarItems: [DiscoverItem] = []
        if !anchorIds.isEmpty && tmdbEnabled {
            let cappedAnchors = Array(anchorIds.prefix(5))
            similarItems = await fetchSimilarForAnchors(
                anchorIds: cappedAnchors,
                kind: kind,
                libraryMode: libraryMode
            )
        }

        let curatedKeys = Set(filtered.map(\.dedupKey))
        let extraSimilars = similarItems.filter { !curatedKeys.contains($0.dedupKey) }
        let merged = filtered + extraSimilars

        // Reported to the model so a heavily suppressed round doesn't read as a resolution failure.
        let suppressedKeys: Set<String>
        if let suppressed {
            suppressedKeys = suppressed
        } else {
            suppressedKeys = await MainActor.run { SwipeSignalStore.shared.suppressedKeys(media: Self.swipeMedia(kind)) }
        }
        let combined = merged.filter { !suppressedKeys.contains($0.dedupKey) }
        let suppressedCount = merged.count - combined.count
        if combined.isEmpty {
            return ToolCallOutput(text: "All \(merged.count) picks are on the user's skip cooldown or not-interested list — they swiped these away recently. STOP: do NOT call discover_in_quiz again this turn. Tell the user their recent skips filtered everything out; they can ask for a different vibe, or bring skipped titles back in Settings → Quiz.")
        }

        // Deduped here, not in `DiscoverViewModel.extend`: an all-repeat round must go back
        // to the model, or the overlay would stop waiting and show "No more cards".
        let payload: [DiscoverItem]
        if append {
            let split = Self.splitAlreadyShown(combined, shown: shown)
            if split.fresh.isEmpty {
                let repeats = split.dropped.prefix(10).map(titleYearLabel).joined(separator: ", ")
                return ToolCallOutput(text: "All \(split.dropped.count) picks are already in this quiz session (\(repeats)). Widen the net before retrying — different decade, adjacent genre, or less canonical titles — and send the next round with append: true.")
            }
            payload = split.fresh
            if payload.count < 6 {
                // Not worth another model round; nudge the next one to arrive ~10 strong.
                thinRoundNote += " Only \(payload.count) fresh card\(payload.count == 1 ? "" : "s") landed this round — next append send a bigger, deeper batch (25-40 picks) so top-ups arrive ~10 at a time."
            }
        } else {
            payload = combined
        }

        // A remote MCP client has no popover: return the list as text instead.
        if headlessSurface {
            let lines = payload.map { item -> String in
                var parts = [item.result.year.map { "\(item.result.title) (\($0))" } ?? item.result.title]
                if item.result.inLibraryArrId != nil { parts.append("[in library]") }
                if let reason = item.reason { parts.append("— \(reason)") }
                return "• " + parts.joined(separator: " ")
            }
            var text = "Resolved \(payload.count) picks for \"\(label)\" (no quiz UI on this surface — presenting the list instead):\n"
            text += lines.joined(separator: "\n")
            if suppressedCount > 0 {
                text += "\n\(suppressedCount) more dropped — recently skipped by the user or marked not interested."
            }
            text += thinRoundNote
            return ToolCallOutput(text: text)
        }

        let undelivered = payload.filter { !delivered.contains($0.dedupKey) }
        if !undelivered.isEmpty {
            AppMessages.post(AppMessages.OpenDiscoverQuiz(items: undelivered,
                                                          append: append || !delivered.isEmpty))
        }
        let frontPosters = payload.prefix(3).compactMap { $0.result.posterURL }
        let curatedCount = payload.filter { curatedKeys.contains($0.dedupKey) }.count
        var summary = "Opened Discover quiz with \(payload.count) picks for: \(label) (\(curatedCount) curated + \(payload.count - curatedCount) similar)"
        if suppressedCount > 0 {
            summary += ". \(suppressedCount) pick\(suppressedCount == 1 ? "" : "s") dropped because the user recently skipped them — the smaller deck is CORRECT, do not top it up."
        }
        summary += " THIS IS THE DECK — the session is open and the user is swiping. Do NOT call discover_in_quiz again this turn, even if the deck is small; the user will ask when they want more.\(thinRoundNote)"
        return ToolCallOutput(text: summary, rich: .discoverSession(mood: label, posterURLs: Array(frontPosters)))
    }

    /// Pure so the dedup rule is testable without arr lookups.
    nonisolated static func splitAlreadyShown(_ items: [DiscoverItem],
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

    /// Capped at ~15 so it doesn't dwarf the curated picks.
    func fetchSimilarForAnchors(
        anchorIds: [Int],
        kind: String,
        libraryMode: String
    ) async -> [DiscoverItem] {
        let tmdb = tmdbClient
        let radarrClient = radarrClient
        let sonarrClient = sonarrClient

        async let libraryMapFetch: [Int: LibraryOwnership] = (kind == "series")
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
                                guard let first = await Self.matchedMovie((s.title, s.year, s.id), client: radarrClient) else { return nil }
                                guard let result = SearchResult(radarr: first, baseURL: radarrClient.config.baseURL) else { return nil }
                                return DiscoverItem(result: result, kind: .movie,
                                                    reason: String(localized: "Similar to what you kept", bundle: .module))
                            }.compactMap { $0 }
                            return (idx, out)
                        } else {
                            let summaries = try await tmdb.recommendedTV(seriesId: anchorId)
                            let out: [DiscoverItem] = await ParallelResolve.orderedMap(Array(summaries.prefix(5)), width: 5) { s -> DiscoverItem? in
                                guard let first = await Self.matchedSeries((s.name, s.year, s.id), client: sonarrClient) else { return nil }
                                guard let result = SearchResult(sonarr: first, baseURL: sonarrClient.config.baseURL) else { return nil }
                                return DiscoverItem(result: result, kind: .show,
                                                    reason: String(localized: "Similar to what you kept", bundle: .module))
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

        let libraryMap = await libraryMapFetch

        var seen = Set<String>()
        var out: [DiscoverItem] = []
        for anchorList in perAnchor {
            for item in anchorList {
                guard seen.insert(item.dedupKey).inserted else { continue }
                let metadataId = item.result.externalId
                if let ownership = libraryMap[metadataId] {
                    if libraryMode == "new" { continue }
                    let owned = item.result.withLibraryOwnership(ownership)
                    out.append(DiscoverItem(result: owned, kind: item.kind))
                } else {
                    out.append(item)
                }
            }
        }
        return out
    }

    // MARK: - Pick resolution

    /// An exact `tmdb:` ref is trusted only when the hit carries that id —
    /// older Sonarr searches the literal text; otherwise the title decides.
    nonisolated static func matchedMovie(_ pick: QuizDeckPipeline.Pick, client: RadarrClient) async -> ArrMovie? {
        if let id = pick.tmdbId,
           let hit = ((await Self.discoverLog.attempt("quiz movie lookup", { try await client.lookupMovies(term: "tmdb:\(id)") })) ?? []).first(where: { $0.tmdbId == id }) {
            return hit
        }
        return await matchedHit(title: pick.title, year: pick.year,
                                lookup: { term in (await Self.discoverLog.attempt("quiz movie lookup", { try await client.lookupMovies(term: term) })) ?? [] },
                                candidate: { hit in
                                    PickMatcher.Candidate(titles: [hit.title, hit.originalTitle].compactMap { $0 }
                                                            + (hit.alternateTitles ?? []).compactMap(\.title),
                                                          year: hit.year, votes: hit.ratings?.tmdb?.votes)
                                })
    }

    nonisolated static func matchedSeries(_ pick: QuizDeckPipeline.Pick, client: SonarrClient) async -> ArrSeries? {
        if let id = pick.tmdbId,
           let hit = ((await Self.discoverLog.attempt("quiz series lookup", { try await client.lookupSeries(term: "tmdb:\(id)") })) ?? []).first(where: { $0.tmdbId == id }) {
            return hit
        }
        return await matchedHit(title: pick.title, year: pick.year,
                                lookup: { term in (await Self.discoverLog.attempt("quiz series lookup", { try await client.lookupSeries(term: term) })) ?? [] },
                                candidate: { hit in
                                    PickMatcher.Candidate(titles: [hit.title] + (hit.alternateTitles ?? []).compactMap(\.title),
                                                          year: hit.year, votes: hit.ratings?.votes)
                                })
    }

    /// "Title Year" first; when none of those hits is the pick, one retry on
    /// the bare title — the arr's year parsing sometimes buries the right row.
    nonisolated static func matchedHit<Hit>(title: String, year: Int?,
                                            lookup: (String) async -> [Hit],
                                            candidate: (Hit) -> PickMatcher.Candidate) async -> Hit? {
        let hits = await lookup(lookupTerm(title: title, year: year, tmdbId: nil))
        if let index = PickMatcher.bestIndex(title: title, year: year, in: hits.map(candidate)) {
            return hits[index]
        }
        guard year != nil else { return nil }
        let bare = await lookup(title)
        return PickMatcher.bestIndex(title: title, year: year, in: bare.map(candidate)).map { bare[$0] }
    }

    private func nowPicks(kind: String) async throws -> [QuizDeckPipeline.Pick] {
        let tmdb = tmdbClient
        if kind == "movie" {
            // The user's country, not the app language: "in cinemas" is a place.
            let region = Locale.current.region?.identifier
            return try await tmdb.moviesInCinemas(region: region).map { ($0.title, $0.year, $0.id) }
        }
        return try await tmdb.seriesOnAir().map { ($0.name, $0.year, $0.id) }
    }

    nonisolated static func swipeMedia(_ kind: String) -> SwipeSignal.Media {
        kind == "series" ? .show : .movie
    }

    nonisolated static func unresolvedNote(_ labels: [String]) -> String {
        guard !labels.isEmpty else { return "." }
        let shown = labels.prefix(8).joined(separator: ", ")
        return ": \(shown)\(labels.count > 8 ? ", …" : "")."
    }

}
