import Foundation

/// Decides what (if anything) the welcome window should show on launch.
///
/// Two variants of the same UI:
///   - `.firstRun`              — user has never seen any welcome screen
///   - `.whatsNew(version)`     — user has seen welcome before, but a newer
///                                version of welcome content was published
///                                AND that version has entries to show
///
/// Force-show for testing or "Show welcome screen" button in Settings:
///   - Launch arg:    --show-welcome
///   - Env var:       ARRBARR_SHOW_WELCOME=1
///   - UserDefaults:  defaults write com.preclowski.ArrBarr ArrBarrShowWelcome -bool true
///                    (one-shot — cleared after the welcome window opens so
///                    it doesn't loop on every launch)
enum WelcomeContent {
    /// Bump when shipping a release with features worth re-introducing.
    /// Must have a matching entry (with at least one item) in `whatsNewEntries`.
    static let currentVersion = "0.9.0"

    enum Variant: Equatable {
        case firstRun
        case whatsNew(version: String)
    }

    struct FeatureItem: Identifiable, Equatable {
        let id: String
        let symbol: String
        let titleKey: String
        let bodyKey: String

        static func == (lhs: FeatureItem, rhs: FeatureItem) -> Bool { lhs.id == rhs.id }
    }

    static let firstRunFeatures: [FeatureItem] = [
        FeatureItem(
            id: "menubar",
            symbol: "menubar.dock.rectangle",
            titleKey: "Lives in your menu bar",
            bodyKey: "ArrBarr stays out of your Dock and shows active downloads at a glance. Click the icon for the popover; right-click for quick options."
        ),
        FeatureItem(
            id: "connect",
            symbol: "server.rack",
            titleKey: "Connect Radarr, Sonarr & Lidarr",
            bodyKey: "Add your existing arr services in Settings — ArrBarr polls live queue, history, and health from each one."
        ),
        FeatureItem(
            id: "tonight",
            symbol: "moon.stars.fill",
            titleKey: "Tonight, Needs you, and notifications",
            bodyKey: "See what's airing tonight, get notified about new grabs, and surface indexer issues before they become a problem."
        ),
    ]

    /// Per-version entries describing what's new. Add entries here when bumping
    /// `currentVersion`. If the entry list for `currentVersion` is empty (or
    /// missing), the welcome window is skipped on update — only first-run users
    /// will see the welcome screen.
    static let whatsNewEntries: [String: [FeatureItem]] = [
        "0.9.0": [
            FeatureItem(
                id: "welcome",
                symbol: "sparkles",
                titleKey: "Welcome screen",
                bodyKey: "ArrBarr now shows a brief intro on first launch and after major updates so you know what's new. Reopen it any time from Settings → General."
            ),
        ],
    ]

    // MARK: - Decision

    /// Pure decision function — used by `variant(seen:defaults:)` in production
    /// and directly by tests so we don't have to mutate static state.
    static func decide(
        seen: String?,
        current: String,
        entries: [String: [FeatureItem]],
        forceShow: Bool
    ) -> Variant? {
        if forceShow {
            return seen == nil ? .firstRun : .whatsNew(version: current)
        }
        if seen == nil {
            return .firstRun
        }
        if seen != current, let items = entries[current], !items.isEmpty {
            return .whatsNew(version: current)
        }
        return nil
    }

    /// Production entry point. Reads the force-show flag and (if set) consumes
    /// the one-shot UserDefaults variant so we don't loop.
    static func variant(seen: String?, defaults: UserDefaults = .standard) -> Variant? {
        let force = shouldForceShow(defaults: defaults)
        let result = decide(
            seen: seen,
            current: currentVersion,
            entries: whatsNewEntries,
            forceShow: force
        )
        if force { consumeForceShowFlag(defaults: defaults) }
        return result
    }

    static func features(for variant: Variant) -> [FeatureItem] {
        switch variant {
        case .firstRun: return firstRunFeatures
        case .whatsNew(let v): return whatsNewEntries[v] ?? []
        }
    }

    // MARK: - Force-show flag

    static let forceShowDefaultsKey = "ArrBarrShowWelcome"

    static func shouldForceShow(defaults: UserDefaults = .standard) -> Bool {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--show-welcome") { return true }
        if ProcessInfo.processInfo.environment["ARRBARR_SHOW_WELCOME"] == "1" { return true }
        return defaults.bool(forKey: forceShowDefaultsKey)
    }

    static func consumeForceShowFlag(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: forceShowDefaultsKey)
    }
}
