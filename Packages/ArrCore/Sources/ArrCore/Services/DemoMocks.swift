import Foundation

/// Reveals Developer options in Settings, independent of `DemoMode`. On via
/// `--demo`, `ARRBARR_DEMO=1` (both persisted) or the `ArrBarrDeveloperMode` default.
public enum DeveloperMode {
    public static let key = "ArrBarrDeveloperMode"

    public static var isActive: Bool {
        let defaults = UserDefaults.standard
        let args = ProcessInfo.processInfo.arguments
        let envOn = ProcessInfo.processInfo.environment["ARRBARR_DEMO"] == "1"
        if args.contains("--demo") || envOn {
            defaults.set(true, forKey: key)
            return true
        }
        return defaults.bool(forKey: key)
    }

    /// iOS 7-tap easter egg: iOS users can't pass launch args.
    public static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key)
    }
}

/// Read live from UserDefaults so toggling takes effect within the session.
nonisolated public enum DemoMode {
    public static let key = "ArrBarrDemo"

    /// The whole demo profile lives in its own suite, so demo never writes to `.standard`.
    public static let demoSuiteName = "pl.incred.ArrBarr.demo"

    /// Lives in the demo suite, so wiping it re-arms the seed.
    public static let seedDoneKey = "ArrBarr.demoSeedDone.v2"

    public static var isActive: Bool { UserDefaults.standard.bool(forKey: key) }

    public static var demoDefaults: UserDefaults? { UserDefaults(suiteName: demoSuiteName) }

    /// For state kept in `.standard` (quiz signals, taste notes, notification trackers): the demo suite while demo runs.
    public static var profileDefaults: UserDefaults { isActive ? (demoDefaults ?? .standard) : .standard }

    /// Passing the suite name removes only that domain, never `.standard`.
    public static func resetDemoStore() {
        UserDefaults.standard.removePersistentDomain(forName: demoSuiteName)
    }

    /// iOS can't relaunch, so demo switches live: the profile re-points to the demo suite (demo edits never reach
    /// the real one) and the gateway swaps its stack.
    @MainActor
    public static func switchLive(_ on: Bool) async {
        UserDefaults.standard.set(on, forKey: key)
        ConfigStore.shared.useDemoStore(on)
        if on { seedConfigsIfNeeded(.shared) } else { resetDemoStore() }
        await QueueViewModel.shared.demoModeChanged(on)
    }

    /// Whisparr stays off (opt-in, age gated).
    @MainActor
    public static func seedConfigsIfNeeded(_ store: ConfigStore) {
        guard isActive else { return }
        store.seedDemoConfigsIfNeeded()
    }
}

/// Public-domain / CC-licensed titles used as preview content.
nonisolated enum DemoMocks {

    /// `Special:FilePath` resolves to the current CDN location, surviving bucket rehashes.
    static let realPosters: [String: String] = [
        "bigbuckbunny":  "Big_buck_bunny_poster_big.jpg",
        "sintel":        "Sintel_poster.jpg",
        "tearsofsteel":  "Tos-poster.png",
        "pioneerone":    "Artwork_for_the_2010_Pioneer_One_series.jpg",
        "ninghosts":     "Nine_Inch_Nails_-_Ghosts_I-IV.png",
        "coultonsomeguys": "Jonathan_Coulton_-_Some_Guys.jpg",
        // Discovery-only titles for the demo search pool.
        "elephantsdream":   "ElephantsDreamPoster.jpg",
        "spring":           "Spring2019AlphaPosterBlender.jpg",
        "cosmoslaundromat": "CosmosLaundromatPoster.jpg",
    ]

    /// Seeds with no Wikipedia art.
    static let directPosters: [String: String] = [
        // The only Wikimedia art is a 16:9 episode cover; TMDB has a portrait poster.
        "caminandes": "https://image.tmdb.org/t/p/w500/753kJbZ5iS7DUomTKX9qF5Cs5NY.jpg",
        "bradsucks": "https://coverartarchive.org/release-group/16f30346-886a-3144-9377-cbfceb32fd34/front-500",
        "bradsucks-debut": "https://coverartarchive.org/release-group/10e85e9b-0f07-33d4-a927-18a273f86eca/front-500",
    ]

    static func poster(label: String, seed: String, w: Int = 200, h: Int = 300) -> URL? {
        // Whisparr demo posters are cats: seed is "kitten:<image_id>".
        if seed.hasPrefix("kitten:") {
            let id = String(seed.dropFirst("kitten:".count))
            return URL(string: "https://placecats.com/\(id)/\(w)/\(h)")
        }

        if let direct = directPosters[seed] {
            return URL(string: direct)
        }

        if let filename = realPosters[seed] {
            let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
            return URL(string: "https://en.wikipedia.org/wiki/Special:FilePath/\(encoded)?width=\(w * 2)")
        }
        let palette = ["3b1d52", "1c3859", "4a2c1d", "1d4a3a", "5c1f1f", "3a3a1f", "1f4a52", "4a1f4a"]
        let bg = palette[abs(seed.hashValue) % palette.count]
        let encoded = label
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: "&", with: "%26")
            ?? label
        return URL(string: "https://placehold.co/\(w)x\(h)/\(bg)/ffffff/png?text=\(encoded)&font=lato")
    }
}
