import Foundation
import SwiftUI

struct UpcomingItem: Identifiable, Equatable {
    enum Source: String {
        case radarr, sonarr, lidarr

        var symbol: String {
            switch self {
            case .radarr: return "film"
            case .sonarr: return "tv"
            case .lidarr: return "music.note"
            }
        }
    }

    let id: String
    let source: Source
    let title: String
    let subtitle: String?
    let airDate: Date
    let releaseType: String?
    let hasFile: Bool
    let overview: String?
    let posterURL: URL?
    let posterRequiresAuth: Bool

    init(
        id: String, source: Source, title: String, subtitle: String?,
        airDate: Date, releaseType: String?, hasFile: Bool, overview: String?,
        posterURL: URL? = nil, posterRequiresAuth: Bool = false
    ) {
        self.id = id; self.source = source; self.title = title; self.subtitle = subtitle
        self.airDate = airDate; self.releaseType = releaseType
        self.hasFile = hasFile; self.overview = overview
        self.posterURL = posterURL; self.posterRequiresAuth = posterRequiresAuth
    }

    func airDateFormatted(locale: Locale) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(airDate) {
            return LocaleBundle.string("Today", locale: locale)
        }
        if cal.isDateInTomorrow(airDate) {
            return LocaleBundle.string("Tomorrow", locale: locale)
        }
        // Date.FormatStyle.locale(_:) honours the explicit locale even when
        // AppleLanguages was set differently at process launch.
        return airDate.formatted(
            .dateTime
                .day()
                .month(.abbreviated)
                .year()
                .locale(locale)
        )
    }
}

/// `String(localized:locale:)` ignores the locale argument for string lookup —
/// it always reads from `Bundle.main.preferredLocalizations`, which is fixed
/// at process launch from `AppleLanguages`. Same applies to `.help(_:)`,
/// `Text(_: LocalizedStringKey)`, and other SwiftUI lookup paths. This helper
/// loads the requested locale's compiled `.lproj/Localizable.strings` directly
/// so in-app language changes take effect without restarting.
enum LocaleBundle {
    static func string(_ key: String, locale: Locale) -> String {
        let langCode = locale.language.languageCode?.identifier ?? locale.identifier
        if let path = Bundle.main.path(forResource: langCode, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            let value = bundle.localizedString(forKey: key, value: key, table: nil)
            if value != key { return value }
        }
        return Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }
}

extension View {
    /// `.help(LocalizedStringKey)` reads from the bundle's launch-time
    /// preferredLocalizations and so doesn't update when the user changes
    /// language in-app. This goes through `LocaleBundle` to resolve against
    /// the currently-configured locale.
    func localizedHelp(_ key: String, locale: Locale) -> some View {
        self.help(Text(verbatim: LocaleBundle.string(key, locale: locale)))
    }
}
