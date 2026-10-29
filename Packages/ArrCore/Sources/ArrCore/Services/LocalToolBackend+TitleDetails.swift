import Foundation
import os
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
            text += await librarySection(profileId: d.qualityProfileId, client: sonarrClient,
                                         files: await seriesFilesLine(seriesId: id))
            guard includeCast else { return ToolCallOutput(text: text) }
            let cast = await seriesCast(tmdbId: d.tmdbId)
            text += cast.text
            return ToolCallOutput(text: text, rich: Self.castRich(cast.members))
        case "radarr":
            guard radarr.isConfigured else { return ToolCallOutput(text: "Radarr is not configured.") }
            let d = try await radarrClient.fetchMovieDetails(id: id)
            var text = Self.formatMovieDetails(d)
            text += await librarySection(profileId: d.qualityProfileId, client: radarrClient,
                                         files: await movieFileLine(d, movieId: id))
            guard includeCast else { return ToolCallOutput(text: text) }
            let cast = await movieCast(movieId: id)
            text += cast.text
            return ToolCallOutput(text: text, rich: Self.castRich(cast.members))
        default:
            return ToolCallOutput(text: "Specify service: 'sonarr' or 'radarr'.")
        }
    }

    // MARK: - Profile and files

    /// The profile decides the next grab; the file is what an upgrade would replace.
    private func librarySection(profileId: Int?, client: some ArrAPIClient, files: String) async -> String {
        var out = "\n\n"
        if let profileId {
            let profiles = (await Logger.extras.attempt("title quality profiles") { try await client.fetchQualityProfiles() }) ?? []
            out += "Quality profile: \(profiles.first { $0.id == profileId }?.name ?? "id \(profileId)")\n"
        }
        return out + files
    }

    private func movieFileLine(_ movie: ArrMovie, movieId: Int) async -> String {
        var file = movie.movieFile
        if file == nil, movie.hasFile == true {
            file = await Logger.extras.attempt("title movie file") { try await radarrClient.fetchMovieFile(movieId: movieId) } ?? nil
        }
        guard let file else { return "File: none on disk" }
        return "File: " + Self.fileLine(file)
    }

    private func seriesFilesLine(seriesId: Int) async -> String {
        guard let files = await Logger.extras.attempt("title episode files", {
            Array(try await sonarrClient.fetchEpisodeFileMap(seriesId: seriesId).values)
        }) else { return "Episode files: couldn't load" }
        guard !files.isEmpty else { return "Episode files: none on disk" }
        let size = files.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let counts = Dictionary(grouping: files) { file in
            Self.qualityLabel(file.quality?.name, revision: revisionLabel(file.quality?.revision)) ?? "unknown"
        }
        .map { (quality: $0.key, count: $0.value.count) }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.quality < $1.quality }
        let mix = counts.prefix(4).map { "\($0.quality) ×\($0.count)" }.joined(separator: ", ")
        return "Episode files: \(files.count) on disk · "
            + ByteCountFormatter.string(fromByteCount: size, countStyle: .file) + " — " + mix
    }

    /// `Bluray-2160p Proper · CF score 120 · CFs: DV, HDR10 · 24.3 GB · HEVC 2160p · TrueHD Atmos 7.1 · group FGT`
    nonisolated static func fileLine(_ file: ArrFile) -> String {
        var parts = [qualityLabel(file.quality?.name, revision: revisionLabel(file.quality?.revision)) ?? "quality unknown"]
        if let score = file.customFormatScore { parts.append("CF score \(score)") }
        if let formats = file.customFormats {
            parts.append(formats.isEmpty ? "CFs: none" : "CFs: " + formats.map(\.name).joined(separator: ", "))
        }
        if let size = file.size, size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let info = file.mediaInfo {
            let video = [info.videoCodec, info.resolution].compactMap { $0?.isEmpty == false ? $0 : nil }
            if !video.isEmpty { parts.append(video.joined(separator: " ")) }
            var audio = [info.audioCodec].compactMap { $0?.isEmpty == false ? $0 : nil }
            if let channels = info.audioChannels, channels > 0 { audio.append(String(format: "%.1f", channels)) }
            if !audio.isEmpty { parts.append(audio.joined(separator: " ")) }
        }
        if let group = file.releaseGroup, !group.isEmpty { parts.append("group \(group)") }
        return parts.joined(separator: " · ")
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
