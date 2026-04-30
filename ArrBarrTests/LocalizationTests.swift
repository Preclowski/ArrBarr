import Testing
import Foundation
@testable import ArrBarr

@Suite("LocaleBundle")
struct LocaleBundleTests {
    /// Strings that the app expects to render correctly when the user has
    /// switched language at runtime — these must not depend on the bundle's
    /// launch-time `preferredLocalizations`.
    private let runtimeKeys = [
        "Today",
        "Tomorrow",
        "Needs you",
        "Tonight",
        "Show indexer issues warning",
        "Show Tonight banner",
        "Show Needs you",
        "Show history",
        "Refresh",
        "More options",
        "Close",
        "Open in browser",
        "Resume",
        "Pause",
        "Remove from client",
    ]

    private let translatedLocales = ["de", "es", "fr", "pl"]

    /// Verify each runtime-visible key has an *entry* in every locale's compiled
    /// `.lproj/Localizable.strings`. Comparing the resolved value against the
    /// English key would false-positive on cases like French "Pause" that are
    /// legitimately identical to the source — instead we ask the bundle with a
    /// sentinel default that can't collide with any real translation.
    @Test("Every runtime-visible key has an entry in every locale", arguments: [
        "de", "es", "fr", "pl",
    ])
    func everyKeyHasEntry(_ locale: String) {
        let bundleLocale = Locale(identifier: locale)
        let langCode = bundleLocale.language.languageCode?.identifier ?? bundleLocale.identifier
        guard let path = Bundle.main.path(forResource: langCode, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            Issue.record("No \(locale).lproj bundle in test host")
            return
        }
        let sentinel = "__MISSING_\(UUID().uuidString)__"
        var missing: [String] = []
        for key in runtimeKeys {
            let value = bundle.localizedString(forKey: key, value: sentinel, table: nil)
            if value == sentinel { missing.append(key) }
        }
        #expect(missing.isEmpty, "Missing keys in \(locale): \(missing.joined(separator: ", "))")
    }

    @Test("Polish 'Today' resolves to 'Dziś'")
    func polishToday() {
        #expect(LocaleBundle.string("Today", locale: Locale(identifier: "pl")) == "Dziś")
    }

    @Test("German 'Tomorrow' resolves to 'Morgen'")
    func germanTomorrow() {
        #expect(LocaleBundle.string("Tomorrow", locale: Locale(identifier: "de")) == "Morgen")
    }

    @Test("Spanish 'Needs you' resolves to 'Requiere tu atención'")
    func spanishNeedsYou() {
        #expect(LocaleBundle.string("Needs you", locale: Locale(identifier: "es")) == "Requiere tu atención")
    }

    @Test("French 'Tonight' resolves to 'Ce soir'")
    func frenchTonight() {
        #expect(LocaleBundle.string("Tonight", locale: Locale(identifier: "fr")) == "Ce soir")
    }

    @Test("Unknown locale falls back to source language (English)")
    func unknownLocaleFallback() {
        // No 'jp.lproj' shipped — should fall through to Bundle.main, which
        // serves the development language.
        let value = LocaleBundle.string("Today", locale: Locale(identifier: "jp"))
        #expect(value == "Today")
    }

    @Test("Missing key returns the key itself")
    func missingKey() {
        let value = LocaleBundle.string("ThisKeyDoesNotExist_xyz", locale: Locale(identifier: "pl"))
        #expect(value == "ThisKeyDoesNotExist_xyz")
    }
}

@Suite("UpcomingItem.airDateFormatted localization")
struct UpcomingDateLocalizationTests {
    private func item(daysAhead: Int) -> UpcomingItem {
        let date = Calendar.current.date(byAdding: .day, value: daysAhead, to: Date())!
        return UpcomingItem(
            id: "loc-\(daysAhead)", source: .radarr, title: "Title",
            subtitle: nil, airDate: date, releaseType: nil,
            hasFile: false, overview: nil
        )
    }

    @Test("'Today' label translates to Polish")
    func todayPolish() {
        #expect(item(daysAhead: 0).airDateFormatted(locale: Locale(identifier: "pl")) == "Dziś")
    }

    @Test("'Tomorrow' label translates to German")
    func tomorrowGerman() {
        #expect(item(daysAhead: 1).airDateFormatted(locale: Locale(identifier: "de")) == "Morgen")
    }

    @Test("Far-future date in French uses French month abbreviation")
    func futureFrench() {
        // Pick a fixed date so we can assert against a specific month name.
        let comps = DateComponents(year: 2026, month: 5, day: 8)
        let date = Calendar.current.date(from: comps)!
        let item = UpcomingItem(
            id: "fixed", source: .radarr, title: "Test",
            subtitle: nil, airDate: date, releaseType: nil,
            hasFile: false, overview: nil
        )
        let formatted = item.airDateFormatted(locale: Locale(identifier: "fr"))
        // French abbreviation for May is "mai".
        #expect(formatted.lowercased().contains("mai"), "Expected French 'mai' in: \(formatted)")
    }

    @Test("Far-future date in German uses German month abbreviation")
    func futureGerman() {
        let comps = DateComponents(year: 2026, month: 12, day: 24)
        let date = Calendar.current.date(from: comps)!
        let item = UpcomingItem(
            id: "fixed-de", source: .radarr, title: "Test",
            subtitle: nil, airDate: date, releaseType: nil,
            hasFile: false, overview: nil
        )
        let formatted = item.airDateFormatted(locale: Locale(identifier: "de"))
        // German abbreviation for December is "Dez.".
        #expect(formatted.lowercased().contains("dez"), "Expected German 'Dez' in: \(formatted)")
    }
}
