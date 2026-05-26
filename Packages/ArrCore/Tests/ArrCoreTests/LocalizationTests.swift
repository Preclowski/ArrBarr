import Testing
import Foundation
@testable import ArrCore

/// We no longer ship a runtime locale-switcher shim — string lookup goes
/// through SwiftUI's native `Text(_:bundle:)` / `String(localized:bundle:)`,
/// which read from the resource bundle Xcode compiles from xcstrings. So
/// there is nothing to unit-test about resolution — Apple owns that. What
/// we still want to guarantee is that the catalog itself has translations
/// for every runtime-visible key in every shipped locale. This test parses
/// `Localizable.xcstrings` directly, which sidesteps the fact that SwiftPM
/// does not compile xcstrings into the test target's `Bundle.module`.
@Suite("Localizable.xcstrings catalog completeness")
struct LocalizationCatalogTests {
    /// Strings the app renders at runtime. Add new user-visible keys here
    /// so missing translations get caught before they ship.
    private let runtimeKeys: [String] = [
        "Today",
        "Tomorrow",
        "Needs you",
        "Tonight",
        "Show indexer issues warning",
        // "Show Tonight banner" / "Show Needs you" dropped — the
        // ConfigStore booleans they used to label live as data only;
        // the Settings section that toggled them with text labels
        // moved to the section-order drag list (showing source
        // names instead). No runtime render = no translation needed.
        "Show history",
        "Refresh",
        "More options",
        "Close",
        "Open in browser",
        "Resume",
        "Pause",
        "Remove from client",
        "Quality",
        "Size",
        "Indexer",
        "File",
        "Custom formats",
        "Existing file",
        "Upgrade",
        "Episodes",
        "Multiple seasons",
        "Season %02lld",
        "%lld episodes",
        "Replacing all %lld episodes",
        "Restart required to apply the new language.",
        "Quit and reopen the app to apply the new language.",
        "Relaunch",
    ]

    private static let catalog: [String: Any] = {
        // #filePath is this test file; walk up to the package root, then into
        // the catalog. Robust as long as tests stay under Tests/ArrCoreTests/.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ArrCoreTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // package root
            .appendingPathComponent("Sources/ArrCore/Resources/Localizable.xcstrings")
        let data = try! Data(contentsOf: url)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

    @Test("Every runtime-visible key has a translated entry in every locale", arguments: [
        "de", "es", "fr", "pl",
    ])
    func everyKeyHasTranslation(_ locale: String) {
        let strings = Self.catalog["strings"] as! [String: [String: Any]]
        var missing: [String] = []
        for key in runtimeKeys {
            guard let entry = strings[key],
                  let localizations = entry["localizations"] as? [String: Any],
                  let loc = localizations[locale] as? [String: Any],
                  let stringUnit = loc["stringUnit"] as? [String: Any],
                  let value = stringUnit["value"] as? String,
                  !value.isEmpty
            else {
                missing.append(key)
                continue
            }
            _ = value
        }
        #expect(missing.isEmpty, "Missing translations in \(locale): \(missing.joined(separator: ", "))")
    }
}
