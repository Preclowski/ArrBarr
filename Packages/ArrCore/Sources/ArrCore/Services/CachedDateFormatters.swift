import Foundation

/// Creating a formatter costs ~50 µs; in a SwiftUI row body that is paid per row per layout pass.
/// Keyed by locale for live language switches. Shared: only use them, never reconfigure.
nonisolated enum CachedDateFormatters {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var dateFormatters: [String: DateFormatter] = [:]
    private nonisolated(unsafe) static var relativeFormatters: [String: RelativeDateTimeFormatter] = [:]

    /// Locale-sensitive on purpose: a non-Gregorian calendar should keep rendering its own year.
    static func format(_ format: String, locale: Locale = .current) -> DateFormatter {
        formatter(key: "f:\(format)|\(locale.identifier)", locale: locale) { $0.dateFormat = format }
    }

    static func styles(date: DateFormatter.Style,
                       time: DateFormatter.Style,
                       locale: Locale = .current) -> DateFormatter {
        formatter(key: "s:\(date.rawValue):\(time.rawValue)|\(locale.identifier)", locale: locale) {
            $0.dateStyle = date
            $0.timeStyle = time
        }
    }

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
