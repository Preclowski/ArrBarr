import Foundation

/// Resolves a `.module` string-catalog key against an *explicit* locale — for
/// text that is SENT rather than rendered by SwiftUI, chiefly the synthesized
/// chat prompts fired by the empty-state suggestion chips and the Quiz
/// movie/series buttons.
///
/// SwiftUI `Text("key", bundle: .module)` already tracks a live in-app language
/// switch through `environment(\.locale)`. Foundation's `String(localized:)`
/// does NOT: it reads the process's `AppleLanguages`, which ArrBarr only sets
/// at launch (`ConfigStore.applyAppLanguageToProcess`) and never live — so a
/// prompt built with `String(localized:)` stayed in the pre-switch language
/// until relaunch. The model, instructed to reply in the user's language, then
/// mirrored that stale prompt and answered the whole turn in the old language.
enum AppLocalized {
    /// Look `key` up in `locale`'s `.lproj` inside `Bundle.module`, falling back
    /// to the module default (Base / English) when that language isn't shipped.
    ///
    /// Note the deliberate detour around `String(localized:locale:)`: that
    /// API's `locale` only drives interpolation formatting — the *table* it
    /// reads is still the bundle's process-resolved localization. Loading the
    /// per-language bundle is the only way to force the lookup itself.
    static func string(_ key: String, locale: Locale) -> String {
        if let code = locale.language.languageCode?.identifier,
           let path = Bundle.module.path(forResource: code, ofType: "lproj"),
           let langBundle = Bundle(path: path) {
            return langBundle.localizedString(forKey: key, value: nil, table: nil)
        }
        return Bundle.module.localizedString(forKey: key, value: nil, table: nil)
    }
}
