import Foundation

// The library-facing tools: the two list tools and `check_titles`.
//
// All three read `LibraryIndex` rather than fetching, so a turn that lists,
// suggests and checks pays for the library once. All three also answer the
// question the model genuinely cannot answer on its own — "what do I already
// own, and have I seen it" — and leave every judgement call (is this
// *atmospheric*, is this *a drama*) to the model by shipping the facts inline.

extension LocalToolBackend {

    /// How many rows a filtered list may print before it starts counting
    /// instead. Generous on purpose: one big result costs a fraction of what a
    /// second LLM round costs, and paging a library through an agent is the
    /// slowest way to answer anything.
    static var libraryRowCap: Int { 100 }
    /// Draw size for an unfiltered call.
    static var librarySampleSize: Int { 40 }

    // MARK: - Shared parsing

    static func libraryQuery(_ args: JSONValue) -> LibraryQuery {
        LibraryQuery(
            title: stringArg(args, key: "query"),
            genre: stringArg(args, key: "genre"),
            startYear: optionalIntArg(args, key: "startYear"),
            endYear: optionalIntArg(args, key: "endYear"),
            unwatchedOnly: optionalBoolArg(args, key: "unwatched") ?? false
        )
    }

    /// Watch state is only knowable with a media server connected. Everywhere
    /// below, "no server" means the marker is simply absent — never a printed
    /// "not watched", which would be a claim we can't back.
    var watchStateAvailable: Bool { mediaServer.isConfigured }

    func isWatched(_ keys: [MediaServerExternalKey]) -> Bool {
        watchStateAvailable && MediaServerIndex.shared.isWatched(keys)
    }

    // MARK: - radarr_get_movies

    func listMovies(_ args: JSONValue) async throws -> ToolCallOutput {
        guard radarr.isConfigured else {
            return ToolCallOutput(text: "Radarr is not configured.")
        }
        let query = Self.libraryQuery(args)
        let all = await LibraryIndex.shared.movies(config: radarr)
        let matched = LibraryFilter.apply(all, query: query) { isWatched($0.mediaServerKeys) }

        let shown = query.isUnfiltered
            ? LibraryFilter.sample(matched, count: Self.librarySampleSize)
            : Array(matched.prefix(Self.libraryRowCap))

        let text = libraryText(
            serviceName: "Radarr", noun: "movie", nounPlural: "movies",
            total: all.count, matched: matched.count, shown: shown,
            query: query, nearest: LibraryFilter.nearest(to: query.title, in: all),
            line: { rec in
                let ids = [rec.id.map { "movieId=\($0)" }, rec.tmdbId.map { "tmdbId=\($0)" }]
                    .compactMap { $0 }.joined(separator: ", ")
                return Self.libraryLine(
                    title: rec.title ?? "(untitled)", year: rec.year,
                    genres: rec.filterGenres, rating: rec.filterRating,
                    state: (rec.hasFile ?? false) ? "downloaded" : "missing",
                    watched: isWatched(rec.mediaServerKeys),
                    ids: ids
                )
            },
            nearestLine: { "\($0.title ?? "(untitled)")\($0.year.map { y in " (\(y))" } ?? "")" }
        )
        return ToolCallOutput(text: text, rich: .libraryMovies(shown))
    }

    // MARK: - sonarr_get_series

    func listSeries(_ args: JSONValue) async throws -> ToolCallOutput {
        guard sonarr.isConfigured else {
            return ToolCallOutput(text: "Sonarr is not configured.")
        }
        let query = Self.libraryQuery(args)
        let seasonFilter = Self.optionalIntArg(args, key: "seasonNumber")
        let all = await LibraryIndex.shared.series(config: sonarr)
        let matched = LibraryFilter.apply(all, query: query) { isWatched($0.mediaServerKeys) }

        let shown = query.isUnfiltered
            ? LibraryFilter.sample(matched, count: Self.librarySampleSize)
            : Array(matched.prefix(Self.libraryRowCap))

        let text = libraryText(
            serviceName: "Sonarr", noun: "series", nounPlural: "series",
            total: all.count, matched: matched.count, shown: shown,
            query: query, nearest: LibraryFilter.nearest(to: query.title, in: all),
            line: { rec in
                let ids = [rec.id.map { "seriesId=\($0)" }, rec.tvdbId.map { "tvdbId=\($0)" }]
                    .compactMap { $0 }.joined(separator: ", ")
                let seasons = Self.seasonsSummary(for: rec, filter: seasonFilter)
                return Self.libraryLine(
                    title: rec.title ?? "(untitled)", year: rec.year,
                    genres: rec.filterGenres, rating: rec.filterRating,
                    state: seasons.isEmpty ? (rec.status ?? "") : seasons,
                    watched: isWatched(rec.mediaServerKeys),
                    ids: ids
                )
            },
            nearestLine: { "\($0.title ?? "(untitled)")\($0.year.map { y in " (\(y))" } ?? "")" }
        )
        return ToolCallOutput(text: text, rich: .librarySeries(shown))
    }

    // MARK: - check_titles

    /// Batch ownership + watch state for titles the model already has in hand.
    ///
    /// This is the tool that keeps the division of labour honest: the model
    /// brings the taste ("essence of the 90s, romantic, not bleak"), this
    /// brings the one fact it can't know. One call for twenty titles instead of
    /// twenty lookups — the round trip, not the HTTP, is what costs.
    func checkTitles(_ args: JSONValue) async throws -> ToolCallOutput {
        let wanted = Self.titleQueries(args)
        guard !wanted.isEmpty else {
            return ToolCallOutput(text: "check_titles needs a non-empty 'titles' array (strings, or {title, year} objects).")
        }
        guard radarr.isConfigured || sonarr.isConfigured else {
            return ToolCallOutput(text: "Neither Radarr nor Sonarr is configured — nothing to check against.")
        }
        let capped = Array(wanted.prefix(50))
        async let moviesFetch = LibraryIndex.shared.movies(config: radarr)
        async let seriesFetch = LibraryIndex.shared.series(config: sonarr)
        let movies = await moviesFetch
        let series = await seriesFetch

        var lines: [String] = []
        var owned = 0
        for item in capped {
            let label = item.year.map { "\(item.title) (\($0))" } ?? item.title
            if let hit = TitleMatch.best(query: item.title, year: item.year,
                                         candidates: movies,
                                         title: { $0.title ?? "" }, year: { $0.year }) {
                owned += 1
                let id = hit.id.map { "movieId=\($0)" } ?? "movieId=?"
                let file = (hit.hasFile ?? false) ? "downloaded" : "not downloaded"
                let watch = watchMark(isWatched(hit.mediaServerKeys))
                lines.append("• \(label) — in library as \(hit.title ?? label)\(hit.year.map { " (\($0))" } ?? ""), \(id), \(file)\(watch)")
            } else if let hit = TitleMatch.best(query: item.title, year: item.year,
                                                candidates: series,
                                                title: { $0.title ?? "" }, year: { $0.year }) {
                owned += 1
                let id = hit.id.map { "seriesId=\($0)" } ?? "seriesId=?"
                let seasons = Self.seasonsSummary(for: hit, filter: nil)
                let watch = watchMark(isWatched(hit.mediaServerKeys))
                lines.append("• \(label) — in library as \(hit.title ?? label), \(id)\(seasons)\(watch)")
            } else {
                lines.append("• \(label) — NOT in library")
            }
        }

        var out = "Checked \(capped.count) title\(capped.count == 1 ? "" : "s"): \(owned) in the library, \(capped.count - owned) not.\n"
        out += lines.joined(separator: "\n")
        if !watchStateAvailable {
            out += "\nWatch state unknown — no media server is connected, so 'watched' is not reported for any of these."
        }
        if wanted.count > capped.count {
            out += "\n(\(wanted.count - capped.count) further titles were not checked — 50 per call.)"
        }
        return ToolCallOutput(text: out)
    }

    /// `titles: ["Dune 2021", {title: "Andor", year: 2022}]` — both forms, since
    /// a model that has just written prose will reach for bare strings.
    static func titleQueries(_ value: JSONValue) -> [(title: String, year: Int?)] {
        guard case .object(let dict) = value, case .array(let arr) = dict["titles"] else { return [] }
        return arr.compactMap { entry -> (String, Int?)? in
            switch entry {
            case .string(let raw):
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                // "Dune 2021" — a trailing year is how a model writes this in
                // prose, and it is the difference between the 1984 and the 2021.
                if let year = extractYear(from: trimmed), trimmed.hasSuffix(String(year)) {
                    let title = String(trimmed.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                    return title.isEmpty ? (trimmed, nil) : (title, year)
                }
                return (trimmed, nil)
            case .object(let obj):
                guard case .string(let title) = obj["title"], !title.isEmpty else { return nil }
                let year: Int? = {
                    switch obj["year"] {
                    case .number(let n): return Int(n)
                    case .string(let s): return Int(s)
                    default: return nil
                    }
                }()
                return (title, year)
            default:
                return nil
            }
        }
    }

    // MARK: - Formatting

    private func watchMark(_ watched: Bool) -> String {
        guard watchStateAvailable else { return "" }
        return watched ? ", watched" : ", not watched"
    }

    static func libraryLine(title: String, year: Int?, genres: [String],
                            rating: Double?, state: String,
                            watched: Bool, ids: String) -> String {
        var parts: [String] = []
        let yearPart = year.map { " (\($0))" } ?? ""
        parts.append("\(title)\(yearPart)")
        if !genres.isEmpty { parts.append(genres.prefix(3).joined(separator: "/")) }
        if let rating { parts.append(String(format: "★%.1f", rating)) }
        if !state.isEmpty { parts.append(state) }
        if watched { parts.append("watched") }
        if !ids.isEmpty { parts.append(ids) }
        return "• " + parts.joined(separator: " · ")
    }

    /// Header + rows + the honest tail. Three things this never does: return an
    /// empty answer to a title query (the nearest titles come back instead),
    /// print the first N of a big library as if they were the answer (an
    /// unfiltered call is labelled a sample), or hide that rows were cut.
    private func libraryText<T>(
        serviceName: String, noun: String, nounPlural: String,
        total: Int, matched: Int, shown: [T],
        query: LibraryQuery,
        nearest: [T],
        line: (T) -> String,
        nearestLine: (T) -> String
    ) -> String {
        if total == 0 {
            return "\(serviceName) library is empty."
        }
        if matched == 0 {
            var out = "No \(nounPlural) in the library match \(Self.describe(query))."
            if !query.title.isEmpty, !nearest.isEmpty {
                out += " Closest titles held: " + nearest.map(nearestLine).joined(separator: ", ") + "."
            }
            if query.unwatchedOnly, !watchStateAvailable {
                out += " Note: no media server is connected, so 'unwatched' could not be applied."
            }
            return out
        }

        var out: String
        if query.isUnfiltered {
            // The sample is for flavour — "what kind of shelf is this" — and
            // saying so stops the model treating 40 rows out of 3000 as
            // evidence that anything absent from them is not owned.
            out = "\(serviceName) library — \(total) \(total == 1 ? noun : nounPlural). "
                + "Here are \(shown.count) at random (ask again for a different draw). "
                + "This sample says NOTHING about whether a particular title is owned — use check_titles for that:"
        } else {
            out = "\(serviceName) library — \(matched) of \(total) \(nounPlural) match \(Self.describe(query)):"
        }
        out += "\n" + shown.map(line).joined(separator: "\n")
        if matched > shown.count, !query.isUnfiltered {
            out += "\n(\(matched - shown.count) more matched — narrow the filter to see them.)"
        }
        if query.unwatchedOnly, !watchStateAvailable {
            out += "\nNote: no media server is connected, so 'unwatched' was ignored — watch state is unknown."
        }
        return out
    }

    static func describe(_ query: LibraryQuery) -> String {
        var parts: [String] = []
        if !query.title.isEmpty { parts.append("'\(query.title)'") }
        if !query.genre.isEmpty { parts.append("genre \(query.genre)") }
        switch (query.startYear, query.endYear) {
        case let (from?, to?): parts.append("\(from)–\(to)")
        case let (from?, nil):  parts.append("\(from) and later")
        case let (nil, to?):    parts.append("up to \(to)")
        case (nil, nil):        break
        }
        if query.unwatchedOnly { parts.append("unwatched") }
        return parts.isEmpty ? "the whole library" : parts.joined(separator: " · ")
    }
}
