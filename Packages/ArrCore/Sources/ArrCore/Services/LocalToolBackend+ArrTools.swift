import os
import Foundation
import MediaKit

extension LocalToolBackend {
    // MARK: - Tool implementations

    func searchSeries(_ args: JSONValue) async throws -> ToolCallOutput {
        try await runSearch(args: args, source: .sonarr, config: sonarr, kind: "series",
                            yearAware: true, rich: { .searchSeriesResults($0) })
    }

    func searchMovie(_ args: JSONValue) async throws -> ToolCallOutput {
        try await runSearch(args: args, source: .radarr, config: radarr, kind: "movie",
                            yearAware: true, rich: { .searchMovieResults($0) })
    }

    /// Resolves the model's own taste picks through the arr lookup so the chat shows actionable cards;
    /// `tmdb_discover_*` is algorithmic and poor at taste-based queries.
    func suggestTitles(_ args: JSONValue) async throws -> ToolCallOutput {
        let kind = Self.stringArg(args, key: "kind").lowercased()
        guard kind == "series" || kind == "movie" else {
            return ToolCallOutput(text: "suggest_titles requires kind='series' or kind='movie'.")
        }
        let items = Self.suggestItems(args)
        guard !items.isEmpty else {
            return ToolCallOutput(text: "suggest_titles needs a non-empty 'items' array of {title, year?} picks.")
        }
        // A deep library owns most canonical picks, so resolving 40 at once beats another round.
        let capped = Array(items.prefix(40))
        // Ownership is a fact, not a judgement, so it is safe to drop here — unlike genre or mood.
        let excludeOwned = Self.optionalBoolArg(args, key: "exclude_owned") ?? false

        let source: QueueItem.Source = (kind == "series") ? .sonarr : .radarr
        let config = (kind == "series") ? sonarr : radarr
        guard config.isConfigured else {
            return ToolCallOutput(text: "\(source.displayName) is not configured — can't resolve \(kind) suggestions.")
        }
        let client = SearchClient(config: config, source: source)

        // Owned cards need `inLibraryArrId` so a tap opens DetailView instead of SearchAddPanel.
        async let libraryMapFetch: [Int: LibraryOwnership] = (kind == "series")
            ? sonarrLibraryByTVDBId()
            : radarrLibraryByTMDBId()

        // Collected by index: the model's ordering is relevance signal.
        var resolved: [(index: Int, result: SearchResult)] = []
        var missing: [(index: Int, label: String)] = []

        await withTaskGroup(of: (Int, Result<SearchResult?, Error>).self) { group in
            for (idx, item) in capped.enumerated() {
                group.addTask { [client] in
                    do {
                        let query = Self.lookupTerm(title: item.title, year: item.year, tmdbId: item.tmdbId)
                        let hits = try await Self.searchWithYearAwareness(client: client, query: query)
                        // An id ref is exact; a titled pick must BE one of the
                        // hits, or it is reported missing rather than swapped.
                        let match = item.tmdbId != nil ? hits.first : PickMatcher.bestIndex(
                            title: item.title, year: item.year,
                            in: hits.map { PickMatcher.Candidate(titles: [$0.title], year: $0.year, votes: $0.votes) }
                        ).map { hits[$0] }
                        return (idx, .success(match))
                    } catch {
                        return (idx, .failure(error))
                    }
                }
            }
            for await (idx, outcome) in group {
                switch outcome {
                case .success(let result?):
                    resolved.append((idx, result))
                case .success(nil), .failure:
                    let label = capped[idx].year.map { "\(capped[idx].title) (\($0))" } ?? capped[idx].title
                    missing.append((idx, label))
                }
            }
        }
        resolved.sort { $0.index < $1.index }
        missing.sort { $0.index < $1.index }

        let libraryMap = await libraryMapFetch
        // `.id` is tvdbId for series / tmdbId for movies, the library map's keys.
        let tagged = resolved.map { entry -> SearchResult in
            guard let ownership = libraryMap[entry.result.externalId] else { return entry.result }
            return entry.result.withLibraryOwnership(ownership)
        }
        let afterOwned = excludeOwned ? tagged.filter { $0.inLibraryArrId == nil } : tagged
        let droppedAsOwned = tagged.count - afterOwned.count

        // Cross-call memory: in a big library every retry otherwise resurfaces the same lone unowned pick.
        // MCP has no cards and outlives any one client conversation, so it keeps none.
        let results = headlessSurface ? afterOwned : afterOwned.filter { !surfacedSuggestionIds.contains($0.id) }
        let repeatCount = afterOwned.count - results.count
        if !headlessSurface { surfacedSuggestionIds.formUnion(results.map(\.id)) }

        if results.isEmpty {
            if repeatCount > 0 {
                return ToolCallOutput(text: "Every surviving pick in this call was ALREADY surfaced as a card earlier in this conversation (\(repeatCount) repeat\(repeatCount == 1 ? "" : "s"))\(droppedAsOwned > 0 ? ", and \(droppedAsOwned) more are in the library" : ""). STOP calling suggest_titles for this ask — the user can see those cards. Summarize what is on screen or ask them a question instead.")
            }
            if droppedAsOwned > 0 {
                return ToolCallOutput(text: "All \(droppedAsOwned) resolved picks are already in the user's library. Do NOT immediately guess another batch — the canon is owned. Go for genuinely deeper cuts in ONE more call at most, or first run check_titles on a 25-40 candidate list and suggest only what it reports as missing.")
            }
            return ToolCallOutput(text: "None of those picks resolved through \(source.displayName) lookup. Do NOT retry the same titles with rephrasings; check spelling/years or pick different titles.")
        }

        var text = Self.formatSuggestionsCondensed(
            resolved: results,
            missing: missing.map { $0.label },
            kind: kind
        )
        if droppedAsOwned > 0 {
            text += "\n\(droppedAsOwned) pick\(droppedAsOwned == 1 ? " was" : "s were") dropped as already in the library."
        }
        if repeatCount > 0 {
            text += "\n\(repeatCount) repeat\(repeatCount == 1 ? "" : "s") of cards already shown earlier were dropped."
        }
        text += "\nPresent these to the user now. Do NOT call suggest_titles again for the same ask — if they want more, they will say so."
        let rich: ChatRichContent = (kind == "series") ? .searchSeriesResults(results) : .searchMovieResults(results)
        return ToolCallOutput(text: text, rich: rich)
    }

    /// Drops malformed entries so one fumbled item doesn't kill the call. No `reason` field:
    /// model-written reasons became plot blurbs and slowed generation.
    nonisolated static func suggestItems(_ value: JSONValue) -> [(title: String, year: Int?, tmdbId: Int?)] {
        guard case .object(let dict) = value, case .array(let arr) = dict["items"] else { return [] }
        func intValue(_ raw: JSONValue?) -> Int? {
            switch raw {
            case .number(let n): return Int(n)
            case .string(let s): return Int(s)
            default: return nil
            }
        }
        return arr.compactMap { entry -> (String, Int?, Int?)? in
            guard case .object(let obj) = entry,
                  case .string(let title) = obj["title"],
                  !title.isEmpty else { return nil }
            return (title, intValue(obj["year"]), intValue(obj["tmdbId"]))
        }
    }

    /// An exact `tmdb:` ref when the model supplied the id (no wrong-remake risk), else title plus year.
    nonisolated static func lookupTerm(title: String, year: Int?, tmdbId: Int?) -> String {
        if let tmdbId { return "tmdb:\(tmdbId)" }
        return year.map { "\(title) \($0)" } ?? title
    }

    /// Kept under ~300 tokens for 15 items to spare the local LLM's context window.
    nonisolated static func formatSuggestionsCondensed(
        resolved: [SearchResult],
        missing: [String],
        kind: String
    ) -> String {
        if resolved.isEmpty && missing.isEmpty {
            return "No suggestions to surface."
        }
        var out: [String] = []
        if !resolved.isEmpty {
            let lines = resolved.map { r -> String in
                let yearPart = r.year.map { " (\($0))" } ?? ""
                // The media server only knows owned titles, so an unowned pick never carries a marker.
                let watched = MediaServerIndex.shared.isWatched(r.mediaServerKeys) ? ", watched" : ""
                let state = (r.inLibraryArrId != nil) ? " [in library\(watched)]" : ""
                return "• \(r.title)\(yearPart)\(state)"
            }
            out.append("Surfaced \(resolved.count) \(kind) card\(resolved.count == 1 ? "" : "s") in the chat:")
            out.append(lines.joined(separator: "\n"))
        }
        if !missing.isEmpty {
            out.append("Couldn't resolve: \(missing.joined(separator: ", ")).")
        }
        return out.joined(separator: "\n")
    }

    /// Surfaces year-matching hits first: TMDB's popularity ranking buries upcoming or niche entries.
    nonisolated static func searchWithYearAwareness(client: SearchClient, query: String) async throws -> [SearchResult] {
        let primary = try await client.lookup(query: query)
        guard let year = extractYear(from: query) else { return primary }
        let matched = primary.filter { $0.year == year }
        let rest = primary.filter { $0.year != year }
        if !matched.isEmpty {
            return matched + rest
        }
        // Re-query without the year so the lookup has a cleaner term, then filter by year.
        let bareQuery = query
            .replacingOccurrences(of: String(year), with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ()[]-,"))
        guard bareQuery != query, !bareQuery.isEmpty else { return primary }
        let secondary = try await client.lookup(query: bareQuery)
        let secondaryYear = secondary.filter { $0.year == year }
        // Keyed on row identity, not the foreign key: TMDB-sourced series have no foreign key yet.
        var seen = Set<String>()
        var merged: [SearchResult] = []
        for r in secondaryYear + primary + secondary where seen.insert(r.id).inserted {
            merged.append(r)
        }
        return merged
    }

    nonisolated static func extractYear(from query: String) -> Int? {
        let now = Calendar.current.component(.year, from: Date())
        guard let regex = try? NSRegularExpression(pattern: #"\b(19|20)\d{2}\b"#) else { return nil }
        let ns = query as NSString
        let matches = regex.matches(in: query, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            if let year = Int(ns.substring(with: m.range)), year <= now + 5 {
                return year
            }
        }
        return nil
    }

    nonisolated static func seasonsSummary(for rec: ArrSeries, filter: Int?) -> String {
        let seasons = rec.seasons?.filter { $0.seasonNumber > 0 } ?? []
        guard !seasons.isEmpty else { return "" }
        if let target = filter {
            guard let s = seasons.first(where: { $0.seasonNumber == target }) else {
                return " · S\(target): not found in record"
            }
            return " · " + Self.formatSeasonLine(s)
        }
        let shown = seasons.prefix(12).map(Self.formatSeasonLine).joined(separator: ", ")
        let trailing = seasons.count > 12 ? ", …" : ""
        return " · seasons: \(shown)\(trailing)"
    }

    nonisolated static func formatSeasonLine(_ s: ArrSeason) -> String {
        let mon = (s.monitored ?? false) ? "✓" : "✗"
        let have = s.statistics?.episodeFileCount ?? 0
        let total = s.statistics?.totalEpisodeCount ?? s.statistics?.episodeCount ?? 0
        return "S\(s.seasonNumber) \(mon) \(have)/\(total)"
    }

    // MARK: - Lidarr tool implementations

    func searchArtist(_ args: JSONValue) async throws -> ToolCallOutput {
        try await runSearchArtist(args: args)
    }

    func listArtists(_ args: JSONValue) async throws -> ToolCallOutput {
        try await runLibraryList(
            args: args, source: .lidarr, config: lidarr,
            itemNounSingular: "artist", itemNounPlural: "artists",
            fetch: { try await self.lidarrClient.fetchAllArtists() },
            filterMatch: { rec, q in (rec.artistName ?? "").lowercased().contains(q) },
            line: { r in
                let name = r.artistName ?? "(untitled)"
                // artistId first: `lidarr_get_artist_albums` requires it and only this tool supplies it;
                // without it the model guessed ids.
                let ids = [r.id.map { "artistId=\($0)" }, r.foreignArtistId.map { "foreignArtistId=\($0)" }]
                    .compactMap { $0 }.joined(separator: " · ")
                let albumCount = r.statistics?.albumCount.map { " · \($0) album\($0 == 1 ? "" : "s")" } ?? ""
                return "• \(name)\(ids.isEmpty ? "" : " · " + ids)\(albumCount)"
            },
            rich: { .libraryArtists($0) }
        )
    }

    // MARK: - Whisparr tool implementations

    func searchScene(_ args: JSONValue) async throws -> ToolCallOutput {
        try await runSearch(args: args, source: .whisparr, config: whisparr, kind: "scene",
                            yearAware: false, rich: { .searchSceneResults($0) })
    }

    func listScenes(_ args: JSONValue) async throws -> ToolCallOutput {
        try await runLibraryList(
            args: args, source: .whisparr, config: whisparr,
            itemNounSingular: "scene", itemNounPlural: "scenes",
            fetch: { try await self.whisparrClient.fetchAllMovies() },
            filterMatch: { rec, q in rec.title.lowercased().contains(q) },
            line: { r in
                let title = r.title
                let yearPart = r.year.map { " (\($0))" } ?? ""
                let fileMark = (r.hasFile ?? false) ? " · downloaded" : " · missing"
                return "• \(title)\(yearPart)\(fileMark)"
            },
            rich: { .libraryScenes($0) }
        )
    }
}
