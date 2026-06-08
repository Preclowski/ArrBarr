import Foundation

// MARK: - get_title_details
//
// Single-title detail lookup for the chat assistant: overview + metadata for
// one movie (Radarr) or series (Sonarr), with an OPTIONAL cast section. Cast
// is TMDB-only, so `include_cast` is off by default — it costs an extra TMDB
// round-trip and tokens, and needs a configured key. Read-only (not in
// MCPToolWhitelist.isDestructive), so no confirm gate.

extension LocalToolBackend {

    func getTitleDetails(_ args: JSONValue) async throws -> ToolCallOutput {
        let service = Self.stringArg(args, key: "service").lowercased()
        let id = Self.intArg(args, key: "id")
        let includeCast = Self.optionalBoolArg(args, key: "include_cast") ?? false
        guard id > 0 else {
            return ToolCallOutput(text: "Provide the title's id — seriesId from sonarr_get_series, or movieId from radarr_get_movies (not the tmdbId).")
        }

        switch service {
        case "sonarr":
            guard sonarr.isConfigured else { return ToolCallOutput(text: "Sonarr is not configured.") }
            let d = try await SonarrClient(config: sonarr).fetchSeriesDetails(id: id)
            var text = Self.formatSeriesDetails(d)
            if includeCast { text += await seriesCastSection(tmdbId: d.tmdbId) }
            return ToolCallOutput(text: text)
        case "radarr":
            guard radarr.isConfigured else { return ToolCallOutput(text: "Radarr is not configured.") }
            let d = try await RadarrClient(config: radarr).fetchMovieDetails(id: id)
            var text = Self.formatMovieDetails(d)
            if includeCast { text += await movieCastSection(movieId: id) }
            return ToolCallOutput(text: text)
        default:
            return ToolCallOutput(text: "Specify service: 'sonarr' or 'radarr'.")
        }
    }

    /// Movie cast from Radarr's `/credit` — no TMDB key needed.
    private func movieCastSection(movieId: Int) async -> String {
        let credits = (try? await RadarrClient(config: radarr).fetchCredits(movieId: movieId)) ?? []
        let cast = credits
            .filter { ($0.type ?? "").lowercased() == "cast" }
            .sorted { ($0.order ?? .max) < ($1.order ?? .max) }
        guard !cast.isEmpty else { return "\n\nCast: (Radarr returned none)." }
        let lines = cast.prefix(15).map { c -> String in
            let name = c.personName ?? "(unknown)"
            if let role = c.character, !role.isEmpty { return "• \(name) — \(role)" }
            return "• \(name)"
        }
        return "\n\nCast:\n" + lines.joined(separator: "\n")
    }

    /// Series cast from TMDB — Sonarr has no `/credit` endpoint, so this is
    /// the only source. Self-describing failure strings for the model.
    private func seriesCastSection(tmdbId: Int?) async -> String {
        guard !tmdbApiKey.isEmpty else {
            return "\n\nCast: unavailable — series cast needs a TMDB key (Sonarr has no cast API). Configure it in Settings."
        }
        guard let tmdbId, tmdbId > 0 else {
            return "\n\nCast: unavailable — TMDB id not found for this series."
        }
        guard let credits = try? await TMDBClient(apiKey: tmdbApiKey).tvCredits(tvId: tmdbId),
              !credits.cast.isEmpty else {
            return "\n\nCast: (TMDB returned none)."
        }
        let lines = credits.cast.prefix(15).map { person -> String in
            if let role = person.character, !role.isEmpty { return "• \(person.name) — \(role)" }
            return "• \(person.name)"
        }
        return "\n\nCast:\n" + lines.joined(separator: "\n")
    }

    // MARK: - Formatting

    private static func formatMovieDetails(_ d: RadarrMovieDetail) -> String {
        var out = d.year.map { "\(d.title) (\($0))" } ?? d.title
        var facts: [String] = []
        if let r = d.runtime, r > 0 { facts.append("\(r) min") }
        if let c = d.certification, !c.isEmpty { facts.append(c) }
        if let g = d.genres, !g.isEmpty { facts.append(g.joined(separator: ", ")) }
        if let s = d.status, !s.isEmpty { facts.append(s) }
        if !facts.isEmpty { out += "\n" + facts.joined(separator: " · ") }
        if let imdb = d.ratings?.imdb?.value { out += "\nIMDb: \(String(format: "%.1f", imdb))" }
        if let o = d.overview, !o.isEmpty { out += "\n\n\(o)" }
        return out
    }

    private static func formatSeriesDetails(_ d: SonarrSeriesDetail) -> String {
        var out = d.year.map { "\(d.title) (\($0))" } ?? d.title
        var facts: [String] = []
        if let n = d.network, !n.isEmpty { facts.append(n) }
        if let r = d.runtime, r > 0 { facts.append("\(r) min/ep") }
        if let g = d.genres, !g.isEmpty { facts.append(g.joined(separator: ", ")) }
        if let s = d.status, !s.isEmpty { facts.append(s) }
        if !facts.isEmpty { out += "\n" + facts.joined(separator: " · ") }
        if let rating = d.ratings?.value { out += "\nRating: \(String(format: "%.1f", rating))" }
        let seasonCount = d.seasons?.filter { $0.seasonNumber > 0 }.count ?? 0
        if seasonCount > 0 { out += "\nSeasons: \(seasonCount)" }
        if let o = d.overview, !o.isEmpty { out += "\n\n\(o)" }
        return out
    }
}
