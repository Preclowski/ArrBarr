import Foundation

/// In-process tool backend. Uses ArrCore's existing Sonarr/Radarr clients.
/// Exposes the same 6 tools as mcp-arr, but with zero external dependencies.
public actor LocalToolBackend: ToolBackend {
    private let sonarr: ServiceConfig
    private let radarr: ServiceConfig
    private let lidarr: ServiceConfig
    private let whisparr: ServiceConfig
    private let aiKnowsAboutWhisparr: Bool

    public init(sonarr: ServiceConfig, radarr: ServiceConfig, lidarr: ServiceConfig = .empty,
                whisparr: ServiceConfig = .empty, aiKnowsAboutWhisparr: Bool = false) {
        self.sonarr = sonarr
        self.radarr = radarr
        self.lidarr = lidarr
        self.whisparr = whisparr
        self.aiKnowsAboutWhisparr = aiKnowsAboutWhisparr
    }

    public func listTools() async throws -> [MCPTool] {
        ChatToolCatalog.tools(includeWhisparr: aiKnowsAboutWhisparr)
    }

    public func callTool(name: String, arguments: JSONValue) async throws -> ToolCallOutput {
        // Guard Whisparr tools when the toggle is off
        if name.hasPrefix("whisparr_") && !aiKnowsAboutWhisparr {
            return ToolCallOutput(text: "Whisparr AI access is disabled in Settings.")
        }
        switch name {
        case "sonarr_search":       return try await searchSeries(arguments)
        case "radarr_search":       return try await searchMovie(arguments)
        case "sonarr_get_series":   return try await listSeries(arguments)
        case "radarr_get_movies":   return try await listMovies(arguments)
        case "sonarr_get_calendar": return try await sonarrCalendar()
        case "radarr_get_calendar": return try await radarrCalendar()
        case "sonarr_add_series":   return try await addSeries(arguments)
        case "radarr_add_movie":    return try await addMovie(arguments)
        case "lidarr_search":       return try await searchArtist(arguments)
        case "lidarr_get_artists":  return try await listArtists(arguments)
        case "lidarr_get_calendar": return try await lidarrCalendar()
        case "lidarr_add_artist":   return try await addArtist(arguments)
        case "whisparr_search":     return try await searchScene(arguments)
        case "whisparr_get_movies": return try await listScenes(arguments)
        case "whisparr_get_calendar": return try await whisparrCalendar()
        case "whisparr_add_scene":  return try await addScene(arguments)
        default:
            throw LocalToolError.unknownTool(name)
        }
    }

    // MARK: - Tool implementations

    private func searchSeries(_ args: JSONValue) async throws -> ToolCallOutput {
        let query = Self.stringArg(args, key: "query")
        guard !query.isEmpty else {
            return ToolCallOutput(text: "Please provide a search query.")
        }
        guard sonarr.isConfigured else {
            return ToolCallOutput(text: "Sonarr is not configured.")
        }
        let client = SearchClient(config: sonarr, source: .sonarr)
        let results = try await Self.searchWithYearAwareness(client: client, query: query)
        let text = Self.formatSearchResultsCondensed(results, query: query, kind: "series")
        return ToolCallOutput(text: text, rich: .searchSeriesResults(results))
    }

    private func searchMovie(_ args: JSONValue) async throws -> ToolCallOutput {
        let query = Self.stringArg(args, key: "query")
        guard !query.isEmpty else {
            return ToolCallOutput(text: "Please provide a search query.")
        }
        guard radarr.isConfigured else {
            return ToolCallOutput(text: "Radarr is not configured.")
        }
        let client = SearchClient(config: radarr, source: .radarr)
        let results = try await Self.searchWithYearAwareness(client: client, query: query)
        let text = Self.formatSearchResultsCondensed(results, query: query, kind: "movie")
        return ToolCallOutput(text: text, rich: .searchMovieResults(results))
    }

    /// Detect a 4-digit year in the query and surface year-matching hits to
    /// the top of the result list. Helps when TMDB's popularity ranking
    /// buries upcoming / niche entries under same-titled hits from years ago.
    private static func searchWithYearAwareness(client: SearchClient, query: String) async throws -> [SearchResult] {
        let primary = try await client.lookup(query: query)
        guard let year = extractYear(from: query) else { return primary }
        // If we already have year-matching hits in the primary list, surface them.
        let matched = primary.filter { $0.year == year }
        let rest = primary.filter { $0.year != year }
        if !matched.isEmpty {
            return matched + rest
        }
        // Year wasn't found in the year-tagged search. Re-query without the
        // year so TMDB's lookup has a cleaner term, then filter by year.
        let bareQuery = query
            .replacingOccurrences(of: String(year), with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ()[]-,"))
        guard bareQuery != query, !bareQuery.isEmpty else { return primary }
        let secondary = try await client.lookup(query: bareQuery)
        let secondaryYear = secondary.filter { $0.year == year }
        // Merge: year-matching from broader search first, then everything else.
        var seen = Set<Int>()
        var merged: [SearchResult] = []
        for r in secondaryYear + primary + secondary where seen.insert(r.id).inserted {
            merged.append(r)
        }
        return merged
    }

    private static func extractYear(from query: String) -> Int? {
        // Look for any 4-digit run that's a plausible year (1900..currentYear+5).
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

    private func listSeries(_ args: JSONValue) async throws -> ToolCallOutput {
        guard sonarr.isConfigured else {
            return ToolCallOutput(text: "Sonarr is not configured.")
        }
        let filter = Self.stringArg(args, key: "query").lowercased()
        let client = SonarrClient(config: sonarr)
        let all = try await client.fetchAllSeries()
        let matched = filter.isEmpty
            ? all
            : all.filter { ($0.title ?? "").lowercased().contains(filter) }
        let text = Self.formatSeriesLibraryCondensed(matched, filter: filter)
        return ToolCallOutput(text: text, rich: .librarySeries(matched))
    }

    private func listMovies(_ args: JSONValue) async throws -> ToolCallOutput {
        guard radarr.isConfigured else {
            return ToolCallOutput(text: "Radarr is not configured.")
        }
        let filter = Self.stringArg(args, key: "query").lowercased()
        let client = RadarrClient(config: radarr)
        let all = try await client.fetchAllMovies()
        let matched = filter.isEmpty
            ? all
            : all.filter { ($0.title ?? "").lowercased().contains(filter) }
        let text = Self.formatMovieLibraryCondensed(matched, filter: filter)
        return ToolCallOutput(text: text, rich: .libraryMovies(matched))
    }

    private func sonarrCalendar() async throws -> ToolCallOutput {
        guard sonarr.isConfigured else {
            return ToolCallOutput(text: "Sonarr is not configured.")
        }
        let client = SonarrClient(config: sonarr)
        let items = try await client.fetchCalendar()
        let text = Self.formatCalendarCondensed(items)
        return ToolCallOutput(text: text, rich: .calendar(items))
    }

    private func radarrCalendar() async throws -> ToolCallOutput {
        guard radarr.isConfigured else {
            return ToolCallOutput(text: "Radarr is not configured.")
        }
        let client = RadarrClient(config: radarr)
        let items = try await client.fetchCalendar()
        let text = Self.formatCalendarCondensed(items)
        return ToolCallOutput(text: text, rich: .calendar(items))
    }

    private func addSeries(_ args: JSONValue) async throws -> ToolCallOutput {
        let tvdbId = Self.intArg(args, key: "tvdbId")
        let title = Self.stringArg(args, key: "title")
        let chosenProfileId = Self.intArg(args, key: "qualityProfileId")
        let chosenFolderPath = Self.stringArg(args, key: "rootFolderPath")
        guard tvdbId != 0 || !title.isEmpty else {
            return ToolCallOutput(text: "Need a tvdbId (preferred) or title to add a series. Run sonarr_search first.")
        }
        guard sonarr.isConfigured else {
            return ToolCallOutput(text: "Sonarr is not configured.")
        }
        let client = SearchClient(config: sonarr, source: .sonarr)
        let lookupQuery = tvdbId != 0 ? "tvdb:\(tvdbId)" : title
        let candidates = try await client.lookup(query: lookupQuery)
        let chosen: SearchResult?
        if tvdbId != 0 {
            chosen = candidates.first(where: { $0.id == tvdbId }) ?? candidates.first
        } else {
            chosen = candidates.first
        }
        guard let pick = chosen else {
            return ToolCallOutput(text: "Couldn't find any series matching '\(lookupQuery)'.")
        }
        let profiles = try await client.fetchQualityProfiles()
        let folders = try await client.fetchRootFolders()
        let profile = profiles.first(where: { $0.id == chosenProfileId }) ?? profiles.first
        let folder = folders.first(where: { $0.path == chosenFolderPath }) ?? folders.first
        guard let profile, let folder else {
            return ToolCallOutput(text: "Sonarr is missing a quality profile or root folder.")
        }
        try await client.addSeries(
            pick,
            qualityProfileId: profile.id,
            rootFolderPath: folder.path,
            monitor: .all,
            seriesType: .standard,
            seasonFolder: true
        )
        let yearPart = pick.year.map { " (\($0))" } ?? ""
        return ToolCallOutput(text: "Added '\(pick.title)\(yearPart)' to Sonarr (profile: \(profile.name), folder: \(folder.path)).")
    }

    private func addMovie(_ args: JSONValue) async throws -> ToolCallOutput {
        let tmdbId = Self.intArg(args, key: "tmdbId")
        let title = Self.stringArg(args, key: "title")
        let chosenProfileId = Self.intArg(args, key: "qualityProfileId")
        let chosenFolderPath = Self.stringArg(args, key: "rootFolderPath")
        guard tmdbId != 0 || !title.isEmpty else {
            return ToolCallOutput(text: "Need a tmdbId (preferred) or title to add a movie. Run radarr_search first.")
        }
        guard radarr.isConfigured else {
            return ToolCallOutput(text: "Radarr is not configured.")
        }
        let client = SearchClient(config: radarr, source: .radarr)
        let lookupQuery = tmdbId != 0 ? "tmdb:\(tmdbId)" : title
        let candidates = try await client.lookup(query: lookupQuery)
        let chosen: SearchResult?
        if tmdbId != 0 {
            chosen = candidates.first(where: { $0.id == tmdbId }) ?? candidates.first
        } else {
            chosen = candidates.first
        }
        guard let pick = chosen else {
            return ToolCallOutput(text: "Couldn't find any movies matching '\(lookupQuery)'.")
        }
        let profiles = try await client.fetchQualityProfiles()
        let folders = try await client.fetchRootFolders()
        let profile = profiles.first(where: { $0.id == chosenProfileId }) ?? profiles.first
        let folder = folders.first(where: { $0.path == chosenFolderPath }) ?? folders.first
        guard let profile, let folder else {
            return ToolCallOutput(text: "Radarr is missing a quality profile or root folder.")
        }
        try await client.addMovie(
            pick,
            qualityProfileId: profile.id,
            rootFolderPath: folder.path,
            monitor: .movieOnly
        )
        let yearPart = pick.year.map { " (\($0))" } ?? ""
        return ToolCallOutput(text: "Added '\(pick.title)\(yearPart)' to Radarr (profile: \(profile.name), folder: \(folder.path)).")
    }

    // MARK: - Lidarr tool implementations

    private func searchArtist(_ args: JSONValue) async throws -> ToolCallOutput {
        let query = Self.stringArg(args, key: "query")
        guard !query.isEmpty else {
            return ToolCallOutput(text: "Please provide a search query.")
        }
        guard lidarr.isConfigured else {
            return ToolCallOutput(text: "Lidarr is not configured.")
        }
        let client = SearchClient(config: lidarr, source: .lidarr)
        let results = try await client.lookup(query: query)
        let text = Self.formatArtistSearchCondensed(results, query: query)
        return ToolCallOutput(text: text, rich: .searchArtistResults(results))
    }

    private func listArtists(_ args: JSONValue) async throws -> ToolCallOutput {
        guard lidarr.isConfigured else {
            return ToolCallOutput(text: "Lidarr is not configured.")
        }
        let filter = Self.stringArg(args, key: "query").lowercased()
        let client = LidarrClient(config: lidarr)
        let all = try await client.fetchAllArtists()
        let matched = filter.isEmpty
            ? all
            : all.filter { ($0.artistName ?? "").lowercased().contains(filter) }
        let text = Self.formatArtistLibraryCondensed(matched, filter: filter)
        return ToolCallOutput(text: text, rich: .libraryArtists(matched))
    }

    private func lidarrCalendar() async throws -> ToolCallOutput {
        guard lidarr.isConfigured else {
            return ToolCallOutput(text: "Lidarr is not configured.")
        }
        let client = LidarrClient(config: lidarr)
        let items = try await client.fetchCalendar()
        let text = Self.formatCalendarCondensed(items)
        return ToolCallOutput(text: text, rich: .calendar(items))
    }

    private func addArtist(_ args: JSONValue) async throws -> ToolCallOutput {
        let foreignArtistId = Self.stringArg(args, key: "foreignArtistId")
        let artistName = Self.stringArg(args, key: "artistName")
        let chosenProfileId = Self.intArg(args, key: "qualityProfileId")
        let chosenMetadataProfileId = Self.intArg(args, key: "metadataProfileId")
        let chosenFolderPath = Self.stringArg(args, key: "rootFolderPath")
        guard !foreignArtistId.isEmpty || !artistName.isEmpty else {
            return ToolCallOutput(text: "Need a foreignArtistId (preferred) or artistName to add an artist. Run lidarr_search first.")
        }
        guard lidarr.isConfigured else {
            return ToolCallOutput(text: "Lidarr is not configured.")
        }
        let client = SearchClient(config: lidarr, source: .lidarr)
        // Look up by name to get a full SearchResult with posterURL etc.
        let lookupQuery = !foreignArtistId.isEmpty ? artistName : artistName
        let candidates = try await client.lookup(query: lookupQuery.isEmpty ? foreignArtistId : lookupQuery)
        // Prefer exact foreign id match when we have it
        let chosen: SearchResult?
        if !foreignArtistId.isEmpty {
            chosen = candidates.first(where: { $0.foreignId == foreignArtistId }) ?? candidates.first
        } else {
            chosen = candidates.first
        }
        guard let pick = chosen else {
            return ToolCallOutput(text: "Couldn't find any artist matching '\(lookupQuery)'.")
        }
        let profiles = try await client.fetchQualityProfiles()
        let metaProfiles = try await client.fetchMetadataProfiles()
        let folders = try await client.fetchRootFolders()
        let profile = profiles.first(where: { $0.id == chosenProfileId }) ?? profiles.first
        let metaProfile = metaProfiles.first(where: { $0.id == chosenMetadataProfileId }) ?? metaProfiles.first
        let folder = folders.first(where: { $0.path == chosenFolderPath }) ?? folders.first
        guard let profile, let folder else {
            return ToolCallOutput(text: "Lidarr is missing a quality profile or root folder.")
        }
        let metaProfileId = metaProfile?.id ?? 1
        try await client.addArtist(
            pick,
            qualityProfileId: profile.id,
            metadataProfileId: metaProfileId,
            rootFolderPath: folder.path
        )
        return ToolCallOutput(text: "Added '\(pick.title)' to Lidarr (profile: \(profile.name), folder: \(folder.path)).")
    }

    // MARK: - Formatting helpers

    private static func stringArg(_ value: JSONValue, key: String) -> String {
        if case .object(let dict) = value, case .string(let s) = dict[key] {
            return s
        }
        return ""
    }

    /// Extract an integer arg. Tolerates JSON numbers OR strings (LLM might
    /// serialize "12345" instead of 12345).
    private static func intArg(_ value: JSONValue, key: String) -> Int {
        guard case .object(let dict) = value, let v = dict[key] else { return 0 }
        switch v {
        case .number(let n): return Int(n)
        case .string(let s): return Int(s) ?? 0
        default: return 0
        }
    }

    /// Condensed search result text for the LLM — id + title + year only.
    /// No overview, no rating, no year-match markers (the carousel makes those visible).
    private static func formatSearchResultsCondensed(
        _ results: [SearchResult],
        query: String,
        kind: String
    ) -> String {
        guard !results.isEmpty else { return "No results found." }
        let top = results.prefix(15)
        let idLabel = kind == "series" ? "tvdbId" : "tmdbId"
        let lines = top.map { r -> String in
            let yearPart = r.year.map { " (\($0))" } ?? ""
            return "• \(idLabel)=\(r.id) — \(r.title)\(yearPart)"
        }
        var out = "Found \(results.count) \(kind) result\(results.count == 1 ? "" : "s") for \"\(query)\". Top matches (LLM: pass \(idLabel) to \(kind == "series" ? "sonarr_add_series" : "radarr_add_movie")):"
        out += "\n" + lines.joined(separator: "\n")
        if results.count > top.count {
            out += "\n(\(results.count - top.count) more not shown — refine query if needed)"
        }
        return out
    }

    private static func formatSeriesLibraryCondensed(_ items: [SonarrLibraryRecord], filter: String) -> String {
        guard !items.isEmpty else {
            return filter.isEmpty ? "Sonarr library is empty." : "No series in your library match '\(filter)'."
        }
        let top = items.prefix(20)
        let lines = top.map { r -> String in
            let title = r.title ?? "(untitled)"
            let yearPart = r.year.map { " (\($0))" } ?? ""
            let idPart = r.tvdbId.map { " · tvdbId=\($0)" } ?? ""
            let statusPart = r.status.map { " · \($0)" } ?? ""
            return "• \(title)\(yearPart)\(idPart)\(statusPart)"
        }
        var out = "Sonarr library — \(items.count) series"
        if !filter.isEmpty { out += " matching '\(filter)'" }
        out += ":\n" + lines.joined(separator: "\n")
        if items.count > top.count { out += "\n(\(items.count - top.count) more not shown)" }
        return out
    }

    private static func formatMovieLibraryCondensed(_ items: [RadarrLibraryRecord], filter: String) -> String {
        guard !items.isEmpty else {
            return filter.isEmpty ? "Radarr library is empty." : "No movies in your library match '\(filter)'."
        }
        let top = items.prefix(20)
        let lines = top.map { r -> String in
            let title = r.title ?? "(untitled)"
            let yearPart = r.year.map { " (\($0))" } ?? ""
            let idPart = r.tmdbId.map { " · tmdbId=\($0)" } ?? ""
            let fileMark = (r.hasFile ?? false) ? " · downloaded" : " · missing"
            return "• \(title)\(yearPart)\(idPart)\(fileMark)"
        }
        var out = "Radarr library — \(items.count) movie\(items.count == 1 ? "" : "s")"
        if !filter.isEmpty { out += " matching '\(filter)'" }
        out += ":\n" + lines.joined(separator: "\n")
        if items.count > top.count { out += "\n(\(items.count - top.count) more not shown)" }
        return out
    }

    private static func formatArtistSearchCondensed(_ results: [SearchResult], query: String) -> String {
        guard !results.isEmpty else { return "No results found." }
        let top = results.prefix(15)
        let lines = top.map { r -> String in
            let subPart = r.subtitle.map { " (\($0))" } ?? ""
            return "• foreignArtistId=\(r.foreignId) — \(r.title)\(subPart)"
        }
        var out = "Found \(results.count) artist result\(results.count == 1 ? "" : "s") for \"\(query)\". Top matches (LLM: pass foreignArtistId to lidarr_add_artist):"
        out += "\n" + lines.joined(separator: "\n")
        if results.count > top.count {
            out += "\n(\(results.count - top.count) more not shown — refine query if needed)"
        }
        return out
    }

    private static func formatArtistLibraryCondensed(_ items: [LidarrLibraryRecord], filter: String) -> String {
        guard !items.isEmpty else {
            return filter.isEmpty ? "Lidarr library is empty." : "No artists in your library match '\(filter)'."
        }
        let top = items.prefix(20)
        let lines = top.map { r -> String in
            let name = r.artistName ?? "(untitled)"
            let idPart = r.foreignArtistId.map { " · foreignArtistId=\($0)" } ?? ""
            let albumCount = r.statistics?.albumCount.map { " · \($0) album\($0 == 1 ? "" : "s")" } ?? ""
            return "• \(name)\(idPart)\(albumCount)"
        }
        var out = "Lidarr library — \(items.count) artist\(items.count == 1 ? "" : "s")"
        if !filter.isEmpty { out += " matching '\(filter)'" }
        out += ":\n" + lines.joined(separator: "\n")
        if items.count > top.count { out += "\n(\(items.count - top.count) more not shown)" }
        return out
    }

    // MARK: - Whisparr tool implementations

    private func searchScene(_ args: JSONValue) async throws -> ToolCallOutput {
        let query = Self.stringArg(args, key: "query")
        guard !query.isEmpty else {
            return ToolCallOutput(text: "Please provide a search query.")
        }
        guard whisparr.isConfigured else {
            return ToolCallOutput(text: "Whisparr is not configured.")
        }
        let client = SearchClient(config: whisparr, source: .whisparr)
        let results = try await client.lookup(query: query)
        let text = Self.formatSearchResultsCondensed(results, query: query, kind: "scene")
        return ToolCallOutput(text: text, rich: .searchSceneResults(results))
    }

    private func listScenes(_ args: JSONValue) async throws -> ToolCallOutput {
        guard whisparr.isConfigured else {
            return ToolCallOutput(text: "Whisparr is not configured.")
        }
        let filter = Self.stringArg(args, key: "query").lowercased()
        let client = WhisparrClient(config: whisparr)
        let all = try await client.fetchAllMovies()
        let matched = filter.isEmpty
            ? all
            : all.filter { ($0.title ?? "").lowercased().contains(filter) }
        let text = Self.formatSceneLibraryCondensed(matched, filter: filter)
        return ToolCallOutput(text: text, rich: .libraryScenes(matched))
    }

    private func whisparrCalendar() async throws -> ToolCallOutput {
        guard whisparr.isConfigured else {
            return ToolCallOutput(text: "Whisparr is not configured.")
        }
        let client = WhisparrClient(config: whisparr)
        let items = try await client.fetchCalendar()
        let text = Self.formatCalendarCondensed(items)
        return ToolCallOutput(text: text, rich: .calendar(items))
    }

    private func addScene(_ args: JSONValue) async throws -> ToolCallOutput {
        let foreignId = Self.stringArg(args, key: "foreignId")
        let title = Self.stringArg(args, key: "title")
        let chosenProfileId = Self.intArg(args, key: "qualityProfileId")
        let chosenFolderPath = Self.stringArg(args, key: "rootFolderPath")
        guard !foreignId.isEmpty || !title.isEmpty else {
            return ToolCallOutput(text: "Need a foreignId (preferred) or title to add a scene. Run whisparr_search first.")
        }
        guard whisparr.isConfigured else {
            return ToolCallOutput(text: "Whisparr is not configured.")
        }
        let client = SearchClient(config: whisparr, source: .whisparr)
        let lookupQuery = !foreignId.isEmpty ? foreignId : title
        let candidates = try await client.lookup(query: lookupQuery)
        let chosen: SearchResult?
        if !foreignId.isEmpty {
            chosen = candidates.first(where: { $0.foreignId == foreignId }) ?? candidates.first
        } else {
            chosen = candidates.first
        }
        guard let pick = chosen else {
            return ToolCallOutput(text: "Couldn't find any scenes matching '\(lookupQuery)'.")
        }
        let profiles = try await client.fetchQualityProfiles()
        let folders = try await client.fetchRootFolders()
        let profile = profiles.first(where: { $0.id == chosenProfileId }) ?? profiles.first
        let folder = folders.first(where: { $0.path == chosenFolderPath }) ?? folders.first
        guard let profile, let folder else {
            return ToolCallOutput(text: "Whisparr is missing a quality profile or root folder.")
        }
        try await client.addScene(pick, qualityProfileId: profile.id, rootFolderPath: folder.path)
        let yearPart = pick.year.map { " (\($0))" } ?? ""
        return ToolCallOutput(text: "Added '\(pick.title)\(yearPart)' to Whisparr (profile: \(profile.name), folder: \(folder.path)).")
    }

    private static func formatSceneLibraryCondensed(_ items: [WhisparrLibraryRecord], filter: String) -> String {
        guard !items.isEmpty else {
            return filter.isEmpty ? "Whisparr library is empty." : "No scenes in your library match '\(filter)'."
        }
        let top = items.prefix(20)
        let lines = top.map { r -> String in
            let title = r.title ?? "(untitled)"
            let yearPart = r.year.map { " (\($0))" } ?? ""
            let fileMark = (r.hasFile ?? false) ? " · downloaded" : " · missing"
            return "• \(title)\(yearPart)\(fileMark)"
        }
        var out = "Whisparr library — \(items.count) scene\(items.count == 1 ? "" : "s")"
        if !filter.isEmpty { out += " matching '\(filter)'" }
        out += ":\n" + lines.joined(separator: "\n")
        if items.count > top.count { out += "\n(\(items.count - top.count) more not shown)" }
        return out
    }

    private static func formatCalendarCondensed(_ items: [UpcomingItem]) -> String {
        guard !items.isEmpty else { return "Nothing upcoming." }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let top = items.prefix(15)
        let lines = top.map { it -> String in
            let dateStr = fmt.string(from: it.airDate)
            if let subtitle = it.subtitle, !subtitle.isEmpty {
                return "• \(dateStr) — \(it.title) · \(subtitle)"
            }
            return "• \(dateStr) — \(it.title)"
        }
        var out = "Upcoming releases:"
        out += "\n" + lines.joined(separator: "\n")
        if items.count > top.count {
            out += "\n(\(items.count - top.count) more not shown)"
        }
        return out
    }

}

public enum LocalToolError: Error, Equatable, Sendable, LocalizedError {
    case unknownTool(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name): return "Unknown tool: \(name)"
        }
    }
}
