import Foundation
import SwiftUI

public struct UpcomingItem: Identifiable, Equatable, Sendable, Codable {
    /// Calendar entries share the same arr-source identity as queue rows;
    /// keeping two parallel enums made every cross-section helper translate
    /// back and forth. `QueueItem.Source` already carries `symbol` and
    /// `displayName`, so we alias instead of duplicating.
    public typealias Source = QueueItem.Source

    public let id: String
    public let source: Source
    public let title: String
    public let subtitle: String?
    public let airDate: Date
    public let releaseType: String?
    public let hasFile: Bool
    public let overview: String?
    public let posterURL: URL?
    public let posterRequiresAuth: Bool
    /// IMDb rating from the arr's stored series/movie metadata. Same units
    /// as `SearchResult.imdb` so the unified poster-metadata row can format
    /// it identically across the + and Upcoming surfaces.
    public let imdb: Double?
    /// TMDB score — the fallback when IMDb hasn't rated the title yet
    /// (typical for unreleased movies). Radarr/Whisparr only.
    public var tmdb: Double? = nil
    /// Runtime in minutes (episode for Sonarr, movie for Radarr/Whisparr).
    /// `nil` for Lidarr — albums don't have a single runtime.
    public let runtime: Int?
    /// Underlying arr entity id — Sonarr `series.id`, Radarr `movie.id`,
    /// Lidarr `album.id`, Whisparr `scene.id`. Lets the row open DetailView
    /// just like a queue tap. `nil` when the source didn't carry one
    /// (e.g. demo entries without a matching backend record).
    public let entityId: Int?
    /// Lidarr only: how many tracks the album has, when the arr knows the
    /// tracklist yet. Carried as a number rather than a formatted string so the
    /// row can pluralize it in the user's language — a service-layer
    /// `String(localized:)` resolves once, at fetch time.
    public var trackCount: Int? = nil
    /// Sonarr only: the on-disk episode file's id (calendar entries carry a
    /// SERIES `entityId`, so the tooltip needs this to find the right file).
    public var episodeFileId: Int? = nil
    /// Title facts mirrored from the library records so the Upcoming tooltip
    /// carries the SAME data set as the Library tooltip.
    public var genres: [String] = []
    public var certification: String? = nil
    public var releaseStatus: String? = nil
    public var ratingRt: Double? = nil
    public var ratingMetacritic: Double? = nil
    public var qualityProfileId: Int? = nil
    /// Sonarr: this calendar entry's episode identity — what lets the row
    /// find its own live queue item (the series-level `entityId` alone
    /// matches every episode of the show).
    public var seasonNumber: Int? = nil
    public var episodeNumber: Int? = nil

    public init(
        id: String, source: Source, title: String, subtitle: String?,
        airDate: Date, releaseType: String?, hasFile: Bool, overview: String?,
        posterURL: URL? = nil, posterRequiresAuth: Bool = false,
        imdb: Double? = nil, tmdb: Double? = nil, runtime: Int? = nil,
        entityId: Int? = nil, episodeFileId: Int? = nil,
        genres: [String] = [], certification: String? = nil,
        releaseStatus: String? = nil,
        ratingRt: Double? = nil, ratingMetacritic: Double? = nil,
        qualityProfileId: Int? = nil,
        seasonNumber: Int? = nil, episodeNumber: Int? = nil,
        trackCount: Int? = nil
    ) {
        self.id = id; self.source = source; self.title = title; self.subtitle = subtitle
        self.airDate = airDate; self.releaseType = releaseType
        self.hasFile = hasFile; self.overview = overview
        self.posterURL = posterURL; self.posterRequiresAuth = posterRequiresAuth
        self.imdb = imdb; self.tmdb = tmdb; self.runtime = runtime
        self.entityId = entityId
        self.episodeFileId = episodeFileId
        self.genres = genres; self.certification = certification
        self.releaseStatus = releaseStatus
        self.ratingRt = ratingRt; self.ratingMetacritic = ratingMetacritic
        self.qualityProfileId = qualityProfileId
        self.seasonNumber = seasonNumber; self.episodeNumber = episodeNumber
        self.trackCount = trackCount
    }

    /// Compact when-label for one-line rows (the queue's "This week"
    /// banner): today → just the time, tomorrow → just "Tomorrow", later →
    /// a short day-month date. The full date + time lives in the tooltip
    /// (`airDateTimeFormatted`).
    public func airDateCompact(locale: Locale) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(airDate) {
            let time = DateFormatter()
            time.locale = locale
            time.dateStyle = .none
            time.timeStyle = .short
            return time.string(from: airDate)
        }
        if cal.isDateInTomorrow(airDate) {
            return AppLocalized.string("upcoming.tomorrow.button", locale: locale)
        }
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f.string(from: airDate)
    }

    /// Tooltip form: the full relative/absolute date plus the air time
    /// ("17 sie 2026, 06:00"). Date-only entries (movie releases parse to
    /// midnight) skip the meaningless ", 00:00".
    public func airDateTimeFormatted(locale: Locale) -> String {
        let date = airDateFormatted(locale: locale)
        let comps = Calendar.current.dateComponents([.hour, .minute], from: airDate)
        guard (comps.hour ?? 0) != 0 || (comps.minute ?? 0) != 0 else { return date }
        let time = DateFormatter()
        time.locale = locale
        time.dateStyle = .none
        time.timeStyle = .short
        return "\(date), \(time.string(from: airDate))"
    }

    /// Localized display form of `releaseType` ("Airing" / "Digital" /
    /// "Physical" / "In Cinemas" — set verbatim by the clients). Unknown
    /// values fall back to the raw string.
    public func releaseTypeText(locale: Locale) -> String? {
        guard let releaseType, !releaseType.isEmpty else { return nil }
        let keys: [String: String] = [
            "airing": "upcoming.type.airing",
            "digital": "upcoming.type.digital",
            "physical": "upcoming.type.physical",
            "in cinemas": "library.release.inCinemas",
        ]
        if let key = keys[releaseType.lowercased()] {
            return AppLocalized.string(key, locale: locale)
        }
        return releaseType
    }

    /// `locale` drives BOTH the numeric date *and* the "Today"/"Tomorrow" words,
    /// so the whole label follows the in-app language picker live. The words go
    /// through `AppLocalized` (per-language bundle) rather than
    /// `String(localized:)`, which reads the process `AppleLanguages` and would
    /// stay in the pre-switch language until relaunch — leaving the word and the
    /// date in different languages. Callers pass `configStore.currentLocale`.
    public func airDateFormatted(locale: Locale = .current) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(airDate) {
            return AppLocalized.string("upcoming.today.button", locale: locale)
        }
        if cal.isDateInTomorrow(airDate) {
            return AppLocalized.string("upcoming.tomorrow.button", locale: locale)
        }
        return airDate.formatted(
            .dateTime
                .day()
                .month(.abbreviated)
                .year()
                .locale(locale)
        )
    }
}
