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
    /// Runtime in minutes (episode for Sonarr, movie for Radarr/Whisparr).
    /// `nil` for Lidarr — albums don't have a single runtime.
    public let runtime: Int?
    /// Underlying arr entity id — Sonarr `series.id`, Radarr `movie.id`,
    /// Lidarr `album.id`, Whisparr `scene.id`. Lets the row open DetailView
    /// just like a queue tap. `nil` when the source didn't carry one
    /// (e.g. demo entries without a matching backend record).
    public let entityId: Int?

    public init(
        id: String, source: Source, title: String, subtitle: String?,
        airDate: Date, releaseType: String?, hasFile: Bool, overview: String?,
        posterURL: URL? = nil, posterRequiresAuth: Bool = false,
        imdb: Double? = nil, runtime: Int? = nil,
        entityId: Int? = nil
    ) {
        self.id = id; self.source = source; self.title = title; self.subtitle = subtitle
        self.airDate = airDate; self.releaseType = releaseType
        self.hasFile = hasFile; self.overview = overview
        self.posterURL = posterURL; self.posterRequiresAuth = posterRequiresAuth
        self.imdb = imdb; self.runtime = runtime
        self.entityId = entityId
    }

    /// `locale` controls date formatting only; the "Today"/"Tomorrow" labels
    /// resolve through the app's active localization (driven by
    /// `AppleLanguages`, which the language picker sets and the user applies
    /// by restarting).
    public func airDateFormatted(locale: Locale = .current) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(airDate) {
            return String(localized: "upcoming.today.button", bundle: Bundle.module)
        }
        if cal.isDateInTomorrow(airDate) {
            return String(localized: "upcoming.tomorrow.button", bundle: Bundle.module)
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
