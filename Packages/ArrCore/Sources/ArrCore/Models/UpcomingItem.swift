import Foundation
import SwiftUI

public struct UpcomingItem: Identifiable, Equatable, Sendable {
    public enum Source: String {
        case radarr, sonarr, lidarr, whisparr

        public var symbol: String {
            switch self {
            case .radarr: return "film"
            case .sonarr: return "tv"
            case .lidarr: return "music.note"
            case .whisparr: return "flame"
            }
        }
    }

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
    /// Underlying arr entity id — Sonarr `series.id`, Radarr `movie.id`,
    /// Lidarr `album.id`, Whisparr `scene.id`. Lets the row open DetailView
    /// just like a queue tap. `nil` when the source didn't carry one
    /// (e.g. demo entries without a matching backend record).
    public let entityId: Int?

    public init(
        id: String, source: Source, title: String, subtitle: String?,
        airDate: Date, releaseType: String?, hasFile: Bool, overview: String?,
        posterURL: URL? = nil, posterRequiresAuth: Bool = false,
        entityId: Int? = nil
    ) {
        self.id = id; self.source = source; self.title = title; self.subtitle = subtitle
        self.airDate = airDate; self.releaseType = releaseType
        self.hasFile = hasFile; self.overview = overview
        self.posterURL = posterURL; self.posterRequiresAuth = posterRequiresAuth
        self.entityId = entityId
    }

    /// `locale` controls date formatting only; the "Today"/"Tomorrow" labels
    /// resolve through the app's active localization (driven by
    /// `AppleLanguages`, which the language picker sets and the user applies
    /// by restarting).
    public func airDateFormatted(locale: Locale = .current) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(airDate) {
            return String(localized: "Today", bundle: Bundle.module)
        }
        if cal.isDateInTomorrow(airDate) {
            return String(localized: "Tomorrow", bundle: Bundle.module)
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
