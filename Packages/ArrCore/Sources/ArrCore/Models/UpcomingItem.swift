import Foundation
import SwiftUI

nonisolated public struct UpcomingItem: Identifiable, Equatable, Sendable, Codable {
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
    /// Same units as `SearchResult.imdb`.
    public let imdb: Double?
    /// Fallback when IMDb hasn't rated the title yet. Radarr/Whisparr only.
    public var tmdb: Double? = nil
    /// Episode or movie minutes; nil for Lidarr.
    public let runtime: Int?
    /// Sonarr `series.id`, Radarr `movie.id`, Lidarr `album.id`, Whisparr `scene.id`.
    public let entityId: Int?
    /// A number so the row pluralizes it live; service-layer `String(localized:)` resolves once.
    public var trackCount: Int? = nil
    /// Calendar entries carry a series `entityId`, so the tooltip needs the file id.
    public var episodeFileId: Int? = nil
    public var genres: [String] = []
    public var certification: String? = nil
    public var releaseStatus: String? = nil
    public var ratingRt: Double? = nil
    public var ratingMetacritic: Double? = nil
    public var qualityProfileId: Int? = nil
    /// The series-level `entityId` alone matches every episode of the show.
    public var seasonNumber: Int? = nil
    public var episodeNumber: Int? = nil
    /// TMDB for movies, TVDB for series (what Sonarr's calendar embeds). Nil for music.
    public var tmdbId: Int? = nil
    public var tvdbId: Int? = nil
    /// The arr's web slug: title slug for movies and series, foreign album id for music.
    public var slug: String? = nil

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
        trackCount: Int? = nil,
        tmdbId: Int? = nil, tvdbId: Int? = nil,
        slug: String? = nil
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
        self.tmdbId = tmdbId; self.tvdbId = tvdbId
        self.slug = slug
    }

    public func airDateCompact(locale: Locale) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(airDate) {
            return CachedDateFormatters.styles(date: .none, time: .short, locale: locale)
                .string(from: airDate)
        }
        if cal.isDateInTomorrow(airDate) {
            return AppLocalized.string("upcoming.tomorrow.button", locale: locale)
        }
        return CachedDateFormatters.template("dMMM", locale: locale).string(from: airDate)
    }

    /// Date-only entries (movie releases parse to midnight) skip ", 00:00".
    public func airDateTimeFormatted(locale: Locale) -> String {
        let date = airDateFormatted(locale: locale)
        let comps = Calendar.current.dateComponents([.hour, .minute], from: airDate)
        guard (comps.hour ?? 0) != 0 || (comps.minute ?? 0) != 0 else { return date }
        let time = CachedDateFormatters.styles(date: .none, time: .short, locale: locale)
        return "\(date), \(time.string(from: airDate))"
    }

    /// Unknown values fall back to the raw string.
    public func releaseTypeText(locale: Locale) -> String? {
        guard let releaseType, !releaseType.isEmpty else { return nil }
        let keys: [String: String] = [
            "airing": "upcoming.type.airing",
            "digital": "upcoming.type.digital",
            "physical": "upcoming.type.physical",
            "in cinemas": "library.release.inCinemas",
            "album": "upcoming.type.album",
        ]
        if let key = keys[releaseType.lowercased()] {
            return AppLocalized.string(key, locale: locale)
        }
        return releaseType
    }

    /// Words go through `AppLocalized`: `String(localized:)` stays in the process
    /// language until relaunch, mismatching the date.
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
