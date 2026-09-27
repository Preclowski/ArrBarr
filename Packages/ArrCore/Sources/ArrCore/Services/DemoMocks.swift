import Foundation

/// Developer mode: reveals the "Developer options" section in Settings, which
/// is where the Demo mode toggle, test notifications, and replay-welcome
/// buttons live. Decoupled from `DemoMode` so that you can poke at the dev
/// options without forcing fixtures on yourself.
///
/// Activate by any of:
///   - Launch arg:        --demo  (persisted to UserDefaults on first sight)
///   - Env var:           ARRBARR_DEMO=1  (persisted to UserDefaults)
///   - UserDefaults:      defaults write pl.incred.ArrBarr ArrBarrDeveloperMode -bool true
public enum DeveloperMode {
    public static let key = "ArrBarrDeveloperMode"

    public static var isActive: Bool {
        let defaults = UserDefaults.standard
        let args = ProcessInfo.processInfo.arguments
        let envOn = ProcessInfo.processInfo.environment["ARRBARR_DEMO"] == "1"
        if args.contains("--demo") || envOn {
            // Persist so subsequent launches without the flag still keep
            // dev options visible — matches how the welcome-screen handoff
            // sets the same UserDefault.
            defaults.set(true, forKey: key)
            return true
        }
        return defaults.bool(forKey: key)
    }

    /// Manually flip Developer mode on/off — used by the iOS About-section
    /// 7-tap easter egg since iOS users can't pass launch args.
    public static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key)
    }
}

/// Demo mode: ship a runnable preview without needing real Radarr/Sonarr/Lidarr instances.
/// Toggled from the "Demo mode" checkbox inside Developer options. The flag is
/// read live from UserDefaults so flipping it can take effect within the same
/// session — every consumer that reads `isActive` (the queue refresh path,
/// the popover's `isVisible(_:)` filter, etc.) sees the new value on its
/// next call.
nonisolated public enum DemoMode {
    public static let key = "ArrBarrDemo"

    /// Separate UserDefaults suite holding the ENTIRE demo profile (service
    /// configs, notification prefs, theme, the seed-done flag…). Demo settings
    /// live here so toggling e.g. Whisparr in demo never writes to the real
    /// profile in `.standard`.
    public static let demoSuiteName = "pl.incred.ArrBarr.demo"

    /// Seed-done marker. Stored in whichever store the demo configs live in
    /// (the demo suite), so wiping the suite re-arms a fresh seed.
    /// v2: the demo instances carry a demo URL and key (v1 left them blank and exempted every gate).
    public static let seedDoneKey = "ArrBarr.demoSeedDone.v2"

    public static var isActive: Bool { UserDefaults.standard.bool(forKey: key) }

    /// Backing store for the demo profile (nil only if the suite can't open).
    public static var demoDefaults: UserDefaults? { UserDefaults(suiteName: demoSuiteName) }

    /// Wipe the demo profile (all configs + the seed flag). Targets ONLY the
    /// demo suite — passing the suite name removes that domain, never the
    /// `.standard` (bundle-id) domain. Leaving demo calls this so re-entering
    /// re-seeds a clean profile.
    public static func resetDemoStore() {
        UserDefaults.standard.removePersistentDomain(forName: demoSuiteName)
    }

    /// First-time demo users get Radarr/Sonarr/Lidarr flipped to `enabled` so
    /// the popover has something to show. Whisparr stays OFF (opt-in, age
    /// gated). Delegates to the store so the seed-done flag lands in the same
    /// backing store the configs do. No-op when demo isn't active.
    @MainActor
    public static func seedConfigsIfNeeded(_ store: ConfigStore) {
        guard isActive else { return }
        store.seedDemoConfigsIfNeeded()
    }
}

/// Public-domain / CC-licensed titles used as preview content.
/// Posters come from picsum.photos with deterministic seeds, no auth.
nonisolated public enum DemoMocks {

    /// Real, stable Wikipedia-hosted poster art for the open-source / CC titles
    /// used in demo mode. Wikipedia's `Special:FilePath` endpoint resolves to the
    /// current canonical CDN location, so these URLs survive bucket rehashing.
    static let realPosters: [String: String] = [
        "bigbuckbunny":  "Big_buck_bunny_poster_big.jpg",
        "sintel":        "Sintel_poster.jpg",
        "tearsofsteel":  "Tos-poster.png",
        "pioneerone":    "Artwork_for_the_2010_Pioneer_One_series.jpg",
        "ninghosts":     "Nine_Inch_Nails_-_Ghosts_I-IV.png",
        "coultonsomeguys": "Jonathan_Coulton_-_Some_Guys.jpg",
        // Discovery-only titles surfaced by the demo search pool (not in the
        // curated library). Verified to resolve via Special:FilePath.
        "elephantsdream":   "ElephantsDreamPoster.jpg",
        "spring":           "Spring2019AlphaPosterBlender.jpg",
        "cosmoslaundromat": "CosmosLaundromatPoster.jpg",
    ]

    /// Seeds whose art isn't on Wikipedia — mapped to a full, stable, no-auth
    /// image URL instead. Brad Sucks' "Out of It" has no Wikipedia page, so we
    /// use the MusicBrainz Cover Art Archive front image for its release group.
    static let directPosters: [String: String] = [
        // Caminandes has no theatrical poster — the only Wikimedia art is the
        // 1920×1080 episode cover, which crops badly into a 2:3 poster slot.
        // TMDB hosts a proper portrait poster (Llamigos) on its no-auth CDN.
        "caminandes": "https://image.tmdb.org/t/p/w500/753kJbZ5iS7DUomTKX9qF5Cs5NY.jpg",
        "bradsucks": "https://coverartarchive.org/release-group/16f30346-886a-3144-9377-cbfceb32fd34/front-500",
        // Brad Sucks' 2003 debut "I Don't Know What I'm Doing" — the free-download
        // album that put him on the map. Cover Art Archive front for its release group.
        "bradsucks-debut": "https://coverartarchive.org/release-group/10e85e9b-0f07-33d4-a927-18a273f86eca/front-500",
    ]

    static func poster(label: String, seed: String, w: Int = 200, h: Int = 300) -> URL? {
        // Whisparr demo: posters are kittens. seed is "kitten:<image_id>" — e.g.
        // "kitten:neo", "kitten:millie". placecats.com is a free, no-auth cat
        // placeholder service that takes a named image plus dimensions.
        if seed.hasPrefix("kitten:") {
            let id = String(seed.dropFirst("kitten:".count))
            // placecats.com format: https://placecats.com/<image_id>/<w>/<h>
            return URL(string: "https://placecats.com/\(id)/\(w)/\(h)")
        }

        // Direct full-URL art (e.g. Cover Art Archive) for seeds not on Wikipedia.
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
