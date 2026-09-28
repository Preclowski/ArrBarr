import Foundation

/// Force-show: `--show-welcome`, `ARRBARR_SHOW_WELCOME=1`, or the one-shot `ArrBarrShowWelcome` default
/// (cleared once the window opens so it doesn't loop).
nonisolated public enum WelcomeContent {
    /// Must have a matching non-empty entry in `whatsNewEntries`.
    public static let currentVersion = "0.10.0"

    public enum Variant: Equatable {
        case firstRun
        case whatsNew(version: String)
    }

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
                titleKey: "Open Settings",
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

    /// An empty or missing entry for `currentVersion` skips the window on update.
    static let whatsNewEntries: [String: [WelcomePage]] = [
        "0.9.0": [
            WelcomePage(
                id: "welcome",
                titleKey: "Welcome screen",
                bodyKey: "ArrBarr now shows a brief intro on first launch and after major updates so you know what's new. Reopen it any time from Settings → General."
            ),
        ],
        "0.10.0": [
            WelcomePage(
                id: "ai-chat",
                titleKey: "Chat with your arrs",
                bodyKey: "A new Chat tab lets you ask questions in plain language — find a show, check what's coming this week, add a movie. Works with Apple Intelligence (macOS 26+) or any OpenAI-compatible API. Set up under Settings → AI."
            ),
            WelcomePage(
                id: "add-shortcut",
                titleKey: "Quicker way to add",
                bodyKey: "The footer is gone. Add new content via the **+** button next to the tabs, or press **⌘N** anywhere in the popover. The **⋯** menu next to it holds Settings, Quit and Open Window — and everything's also in the right-click menu on the menu bar icon."
            ),
            WelcomePage(
                id: "lidarr",
                titleKey: "Lidarr support",
                bodyKey: "If you've configured Lidarr, music artists now show up in search results and the AI chat. Add an artist the same way you'd add a series or movie."
            ),
        ],
    ]

    // MARK: - Decision

    static func decide(
        seen: String?,
        current: String,
        entries: [String: [WelcomePage]],
        forceShow: Bool
    ) -> Variant? {
        // Force-show returns the broader first-run tour.
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

    /// Consumes the one-shot UserDefaults flag so we don't loop.
    public static func variant(seen: String?, defaults: UserDefaults = .standard) -> Variant? {
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
