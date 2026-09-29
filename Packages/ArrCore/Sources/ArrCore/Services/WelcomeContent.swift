import Foundation

/// Force-show: `--show-welcome`, `ARRBARR_SHOW_WELCOME=1`, or the one-shot `ArrBarrShowWelcome` default
/// (cleared once the window opens so it doesn't loop).
nonisolated public enum WelcomeContent {
    /// Stored once the tour has been seen; any stored value means seen.
    public static let currentVersion = "0.10.0"

    struct WelcomePage: Identifiable, Equatable {
        let id: String
        let titleKey: String
        let bodyKey: String
        let cta: CTA?
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
            titleKey: String,
            bodyKey: String,
            cta: CTA? = nil,
            illustrationPosition: IllustrationPosition = .above
        ) {
            self.id = id
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
            titleKey: "Lives in your menu bar",
            bodyKey: "ArrBarr stays out of your Dock and shows active downloads at a glance. **Left-click** the icon to open the popover. **Right-click** for Add, Refresh, Settings — every action also has a keyboard shortcut.",
            illustrationPosition: .below
        ),
        WelcomePage(
            id: "connect",
            titleKey: "Connect Radarr, Sonarr & Lidarr",
            bodyKey: "Add your existing arr services in Settings — ArrBarr polls live queue, history, and health from each one.",
            cta: WelcomePage.CTA(
                titleKey: "common.openSettings.button",
                symbol: "gearshape.fill",
                kind: .openSettings
            )
        ),
        WelcomePage(
            id: "tonight",
            titleKey: "Tonight, Needs you, and notifications",
            bodyKey: "See what's airing tonight, get notified about new grabs, and surface indexer issues before they become a problem.",
            illustrationPosition: .below
        ),
        WelcomePage(
            id: "customize",
            titleKey: "Make it yours",
            bodyKey: "Reorder sections, hide what you don't need, tweak refresh intervals, and pick your language in Settings. Show only what matters to you.",
            illustrationPosition: .below
        ),
        WelcomePage(
            id: "star",
            titleKey: "Enjoying ArrBarr?",
            bodyKey: "It's free and open-source. A star on GitHub helps other people find it — and means a lot. Thanks for trying it out!",
            cta: WelcomePage.CTA(
                titleKey: "Star on GitHub",
                symbol: "star",
                kind: .openURL(URL(string: "https://github.com/Preclowski/ArrBarr")!)
            )
        ),
    ]

    // MARK: - Decision

    /// First run, or forced. The per-release "What's new" variant was retired pending a rewrite.
    static func decide(seen: String?, forceShow: Bool) -> Bool {
        forceShow || seen == nil
    }

    /// Consumes the one-shot UserDefaults flag so we don't loop.
    public static func shouldShow(seen: String?, defaults: UserDefaults = .standard) -> Bool {
        let force = shouldForceShow(defaults: defaults)
        if force { consumeForceShowFlag(defaults: defaults) }
        return decide(seen: seen, forceShow: force)
    }

    // MARK: - Force-show flag

    static let forceShowDefaultsKey = "ArrBarrShowWelcome"

    public static func shouldForceShow(defaults: UserDefaults = .standard) -> Bool {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--show-welcome") { return true }
        if ProcessInfo.processInfo.environment["ARRBARR_SHOW_WELCOME"] == "1" { return true }
        return defaults.bool(forKey: forceShowDefaultsKey)
    }

    static func consumeForceShowFlag(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: forceShowDefaultsKey)
    }
}
