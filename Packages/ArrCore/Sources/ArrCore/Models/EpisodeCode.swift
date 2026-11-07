import Foundation

nonisolated enum EpisodeCode {
    /// `S02E04`, or `S02` for a whole season.
    static func string(season: Int, episode: Int?) -> String {
        episode.map { String(format: "S%02dE%02d", season, $0) } ?? String(format: "S%02d", season)
    }

    /// "Season 2", or "Specials" for Sonarr's season 0.
    static func seasonName(_ season: Int) -> String {
        season == 0 ? String(localized: "detail.specials.label", bundle: .module)
            : String(format: String(localized: "detail.seasonLld.label", bundle: .module), season)
    }

    /// "Season 02", or "Specials" for Sonarr's season 0.
    static func paddedSeasonName(_ season: Int) -> String {
        season == 0 ? String(localized: "detail.specials.label", bundle: .module)
            : String(format: String(localized: "queue.season02lld.button", bundle: .module), season)
    }

    /// `S02E04 · Title`, or the code alone when there is no title.
    static func line(season: Int, episode: Int, title: String?) -> String {
        let code = string(season: season, episode: episode)
        guard let title, !title.isEmpty else { return code }
        return "\(code) · \(title)"
    }
}
