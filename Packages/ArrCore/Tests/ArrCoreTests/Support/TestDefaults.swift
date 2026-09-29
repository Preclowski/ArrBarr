import Foundation

/// Every defaults suite a test makes: empty on creation, under one prefix. cfprefsd writes a suite to
/// ~/Library/Preferences on its own schedule, even after `removePersistentDomain`, so a run can't delete its own
/// files; it sweeps earlier runs' instead. Only files older than five minutes: suites run in parallel, and a
/// sibling's live suite must not vanish mid-test.
enum TestDefaults {
    private static let prefix = "ArrCoreTests."
    private static let sweep: Void = {
        let fm = FileManager.default
        let preferences = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        for file in (try? fm.contentsOfDirectory(atPath: preferences.path)) ?? [] where file.hasPrefix(prefix) && file.hasSuffix(".plist") {
            let url = preferences.appendingPathComponent(file)
            guard let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date,
                  Date().timeIntervalSince(modified) > 300 else { continue }
            try? fm.removeItem(at: url)
        }
    }()

    static func suite(_ name: String) -> UserDefaults {
        _ = sweep
        let defaults = UserDefaults(suiteName: prefix + name)!
        defaults.removePersistentDomain(forName: prefix + name)
        return defaults
    }
}
