import Foundation

struct UpcomingItem: Identifiable, Equatable {
    enum Source: String { case radarr, sonarr, lidarr }

    let id: String
    let source: Source
    let title: String
    let subtitle: String?
    let airDate: Date
    let releaseType: String?
    let hasFile: Bool
    let overview: String?

    private static let mediumDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var airDateFormatted: String {
        let cal = Calendar.current
        if cal.isDateInToday(airDate) { return "Today" }
        if cal.isDateInTomorrow(airDate) { return "Tomorrow" }
        return Self.mediumDateFormatter.string(from: airDate)
    }
}
