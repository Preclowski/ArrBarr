import Foundation

/// Resolves a catalog key against an explicit locale, for text that is sent rather than rendered.
/// `String(localized:)` reads the process `AppleLanguages`, set only at launch, so it lags a live switch.
nonisolated enum AppLocalized {
    /// Loads the per-language bundle: `String(localized:locale:)` uses `locale` only for formatting,
    /// not for picking the table.
    static func string(_ key: String, locale: Locale) -> String {
        if let code = locale.language.languageCode?.identifier,
           let path = Bundle.module.path(forResource: code, ofType: "lproj"),
           let langBundle = Bundle(path: path) {
            return langBundle.localizedString(forKey: key, value: nil, table: nil)
        }
        return Bundle.module.localizedString(forKey: key, value: nil, table: nil)
    }
}
