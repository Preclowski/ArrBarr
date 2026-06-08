# Library Status Widget (Phase 0 + Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the iOS "Library Status" home-screen widget plus the shared foundation (App Group config sharing, `arrbarr://` deep-link router, `sizeOnDisk` decoding, a public library-summary helper) that every later widget reuses.

**Architecture:** A new WidgetKit extension target `ArrBarrWidgets` links the existing `ArrCore` package. The widget's `TimelineProvider` reads server config directly from a shared App Group `UserDefaults` suite (never constructing the `@MainActor` `ConfigStore.shared`) and calls ArrCore's `actor` clients through one thin `public` summary entry point. A one-shot launch migration copies the user's real profile from `.standard` into the App Group suite. A net-new `arrbarr://` URL scheme + `onOpenURL` router lets the widget deep-link into the app.

**Tech Stack:** Swift 6, SwiftUI, WidgetKit, AppIntents, Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`), Xcode project `ArrBarr.xcodeproj`, Swift package `Packages/ArrCore`.

**Spec:** `docs/superpowers/specs/2026-06-08-home-screen-widgets-design.md`

**Run tests with:** `cd Packages/ArrCore && swift test` (filter with `--filter <SuiteOrTestName>`).

---

## File Structure

**ArrCore (logic — testable, do first):**
- Modify `Packages/ArrCore/Sources/ArrCore/Models/ArrTypes.swift` — add `sizeOnDisk` to four decodable structs.
- Create `Packages/ArrCore/Sources/ArrCore/Models/LibrarySummary.swift` — `LibrarySummary` value type + pure summation.
- Create `Packages/ArrCore/Sources/ArrCore/Services/LibrarySummaryService.swift` — `public` actor: configs → fetch → summary.
- Create `Packages/ArrCore/Sources/ArrCore/Services/WidgetDataStore.swift` — `nonisolated` App Group suite reader.
- Modify `Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift` — App Group suite repoint + copy-all-keys migration + a `public nonisolated` config decoder reused by `WidgetDataStore`.
- Create `Packages/ArrCore/Sources/ArrCore/Services/WidgetDeepLink.swift` — pure URL → route parser.

**Tests:**
- Create `Packages/ArrCore/Tests/ArrCoreTests/LibrarySizeDecodingTests.swift`
- Create `Packages/ArrCore/Tests/ArrCoreTests/LibrarySummaryTests.swift`
- Create `Packages/ArrCore/Tests/ArrCoreTests/AppGroupMigrationTests.swift`
- Create `Packages/ArrCore/Tests/ArrCoreTests/WidgetDeepLinkTests.swift`

**App + Widget target (Xcode — manual, no unit tests):**
- Modify `ArrBarr/Info.plist` — register `CFBundleURLTypes` for `arrbarr`.
- Modify `ArrBarr/ArrBarrApp.swift` — `onOpenURL` router; call migration at launch; `WidgetCenter.reloadTimelines`.
- Modify `ArrBarr/ArrBarr.entitlements` — add App Group.
- Create target `ArrBarrWidgets` with: `ArrBarrWidgetsBundle.swift`, `LibraryStatusWidget.swift`, `LibraryStatusProvider.swift`, `LibraryStatusView.swift`, `LibraryStatusConfigIntent.swift`, `ArrBarrWidgets.entitlements`.

---

## Phase 0 + 1 — ArrCore logic (TDD)

### Task 1: Decode `sizeOnDisk` into library records

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Models/ArrTypes.swift` (`RadarrLibraryRecord` ~479, `WhisparrLibraryRecord` ~590, `SonarrLibraryStatistics` ~510, `LidarrLibraryStatistics` ~454)
- Test: `Packages/ArrCore/Tests/ArrCoreTests/LibrarySizeDecodingTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import ArrCore

@Suite("Library size decoding")
struct LibrarySizeDecodingTests {
    @Test("Radarr movie decodes sizeOnDisk")
    func radarrSize() throws {
        let json = #"[{"id":1,"hasFile":true,"sizeOnDisk":1073741824}]"#.data(using: .utf8)!
        let recs = try JSONDecoder().decode([RadarrLibraryRecord].self, from: json)
        #expect(recs.first?.sizeOnDisk == 1_073_741_824)
    }

    @Test("Whisparr movie decodes sizeOnDisk")
    func whisparrSize() throws {
        let json = #"[{"id":1,"hasFile":true,"sizeOnDisk":500}]"#.data(using: .utf8)!
        let recs = try JSONDecoder().decode([WhisparrLibraryRecord].self, from: json)
        #expect(recs.first?.sizeOnDisk == 500)
    }

    @Test("Sonarr series statistics decodes sizeOnDisk")
    func sonarrSize() throws {
        let json = #"[{"id":1,"statistics":{"episodeCount":10,"sizeOnDisk":2048}}]"#.data(using: .utf8)!
        let recs = try JSONDecoder().decode([SonarrLibraryRecord].self, from: json)
        #expect(recs.first?.statistics?.sizeOnDisk == 2048)
    }

    @Test("Lidarr artist statistics decodes sizeOnDisk")
    func lidarrSize() throws {
        let json = #"[{"artistName":"X","statistics":{"albumCount":3,"sizeOnDisk":4096}}]"#.data(using: .utf8)!
        let recs = try JSONDecoder().decode([LidarrLibraryRecord].self, from: json)
        #expect(recs.first?.statistics?.sizeOnDisk == 4096)
    }

    @Test("Missing sizeOnDisk decodes to nil, not a failure")
    func missingSize() throws {
        let json = #"[{"id":1,"hasFile":false}]"#.data(using: .utf8)!
        let recs = try JSONDecoder().decode([RadarrLibraryRecord].self, from: json)
        #expect(recs.first?.sizeOnDisk == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/ArrCore && swift test --filter LibrarySizeDecodingTests`
Expected: FAIL — `value of type 'RadarrLibraryRecord' has no member 'sizeOnDisk'`.

- [ ] **Step 3: Add the fields**

In `ArrTypes.swift`, add `let sizeOnDisk: Int64?` to `RadarrLibraryRecord` and `WhisparrLibraryRecord`, and to `SonarrLibraryStatistics` and `LidarrLibraryStatistics`. Example (Radarr):

```swift
public struct RadarrLibraryRecord: Decodable, Sendable, Equatable {
    let id: Int?
    let tmdbId: Int?
    // ... existing fields ...
    let certification: String?
    let studio: String?
    let sizeOnDisk: Int64?   // bytes; present in /api/v3/movie, previously undecoded
}
```

And the two statistics structs:

```swift
public struct SonarrLibraryStatistics: Decodable, Sendable, Equatable {
    let episodeCount: Int?
    let episodeFileCount: Int?
    let seasonCount: Int?
    let sizeOnDisk: Int64?
}
public struct LidarrLibraryStatistics: Decodable, Sendable, Equatable {
    public let albumCount: Int?
    public let trackCount: Int?
    public let trackFileCount: Int?
    public let sizeOnDisk: Int64?
}
```

Note: `Decodable` synthesis makes the new optional field decode-or-nil automatically; no `CodingKeys` change needed (the JSON key matches the property name).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/ArrCore && swift test --filter LibrarySizeDecodingTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Models/ArrTypes.swift Packages/ArrCore/Tests/ArrCoreTests/LibrarySizeDecodingTests.swift
git commit -m "feat(arrcore): decode sizeOnDisk in library list records"
```

---

### Task 2: `LibrarySummary` value + pure summation

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Models/LibrarySummary.swift`
- Test: `Packages/ArrCore/Tests/ArrCoreTests/LibrarySummaryTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import ArrCore

@Suite("Library summary summation")
struct LibrarySummaryTests {
    @Test("Radarr summary counts records and sums sizeOnDisk")
    func radarr() throws {
        let recs = [
            try JSONDecoder().decode(RadarrLibraryRecord.self, from: #"{"id":1,"sizeOnDisk":100}"#.data(using: .utf8)!),
            try JSONDecoder().decode(RadarrLibraryRecord.self, from: #"{"id":2,"sizeOnDisk":250}"#.data(using: .utf8)!),
            try JSONDecoder().decode(RadarrLibraryRecord.self, from: #"{"id":3}"#.data(using: .utf8)!),
        ]
        let s = LibrarySummary.radarr(from: recs)
        #expect(s.source == .radarr)
        #expect(s.count == 3)
        #expect(s.totalBytes == 350)   // nil sizeOnDisk treated as 0
    }

    @Test("Sonarr summary sums per-series statistics size")
    func sonarr() throws {
        let recs = [
            try JSONDecoder().decode(SonarrLibraryRecord.self, from: #"{"id":1,"statistics":{"sizeOnDisk":1000}}"#.data(using: .utf8)!),
            try JSONDecoder().decode(SonarrLibraryRecord.self, from: #"{"id":2,"statistics":{"sizeOnDisk":500}}"#.data(using: .utf8)!),
        ]
        let s = LibrarySummary.sonarr(from: recs)
        #expect(s.count == 2)
        #expect(s.totalBytes == 1500)
    }

    @Test("Lidarr summary sums per-artist statistics size")
    func lidarr() throws {
        let recs = [
            try JSONDecoder().decode(LidarrLibraryRecord.self, from: #"{"artistName":"A","statistics":{"sizeOnDisk":700}}"#.data(using: .utf8)!),
        ]
        let s = LibrarySummary.lidarr(from: recs)
        #expect(s.count == 1)
        #expect(s.totalBytes == 700)
    }

    @Test("Whisparr summary mirrors Radarr shape")
    func whisparr() throws {
        let recs = [
            try JSONDecoder().decode(WhisparrLibraryRecord.self, from: #"{"id":1,"sizeOnDisk":42}"#.data(using: .utf8)!),
        ]
        let s = LibrarySummary.whisparr(from: recs)
        #expect(s.source == .whisparr)
        #expect(s.totalBytes == 42)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/ArrCore && swift test --filter LibrarySummaryTests`
Expected: FAIL — `cannot find 'LibrarySummary' in scope`.

- [ ] **Step 3: Create `LibrarySummary.swift`**

```swift
import Foundation

/// One arr's library headline: how many items and how many bytes on disk.
/// Pure value type so the summation logic is unit-testable without a network.
public struct LibrarySummary: Sendable, Equatable, Identifiable {
    public enum Source: String, Sendable, CaseIterable, Identifiable {
        case radarr, sonarr, lidarr, whisparr
        public var id: String { rawValue }
    }

    public let source: Source
    public let count: Int
    public let totalBytes: Int64

    public var id: String { source.rawValue }

    public init(source: Source, count: Int, totalBytes: Int64) {
        self.source = source
        self.count = count
        self.totalBytes = totalBytes
    }

    public static func radarr(from recs: [RadarrLibraryRecord]) -> LibrarySummary {
        .init(source: .radarr, count: recs.count,
              totalBytes: recs.reduce(0) { $0 + ($1.sizeOnDisk ?? 0) })
    }
    public static func whisparr(from recs: [WhisparrLibraryRecord]) -> LibrarySummary {
        .init(source: .whisparr, count: recs.count,
              totalBytes: recs.reduce(0) { $0 + ($1.sizeOnDisk ?? 0) })
    }
    public static func sonarr(from recs: [SonarrLibraryRecord]) -> LibrarySummary {
        .init(source: .sonarr, count: recs.count,
              totalBytes: recs.reduce(0) { $0 + ($1.statistics?.sizeOnDisk ?? 0) })
    }
    public static func lidarr(from recs: [LidarrLibraryRecord]) -> LibrarySummary {
        .init(source: .lidarr, count: recs.count,
              totalBytes: recs.reduce(0) { $0 + ($1.statistics?.sizeOnDisk ?? 0) })
    }
}
```

Note: `sizeOnDisk` on the records was declared `internal` (no modifier) in Task 1; that's fine because `LibrarySummary` lives in the same module. The static factories are the only `public` surface — raw records stay module-internal, satisfying the architecture review's "don't expose raw records to the extension."

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/ArrCore && swift test --filter LibrarySummaryTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Models/LibrarySummary.swift Packages/ArrCore/Tests/ArrCoreTests/LibrarySummaryTests.swift
git commit -m "feat(arrcore): LibrarySummary value type + pure summation"
```

---

### Task 3: `LibrarySummaryService` (configs → fetch → summaries)

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Services/LibrarySummaryService.swift`

This is the thin `public` entry point the widget calls — it constructs the `actor` clients itself and never drags in `LocalToolBackend`'s full tool catalog. It hits the network, so there's no pure unit test; the summation it delegates to is already covered by Task 2. Verify it compiles and is `public`.

- [ ] **Step 1: Create the service**

```swift
import Foundation

/// Thin, extension-safe entry point: given the four arr configs, fetch each
/// configured library and return per-source summaries. Constructs the arr
/// `actor` clients directly — deliberately avoids `LocalToolBackend` (TMDB,
/// custom formats, discover) which is too heavy for a widget's memory budget.
public actor LibrarySummaryService {
    public init() {}

    /// Fetch summaries for the given configs, in `LibrarySummary.Source` order,
    /// skipping unconfigured services. A service that errors is omitted (the
    /// caller renders it as a stale/"—" row).
    public func summaries(
        radarr: ServiceConfig,
        sonarr: ServiceConfig,
        lidarr: ServiceConfig,
        whisparr: ServiceConfig
    ) async -> [LibrarySummary] {
        async let r = Self.fetch(radarr) { LibrarySummary.radarr(from: try await RadarrClient(config: $0).fetchAllMovies()) }
        async let s = Self.fetch(sonarr) { LibrarySummary.sonarr(from: try await SonarrClient(config: $0).fetchAllSeries()) }
        async let l = Self.fetch(lidarr) { LibrarySummary.lidarr(from: try await LidarrClient(config: $0).fetchAllArtists()) }
        async let w = Self.fetch(whisparr) { LibrarySummary.whisparr(from: try await WhisparrClient(config: $0).fetchAllMovies()) }
        return await [r, s, l, w].compactMap { $0 }
    }

    private static func fetch(
        _ config: ServiceConfig,
        _ body: @Sendable (ServiceConfig) async throws -> LibrarySummary
    ) async -> LibrarySummary? {
        guard config.isConfigured else { return nil }
        return try? await body(config)
    }
}
```

Note: the per-arr `init(config:)` is currently `internal`; this service is in the same module so that's fine. The clients are `actor`s with `Sendable` records, safe to call from the widget's background provider.

- [ ] **Step 2: Verify it compiles**

Run: `cd Packages/ArrCore && swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/LibrarySummaryService.swift
git commit -m "feat(arrcore): public LibrarySummaryService for widget data"
```

---

### Task 4: App Group suite reader + public config decoder

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift` (expose a `public nonisolated` decoder; see `load(_:from:)` ~533 and `key(_:)` ~531)
- Create: `Packages/ArrCore/Sources/ArrCore/Services/WidgetDataStore.swift`
- Test: `Packages/ArrCore/Tests/ArrCoreTests/AppGroupMigrationTests.swift` (config-read tests live here too)

- [ ] **Step 1: Write the failing test (config round-trip through a suite)**

```swift
import Testing
import Foundation
@testable import ArrCore

@Suite("Widget data store config read")
struct WidgetDataStoreReadTests {
    private func freshSuite(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("Reads a ServiceConfig written under the ArrBarr.config.<kind> key")
    func reads() throws {
        let suite = freshSuite("test.widgetstore.read")
        let cfg = ServiceConfig(enabled: true, baseURL: "https://radarr.local", apiKey: "k", username: "", password: "")
        let data = try JSONEncoder().encode(cfg)
        suite.set(data, forKey: "ArrBarr.config.radarr")

        let read = ConfigStore.decodeServiceConfig(.radarr, from: suite)
        #expect(read.baseURL == "https://radarr.local")
        #expect(read.apiKey == "k")
    }

    @Test("Missing key yields an empty (unconfigured) config")
    func missing() {
        let suite = freshSuite("test.widgetstore.missing")
        let read = ConfigStore.decodeServiceConfig(.sonarr, from: suite)
        #expect(read.isConfigured == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/ArrCore && swift test --filter WidgetDataStoreReadTests`
Expected: FAIL — `type 'ConfigStore' has no member 'decodeServiceConfig'`.

- [ ] **Step 3: Expose a public nonisolated decoder in ConfigStore**

In `ConfigStore.swift`, the existing private `static func load(_ kind:from:)` and `key(_:)` already do exactly this. Add a thin public wrapper near them:

```swift
/// Extension-safe config read. The widget process must NOT construct
/// `ConfigStore.shared` (it is @MainActor and spins up Combine sinks,
/// keychain migration, and LaunchAtLogin). This decodes a single service's
/// config straight from a `UserDefaults` suite.
public nonisolated static func decodeServiceConfig(_ kind: ServiceKind, from defaults: UserDefaults) -> ServiceConfig {
    load(kind, from: defaults)
}
```

(If `load` or `key` reference `self`/instance state, keep them static as they already are — they take `defaults` explicitly.)

- [ ] **Step 4: Create `WidgetDataStore.swift`**

```swift
import Foundation

/// The App Group suite shared between the host app and the widget extension,
/// plus extension-safe config reads. `nonisolated` throughout — a widget
/// `TimelineProvider` calls this from a background context.
public enum WidgetDataStore {
    /// iOS App Group identifier. (macOS, shipped later, needs the
    /// team-id-prefixed form under app-sandbox — handled when the macOS
    /// widget target is added.)
    public static let appGroupSuiteName = "group.com.preclowski.ArrBarr"

    public static func groupDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupSuiteName)
    }

    /// Reads a service config from the group suite. Returns an empty
    /// (unconfigured) config if the group suite is unavailable or the app
    /// hasn't migrated yet.
    public static func serviceConfig(_ kind: ServiceKind) -> ServiceConfig {
        guard let d = groupDefaults() else { return .empty }
        return ConfigStore.decodeServiceConfig(kind, from: d)
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd Packages/ArrCore && swift test --filter WidgetDataStoreReadTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift Packages/ArrCore/Sources/ArrCore/Services/WidgetDataStore.swift Packages/ArrCore/Tests/ArrCoreTests/AppGroupMigrationTests.swift
git commit -m "feat(arrcore): App Group suite reader + public config decoder"
```

---

### Task 5: Copy-all-keys migration into the App Group suite

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift`
- Test: `Packages/ArrCore/Tests/ArrCoreTests/AppGroupMigrationTests.swift` (append a suite)

The migration copies **all** `ArrBarr.*` keys from a source suite to the group suite, once, idempotently, and never touches the demo suite. It must run on the host app before `ConfigStore` reads.

- [ ] **Step 1: Write the failing test**

```swift
@Suite("App Group migration")
struct AppGroupMigrationTests {
    private func fresh(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("Copies all ArrBarr.* keys from source to group, sets done flag")
    func copies() throws {
        let src = fresh("test.mig.src")
        let grp = fresh("test.mig.grp")
        let cfg = try JSONEncoder().encode(ServiceConfig(enabled: true, baseURL: "https://r", apiKey: "k", username: "", password: ""))
        src.set(cfg, forKey: "ArrBarr.config.radarr")
        src.set(true, forKey: "ArrBarr.notifyRadarr")
        src.set("not-arrbarr", forKey: "SomeOtherApp.flag")   // must NOT be copied

        ConfigStore.migrateToGroupSuite(from: src, to: grp)

        #expect(grp.data(forKey: "ArrBarr.config.radarr") == cfg)
        #expect(grp.bool(forKey: "ArrBarr.notifyRadarr") == true)
        #expect(grp.object(forKey: "SomeOtherApp.flag") == nil)
        #expect(grp.bool(forKey: ConfigStore.groupMigrationDoneKeyForTesting) == true)
    }

    @Test("Idempotent: a second run does not overwrite group edits")
    func idempotent() throws {
        let src = fresh("test.mig.src2")
        let grp = fresh("test.mig.grp2")
        src.set(1, forKey: "ArrBarr.foregroundInterval")
        ConfigStore.migrateToGroupSuite(from: src, to: grp)
        grp.set(99, forKey: "ArrBarr.foregroundInterval")   // user changed it in-app post-migration
        ConfigStore.migrateToGroupSuite(from: src, to: grp) // second launch
        #expect(grp.integer(forKey: "ArrBarr.foregroundInterval") == 99)
    }

    @Test("Never reads or writes the demo suite")
    func demoUntouched() throws {
        let src = fresh("test.mig.src3")
        let grp = fresh("test.mig.grp3")
        let demo = fresh("com.preclowski.ArrBarr.demo")
        demo.set("DEMO", forKey: "ArrBarr.config.radarr")
        src.set(Data("REAL".utf8), forKey: "ArrBarr.config.radarr")
        ConfigStore.migrateToGroupSuite(from: src, to: grp)
        #expect(demo.string(forKey: "ArrBarr.config.radarr") == "DEMO")   // unchanged
        #expect(grp.data(forKey: "ArrBarr.config.radarr") == Data("REAL".utf8))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/ArrCore && swift test --filter AppGroupMigrationTests`
Expected: FAIL — `type 'ConfigStore' has no member 'migrateToGroupSuite'`.

- [ ] **Step 3: Implement the migration**

In `ConfigStore.swift`:

```swift
static let groupMigrationDoneKey = "ArrBarr.groupMigrationDone"
// Test hook so tests don't hardcode the literal:
static var groupMigrationDoneKeyForTesting: String { groupMigrationDoneKey }

/// One-shot copy of every `ArrBarr.*` key from `source` into the App Group
/// `group` suite. Idempotent (guarded by `groupMigrationDoneKey` in `group`),
/// prefix-scoped (only `ArrBarr.*`), and demo-suite-agnostic (it only ever
/// touches the two suites passed in — never the demo suite).
public nonisolated static func migrateToGroupSuite(from source: UserDefaults, to group: UserDefaults) {
    guard !group.bool(forKey: groupMigrationDoneKey) else { return }
    for (key, value) in source.dictionaryRepresentation() where key.hasPrefix("ArrBarr.") {
        group.set(value, forKey: key)
    }
    group.set(true, forKey: groupMigrationDoneKey)
}

/// Convenience for app launch: migrate `.standard` → the App Group suite.
public nonisolated static func migrateStandardToGroupIfNeeded() {
    guard let group = WidgetDataStore.groupDefaults() else { return }
    migrateToGroupSuite(from: .standard, to: group)
}
```

Then repoint the **real** branch of `resolveDefaults()` to the group suite (demo branch unchanged):

```swift
nonisolated public static func resolveDefaults() -> UserDefaults {
    if DemoMode.isActive, let demo = DemoMode.demoDefaults { return demo }
    return WidgetDataStore.groupDefaults() ?? .standard
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/ArrCore && swift test --filter AppGroupMigrationTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Run the full ArrCore suite (guard the ConfigStore change)**

Run: `cd Packages/ArrCore && swift test`
Expected: PASS — no regressions in existing ConfigStore/demo tests.

- [ ] **Step 6: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift Packages/ArrCore/Tests/ArrCoreTests/AppGroupMigrationTests.swift
git commit -m "feat(arrcore): copy-all-keys App Group migration + suite repoint"
```

---

### Task 6: `arrbarr://` deep-link parser

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Services/WidgetDeepLink.swift`
- Test: `Packages/ArrCore/Tests/ArrCoreTests/WidgetDeepLinkTests.swift`

Only the **library** route is needed for Phase 1, but the parser is defined with the routes the spec lists so later phases extend one enum.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import ArrCore

@Suite("Widget deep link parsing")
struct WidgetDeepLinkTests {
    @Test("arrbarr://library parses to .library")
    func library() {
        #expect(WidgetDeepLink(url: URL(string: "arrbarr://library")!) == .library)
    }

    @Test("Unknown host parses to nil")
    func unknown() {
        #expect(WidgetDeepLink(url: URL(string: "arrbarr://nope")!) == nil)
    }

    @Test("Wrong scheme parses to nil")
    func wrongScheme() {
        #expect(WidgetDeepLink(url: URL(string: "https://library")!) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/ArrCore && swift test --filter WidgetDeepLinkTests`
Expected: FAIL — `cannot find 'WidgetDeepLink' in scope`.

- [ ] **Step 3: Create the parser**

```swift
import Foundation

/// Routes carried by `arrbarr://` deep links from widgets. Phase 1 only emits
/// `.library`; later phases add `.upcoming`, `.needs`, `.quiz`, `.quizAdd`.
public enum WidgetDeepLink: Equatable, Sendable {
    case library

    public static let scheme = "arrbarr"

    public init?(url: URL) {
        guard url.scheme == Self.scheme else { return nil }
        switch url.host {
        case "library": self = .library
        default: return nil
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/ArrCore && swift test --filter WidgetDeepLinkTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/WidgetDeepLink.swift Packages/ArrCore/Tests/ArrCoreTests/WidgetDeepLinkTests.swift
git commit -m "feat(arrcore): arrbarr:// deep-link parser"
```

---

## Phase 0 + 1 — Xcode target & app wiring (manual)

> These tasks are Xcode-GUI / Info.plist / entitlements work with no unit tests. Verify by **building** (`xcodebuild`) and running on a simulator. Commit after each.

### Task 7: Register the `arrbarr` URL scheme and wire `onOpenURL`

**Files:**
- Modify: `ArrBarr/Info.plist`
- Modify: `ArrBarr/ArrBarrApp.swift`

- [ ] **Step 1: Register the scheme in Info.plist**

Add to `ArrBarr/Info.plist`:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key>
    <string>com.preclowski.ArrBarr.deeplink</string>
    <key>CFBundleURLSchemes</key>
    <array><string>arrbarr</string></array>
  </dict>
</array>
```

- [ ] **Step 2: Call the migration at the earliest launch point**

In `ArrBarrApp.swift`, before any `ConfigStore.shared` access (e.g. in the `App`'s `init()`), call:

```swift
ConfigStore.migrateStandardToGroupIfNeeded()
```

- [ ] **Step 3: Add the `onOpenURL` router**

On the root scene's content view in `ArrBarrApp.swift`:

```swift
.onOpenURL { url in
    guard let route = WidgetDeepLink(url: url) else { return }
    switch route {
    case .library:
        // Phase 1: bring the app to its default/library view. Reuse the
        // existing tab-selection state used by iOSAppRoot.
        break   // default scene already shows the library; deep dives added in later phases
    }
}
```

- [ ] **Step 4: Build & run, verify the link opens the app**

Run: `xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -destination 'platform=iOS Simulator,name=iPhone 16' build`
Then in a booted simulator: `xcrun simctl openurl booted arrbarr://library`
Expected: the app launches/foregrounds without crashing.

- [ ] **Step 5: Commit**

```bash
git add ArrBarr/Info.plist ArrBarr/ArrBarrApp.swift
git commit -m "feat(app): register arrbarr:// scheme, onOpenURL router, group migration at launch"
```

---

### Task 8: Create the `ArrBarrWidgets` extension target + App Group entitlements

**Files:**
- Xcode: new Widget Extension target `ArrBarrWidgets` (bundle id `com.preclowski.ArrBarr.iOS.Widgets`)
- Modify: `ArrBarr/ArrBarr.entitlements`
- Create: `ArrBarrWidgets/ArrBarrWidgets.entitlements`

- [ ] **Step 1: Add the Widget Extension target**

In Xcode: File ▸ New ▸ Target ▸ Widget Extension, name `ArrBarrWidgets`, embed in the iOS `ArrBarr` app. Uncheck "Include Live Activity" and "Include Configuration Intent" (we add an AppIntent config manually in Task 9). Set bundle id `com.preclowski.ArrBarr.iOS.Widgets`. Set the iOS Deployment Target to match the app.

- [ ] **Step 2: Link ArrCore to the widget target**

In the `ArrBarrWidgets` target ▸ General ▸ Frameworks and Libraries, add the `ArrCore` library product.

- [ ] **Step 3: Add the App Group to both targets**

In Signing & Capabilities, add the **App Groups** capability to **both** `ArrBarr` (iOS) and `ArrBarrWidgets`, with group `group.com.preclowski.ArrBarr`. This writes:
- `ArrBarr/ArrBarr.entitlements` gains:
```xml
<key>com.apple.security.application-groups</key>
<array><string>group.com.preclowski.ArrBarr</string></array>
```
- `ArrBarrWidgets/ArrBarrWidgets.entitlements` gets the same array (plus the extension is iOS, so no app-sandbox key needed — that's the macOS app's).

- [ ] **Step 4: Build the empty widget target**

Run: `xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: builds with the default template widget. (Provisioning: if signing fails locally, set the team and let Xcode register the new App Group / widget id in the portal.)

- [ ] **Step 5: Commit**

```bash
git add ArrBarr.xcodeproj ArrBarr/ArrBarr.entitlements ArrBarrWidgets
git commit -m "feat(widgets): add ArrBarrWidgets extension target + App Group"
```

---

### Task 9: Library Status widget — config intent, provider, view

**Files:**
- Replace the template widget files. Create:
  - `ArrBarrWidgets/ArrBarrWidgetsBundle.swift`
  - `ArrBarrWidgets/LibraryStatusConfigIntent.swift`
  - `ArrBarrWidgets/LibraryStatusProvider.swift`
  - `ArrBarrWidgets/LibraryStatusView.swift`
  - `ArrBarrWidgets/LibraryStatusWidget.swift`

- [ ] **Step 1: Configuration AppIntent (which services to show)**

`LibraryStatusConfigIntent.swift`:

```swift
import AppIntents
import ArrCore

struct LibraryStatusConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Library Status"
    static var description = IntentDescription("Choose which services to show.")

    @Parameter(title: "Movies (Radarr)", default: true) var showRadarr: Bool
    @Parameter(title: "TV (Sonarr)", default: true) var showSonarr: Bool
    @Parameter(title: "Music (Lidarr)", default: true) var showLidarr: Bool
    // Whisparr OFF by default — discretion on a visible home screen.
    @Parameter(title: "Adult (Whisparr)", default: false) var showWhisparr: Bool
}
```

- [ ] **Step 2: Timeline entry + provider (reads group suite directly, never ConfigStore.shared)**

`LibraryStatusProvider.swift`:

```swift
import WidgetKit
import ArrCore

struct LibraryStatusEntry: TimelineEntry {
    let date: Date
    let summaries: [LibrarySummary]
    let isStale: Bool          // true when we reused the last snapshot after a fetch failure
    let anyConfigured: Bool
}

struct LibraryStatusProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LibraryStatusEntry {
        LibraryStatusEntry(date: Date(), summaries: [
            .init(source: .radarr, count: 1204, totalBytes: 8_400_000_000_000),
            .init(source: .sonarr, count: 58, totalBytes: 12_100_000_000_000),
        ], isStale: false, anyConfigured: true)
    }

    func snapshot(for configuration: LibraryStatusConfigIntent, in context: Context) async -> LibraryStatusEntry {
        await entry(for: configuration)
    }

    func timeline(for configuration: LibraryStatusConfigIntent, in context: Context) async -> Timeline<LibraryStatusEntry> {
        let entry = await self.entry(for: configuration)
        // Library grows slowly: refresh ~every 6h.
        let next = Date().addingTimeInterval(6 * 3600)
        return Timeline(entries: [entry], policy: .after(next))
    }

    private func entry(for configuration: LibraryStatusConfigIntent) async -> LibraryStatusEntry {
        let radarr = configuration.showRadarr ? WidgetDataStore.serviceConfig(.radarr) : .empty
        let sonarr = configuration.showSonarr ? WidgetDataStore.serviceConfig(.sonarr) : .empty
        let lidarr = configuration.showLidarr ? WidgetDataStore.serviceConfig(.lidarr) : .empty
        let whisparr = configuration.showWhisparr ? WidgetDataStore.serviceConfig(.whisparr) : .empty

        let anyConfigured = [radarr, sonarr, lidarr, whisparr].contains { $0.isConfigured }
        let summaries = await LibrarySummaryService().summaries(
            radarr: radarr, sonarr: sonarr, lidarr: lidarr, whisparr: whisparr)
        return LibraryStatusEntry(date: Date(), summaries: summaries, isStale: false, anyConfigured: anyConfigured)
    }
}
```

Note: `.empty` is the existing `ServiceConfig.empty`. Demo mode: `WidgetDataStore.serviceConfig` reads the group suite which the app keeps in sync; demo data flows through automatically when the app is in demo mode (the spec's demo behavior — verify in Task 10).

- [ ] **Step 3: The view (small + medium)**

`LibraryStatusView.swift`:

```swift
import SwiftUI
import WidgetKit
import ArrCore

struct LibraryStatusView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LibraryStatusEntry

    var body: some View {
        if !entry.anyConfigured {
            Text("Set up a server in ArrBarr")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding()
        } else if family == .systemSmall {
            small
        } else {
            medium
        }
    }

    private var small: some View {
        let first = entry.summaries.first
        return VStack(alignment: .leading, spacing: 4) {
            if let s = first {
                Text(label(s.source)).font(.caption2).foregroundStyle(.secondary)
                Text("\(s.count)").font(.system(size: 34, weight: .bold))
                Text(byteString(s.totalBytes)).font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding()
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(entry.summaries) { s in
                HStack {
                    Text(label(s.source)).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(s.count)").font(.subheadline.monospacedDigit())
                    Text("·").foregroundStyle(.tertiary)
                    Text(byteString(s.totalBytes)).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }.padding()
    }

    private func label(_ s: LibrarySummary.Source) -> String {
        switch s {
        case .radarr: return "Movies"
        case .sonarr: return "Series"
        case .lidarr: return "Artists"
        case .whisparr: return "Scenes"
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
```

(Service icons from `ServiceIcons.xcassets` can replace the text labels in a polish pass; text keeps Task 9 self-contained.)

- [ ] **Step 4: Widget + bundle declarations**

`LibraryStatusWidget.swift`:

```swift
import WidgetKit
import SwiftUI
import ArrCore

struct LibraryStatusWidget: Widget {
    let kind = "LibraryStatusWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: LibraryStatusConfigIntent.self, provider: LibraryStatusProvider()) { entry in
            LibraryStatusView(entry: entry)
                .widgetURL(URL(string: "arrbarr://library"))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Library Status")
        .description("Your library size at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
```

`ArrBarrWidgetsBundle.swift`:

```swift
import WidgetKit
import SwiftUI

@main
struct ArrBarrWidgetsBundle: WidgetBundle {
    var body: some Widget {
        LibraryStatusWidget()
    }
}
```

(Delete the template-generated bundle/widget files so there's only one `@main`.)

- [ ] **Step 5: Build and add the widget on the simulator**

Run: `xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -destination 'platform=iOS Simulator,name=iPhone 16' build`
Then run the app, background it, long-press the home screen, add the **Library Status** widget. With a configured server, it shows counts + sizes; tapping opens the app.
Expected: builds; widget renders real counts (or the placeholder until first fetch).

- [ ] **Step 6: Commit**

```bash
git add ArrBarrWidgets
git commit -m "feat(widgets): Library Status widget (small + medium, configurable)"
```

---

### Task 10: Reload timelines + demo-mode verification

**Files:**
- Modify: `ArrBarr/ArrBarrApp.swift` (or wherever config is saved / demo toggled)

- [ ] **Step 1: Reload widget timelines when data changes**

After config save and on app foreground, and on demo toggle, add:

```swift
import WidgetKit
WidgetCenter.shared.reloadAllTimelines()
```

Place it where `ConfigStore` persists changes and in the demo-toggle path (so the widget reflects demo data immediately). Guard with `#if canImport(WidgetKit)` if the call site is shared with macOS.

- [ ] **Step 2: Verify demo mode flows into the widget**

Run the app, enable Demo mode, foreground/background, check the widget shows the demo library counts (from `DemoMocks`). Disable demo → widget returns to the real profile (or the empty state).
Expected: widget tracks demo mode because the group suite is repointed live (per [[project_demo_isolated_suite]]).

- [ ] **Step 3: Verify the stale/empty states**

- Unconfigured (fresh install, no servers): widget shows "Set up a server in ArrBarr".
- Server unreachable (turn off the server / wrong URL): the failed service is omitted; remaining rows still render. (Full last-known-snapshot caching is a follow-up; Phase 1 omits unreachable services.)

- [ ] **Step 4: Commit**

```bash
git add ArrBarr/ArrBarrApp.swift
git commit -m "feat(app): reload widget timelines on config/demo changes"
```

---

## Self-Review notes

- **Spec coverage:** Phase 0 (App Group + migration: Tasks 4–5, 8; deep-link scheme + router: Tasks 6–7; demo support: Task 10) and Phase 1 (sizeOnDisk decode: Task 1; summary helper: Tasks 2–3; configurable widget, Whisparr-off, small/medium, 6h refresh, tap → library, empty/unreachable states: Tasks 9–10) are all covered.
- **Deferred to later phases (not this plan):** full last-known-snapshot caching on fetch failure (Phase 1 omits unreachable services instead — noted in Task 10 Step 3); service-icon artwork in the widget rows (text labels for now — Task 9 Step 3); macOS target + team-prefixed App Group (spec amendment #5 — the suite-name seam is in place in `WidgetDataStore`).
- **Type consistency:** `LibrarySummary` / `LibrarySummary.Source` (`.radarr/.sonarr/.lidarr/.whisparr`), `LibrarySummaryService().summaries(radarr:sonarr:lidarr:whisparr:)`, `WidgetDataStore.serviceConfig(_:)`, `ConfigStore.decodeServiceConfig(_:from:)`, `ConfigStore.migrateToGroupSuite(from:to:)`, `WidgetDeepLink(url:)` are used consistently across tasks.
