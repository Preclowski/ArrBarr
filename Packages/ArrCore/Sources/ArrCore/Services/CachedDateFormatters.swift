import Foundation

/// Date formatters, built once per configuration instead of per call.
///
/// Foundation date formatters are expensive to *create* — each one spins up an
/// ICU formatter, ~50 µs — and cheap to *use*. That distinction doesn't matter
/// on a decoding path, and matters enormously in a SwiftUI body: a formatter
/// built inside a row's computed property is rebuilt for every row on every
/// layout pass. The same shape cost a third of the main thread in the season
/// view before `parseArrDate` was given the same treatment (see
/// `ArrDateParser`).
///
/// Keyed by locale as well as by format, because several call sites take an
/// explicit locale so their labels follow a live language switch — a single
/// shared formatter would freeze the language of whichever locale asked first.
///
/// The returned formatters are shared and must only be *used*, never
/// reconfigured. Formatting itself is thread-safe (Foundation guarantees it for
/// `DateFormatter` and friends); only the construction below is serialized.
enum CachedDateFormatters {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var dateFormatters: [String: DateFormatter] = [:]
    private nonisolated(unsafe) static var relativeFormatters: [String: RelativeDateTimeFormatter] = [:]

    /// A fixed pattern ("yyyy"). Locale-sensitive on purpose: the call sites
    /// that use this render a year for display, and a non-Gregorian calendar
    /// should keep rendering its own.
    static func format(_ format: String, locale: Locale = .current) -> DateFormatter {
        formatter(key: "f:\(format)|\(locale.identifier)", locale: locale) { $0.dateFormat = format }
    }

    /// Date/time styles — the `.medium`/`.short` pairs used across rows.
    static func styles(date: DateFormatter.Style,
                       time: DateFormatter.Style,
                       locale: Locale = .current) -> DateFormatter {
        formatter(key: "s:\(date.rawValue):\(time.rawValue)|\(locale.identifier)", locale: locale) {
            $0.dateStyle = date
            $0.timeStyle = time
        }
    }

    /// A localized template ("dMMM") — the order and separators come from the
    /// locale, which is the whole point of `setLocalizedDateFormatFromTemplate`.
    static func template(_ template: String, locale: Locale = .current) -> DateFormatter {
        formatter(key: "t:\(template)|\(locale.identifier)", locale: locale) {
            $0.setLocalizedDateFormatFromTemplate(template)
        }
    }

    static func relative(_ style: RelativeDateTimeFormatter.UnitsStyle,
                         locale: Locale = .current) -> RelativeDateTimeFormatter {
        let key = "r:\(style.rawValue)|\(locale.identifier)"
        lock.lock()
        defer { lock.unlock() }
        if let hit = relativeFormatters[key] { return hit }
        let f = RelativeDateTimeFormatter()
        f.locale = locale
        f.unitsStyle = style
        relativeFormatters[key] = f
        return f
    }

    private static func formatter(key: String,
                                  locale: Locale,
                                  configure: (DateFormatter) -> Void) -> DateFormatter {
        lock.lock()
        defer { lock.unlock() }
        if let hit = dateFormatters[key] { return hit }
        let f = DateFormatter()
        f.locale = locale
        configure(f)
        dateFormatters[key] = f
        return f
    }
}
