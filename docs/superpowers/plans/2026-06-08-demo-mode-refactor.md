# Demo Mode Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Isolate the demo profile into its own `UserDefaults` suite (so demo settings never bleed into the real profile) and curate the demo content down to a tight, coherent open-source universe (3 movies, 5 episodes across 2 series, 2 albums, 2 cat "nature films").

**Architecture:** `ConfigStore` gains a swappable backing store (`var defaults`) selected by `DemoMode.isActive`; a `useDemoStore(_:)` re-point makes both the macOS (relaunch) and iOS (no-relaunch) toggle paths isolate correctly. Demo settings + a seed-done flag live in the `com.preclowski.ArrBarr.demo` suite; leaving demo wipes only that suite, never `.standard`. The `DemoMocks+*` fixtures are pruned to the curated entities and their states are tuned to showcase quality upgrades, custom-format scores, and the calendar/history.

**Tech Stack:** Swift 6 / SwiftPM package `ArrCore`, Swift Testing (`import Testing`, `@Test`, `#expect`), `UserDefaults` suites, Combine `@Published`.

**Safety invariant (non-negotiable):** No step may delete, clear, or `removePersistentDomain` the user's real profile. Every wipe targets the demo suite by name. The user's `.standard` profile must survive enable-demo → toggle-Whisparr → disable-demo untouched.

**Spec:** `docs/superpowers/specs/2026-06-08-demo-mode-refactor-design.md`

---

## File Structure

**Phase 1 — settings isolation (logic):**
- `Packages/ArrCore/Sources/ArrCore/Services/DemoMocks.swift` — add demo suite name + `demoDefaults` + `resetDemoStore()`; rewrite `seedConfigsIfNeeded`.
- `Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift` — `defaults` becomes `var`; add `resolveDefaults()`, `applyValues(from:)`, `useStore(_:)`, `useDemoStore(_:)`, `seedDemoConfigsIfNeeded()`; extract `setupSinks()`; give `@Published` declarations inline defaults.
- `ArrBarr/AppDelegate.swift` — disable path wipes demo suite instead of removing the `.standard` seed key; call `useDemoStore` before relaunch.
- `Packages/ArrCore/Sources/ArrCore/Views/iOSAppRoot.swift` — toggle calls `configStore.useDemoStore(enable)` and wipes the suite on disable.
- `Packages/ArrCore/Tests/ArrCoreTests/DemoIsolationTests.swift` — **new** test suite.

**Phase 2 — content curation (data):**
- `Packages/ArrCore/Sources/ArrCore/Services/DemoMocks.swift` — trim `realPosters`.
- `Packages/ArrCore/Sources/ArrCore/Services/DemoMocks+Queue.swift` — rewrite to curated queues.
- `Packages/ArrCore/Sources/ArrCore/Services/DemoMocks+Upcoming.swift` — rewrite calendar; health all-green.
- `Packages/ArrCore/Sources/ArrCore/Services/DemoMocks+History.swift` — rewrite history (no failures/deletes).
- `Packages/ArrCore/Sources/ArrCore/Services/DemoMocks+Details.swift` — remove orphan entities; keep curated detail data.

**Curated entity ID map (must stay consistent across all fixture files):**

| Source | Entity | id | posterSeed |
|---|---|---|---|
| Radarr | Big Buck Bunny (2008) | 201 | `bigbuckbunny` |
| Radarr | Sintel (2010) | 202 | `sintel` |
| Radarr | Tears of Steel (2012) | 203 | `tearsofsteel` |
| Sonarr | Pioneer One (2010) | 101 | `pioneerone` |
| Sonarr | Caminandes (2013) | 102 | `caminandes` |
| Lidarr | NIN — Ghosts I-IV | 301 | `ninghosts` |
| Lidarr | Brad Sucks — Out of It | 302 | `bradsucks` |
| Whisparr | Kitten Cam: Backyard Drama (2024) | 401 | `kitten:neo` |
| Whisparr | The Black Cat Chronicles (2023) | 402 | `kitten:millie` |

**Removed entities (delete every reference):** Tears of Steel-as-series (103), Cosmos Laundromat (104), Northern Cascade (105), Spring Tales (106), and titles Spring, Charge, Jonathan Coulton, Nine Lives of Mittens, Garage Cat Files, Whiskers & Whispers. Removed posterSeeds: `spring`, `cosmoslaundromat`, `coultonsomeguys`, `northerncascade`, `charge`, `kitten:poppy`, `kitten:bella`.

---

# Phase 1 — Settings isolation

### Task 1: Demo suite primitives in `DemoMocks.swift`

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/DemoMocks.swift:42-63`

- [ ] **Step 1: Write the failing test**

Create `Packages/ArrCore/Tests/ArrCoreTests/DemoIsolationTests.swift`:

```swift
import Testing
import Foundation
@testable import ArrCore

@Suite("Demo isolation")
struct DemoIsolationTests {
    /// A throwaway suite standing in for `.standard` (the "real profile") plus
    /// a second standing in for the demo suite, so tests never touch the real
    /// user defaults.
    private func makeSuite() -> (UserDefaults, String) {
        let name = "ArrBarrDemoTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("resetDemoStore wipes only the demo suite, never standard")
    func resetTargetsDemoSuiteOnly() {
        // Real profile sentinel lives in .standard under a unique key.
        let sentinelKey = "ArrBarrDemoTests.realSentinel.\(UUID().uuidString)"
        UserDefaults.standard.set("keep-me", forKey: sentinelKey)
        defer { UserDefaults.standard.removeObject(forKey: sentinelKey) }

        // Seed the demo suite, then reset it.
        let demo = DemoMode.demoDefaults!
        demo.set(true, forKey: DemoMode.seedDoneKey)
        DemoMode.resetDemoStore()
        defer { DemoMode.resetDemoStore() }

        #expect(DemoMode.demoDefaults!.bool(forKey: DemoMode.seedDoneKey) == false)
        #expect(UserDefaults.standard.string(forKey: sentinelKey) == "keep-me")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/ArrCore && swift test --filter DemoIsolationTests`
Expected: FAIL to compile — `DemoMode.demoDefaults`, `DemoMode.seedDoneKey`, `DemoMode.resetDemoStore` don't exist yet.

- [ ] **Step 3: Implement the primitives**

In `DemoMocks.swift`, replace the `DemoMode` enum (lines 42-63) with:

```swift
public enum DemoMode {
    public static let key = "ArrBarrDemo"

    /// Separate UserDefaults suite holding the ENTIRE demo profile (service
    /// configs, notification prefs, theme, the seed-done flag…). Demo settings
    /// live here so toggling e.g. Whisparr in demo never writes to the real
    /// profile in `.standard`.
    public static let demoSuiteName = "com.preclowski.ArrBarr.demo"

    /// Seed-done marker. Stored in whichever store the demo configs live in
    /// (the demo suite), so wiping the suite re-arms a fresh seed.
    public static let seedDoneKey = "ArrBarr.demoSeedDone"

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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Packages/ArrCore && swift test --filter DemoIsolationTests`
Expected: PASS (1 test). It will not compile until Task 2 adds `store.seedDemoConfigsIfNeeded()` — if compilation fails on that symbol, proceed to Task 2 and re-run at the end of Task 2.

> Note: `seedConfigsIfNeeded` now references `store.seedDemoConfigsIfNeeded()`, added in Task 2. If you implement strictly task-by-task, temporarily stub the body of `seedConfigsIfNeeded` as `guard isActive else { return }` and fill it in Task 2. Otherwise do Tasks 1 and 2 together before running tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/DemoMocks.swift Packages/ArrCore/Tests/ArrCoreTests/DemoIsolationTests.swift
git commit -m "feat(demo): demo UserDefaults suite primitives (suite name, reset, seed flag)"
```

---

### Task 2: `ConfigStore` swappable backing store + seeding

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift`
- Test: `Packages/ArrCore/Tests/ArrCoreTests/DemoIsolationTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `DemoIsolationTests.swift` (inside the `DemoIsolationTests` struct):

```swift
    @Test("seedDemoConfigsIfNeeded enables radarr/sonarr/lidarr, leaves whisparr off")
    @MainActor func seedEnablesThreeArrs() {
        let (suite, name) = makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let store = ConfigStore(defaults: suite)
        store.seedDemoConfigsIfNeeded()

        #expect(store.radarr.enabled == true)
        #expect(store.sonarr.enabled == true)
        #expect(store.lidarr.enabled == true)
        #expect(store.whisparr.enabled == false)
        #expect(suite.bool(forKey: DemoMode.seedDoneKey) == true)
    }

    @Test("seed runs once — after seedDone, re-seeding does not re-enable a user-disabled arr")
    @MainActor func seedRunsOnce() {
        let (suite, name) = makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let store = ConfigStore(defaults: suite)
        store.seedDemoConfigsIfNeeded()          // first seed: all three on
        store.radarr.enabled = false             // user turns radarr off
        store.seedDemoConfigsIfNeeded()          // should be a no-op now

        #expect(store.radarr.enabled == false)
    }

    @Test("useStore re-points backing store so later writes isolate to the new suite")
    @MainActor func useStoreIsolatesWrites() {
        let (real, realName) = makeSuite()
        let (demo, demoName) = makeSuite()
        defer {
            UserDefaults.standard.removePersistentDomain(forName: realName)
            UserDefaults.standard.removePersistentDomain(forName: demoName)
        }

        let store = ConfigStore(defaults: real)
        store.useStore(demo)                      // switch to "demo" backing store
        store.whisparr = ServiceConfig(enabled: true, baseURL: "", apiKey: "", username: "", password: "")

        // The write landed in demo, NOT in real.
        let realReload = ConfigStore(defaults: real)
        let demoReload = ConfigStore(defaults: demo)
        #expect(realReload.whisparr.enabled == false)
        #expect(demoReload.whisparr.enabled == true)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/ArrCore && swift test --filter DemoIsolationTests`
Expected: FAIL to compile — `seedDemoConfigsIfNeeded()` and `useStore(_:)` don't exist.

- [ ] **Step 3: Implement in `ConfigStore.swift`**

3a. Give every `@Published` declaration (lines 47-100) an inline default so `self` is fully initialized before `init` calls an instance method. Change each declaration to include `= <default>`:

```swift
    @Published public var radarr: ServiceConfig = .empty
    @Published public var sonarr: ServiceConfig = .empty
    @Published public var lidarr: ServiceConfig = .empty
    @Published public var whisparr: ServiceConfig = .empty
    @Published public var sabnzbd: ServiceConfig = .empty
    @Published public var qbittorrent: ServiceConfig = .empty
    @Published public var nzbget: ServiceConfig = .empty
    @Published public var transmission: ServiceConfig = .empty
    @Published public var rtorrent: ServiceConfig = .empty
    @Published public var deluge: ServiceConfig = .empty
    @Published public var foregroundInterval: TimeInterval = 5
    @Published public var backgroundInterval: TimeInterval = 30
    @Published public var notifyRadarr: Bool = true
    @Published public var notifySonarr: Bool = true
    @Published public var notifyLidarr: Bool = true
    @Published public var notificationSoundName: String = ""
    @Published public var blurWhisparrPosters: Bool = true
    @Published public var whisparrAgeConfirmed: Bool = false
    @Published public var fontScale: Double = 1.0
    @Published public var aiKnowsAboutWhisparr: Bool = false
    @Published public var launchAtLogin: Bool = false
    @Published public var appLanguage: String = "system"
    @Published public var appearance: String = "system"
    @Published public var arrOrder: [String] = ConfigStore.defaultArrOrder
    @Published public var showTonight: Bool = true
    @Published public var showNeedsYou: Bool = true
    @Published public var showIndexerIssues: Bool = true
    @Published public var collapsedArrs: Set<String> = []
    @Published public var tonightHours: Int = 168
    @Published public var welcomeSeenVersion: String? = nil
    @Published public var aiEnabled: Bool = false
    @Published public var chatProvider: ChatProvider = .foundationModels
    @Published public var openai: OpenAIConfig = .empty
    @Published public var tmdbApiKey: String = ""
```

(Keep the existing doc comments above each property.)

3b. Change the backing store to a `var` and add the resolver. Replace line 158 (`private let defaults: UserDefaults`) with:

```swift
    private var defaults: UserDefaults

    /// Backing store for `ConfigStore.shared`: the demo suite while demo is
    /// active, otherwise the real profile. Falls back to `.standard` if the
    /// demo suite can't be opened.
    public static func resolveDefaults() -> UserDefaults {
        (DemoMode.isActive ? DemoMode.demoDefaults : nil) ?? .standard
    }
```

3c. Replace the `init` (lines 189-365) with a thin init that delegates to `applyValues(from:)` and `setupSinks()`:

```swift
    public init(defaults: UserDefaults = ConfigStore.resolveDefaults()) {
        self.defaults = defaults
        // One-time migration: pull leftover Keychain secrets back into
        // UserDefaults. See migrateLegacyKeychainSecrets for why. Runs against
        // whichever store we boot with (demo suite has nothing to migrate).
        if !defaults.bool(forKey: Self.keychainMigrationDoneKey) {
            Self.migrateLegacyKeychainSecrets(defaults: defaults)
            defaults.set(true, forKey: Self.keychainMigrationDoneKey)
        }
        applyValues(from: defaults)
        setupSinks()
    }

    /// Load every published value from `defaults`. Called once at init (before
    /// sinks exist, so no spurious writes) and again by `useStore` on a live
    /// swap (after sinks exist — the resulting writes just re-persist the same
    /// values into the now-current store, which is harmless).
    private func applyValues(from defaults: UserDefaults) {
        self.radarr = Self.load(.radarr, from: defaults)
        self.sonarr = Self.load(.sonarr, from: defaults)
        self.lidarr = Self.load(.lidarr, from: defaults)
        self.whisparr = Self.load(.whisparr, from: defaults)
        self.sabnzbd = Self.load(.sabnzbd, from: defaults)
        self.qbittorrent = Self.load(.qbittorrent, from: defaults)
        self.nzbget = Self.load(.nzbget, from: defaults)
        self.transmission = Self.load(.transmission, from: defaults)
        self.rtorrent = Self.load(.rtorrent, from: defaults)
        self.deluge = Self.load(.deluge, from: defaults)
        let fgKey = Self.foregroundIntervalKey
        self.foregroundInterval = defaults.object(forKey: fgKey) != nil ? defaults.double(forKey: fgKey) : 5
        let bgKey = Self.backgroundIntervalKey
        self.backgroundInterval = defaults.object(forKey: bgKey) != nil ? defaults.double(forKey: bgKey) : 30
        self.notifyRadarr = defaults.object(forKey: Self.notifyRadarrKey) != nil ? defaults.bool(forKey: Self.notifyRadarrKey) : true
        self.notifySonarr = defaults.object(forKey: Self.notifySonarrKey) != nil ? defaults.bool(forKey: Self.notifySonarrKey) : true
        self.notifyLidarr = defaults.object(forKey: Self.notifyLidarrKey) != nil ? defaults.bool(forKey: Self.notifyLidarrKey) : true
        self.notificationSoundName = defaults.string(forKey: Self.notificationSoundNameKey) ?? ""
        self.blurWhisparrPosters = defaults.object(forKey: Self.blurWhisparrPostersKey) != nil ? defaults.bool(forKey: Self.blurWhisparrPostersKey) : true
        self.whisparrAgeConfirmed = defaults.bool(forKey: Self.whisparrAgeConfirmedKey)
        let storedScale = defaults.double(forKey: Self.fontScaleKey)
        self.fontScale = storedScale > 0 ? storedScale : 1.0
        self.aiKnowsAboutWhisparr = defaults.object(forKey: Self.aiKnowsAboutWhisparrKey) != nil ? defaults.bool(forKey: Self.aiKnowsAboutWhisparrKey) : false
        self.launchAtLogin = defaults.object(forKey: Self.launchAtLoginKey) != nil ? defaults.bool(forKey: Self.launchAtLoginKey) : false
        self.appLanguage = defaults.string(forKey: Self.appLanguageKey) ?? "system"
        self.appearance = defaults.string(forKey: Self.appearanceKey) ?? "system"
        #if os(iOS)
        self.appLanguage = "system"
        defaults.removeObject(forKey: "AppleLanguages")
        #endif
        self.arrOrder = Self.normalizeArrOrder(defaults.stringArray(forKey: Self.arrOrderKey))
        self.showTonight = defaults.object(forKey: Self.showTonightKey) != nil ? defaults.bool(forKey: Self.showTonightKey) : true
        self.showNeedsYou = defaults.object(forKey: Self.showNeedsYouKey) != nil ? defaults.bool(forKey: Self.showNeedsYouKey) : true
        self.showIndexerIssues = defaults.object(forKey: Self.showIndexerIssuesKey) != nil ? defaults.bool(forKey: Self.showIndexerIssuesKey) : true
        #if os(iOS)
        self.showIndexerIssues = false
        self.foregroundInterval = 5
        self.appearance = "system"
        #endif
        self.collapsedArrs = Set(defaults.stringArray(forKey: Self.collapsedArrsKey) ?? [])
        self.tonightHours = 168
        self.welcomeSeenVersion = defaults.string(forKey: Self.welcomeSeenVersionKey)
        self.aiEnabled = defaults.object(forKey: Self.aiEnabledKey) != nil ? defaults.bool(forKey: Self.aiEnabledKey) : false
        let storedProvider = ChatProvider(rawValue: defaults.string(forKey: Self.chatProviderKey) ?? "") ?? .foundationModels
        self.chatProvider = (storedProvider == .foundationModels && !FoundationModelsAvailability.isSupported)
            ? .openai
            : storedProvider
        if let data = defaults.data(forKey: Self.openaiConfigKey),
           let cfg = try? JSONDecoder().decode(OpenAIConfig.self, from: data) {
            self.openai = cfg
        } else {
            self.openai = .empty
        }
        self.tmdbApiKey = defaults.string(forKey: Self.tmdbApiKeyKey) ?? ""
    }
```

3d. Move the entire sink-wiring block (the `for kind in ServiceKind.allCases { ... }` loop and every `$property.dropFirst().sink { ... }` chain, original lines 275-364) verbatim into a new method, and reset `cancellables` first so a live swap doesn't double-subscribe:

```swift
    private func setupSinks() {
        cancellables.removeAll()
        for kind in ServiceKind.allCases {
            publisher(for: kind).dropFirst().sink { [weak self] cfg in
                self?.save(kind, cfg)
            }.store(in: &cancellables)
        }
        $foregroundInterval.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.foregroundIntervalKey)
        }.store(in: &cancellables)
        // … (paste the rest of the original sink chain unchanged: backgroundInterval,
        //    notifyRadarr, notifySonarr, notifyLidarr, notificationSoundName,
        //    whisparrAgeConfirmed, blurWhisparrPosters, fontScale, aiKnowsAboutWhisparr,
        //    launchAtLogin, arrOrder, showTonight, showNeedsYou, showIndexerIssues,
        //    collapsedArrs, tonightHours, appearance, welcomeSeenVersion, appLanguage,
        //    aiEnabled, chatProvider, openai, tmdbApiKey) …
    }
```

Each sink already reads `self?.defaults` dynamically, so after a swap they persist to the new store automatically — no change to the sink bodies.

3e. Add the live-swap and seeding API (place after `setupSinks()`):

```swift
    /// Re-point the backing store to the demo suite (`on == true`) or the real
    /// profile, in place, reloading all values. Used by the demo toggle on both
    /// platforms so demo edits never reach `.standard`.
    public func useDemoStore(_ on: Bool) {
        useStore(on ? (DemoMode.demoDefaults ?? .standard) : .standard)
    }

    /// Swap to an explicit backing store and reload. Internal seam for tests.
    ///
    /// Tears down sinks BEFORE reloading so the reload assignments don't fire
    /// persistence writes or side effects (notably the `launchAtLogin` sink,
    /// which would otherwise (de)register the real login item from the new
    /// store's value). `setupSinks()` re-subscribes with `dropFirst()`, so the
    /// freshly-loaded values are not re-persisted.
    func useStore(_ target: UserDefaults) {
        guard target !== defaults else { return }
        cancellables.removeAll()
        defaults = target
        applyValues(from: target)
        setupSinks()
    }

    /// Seed demo configs once. Enables Radarr/Sonarr/Lidarr; leaves Whisparr off
    /// (opt-in, age gated). The seed-done flag lives in the current backing
    /// store, so wiping the demo suite re-arms it. Caller guards on demo being
    /// active (see DemoMode.seedConfigsIfNeeded).
    func seedDemoConfigsIfNeeded() {
        guard !defaults.bool(forKey: DemoMode.seedDoneKey) else { return }
        if radarr == .empty { radarr.enabled = true }
        if sonarr == .empty { sonarr.enabled = true }
        if lidarr == .empty { lidarr.enabled = true }
        defaults.set(true, forKey: DemoMode.seedDoneKey)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/ArrCore && swift test --filter DemoIsolationTests`
Expected: PASS (4 tests). Also run the existing ConfigStore suite to confirm no regression:
Run: `cd Packages/ArrCore && swift test --filter ConfigStore`
Expected: PASS (all existing tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift Packages/ArrCore/Tests/ArrCoreTests/DemoIsolationTests.swift
git commit -m "feat(demo): swappable ConfigStore backing store + demo-suite seeding"
```

---

### Task 3: Wire the toggle paths to the demo suite

**Files:**
- Modify: `ArrBarr/AppDelegate.swift:449-453`
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/iOSAppRoot.swift:339-349`

- [ ] **Step 1: Update the macOS toggle**

In `AppDelegate.swift`, replace lines 449-454:

```swift
        UserDefaults.standard.set(enabled, forKey: DemoMode.key)
        if !enabled {
            // Re-arm the seed so re-enabling later flips configs back on.
            UserDefaults.standard.removeObject(forKey: "ArrBarr.demoSeedDone")
        }
        relaunchSelf()
```

with:

```swift
        UserDefaults.standard.set(enabled, forKey: DemoMode.key)
        // Re-point the live store now (belt-and-suspenders before relaunch).
        configStore.useDemoStore(enabled)
        if !enabled {
            // Wipe the demo profile entirely (configs + seed flag) so the next
            // enable re-seeds a clean demo. Targets ONLY the demo suite — the
            // real profile in `.standard` is never touched.
            DemoMode.resetDemoStore()
        }
        relaunchSelf()
```

- [ ] **Step 2: Update the iOS toggle**

In `iOSAppRoot.swift`, replace the `onSetDemoMode` closure body (lines 339-349):

```swift
            onSetDemoMode: { enable in
                // iOS can't relaunch itself. Persist the flag, re-point the
                // ConfigStore to the demo suite (so demo edits never reach the
                // real profile), seed on enable, wipe the demo suite on disable.
                UserDefaults.standard.set(enable, forKey: DemoMode.key)
                configStore.useDemoStore(enable)
                if enable {
                    DemoMode.seedConfigsIfNeeded(configStore)
                } else {
                    DemoMode.resetDemoStore()
                }
                Task { await viewModel.refresh() }
                return true
            }
```

- [ ] **Step 3: Build both targets**

Run: `cd Packages/ArrCore && swift build`
Expected: Build succeeds.
Then build the macOS app (see Phase 3 for the xcodebuild invocation) — or defer the full app build to Phase 3.

- [ ] **Step 4: Commit**

```bash
git add ArrBarr/AppDelegate.swift Packages/ArrCore/Sources/ArrCore/Views/iOSAppRoot.swift
git commit -m "feat(demo): route demo toggle through isolated suite (macOS + iOS), wipe on disable"
```

---

# Phase 2 — Content curation

> These tasks change declarative fixtures only. There is no unit test for fixture content; verification is the build plus the in-app relaunch in Phase 3. After each task run `cd Packages/ArrCore && swift build` and confirm it compiles.

### Task 4: Trim `realPosters`

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/DemoMocks.swift:71-82`

- [ ] **Step 1: Replace the `realPosters` map** with only curated seeds:

```swift
    static let realPosters: [String: String] = [
        "bigbuckbunny":  "Big_buck_bunny_poster_big.jpg",
        "sintel":        "Sintel_poster.jpg",
        "tearsofsteel":  "Tos-poster.png",
        "caminandes":    "Blender_Foundation_-_Caminandes_-_Episode_3_-_Llamigos_-_Cover_thumbnail.png",
        "pioneerone":    "Artwork_for_the_2010_Pioneer_One_series.jpg",
        "ninghosts":     "Nine_Inch_Nails_-_Ghosts_I-IV.png",
        "bradsucks":     "Brad_Sucks_Out_of_It.jpg",
    ]
```

- [ ] **Step 2: Build**

Run: `cd Packages/ArrCore && swift build`
Expected: Build succeeds (removed seeds are only referenced by fixtures rewritten in later tasks; if a reference remains it surfaces here — fix by removing that fixture entry per the relevant task).

- [ ] **Step 3: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/DemoMocks.swift
git commit -m "refactor(demo): trim poster map to curated titles"
```

---

### Task 5: Rewrite the queues (`DemoMocks+Queue.swift`)

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/DemoMocks+Queue.swift` (full rewrite of the `extension DemoMocks` body)

Composition: 3 Radarr movies (one headline upgrade), 5 Sonarr episodes (Caminandes 2-ep pack that groups + 3 independent Pioneer One S01 rows, one of them an upgrade), 2 Lidarr albums (one upgrade), 2 Whisparr cats. No `.warning`/failed items, no negative scores.

- [ ] **Step 1: Replace the whole file body** with:

```swift
import Foundation

// Queue fixtures: curated open-source universe (3 movies, 5 episodes / 2 series,
// 2 albums, 2 cat "nature films"). States are tuned to show off quality upgrades
// and custom-format scores. No failures/warnings — health stays green.

extension DemoMocks {
    // MARK: - Radarr (3 movies)

    static var radarrQueue: [QueueItem] {
        [
            // CF-score showcase: high-tier 2160p remux, big positive score.
            queueItem(
                source: .radarr, id: "demo-radarr-1",
                title: "Big Buck Bunny (2008)",
                releaseName: "Big.Buck.Bunny.2008.2160p.BluRay.x265.HDR-DEMO",
                status: .downloading, progress: 0.42,
                quality: "Bluray-2160p",
                formats: ["HDR10+", "DV", "Atmos", "TrueHD", "Remux Tier 01", "HQ Source Group"], score: 1850,
                client: "SABnzbd", indexer: "DemoUsenet",
                upgrade: false, posterSeed: "bigbuckbunny", aspect: .portrait,
                entityId: 201
            ),
            // Headline UPGRADE: Bluray-1080p -> Bluray-2160p, score jumps, size grows.
            queueItem(
                source: .radarr, id: "demo-radarr-2",
                title: "Tears of Steel (2012)",
                releaseName: "Tears.of.Steel.2012.2160p.BluRay.x265.HDR10.DV.Atmos-DEMO",
                status: .downloading, progress: 0.62,
                quality: "Bluray-2160p",
                formats: ["HDR10+", "DV", "Atmos", "TrueHD", "x265"], score: 1720,
                client: "NZBGet", indexer: "DemoUsenet",
                upgrade: true,
                existing: ExistingFile(
                    quality: "Bluray-1080p", formats: ["x264", "DTS-HD MA 5.1"], score: 350,
                    size: 8_400_000_000,
                    fileName: "Tears.of.Steel.2012.1080p.BluRay.x264-OLD.mkv"
                ),
                posterSeed: "tearsofsteel", aspect: .portrait,
                entityId: 203
            ),
            // Second upgrade, importing — codec/source bump (SD HDTV -> WEB-DL AV1).
            queueItem(
                source: .radarr, id: "demo-radarr-3",
                title: "Sintel (2010)",
                releaseName: "Sintel.2010.1080p.WEB-DL.AV1.Atmos-DEMO",
                status: .importing, progress: 1.0,
                quality: "WEB-DL 1080p",
                formats: ["AMZN", "Atmos", "DDP 5.1", "AV1", "HQ Source Group"], score: 720,
                client: "qBittorrent", indexer: "DemoTracker",
                upgrade: true,
                existing: ExistingFile(
                    quality: "HDTV-720p", formats: ["x264", "AAC 2.0"], score: 60,
                    size: 850_000_000,
                    fileName: "Sintel.2010.720p.HDTV.x264-OLD.mkv"
                ),
                posterSeed: "sintel", aspect: .portrait,
                entityId: 202
            ),
        ]
    }

    // MARK: - Sonarr (5 episodes / 2 series)

    static var sonarrQueue: [QueueItem] {
        // The Caminandes 2-ep season pack (groups into one row) followed by the
        // three independent Pioneer One S01 rows (distinct downloadIds => do NOT
        // group). 5 episodes total.
        var items: [QueueItem] = []
        items.append(contentsOf: caminandesSeasonPack)
        items.append(contentsOf: pioneerOneIndependentEpisodes)
        return items
    }

    /// Caminandes S01 two-episode pack — shared downloadId so QueueGrouping
    /// renders a single "Caminandes · S01" row. Each member is an upgrade over a
    /// different original file (mixed-source pack), shown in the per-episode grid.
    static var caminandesSeasonPack: [QueueItem] {
        let sharedDownloadId = "demo-pack-caminandes-s01"
        let baseRelease = "Caminandes.S01.1080p.WEB-DL.x264-DEMO"
        let episodes: [(num: Int, title: String, existing: ExistingFile?)] = [
            (2, "Gran Dillama", ExistingFile(
                quality: "WEBRip-480p", formats: ["x264"], score: 20,
                size: 180_000_000,
                fileName: "Caminandes.S01E02.480p.WEBRip.x264-OLD.mkv"
            )),
            (3, "Llamigos", ExistingFile(
                quality: "HDTV-720p", formats: ["x264", "Repack"], score: 60,
                size: 320_000_000,
                fileName: "Caminandes.S01E03.720p.HDTV.x264-OLD.mkv"
            )),
        ]
        return episodes.map { ep in
            queueItem(
                source: .sonarr,
                id: "demo-sonarr-pack-\(ep.num)",
                title: "Caminandes (2013)",
                subtitle: String(format: String(localized: "Season 01 · Episode %lld — %@", bundle: .module), ep.num, ep.title),
                seasonNumber: 1, episodeNumber: ep.num, episodeTitle: ep.title,
                releaseName: baseRelease,
                status: .downloading, progress: 0.55,
                quality: "WEB-DL 1080p",
                formats: ["AMZN", "x264", "AAC 2.0", "HQ Source Group"], score: 720,
                client: "qBittorrent", indexer: "DemoTracker",
                upgrade: true, existing: ep.existing,
                posterSeed: "caminandes", aspect: .portrait,
                downloadId: sharedDownloadId,
                entityId: 102
            )
        }
    }

    /// Three Pioneer One S01 episodes grabbed as separate releases — each has its
    /// own downloadId, so they render as three independent rows. E03 is an
    /// upgrade; E04 a fresh grab; E05 queued.
    static var pioneerOneIndependentEpisodes: [QueueItem] {
        let releases: [(num: Int, title: String, status: QueueItem.Status, progress: Double, score: Int, formats: [String], upgrade: Bool, existing: ExistingFile?)] = [
            (3, "Endurance", .downloading, 0.67, 380, ["x264", "AAC 2.0", "HQ Source Group"], true,
                ExistingFile(quality: "WEBRip-480p", formats: ["x264", "Repack"], score: 30,
                             size: 350_000_000, fileName: "Pioneer.One.S01E03.480p.WEBRip-OLD.mkv")),
            (4, "Brave New Earth", .downloading, 0.34, 420, ["x264", "AAC 2.0"], false, nil),
            (5, "Foothold", .queued, 0.0, 60, [], false, nil),
        ]
        return releases.map { rel in
            queueItem(
                source: .sonarr,
                id: "demo-sonarr-pone-\(rel.num)",
                title: "Pioneer One (2010)",
                subtitle: String(format: String(localized: "Season 01 · Episode %lld — %@", bundle: .module), rel.num, rel.title),
                seasonNumber: 1, episodeNumber: rel.num, episodeTitle: rel.title,
                releaseName: String(format: "Pioneer.One.S01E%02d.720p.HDTV.x264-DEMO", rel.num),
                status: rel.status, progress: rel.progress,
                quality: "HDTV-720p", formats: rel.formats, score: rel.score,
                client: "qBittorrent", indexer: "DemoTracker",
                upgrade: rel.upgrade, existing: rel.existing,
                posterSeed: "pioneerone", aspect: .portrait,
                entityId: 101
            )
        }
    }

    // MARK: - Lidarr (2 albums)

    static var lidarrQueue: [QueueItem] {
        [
            // UPGRADE: MP3-320 -> FLAC lossless.
            queueItem(
                source: .lidarr, id: "demo-lidarr-1",
                title: "Nine Inch Nails — Ghosts I-IV",
                releaseName: "Nine.Inch.Nails-Ghosts.I-IV-FLAC-2008-DEMO",
                status: .downloading, progress: 0.81,
                quality: "FLAC", formats: ["Lossless", "24bit", "Original Source"], score: 320,
                client: "qBittorrent", indexer: "DemoTracker",
                upgrade: true,
                existing: ExistingFile(
                    quality: "MP3-320", formats: ["Lossy"], score: 0,
                    size: 220_000_000,
                    fileName: "Nine Inch Nails - Ghosts I-IV (320kbps).zip"
                ),
                posterSeed: "ninghosts", aspect: .square,
                entityId: 301
            ),
            queueItem(
                source: .lidarr, id: "demo-lidarr-2",
                title: "Brad Sucks — Out of It",
                releaseName: "Brad.Sucks-Out.of.It-MP3-DEMO",
                status: .completed, progress: 1.0,
                quality: "MP3-320", formats: [], score: 0,
                client: "rTorrent", indexer: "DemoTracker",
                upgrade: false, posterSeed: "bradsucks", aspect: .square,
                entityId: 302
            ),
        ]
    }

    // MARK: - Whisparr (2 cat "nature films")

    static var whisparrQueue: [QueueItem] {
        [
            queueItem(
                source: .whisparr, id: "demo-whisparr-1",
                title: "Kitten Cam: Backyard Drama (2024)",
                releaseName: "Kitten.Cam.Backyard.Drama.2024.1080p.WEB-DL.x264-DEMO",
                status: .downloading, progress: 0.55,
                quality: "WEB-DL 1080p", formats: ["x264", "Atmos", "HQ Source Group"], score: 280,
                client: "qBittorrent", indexer: "DemoTracker",
                upgrade: false, posterSeed: "kitten:neo", aspect: .portrait,
                entityId: 401
            ),
            // UPGRADE: 1080p -> 2160p HDR.
            queueItem(
                source: .whisparr, id: "demo-whisparr-2",
                title: "The Black Cat Chronicles (2023)",
                releaseName: "The.Black.Cat.Chronicles.2023.2160p.WEB-DL.HDR-DEMO",
                status: .completed, progress: 1.0,
                quality: "WEB-DL 2160p", formats: ["HDR10", "AV1"], score: 690,
                client: "SABnzbd", indexer: "DemoUsenet",
                upgrade: true,
                existing: ExistingFile(
                    quality: "WEB-DL 1080p", formats: ["x264"], score: 240,
                    size: 2_400_000_000,
                    fileName: "The.Black.Cat.Chronicles.2023.1080p.WEB-DL.x264-OLD.mkv"
                ),
                posterSeed: "kitten:millie", aspect: .portrait,
                entityId: 402
            ),
        ]
    }
}
```

- [ ] **Step 2: Build**

Run: `cd Packages/ArrCore && swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/DemoMocks+Queue.swift
git commit -m "refactor(demo): curate queues to 3 movies / 5 eps / 2 albums / 2 cats, upgrade+CF showcase"
```

---

### Task 6: Rewrite upcoming + green health (`DemoMocks+Upcoming.swift`)

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/DemoMocks+Upcoming.swift` (full rewrite)

Calendar showcases multi-season (Pioneer One S02 airing soon), a Caminandes future ep, an album release, and movie digital/physical releases — all from the curated set. Health is all-green. No Whisparr in the calendar (off by default; keeps it clean).

- [ ] **Step 1: Replace the whole file body** with:

```swift
import Foundation

// Upcoming-episodes and health-check fixtures for demo mode. Calendar uses only
// curated entities; health is all-green.

extension DemoMocks {
    // MARK: - Upcoming

    static var upcoming: [UpcomingItem] {
        [
            // Tonight: next Pioneer One episode (S02 -> shows multi-season).
            upcomingItem(
                source: .sonarr, id: "demo-cal-tonight-1",
                title: "Pioneer One (2010)",
                subtitle: "S02E01 · Reentry",
                hoursAhead: 3, releaseType: "Airing", hasFile: false,
                posterSeed: "pioneerone", aspect: .portrait,
                entityId: 101
            ),
            // Tonight: a movie digital release.
            upcomingItem(
                source: .radarr, id: "demo-cal-tonight-2",
                title: "Sintel (2010)",
                hoursAhead: 8, releaseType: "Digital", hasFile: false,
                posterSeed: "sintel", aspect: .portrait,
                entityId: 202
            ),
            // This week: Caminandes future episode.
            upcomingItem(
                source: .sonarr, id: "demo-cal-2",
                title: "Caminandes (2013)",
                subtitle: "S01E04 · Snow Day",
                daysAhead: 2, releaseType: "Airing", hasFile: false,
                posterSeed: "caminandes", aspect: .portrait,
                entityId: 102
            ),
            // This week: album release.
            upcomingItem(
                source: .lidarr, id: "demo-cal-3",
                title: "Brad Sucks — Out of It",
                daysAhead: 4, releaseType: "Album", hasFile: false,
                posterSeed: "bradsucks", aspect: .square,
                entityId: 302
            ),
            // This week: movie physical release.
            upcomingItem(
                source: .radarr, id: "demo-cal-4",
                title: "Big Buck Bunny (2008)",
                daysAhead: 5, releaseType: "Physical", hasFile: false,
                posterSeed: "bigbuckbunny", aspect: .portrait,
                entityId: 201
            ),
            // Next week: Pioneer One S02E02.
            upcomingItem(
                source: .sonarr, id: "demo-cal-5",
                title: "Pioneer One (2010)",
                subtitle: "S02E02 · Witness",
                daysAhead: 8, releaseType: "Airing", hasFile: false,
                posterSeed: "pioneerone", aspect: .portrait,
                entityId: 101
            ),
        ]
        .sorted { $0.airDate < $1.airDate }
    }

    // MARK: - Health (all green)

    static var health: HealthResult {
        HealthResult(radarr: [], sonarr: [], lidarr: [], whisparr: [])
    }
}
```

- [ ] **Step 2: Build**

Run: `cd Packages/ArrCore && swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/DemoMocks+Upcoming.swift
git commit -m "refactor(demo): curate calendar to showcase entities, health all-green"
```

---

### Task 7: Rewrite history (`DemoMocks+History.swift`)

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/DemoMocks+History.swift` (full rewrite)

History showcases grabbed/imported with CF scores plus upgrade-replacement imports. No `.failed`/`.deleted` events.

- [ ] **Step 1: Replace the whole file body** with:

```swift
import Foundation

// Per-source history fixtures (curated entities only; grabbed/imported with CF
// scores and upgrade replacements, no failures).

extension DemoMocks {
    // MARK: - History

    static func history(for source: QueueItem.Source) -> [HistoryItem] {
        switch source {
        case .radarr: return radarrHistory
        case .sonarr: return sonarrHistory
        case .lidarr: return lidarrHistory
        case .whisparr: return whisparrHistory
        }
    }

    static var radarrHistory: [HistoryItem] {
        [
            historyItem(.radarr, id: "rh1", minutesAgo: 12, event: .grabbed,
                        title: "Big Buck Bunny (2008)",
                        sourceTitle: "Big.Buck.Bunny.2008.2160p.BluRay.x265.HDR-DEMO",
                        quality: "Bluray-2160p", formats: ["HDR10+", "DV", "Atmos", "Remux Tier 01"], score: 1850),
            historyItem(.radarr, id: "rh2", minutesAgo: 95, event: .imported,
                        title: "Tears of Steel (2012)",
                        subtitle: "Upgrade — Bluray-2160p",
                        sourceTitle: "Tears.of.Steel.2012.2160p.BluRay.x265.HDR10.DV.Atmos-DEMO",
                        quality: "Bluray-2160p", formats: ["HDR10+", "DV", "Atmos", "x265"], score: 1720),
            historyItem(.radarr, id: "rh3", minutesAgo: 240, event: .imported,
                        title: "Sintel (2010)",
                        subtitle: "Upgrade — WEB-DL 1080p",
                        sourceTitle: "Sintel.2010.1080p.WEB-DL.AV1.Atmos-DEMO",
                        quality: "WEB-DL 1080p", formats: ["AMZN", "Atmos", "DDP 5.1", "AV1"], score: 720),
        ]
    }

    static var sonarrHistory: [HistoryItem] {
        [
            historyItem(.sonarr, id: "sh1", minutesAgo: 5, event: .grabbed,
                        title: "Pioneer One (2010)",
                        subtitle: "S01E03 · Endurance",
                        sourceTitle: "Pioneer.One.S01E03.720p.HDTV.x264-DEMO",
                        quality: "HDTV-720p", formats: ["x264", "HQ Source Group"], score: 380),
            historyItem(.sonarr, id: "sh2", minutesAgo: 60, event: .imported,
                        title: "Pioneer One (2010)",
                        subtitle: "S01E02 · Earthfall",
                        sourceTitle: "Pioneer.One.S01E02.720p.HDTV.x264-DEMO",
                        quality: "HDTV-720p", formats: ["x264"], score: 180),
            historyItem(.sonarr, id: "sh3", minutesAgo: 320, event: .imported,
                        title: "Caminandes (2013)",
                        subtitle: "S01E01 · Llama Drama",
                        sourceTitle: "Caminandes.S01E01.1080p.WEB-DL.x264-DEMO",
                        quality: "WEB-DL 1080p", formats: ["AMZN", "x264", "HQ Source Group"], score: 720),
        ]
    }

    static var lidarrHistory: [HistoryItem] {
        [
            historyItem(.lidarr, id: "lh1", minutesAgo: 30, event: .grabbed,
                        title: "Nine Inch Nails",
                        subtitle: "Ghosts I-IV · Upgrade — FLAC",
                        sourceTitle: "Nine.Inch.Nails-Ghosts.I-IV-FLAC-2008-DEMO",
                        quality: "FLAC", formats: ["Lossless", "24bit"], score: 320),
            historyItem(.lidarr, id: "lh2", minutesAgo: 600, event: .imported,
                        title: "Brad Sucks",
                        subtitle: "Out of It",
                        sourceTitle: "Brad.Sucks-Out.of.It-MP3-DEMO",
                        quality: "MP3-320", formats: [], score: 0),
        ]
    }

    static var whisparrHistory: [HistoryItem] {
        [
            historyItem(.whisparr, id: "wh1", minutesAgo: 360, event: .imported,
                        title: "The Black Cat Chronicles (2023)",
                        subtitle: "Upgrade — WEB-DL 2160p HDR",
                        sourceTitle: "The.Black.Cat.Chronicles.2023.2160p.WEB-DL.HDR-DEMO",
                        quality: "WEB-DL 2160p", formats: ["HDR10", "AV1"], score: 690),
            historyItem(.whisparr, id: "wh2", minutesAgo: 840, event: .grabbed,
                        title: "Kitten Cam: Backyard Drama (2024)",
                        sourceTitle: "Kitten.Cam.Backyard.Drama.2024.1080p.WEB-DL.x264-DEMO",
                        quality: "WEB-DL 1080p", formats: ["x264"], score: 280),
        ]
    }
}
```

- [ ] **Step 2: Build**

Run: `cd Packages/ArrCore && swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/DemoMocks+History.swift
git commit -m "refactor(demo): curate history to grabbed/imported + upgrades, no failures"
```

---

### Task 8: Prune detail fixtures (`DemoMocks+Details.swift`)

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/DemoMocks+Details.swift`

Keep only curated entities. Remove series 103/104/105/106, the orphan episode helpers, and the orphan `image(seed:)` calls for removed seeds. Keep movies 201/202/203, series 101/102 (with their episode data), albums 301/302.

- [ ] **Step 1: Trim `sonarrDetails`** — keep only entries `101` (Pioneer One) and `102` (Caminandes) exactly as they are today (`DemoMocks+Details.swift:136-179`). Delete entries `103`, `104`, `105`, `106` (lines 180-263).

- [ ] **Step 2: Trim `sonarrEpisodeData`** — replace the dictionary (lines 267-304) with only the two kept series:

```swift
    static var sonarrEpisodeData: [Int: [SonarrEpisodeDetail]] {
        [
            101: [ // Pioneer One
                episode(101, 1, 1, "Earthfall", "A capsule re-enters over rural Montana.", daysAgo: 700, hasFile: true),
                episode(102, 1, 2, "Tomorrow Belongs to Us", "DHS gets involved.", daysAgo: 690, hasFile: true),
                episode(103, 1, 3, "Endurance", "A doctor risks her career.", daysAgo: 680, hasFile: false),
                episode(104, 1, 4, "Brave New Earth", "The signal travels.", daysAgo: 670, hasFile: false),
                episode(105, 1, 5, "Foothold", "An offer no one can refuse.", daysAgo: 660, hasFile: false),
                episode(106, 1, 6, "What Remains", "Things break, others mend.", daysAgo: 650, hasFile: true),
                episode(201, 2, 1, "Reentry", "Aftermath.", daysAhead: 1, hasFile: false),
                episode(202, 2, 2, "Witness", "An unexpected ally.", daysAhead: 8, hasFile: false),
                episode(203, 2, 3, "Cold War Echo", "An old enemy.", daysAhead: 15, hasFile: false),
                episode(204, 2, 4, "Diaspora", "The cosmonaut speaks.", daysAhead: 22, hasFile: false),
            ],
            102: [ // Caminandes
                episode(301, 1, 1, "Llama Drama", "Koro meets a fence.", daysAgo: 1100, hasFile: true),
                episode(302, 1, 2, "Gran Dillama", "Koro meets a llama-vending machine.", daysAgo: 950, hasFile: false),
                episode(303, 1, 3, "Llamigos", "Koro meets a penguin.", daysAgo: 800, hasFile: false),
                episode(304, 1, 4, "Snow Day", "Koro climbs.", daysAhead: 2, hasFile: false),
            ],
        ]
    }
```

- [ ] **Step 3: Delete the orphan episode helpers** `sprintTalesEpisodes` (lines 306-313) and `tosSeriesEpisodes` (lines 315-321). Keep the `episode(...)` factory (lines 323-345).

- [ ] **Step 4: Verify `radarrDetails` and `lidarrDetails` are unchanged** — they already contain exactly the curated entities (201/202/203 and 301/302). No edit needed. `lidarrTrackData` (301/302) is unchanged.

- [ ] **Step 5: Build**

Run: `cd Packages/ArrCore && swift build`
Expected: Build succeeds with no "unresolved seed" / unused-symbol issues. If the compiler flags an unused `image(seed:)` for a removed seed, it's only ever called with curated seeds now — no action needed (the function is generic).

- [ ] **Step 6: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/DemoMocks+Details.swift
git commit -m "refactor(demo): prune detail fixtures to curated entities"
```

---

# Phase 3 — Verification

### Task 9: Full build + test + manual demo verification

- [ ] **Step 1: Run the full ArrCore test suite**

Run: `cd Packages/ArrCore && swift test`
Expected: All tests pass (including the new `DemoIsolationTests` and the existing `ConfigStore`, `QueueGrouping`, `QueueViewModel`, `Localization` suites).

- [ ] **Step 2: Build the macOS app**

Run:
```bash
xcodebuild -scheme ArrBarr -destination 'platform=macOS' -configuration Debug build 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`. (If the scheme/name differs, list with `xcodebuild -list`.)

- [ ] **Step 3: Manual isolation check (the user's core requirement)**

This proves the Whisparr bleed is fixed and the real profile is intact. Per project memory, relaunch the app after the change automatically.

1. Ensure you have a real profile state to protect: note current real `whisparr.enabled` (Settings → Services) — expected OFF.
2. Enable Developer options, then Settings → General → Demo mode ON (app relaunches).
3. In demo, Settings → enable Whisparr (confirm age gate). Confirm Whisparr content appears.
4. Settings → General → Demo mode OFF (app relaunches).
5. **Verify:** Settings → Services → Whisparr is still OFF (no bleed). The real profile's other settings (theme, language, services) are unchanged.
6. Confirm at the defaults level that the real profile is intact and the demo suite was wiped:

```bash
# Real profile: Whisparr config must NOT show enabled=true from the demo toggle.
defaults read com.preclowski.ArrBarr ArrBarr.config.whisparr 2>/dev/null || echo "no real whisparr config (expected)"
# Demo suite: wiped after disabling demo.
defaults read com.preclowski.ArrBarr.demo 2>/dev/null || echo "demo suite empty (expected)"
```
Expected: real profile shows no demo-induced Whisparr enable; demo suite is empty.

- [ ] **Step 4: Manual content check**

Re-enable Demo mode and confirm the curated universe renders: 3 movies, a grouped Caminandes row + 3 independent Pioneer One rows, 2 albums, 2 cats; the upgrade badges (Tears of Steel, Sintel, NIN, Caminandes pack, Pioneer E03, Black Cat) show before/after; the calendar shows Pioneer S02 + album + movie releases; health is green; history shows grabbed/imported with CF scores and no failures.

- [ ] **Step 5: Final commit (if any verification fixes were needed)**

```bash
git add -A && git commit -m "test(demo): verify isolation + curated content"
```

---

## Notes / deviations from the original brainstorm

- **Live re-point added (not deferred to iOS-later):** the existing iOS demo toggle flips demo without relaunch, so an init-only suite selection would still bleed on iOS. `useDemoStore(_:)` handles both platforms now.
- **Sonarr queue composition refined:** the 5 episodes are the active-queue set (Caminandes 2-ep pack + Pioneer One 3 independent S01 rows). Pioneer S02 lives in the calendar, not the queue, so no episode is both "airing later" and "downloading now". Both grouping behaviours stay visible.
- **Failures removed:** per the chosen feature priorities (upgrades, CF scores, calendar/history), demo stays clean — health is green and history/queue carry no failed/warning items.
