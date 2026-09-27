import Foundation

/// The arrs report genres in English; the catalog carries the known ones as `genre.<Name>`.
nonisolated enum GenreName {
    static func localized(_ raw: String, locale: Locale) -> String {
        let key = "genre.\(raw)"
        let value = AppLocalized.string(key, locale: locale)
        return value == key ? raw : value
    }
}
