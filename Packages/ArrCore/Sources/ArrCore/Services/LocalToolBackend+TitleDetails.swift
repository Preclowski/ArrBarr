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
            guard includeCast else { return ToolCallOutput(text: text) }
            let cast = await seriesCast(tmdbId: d.tmdbId)
            text += cast.text
            return ToolCallOutput(text: text, rich: Self.castRich(cast.members))
        case "radarr":
            guard radarr.isConfigured else { return ToolCallOutput(text: "Radarr is not configured.") }
            let d = try await RadarrClient(config: radarr).fetchMovieDetails(id: id)
            var text = Self.formatMovieDetails(d)
            guard includeCast else { return ToolCallOutput(text: text) }
            let cast = await movieCast(movieId: id)
            text += cast.text
            return ToolCallOutput(text: text, rich: Self.castRich(cast.members))
        default:
            return ToolCallOutput(text: "Specify service: 'sonarr' or 'radarr'.")
        }
    }

    /// The cast section in both shapes: prose for the model, `CastMember`s for
    /// the head strip. Same list, so what the user sees and what the assistant
    /// talks about can't drift apart.
    private typealias CastSection = (text: String, members: [CastMember])

    /// Only strips with at least one tappable head are worth rendering — a row
    /// of grey silhouettes that go nowhere is worse than the prose alone.
    private static func castRich(_ members: [CastMember]) -> ChatRichContent? {
        let usable = members.filter { $0.tmdbPersonId != nil }
        return usable.isEmpty ? nil : .cast(usable)
    }

    /// Movie cast from Radarr's `/credit` — no TMDB key needed.
    private func movieCast(movieId: Int) async -> CastSection {
        let credits = (try? await RadarrClient(config: radarr).fetchCredits(movieId: movieId)) ?? []
        // `CastMember.from` owns the cast/crew filter and the billing-order
        // sort, and is what the detail surfaces render, so chat and detail
        // agree on who the top of the cast is.
        let members = CastMember.from(radarrCredits: credits)
        guard !members.isEmpty else { return ("\n\nCast: (Radarr returned none).", []) }
        return (Self.castText(members), members)
    }

    /// Series cast from TMDB — Sonarr has no `/credit` endpoint, so this is
    /// the only source. Self-describing failure strings for the model.
    private func seriesCast(tmdbId: Int?) async -> CastSection {
        guard !tmdbApiKey.isEmpty else {
            return ("\n\nCast: unavailable — series cast needs a TMDB key (Sonarr has no cast API). Configure it in Settings.", [])
        }
        guard let tmdbId, tmdbId > 0 else {
            return ("\n\nCast: unavailable — TMDB id not found for this series.", [])
        }
        guard let credits = try? await TMDBClient(apiKey: tmdbApiKey).tvCredits(tvId: tmdbId),
              !credits.cast.isEmpty else {
            return ("\n\nCast: (TMDB returned none).", [])
        }
        let members = CastMember.from(tmdbCast: credits.cast)
        return (Self.castText(members), members)
    }

    /// "• Keanu Reeves — Neo" ×15. The personId rides along so the model can
    /// link a name it mentions (see the linking rules in the system prompt) or
    /// pull that person's filmography without a second name lookup.
    private static func castText(_ members: [CastMember]) -> String {
        let lines = members.prefix(15).map { m -> String in
            var line = "• \(m.name)"
            if let role = m.role, !role.isEmpty { line += " — \(role)" }
            if let id = m.tmdbPersonId { line += " (personId: \(id))" }
            return line
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
