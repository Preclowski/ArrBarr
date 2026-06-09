import Testing
import Foundation
@testable import ArrCore

/// String lookup goes through SwiftUI's native `Text(_:bundle:)` /
/// `String(localized:bundle:)`, which read from the resource bundle Xcode
/// compiles from `Localizable.xcstrings`. Apple owns resolution, so there is
/// nothing to unit-test about that — and SwiftPM does not compile xcstrings
/// into the test target's `Bundle.module` anyway.
///
/// What we DO guarantee is catalog integrity: every key carries a non-empty
/// value in every shipped locale (en, pl, de, es, fr, nl), whether it's a
/// plain `stringUnit` or a pluralised `variations.plural` entry. This test
/// parses `Localizable.xcstrings` directly, mirroring `Tools/loc/loc_audit.py`.
@Suite("Localizable.xcstrings catalog completeness")
struct LocalizationCatalogTests {
    private static let shippedLocales = ["en", "pl", "de", "es", "fr", "nl"]

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

    /// A localization unit is complete when it has either a non-empty
    /// `stringUnit.value` or a `variations.plural` whose every category value
    /// is non-empty.
    private func isComplete(_ unit: Any?) -> Bool {
        guard let loc = unit as? [String: Any] else { return false }
        if let su = loc["stringUnit"] as? [String: Any],
           let value = su["value"] as? String, !value.isEmpty {
            return true
        }
        if let variations = loc["variations"] as? [String: Any],
           let plural = variations["plural"] as? [String: Any], !plural.isEmpty {
            for case let cat as [String: Any] in plural.values {
                guard let su = cat["stringUnit"] as? [String: Any],
                      let value = su["value"] as? String, !value.isEmpty
                else { return false }
            }
            return true
        }
        return false
    }

    @Test("Every catalog key has a non-empty value in every shipped locale",
          arguments: shippedLocales)
    func everyKeyHasTranslation(_ locale: String) {
        let strings = Self.catalog["strings"] as! [String: [String: Any]]
        var missing: [String] = []
        for (key, entry) in strings where !key.isEmpty {
            let localizations = entry["localizations"] as? [String: Any]
            if !isComplete(localizations?[locale]) {
                missing.append(key)
            }
        }
        let preview = missing.sorted().prefix(20).joined(separator: ", ")
        #expect(missing.isEmpty, "Missing \(locale) for \(missing.count) keys: \(preview)")
    }

    @Test("Catalog has no empty-string key")
    func catalogIsClean() {
        let strings = Self.catalog["strings"] as! [String: [String: Any]]
        #expect(strings[""] == nil, "empty-string key must be dropped")
    }
}
