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

    struct WelcomePage: Identifiable, Equatable {
        let id: String
        let symbol: String
        let titleKey: String
        let bodyKey: String
        /// Optional secondary action button that appears under the body.
        let cta: CTA?
        /// Whether the hero illustration sits above or below the text.
        /// Detailed/wide illustrations (mock menu bar, settings rows) read
        /// better as a "preview" under the explanation; symbol-style heroes
        /// look better above.
        let illustrationPosition: IllustrationPosition

        enum IllustrationPosition: Equatable {
            case above
            case below
        }

        struct CTA: Equatable {
            let titleKey: String
            let symbol: String
            let kind: Kind

            enum Kind: Equatable {
                case openURL(URL)
                case openSettings
            }
        }

        init(
            id: String,
            symbol: String,
            titleKey: String,
            bodyKey: String,
            cta: CTA? = nil,
            illustrationPosition: IllustrationPosition = .above
        ) {
            self.id = id
            self.symbol = symbol
            self.titleKey = titleKey
            self.bodyKey = bodyKey
            self.cta = cta
            self.illustrationPosition = illustrationPosition
        }

        static func == (lhs: WelcomePage, rhs: WelcomePage) -> Bool { lhs.id == rhs.id }
    }

    static let firstRunPages: [WelcomePage] = [
        WelcomePage(
            id: "menubar",
            symbol: "menubar.dock.rectangle",
            titleKey: "Lives in your menu bar",
            bodyKey: "ArrBarr stays out of your Dock and shows active downloads at a glance. Click the icon for the popover; right-click for quick options.",
            illustrationPosition: .below
        ),
        WelcomePage(
            id: "connect",
            symbol: "server.rack",
            titleKey: "Connect Radarr, Sonarr & Lidarr",
            bodyKey: "Add your existing arr services in Settings — ArrBarr polls live queue, history, and health from each one.",
            cta: WelcomePage.CTA(
                titleKey: "Open Settings",
                symbol: "gearshape.fill",
                kind: .openSettings
            )
        ),
        WelcomePage(
            id: "tonight",
            symbol: "moon.stars.fill",
            titleKey: "Tonight, Needs you, and notifications",
            bodyKey: "See what's airing tonight, get notified about new grabs, and surface indexer issues before they become a problem.",
            illustrationPosition: .below
        ),
        WelcomePage(
            id: "customize",
            symbol: "slider.horizontal.3",
            titleKey: "Make it yours",
            bodyKey: "Reorder sections, hide what you don't need, tweak refresh intervals, and pick your language in Settings. Show only what matters to you.",
            illustrationPosition: .below
        ),
        WelcomePage(
            id: "star",
            symbol: "star.fill",
            titleKey: "Enjoying ArrBarr?",
            bodyKey: "It's free and open-source. A star on GitHub helps other people find it — and means a lot. Thanks for trying it out!",
            cta: WelcomePage.CTA(
                titleKey: "Star on GitHub",
                symbol: "star",
                kind: .openURL(URL(string: "https://github.com/Preclowski/ArrBarr")!)
            )
        ),
    ]

    /// Per-version entries describing what's new. Add entries here when bumping
    /// `currentVersion`. If the entry list for `currentVersion` is empty (or
    /// missing), the welcome window is skipped on update — only first-run users
    /// will see the welcome screen.
    static let whatsNewEntries: [String: [WelcomePage]] = [
        "0.9.0": [
            WelcomePage(
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
        entries: [String: [WelcomePage]],
        forceShow: Bool
    ) -> Variant? {
        // Force-show always returns firstRun — that's the broader "tour"
        // content, and it's what users actually want to re-view from Settings
        // or from `--show-welcome` while testing. Returning users seeing
        // version-specific changes is handled by the normal upgrade path
        // below (no force flag).
        if forceShow {
            return .firstRun
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

    static func pages(for variant: Variant) -> [WelcomePage] {
        switch variant {
        case .firstRun: return firstRunPages
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
