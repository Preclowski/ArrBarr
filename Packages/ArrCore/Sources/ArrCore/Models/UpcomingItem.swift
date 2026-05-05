import Foundation
import SwiftUI

public struct UpcomingItem: Identifiable, Equatable {
    public enum Source: String {
        case radarr, sonarr, lidarr

        public var symbol: String {
            switch self {
            case .radarr: return "film"
            case .sonarr: return "tv"
            case .lidarr: return "music.note"
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

    public init(
        id: String, source: Source, title: String, subtitle: String?,
        airDate: Date, releaseType: String?, hasFile: Bool, overview: String?,
        posterURL: URL? = nil, posterRequiresAuth: Bool = false
    ) {
        self.id = id; self.source = source; self.title = title; self.subtitle = subtitle
        self.airDate = airDate; self.releaseType = releaseType
        self.hasFile = hasFile; self.overview = overview
        self.posterURL = posterURL; self.posterRequiresAuth = posterRequiresAuth
    }

    public func airDateFormatted(locale: Locale) -> String {
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
public enum LocaleBundle {
    /// Bundles to search for compiled `.lproj/Localizable.strings`. We
    /// prefer the package's own resource bundle (`Bundle.module`) so
    /// strings ship with the package itself — that way the macOS app,
    /// the iOS app, and the test runner all read the same compiled
    /// strings. Bundle.main stays as a fallback for legacy callers.
    private static let candidateBundles: [Bundle] = [.module, .main]

    public static func string(_ key: String, locale: Locale) -> String {
        let langCode = locale.language.languageCode?.identifier ?? locale.identifier
        // Look for the explicit per-language `.lproj` first. This bypasses
        // the bundle's preferred-localizations resolution, which would
        // otherwise return whatever language the host process happens to
        // be running in — wrong both for unit tests and for the in-app
        // language picker that lets the user pick a locale at runtime.
        for bundle in candidateBundles {
            if let path = bundle.path(forResource: langCode, ofType: "lproj"),
               let lproj = Bundle(path: path) {
                let value = lproj.localizedString(forKey: key, value: key, table: nil)
                if value != key { return value }
            }
        }
        // No explicit hit. Don't fall back to `bundle.localizedString` —
        // it uses preferred-localizations and would leak the host's
        // language into our explicit-locale callers. Just hand the key
        // back, which is what English (the source language) effectively
        // does anyway.
        return key
    }
}

public extension View {
    /// `.help(LocalizedStringKey)` reads from the bundle's launch-time
    /// preferredLocalizations and so doesn't update when the user changes
    /// language in-app. This goes through `LocaleBundle` to resolve against
    /// the currently-configured locale.
    public func localizedHelp(_ key: String, locale: Locale) -> some View {
        self.help(Text(verbatim: LocaleBundle.string(key, locale: locale)))
    }
}
