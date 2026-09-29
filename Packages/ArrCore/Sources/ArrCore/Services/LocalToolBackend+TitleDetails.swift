import Foundation
import MediaKit

// MARK: - get_title_details
//
// Cast is TMDB-only for series, so `include_cast` is off by default: an extra
// round-trip, more tokens, and a key.

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
            let d = try await sonarrClient.fetchSeriesDetails(id: id)
            var text = Self.formatSeriesDetails(d)
            guard includeCast else { return ToolCallOutput(text: text) }
            let cast = await seriesCast(tmdbId: d.tmdbId)
            text += cast.text
            return ToolCallOutput(text: text, rich: Self.castRich(cast.members))
        case "radarr":
            guard radarr.isConfigured else { return ToolCallOutput(text: "Radarr is not configured.") }
            let d = try await radarrClient.fetchMovieDetails(id: id)
            var text = Self.formatMovieDetails(d)
            guard includeCast else { return ToolCallOutput(text: text) }
            let cast = await movieCast(movieId: id)
            text += cast.text
            return ToolCallOutput(text: text, rich: Self.castRich(cast.members))
        default:
            return ToolCallOutput(text: "Specify service: 'sonarr' or 'radarr'.")
        }
    }

    /// One list in both shapes, so what the user sees and the assistant says can't drift.
    private typealias CastSection = (text: String, members: [CastMember])

    /// A row of grey silhouettes that go nowhere is worse than the prose alone.
    nonisolated private static func castRich(_ members: [CastMember]) -> ChatRichContent? {
        let usable = members.filter { $0.tmdbPersonId != nil }
        return usable.isEmpty ? nil : .cast(usable)
    }

    /// Movie cast from Radarr's `/credit` — no TMDB key needed.
    private func movieCast(movieId: Int) async -> CastSection {
        let credits: [ArrCredit]
        do { credits = try await radarrClient.fetchCredits(movieId: movieId) } catch {
            return ("\n\nCast: couldn't load (\(error.localizedDescription)).", [])
        }
        // Same ordering the detail surfaces render, so chat and detail agree on top billing.
        let members = CastMember.from(radarrCredits: credits)
        guard !members.isEmpty else { return ("\n\nCast: (Radarr returned none).", []) }
        return (Self.castText(members), members)
    }

    /// Sonarr has no `/credit` endpoint, so TMDB is the only source.
    private func seriesCast(tmdbId: Int?) async -> CastSection {
        guard !tmdbApiKey.isEmpty else {
            return ("\n\nCast: unavailable — series cast needs a TMDB key (Sonarr has no cast API). Configure it in Settings.", [])
        }
        guard let tmdbId, tmdbId > 0 else {
            return ("\n\nCast: unavailable — TMDB id not found for this series.", [])
        }
        let credits: TMDBCredits
        do { credits = try await tmdbClient.tvCredits(tvId: tmdbId) } catch {
            return ("\n\nCast: couldn't load (\(error.localizedDescription)).", [])
        }
        guard !credits.cast.isEmpty else { return ("\n\nCast: (TMDB returned none).", []) }
        let members = CastMember.from(tmdbCast: credits.cast)
        return (Self.castText(members), members)
    }

    /// The personId rides along so the model can link a name or pull a filmography
    /// without a second lookup.
    nonisolated private static func castText(_ members: [CastMember]) -> String {
        let lines = members.prefix(15).map { m -> String in
            var line = "• \(m.name)"
            if let role = m.role, !role.isEmpty { line += " — \(role)" }
            if let id = m.tmdbPersonId { line += " (personId: \(id))" }
            return line
        }
        return "\n\nCast:\n" + lines.joined(separator: "\n")
    }

    // MARK: - Formatting

    nonisolated private static func formatMovieDetails(_ d: ArrMovie) -> String {
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

    nonisolated private static func formatSeriesDetails(_ d: ArrSeries) -> String {
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
