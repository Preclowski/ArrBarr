# iCloud Settings Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an iCloud tab to Settings (App Store builds only) where the user toggles iCloud sync on/off and sees sync status (account availability, last sync time, last error, what syncs).

**Architecture:** A new device-local `ConfigStore.iCloudSyncEnabled` flag drives both preference sync (`KVSyncCoordinator.setEnabled`) and a hard secret re-sync (`SecretStore.reapplySyncAttribute`, which rewrites Keychain items to/from `synchronizable`). `KVSyncCoordinator` becomes `ObservableObject` exposing status, and a new isolated `ICloudSettingsView` binds to it. The tab's entry points are wrapped in `#if APPSTORE`.

**Tech Stack:** Swift 6 (lang mode v5), SwiftUI, Combine, Security (Keychain), `NSUbiquitousKeyValueStore`, Swift Testing (`import Testing`, `@Test`/`#expect`).

**Spec:** `docs/superpowers/specs/2026-06-09-icloud-settings-tab-design.md`

---

## File Structure

- **Modify** `Packages/ArrCore/Sources/ArrCore/Services/SecretStore.swift` — add `SecretKey.syncable`, runtime sync provider in `baseQuery`, and a `reapplySyncAttribute` protocol extension.
- **Modify** `Packages/ArrCore/Sources/ArrCore/Services/KVSyncCoordinator.swift` — conform to `ObservableObject`, add status properties, `stop()`, `setEnabled(_:)`, public `shared`, and flag-gated `startShared()`.
- **Modify** `Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift` — add `iCloudSyncEnabled` flag (key, `@Published`, load, sink).
- **Create** `Packages/ArrCore/Sources/ArrCore/Views/ICloudSettingsView.swift` — the new pane.
- **Modify** `Packages/ArrCore/Sources/ArrCore/Views/SettingsView.swift` — enum case + macOS sidebar/title/detail wiring + iOS link.
- **Modify** `Packages/ArrCore/Resources/Localizable.xcstrings` — new strings.
- **Modify** tests: `SecretStoreTests.swift`, `KVSyncCoordinatorTests.swift`, `ConfigStoreTests.swift`, `SyncedKeysTests.swift`.

All test commands run from `Packages/ArrCore`: `swift test`. Note: `#if APPSTORE` is **not** set during `swift test`, so `synchronizable`-true assertions stay behind `#if APPSTORE`/`#else` like the existing tests.

---

## Task 1: Secret re-sync primitives (`SecretKey.syncable` + `reapplySyncAttribute`)

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/SecretStore.swift`
- Test: `Packages/ArrCore/Tests/ArrCoreTests/SecretStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `SecretStoreSuite` in `SecretStoreTests.swift`:

```swift
@Test("syncable lists every per-service key plus openai/tmdb, excludes mcpBearer")
func syncableContents() {
    let accounts = Set(SecretKey.syncable.map(\.account))
    for kind in ServiceKind.allCases {
        #expect(accounts.contains("secret.\(kind.rawValue).apiKey"))
        #expect(accounts.contains("secret.\(kind.rawValue).password"))
    }
    #expect(accounts.contains("secret.openai.apiKey"))
    #expect(accounts.contains("secret.tmdb.apiKey"))
    #expect(!accounts.contains("secret.mcp.bearer"))
    #expect(SecretKey.syncable.allSatisfy { $0.synced && !$0.deviceOnly })
}

@Test("reapplySyncAttribute rewrites only keys that currently hold a value")
func reapplyRewritesPresentOnly() {
    let store = RecordingSecretStore()
    let present = SecretKey.apiKey(for: .radarr)
    store.set("v", for: present)
    store.resetLog()

    store.reapplySyncAttribute(for: SecretKey.syncable)

    // The only key with a value is rewritten (set called); others untouched.
    #expect(store.setLog == [present.account])
    #expect(store.read(present) == "v")
}
```

Add this test double at the bottom of the file (outside the suite):

```swift
/// SecretStore that records which accounts were re-written, to assert
/// `reapplySyncAttribute` only touches keys that hold a value.
final class RecordingSecretStore: SecretStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    private(set) var setLog: [String] = []
    func read(_ key: SecretKey) -> String? { values[key.account] }
    func set(_ value: String, for key: SecretKey) {
        values[key.account] = value; setLog.append(key.account)
    }
    func delete(_ key: SecretKey) { values[key.account] = nil }
    func resetLog() { setLog.removeAll() }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/ArrCore && swift test --filter SecretStore`
Expected: FAIL — `SecretKey.syncable` and `reapplySyncAttribute` do not exist (compile error).

- [ ] **Step 3: Implement `SecretKey.syncable` and the extension**

In `SecretStore.swift`, add inside the `SecretKey` struct (after the `mcpBearer` static, before the closing brace at line ~29):

```swift
    /// Every secret eligible for iCloud Keychain sync: API key + password for
    /// each service, plus the OpenAI and TMDB keys. `mcpBearer` is excluded —
    /// it is `deviceOnly` and must never replicate.
    public static var syncable: [SecretKey] {
        var keys: [SecretKey] = []
        for kind in ServiceKind.allCases {
            keys.append(.apiKey(for: kind))
            keys.append(.password(for: kind))
        }
        keys.append(.openAIKey)
        keys.append(.tmdbKey)
        return keys
    }
```

Add after the `SecretStore` protocol declaration (after line ~35):

```swift
public extension SecretStore {
    /// Rewrite each given secret that currently holds a value, so the store's
    /// write path re-stamps the (possibly changed) `synchronizable` attribute.
    /// Keys with no value are skipped. Used to hard-toggle iCloud Keychain sync.
    func reapplySyncAttribute(for keys: [SecretKey]) {
        for key in keys {
            if let value = read(key) { set(value, for: key) }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/ArrCore && swift test --filter SecretStore`
Expected: PASS (all SecretStore tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/SecretStore.swift Packages/ArrCore/Tests/ArrCoreTests/SecretStoreTests.swift
git commit -m "feat(secrets): add SecretKey.syncable + reapplySyncAttribute"
```

---

## Task 2: Runtime sync gating in `KeychainSecretStore.baseQuery`

Makes `synchronizable` depend on a runtime flag (default true) so the toggle can stop secret replication. The flag is read via an injectable provider so tests can drive both states.

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/SecretStore.swift`
- Test: `Packages/ArrCore/Tests/ArrCoreTests/SecretStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `SecretStoreSuite`:

```swift
@Test("baseQuery synchronizable honors the runtime sync provider (APPSTORE only)")
func keychainSynchronizableRuntimeGating() {
    let original = KeychainSecretStore.syncEnabledProvider
    defer { KeychainSecretStore.syncEnabledProvider = original }

    KeychainSecretStore.syncEnabledProvider = { false }
    let off = KeychainSecretStore.baseQuery(for: .openAIKey)
    #expect(off[kSecAttrSynchronizable as String] as? Bool == false)

    KeychainSecretStore.syncEnabledProvider = { true }
    let on = KeychainSecretStore.baseQuery(for: .openAIKey)
    #if APPSTORE
    #expect(on[kSecAttrSynchronizable as String] as? Bool == true)
    #else
    #expect(on[kSecAttrSynchronizable as String] as? Bool == false)
    #endif
}

@Test("defaultSyncEnabled reads the device-local flag, defaulting true")
func defaultSyncEnabledReadsFlag() {
    let suite = "test.icloudflag.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    #expect(KeychainSecretStore.syncEnabled(in: d) == true)   // unset → true
    d.set(false, forKey: "ArrBarr.iCloudSyncEnabled")
    #expect(KeychainSecretStore.syncEnabled(in: d) == false)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/ArrCore && swift test --filter SecretStore`
Expected: FAIL — `syncEnabledProvider` / `syncEnabled(in:)` do not exist.

- [ ] **Step 3: Implement the provider and gating**

In `KeychainSecretStore` (in `SecretStore.swift`), add after `private static let logger` (line ~46):

```swift
    /// Device-local UserDefaults key mirroring `ConfigStore.iCloudSyncEnabled`.
    /// Duplicated here (not imported) so the nonisolated Keychain layer stays
    /// free of ConfigStore. Kept in sync with `ConfigStore.iCloudSyncEnabledKey`.
    static let iCloudSyncEnabledKey = "ArrBarr.iCloudSyncEnabled"

    /// Whether iCloud sync is currently enabled, read from the App Group suite
    /// (defaults to `true` when unset or unavailable). Overridable for tests.
    public static var syncEnabledProvider: @Sendable () -> Bool = {
        syncEnabled(in: WidgetDataStore.groupDefaults())
    }

    /// Pure reader for the device-local flag, defaulting to `true`.
    public static func syncEnabled(in defaults: UserDefaults?) -> Bool {
        guard let defaults, defaults.object(forKey: iCloudSyncEnabledKey) != nil
        else { return true }
        return defaults.bool(forKey: iCloudSyncEnabledKey)
    }
```

Then change the `synchronizable` computation in `baseQuery` (currently lines 54-58):

```swift
        #if APPSTORE
        let synchronizable = key.synced && Self.syncEnabledProvider()
        #else
        let synchronizable = false
        #endif
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/ArrCore && swift test --filter SecretStore`
Expected: PASS (including the pre-existing `keychainSynchronizableGating`, which still sees the default provider → true under APPSTORE).

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/SecretStore.swift Packages/ArrCore/Tests/ArrCoreTests/SecretStoreTests.swift
git commit -m "feat(secrets): runtime iCloud-sync gating in Keychain baseQuery"
```

---

## Task 3: `KVSyncCoordinator` — observable status, stop/setEnabled, flag-gated start

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/KVSyncCoordinator.swift`
- Test: `Packages/ArrCore/Tests/ArrCoreTests/KVSyncCoordinatorTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `KVSyncCoordinatorSuite` in `KVSyncCoordinatorTests.swift`:

```swift
@Test("setEnabled(true) marks running and stamps lastSyncDate")
@MainActor func setEnabledStarts() {
    let (defaults, name) = makeDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: name) }
    let kv = FakeKVStore()
    let coord = KVSyncCoordinator(defaults: defaults, kv: kv, reload: {})

    #expect(coord.isRunning == false)
    #expect(coord.lastSyncDate == nil)
    coord.setEnabled(true)
    #expect(coord.isRunning == true)
    #expect(coord.lastSyncDate != nil)
}

@Test("setEnabled(false) stops outbound pushes")
@MainActor func setEnabledStops() async {
    let (defaults, name) = makeDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: name) }
    let kv = FakeKVStore()
    let coord = KVSyncCoordinator(defaults: defaults, kv: kv, reload: {})
    coord.setEnabled(true)
    await Task.yield()
    coord.setEnabled(false)
    #expect(coord.isRunning == false)
    let baseline = kv.setCount

    // A local change after stop must NOT push to KVS.
    defaults.set(["radarr"], forKey: "ArrBarr.arrOrder")
    await Task.yield(); await Task.yield()
    #expect(kv.setCount == baseline)
}

@Test("setEnabled is idempotent — repeated enables don't double-stamp errors")
@MainActor func setEnabledIdempotent() {
    let (defaults, name) = makeDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: name) }
    let coord = KVSyncCoordinator(defaults: defaults, kv: FakeKVStore(), reload: {})
    coord.setEnabled(true)
    coord.setEnabled(true)
    #expect(coord.isRunning == true)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/ArrCore && swift test --filter KVSyncCoordinator`
Expected: FAIL — `isRunning`, `lastSyncDate`, `setEnabled` do not exist.

- [ ] **Step 3: Implement the observable + control surface**

In `KVSyncCoordinator.swift`, change the class declaration (line 17-18) to conform to `ObservableObject`:

```swift
@MainActor
public final class KVSyncCoordinator: ObservableObject {
```

Add these published properties right after the existing stored properties (after `private var observers` at line 24):

```swift
    /// Timestamp of the last successful push or pull. `nil` until first sync.
    @Published public private(set) var lastSyncDate: Date?
    /// Human-readable description of the last sync failure, or `nil` if healthy.
    @Published public private(set) var lastError: String?
    /// Whether the coordinator is currently observing and mirroring changes.
    @Published public private(set) var isRunning: Bool = false

    /// Whether this device is signed into iCloud (Keychain/KVS can replicate).
    public var accountAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }
```

Set `isRunning` and stamp the date inside `start()`. Change the body of `start()` so its tail (currently lines 52-55) reads:

```swift
        observers = [kvObs, defObs]
        applyFromKV(keys: Array(SyncedKeys.all))
        pushAllToKV()
        kv.synchronize()
        isRunning = true
        lastSyncDate = Date()
        lastError = nil
```

Add `stop()` and `setEnabled(_:)` after `start()` (before `pushAllToKV`):

```swift
    /// Stop observing and mirroring. Existing KVS/Keychain data is left intact.
    public func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        isRunning = false
    }

    /// Idempotently start or stop syncing to match the user's toggle.
    public func setEnabled(_ enabled: Bool) {
        if enabled {
            guard !isRunning else { return }
            start()
        } else {
            guard isRunning else { return }
            stop()
        }
    }
```

Stamp `lastSyncDate` on outbound pushes too — at the end of `pushAllToKV()` add:

```swift
        lastSyncDate = Date()
```

Expose `shared` and gate `startShared()` on the flag. Replace the `extension KVSyncCoordinator` block (lines 93-113) with:

```swift
@MainActor
extension KVSyncCoordinator {
    private static var _shared: KVSyncCoordinator?

    /// The process-wide coordinator, if one has been created. Read-only access
    /// for UI (status display) and for `ConfigStore`'s toggle sink.
    public static var shared: KVSyncCoordinator? { _shared }

    /// Create, retain, and (if iCloud sync is enabled) start the process-wide
    /// coordinator bound to the real App Group suite and the live iCloud KVS.
    /// Idempotent. No-op if the group suite is unavailable. Call only under
    /// `#if APPSTORE`.
    @discardableResult
    public static func startShared() -> KVSyncCoordinator? {
        if let existing = _shared { return existing }
        guard let group = WidgetDataStore.groupDefaults() else { return nil }
        let coord = KVSyncCoordinator(
            defaults: group,
            kv: NSUbiquitousKeyValueStore.default,
            reload: { ConfigStore.shared.reloadFromDefaults() })
        _shared = coord
        if KeychainSecretStore.syncEnabled(in: group) { coord.start() }
        return coord
    }
}
```

Note: `deinit` (line 90) still removes observers — keep it; `stop()` is the runtime path.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/ArrCore && swift test --filter KVSyncCoordinator`
Expected: PASS (new tests + the four existing ones).

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/KVSyncCoordinator.swift Packages/ArrCore/Tests/ArrCoreTests/KVSyncCoordinatorTests.swift
git commit -m "feat(sync): observable status + stop/setEnabled + flag-gated startShared"
```

---

## Task 4: `ConfigStore.iCloudSyncEnabled` flag wired to coordinator + secrets

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift`
- Test: `Packages/ArrCore/Tests/ArrCoreTests/ConfigStoreTests.swift`, `Packages/ArrCore/Tests/ArrCoreTests/SyncedKeysTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `ConfigStoreTests.swift` (inside its suite — match the file's existing suite name/style):

```swift
@Test("iCloudSyncEnabled defaults to true and persists")
@MainActor func iCloudSyncEnabledPersists() {
    let suite = "test.cfg.icloud.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

    let store = ConfigStore(defaults: d, secrets: InMemorySecretStore())
    #expect(store.iCloudSyncEnabled == true)

    store.iCloudSyncEnabled = false
    #expect(d.bool(forKey: "ArrBarr.iCloudSyncEnabled") == false)

    let reloaded = ConfigStore(defaults: d, secrets: InMemorySecretStore())
    #expect(reloaded.iCloudSyncEnabled == false)
}
```

Add to `SyncedKeysTests.swift`:

```swift
@Test("iCloudSyncEnabled is device-local — never in the sync allowlist")
func iCloudFlagNotSynced() {
    #expect(!SyncedKeys.all.contains("ArrBarr.iCloudSyncEnabled"))
    #expect(SyncedKeys.isSynced("ArrBarr.iCloudSyncEnabled") == false)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/ArrCore && swift test --filter "ConfigStore"` then `swift test --filter SyncedKeys`
Expected: FAIL — `iCloudSyncEnabled` does not exist (ConfigStore test won't compile); SyncedKeys test passes already but keep it as a guard (if it fails, the key was wrongly added).

- [ ] **Step 3: Implement the flag**

In `ConfigStore.swift`:

a) Add the `@Published` property near the other booleans (after `launchAtLogin` at line 83):

```swift
    @Published public var iCloudSyncEnabled: Bool = true
```

b) Add the key constant (after `launchAtLoginKey` at line 239):

```swift
    private static let iCloudSyncEnabledKey = "ArrBarr.iCloudSyncEnabled"
```

c) Read it in `applyValues(from:)` (next to the `launchAtLogin` read at line 356):

```swift
        self.iCloudSyncEnabled = defaults.object(forKey: Self.iCloudSyncEnabledKey) != nil
            ? defaults.bool(forKey: Self.iCloudSyncEnabledKey) : true
```

d) Add the sink in `setupSinks()` (after the `$launchAtLogin` sink at lines 449-452):

```swift
        $iCloudSyncEnabled.dropFirst().sink { [weak self] val in
            guard let self else { return }
            self.defaults.set(val, forKey: Self.iCloudSyncEnabledKey)
            // Preferences (KVS): start/stop the live coordinator.
            KVSyncCoordinator.shared?.setEnabled(val)
            // Secrets (iCloud Keychain): rewrite items to the new sync state.
            self.secrets.reapplySyncAttribute(for: SecretKey.syncable)
        }.store(in: &cancellables)
```

(`ConfigStore` is `@MainActor`, so the `@MainActor`-isolated `KVSyncCoordinator.shared` is reachable directly.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/ArrCore && swift test --filter "ConfigStore"` then `swift test --filter SyncedKeys`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift Packages/ArrCore/Tests/ArrCoreTests/ConfigStoreTests.swift Packages/ArrCore/Tests/ArrCoreTests/SyncedKeysTests.swift
git commit -m "feat(config): iCloudSyncEnabled flag drives KVS + secret re-sync"
```

---

## Task 5: `ICloudSettingsView` pane

A self-contained pane. No unit test (SwiftUI view); verified by the package build in Task 8. Uses `Text(..., bundle: .module)`; strings are added in Task 7 (the keys below must match exactly).

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Views/ICloudSettingsView.swift`

- [ ] **Step 1: Create the view**

```swift
import SwiftUI

/// Settings pane for iCloud sync: a master on/off toggle plus live status
/// (account availability, last sync time, last error) and a static summary of
/// what syncs. Reachable only in App Store builds (the sidebar entry and iOS
/// link are `#if APPSTORE`-gated in SettingsView).
struct ICloudSettingsView: View {
    @ObservedObject private var config = ConfigStore.shared
    @ObservedObject private var coordinator = ICloudSettingsView.coordinator

    /// A non-optional coordinator for the view to observe. Falls back to a
    /// stopped instance when the shared one was never created (e.g. previews,
    /// non-APPSTORE), so status simply reads "Off / Never".
    @MainActor private static var coordinator: KVSyncCoordinator = {
        KVSyncCoordinator.shared ?? KVSyncCoordinator(
            defaults: WidgetDataStore.groupDefaults() ?? .standard,
            kv: NSUbiquitousKeyValueStore.default,
            reload: {})
    }()

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $config.iCloudSyncEnabled) {
                    Text("Sync with iCloud", bundle: .module)
                }
            } footer: {
                Text("Keep your servers, preferences, and saved keys in sync across your devices. Keys are stored in your encrypted iCloud Keychain.", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if config.iCloudSyncEnabled {
                statusSection
            }
            whatSyncsSection
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var statusSection: some View {
        Section {
            if !coordinator.accountAvailable {
                Label {
                    Text("Sign in to iCloud in System Settings to enable sync.", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            LabeledContent {
                if let date = coordinator.lastSyncDate {
                    Text(date, format: .relative(presentation: .named))
                } else {
                    Text("Never", bundle: .module)
                }
            } label: {
                Text("Last sync", bundle: .module)
            }
            if let error = coordinator.lastError {
                Label {
                    Text(verbatim: error)
                } icon: {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
                .foregroundStyle(.red)
            }
        } header: {
            Text("Status", bundle: .module)
        }
    }

    private var whatSyncsSection: some View {
        Section {
            row("server.rack", "Server configurations")
            row("key.fill", "Passwords & API keys (iCloud Keychain)")
            row("bell.badge", "Notification settings")
            row("sparkles", "Assistant settings")
            row("rectangle.3.group", "Layout & visibility preferences")
        } header: {
            Text("What syncs", bundle: .module)
        } footer: {
            Text("Device-specific settings (refresh intervals, appearance, MCP) stay on this device.", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ symbol: String, _ key: LocalizedStringKey) -> some View {
        Label {
            Text(key, bundle: .module)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 2: Build the package to verify it compiles**

Run: `cd Packages/ArrCore && swift build`
Expected: SUCCESS (strings resolve to their keys even before the catalog entries exist; missing catalog entries are not build errors).

- [ ] **Step 3: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/ICloudSettingsView.swift
git commit -m "feat(ui): add ICloudSettingsView pane"
```

---

## Task 6: Wire the tab into `SettingsView`

The enum case is compiled in all builds (keeps the switches exhaustive without `#if` inside them); only the entry points (sidebar row, iOS link) are `#if APPSTORE`-gated, so the tab is unreachable in OSS builds.

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/SettingsView.swift`

- [ ] **Step 1: Add the enum case**

In the `SettingsSection` enum (lines 49-58), add `case icloud` after `case mcp`:

```swift
        case assistant
        case mcp
        case icloud
        case siri
        case about
```

- [ ] **Step 2: Add the macOS sidebar row (gated)**

In `structuredSidebar` (lines 393-408), after the MCP `Label` (line 402-403) add:

```swift
        #if APPSTORE
        Label { Text("iCloud", bundle: .module) } icon: { Image(systemName: "icloud") }
            .tag(SettingsSection.icloud)
        #endif
```

- [ ] **Step 3: Add the search directory entry (gated)**

In `sidebarEntries` (lines 431-436), insert after the `.mcp` entry:

```swift
        ]
        #if APPSTORE
        items.append(.init(section: .icloud, title: String(localized: "iCloud", bundle: .module), kind: nil, systemImage: "icloud"))
        #endif
        items += [
```

(Split the existing `items += [ ... ]` so the `.assistant`/`.mcp` entries stay in the first array and `.siri`/`.about` in the second; the App Store iCloud entry goes between them. Concretely: close the array after the `.mcp` line, add the gated `append`, then open a new `items += [` for the `.siri` and `.about` lines.)

- [ ] **Step 4: Add the `navTitle` case**

In `navTitle(for:)` (lines 491-502), after `case .mcp` add:

```swift
        case .icloud: return Text("iCloud", bundle: .module)
```

- [ ] **Step 5: Add the `detailPane` case**

In `detailPane(for:)` (lines 504-516), after `case .mcp: MCPSettingsPane()` add:

```swift
        case .icloud: ICloudSettingsView()
```

- [ ] **Step 6: Add the iOS link (gated)**

In `iOSCombinedForm` (lines ~640-653), after the Assistant link add:

```swift
        #if APPSTORE
        iosSettingsLink("iCloud", systemImage: "icloud") { ICloudSettingsView() }
        #endif
```

(Place it before the "Siri & Shortcuts" link to mirror the macOS order. Confirm the exact `iosSettingsLink` signature in the file and match it — the title string is passed positionally as in the surrounding links.)

- [ ] **Step 7: Build the package**

Run: `cd Packages/ArrCore && swift build`
Expected: SUCCESS. (Builds without `APPSTORE`, so the gated rows are excluded; the `.icloud` enum case + `detailPane`/`navTitle` cases still compile.)

- [ ] **Step 8: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/SettingsView.swift
git commit -m "feat(ui): wire iCloud tab into Settings (App Store builds)"
```

---

## Task 7: Localization strings

Add every new user-facing key to the catalog for all five languages (en/de/es/fr/pl). English is authoritative; provide translations for the others.

**Files:**
- Modify: `Packages/ArrCore/Resources/Localizable.xcstrings`

- [ ] **Step 1: Add the strings**

Add catalog entries (key = English source) for:

- `Sync with iCloud`
- `Keep your servers, preferences, and saved keys in sync across your devices. Keys are stored in your encrypted iCloud Keychain.`
- `Sign in to iCloud in System Settings to enable sync.`
- `Last sync`
- `Never`
- `Status`
- `What syncs`
- `Server configurations`
- `Passwords & API keys (iCloud Keychain)`
- `Notification settings`
- `Assistant settings`
- `Layout & visibility preferences`
- `Device-specific settings (refresh intervals, appearance, MCP) stay on this device.`
- `iCloud`

Edit the JSON directly. Each entry follows the catalog's existing shape, e.g.:

```json
"Last sync" : {
  "localizations" : {
    "de" : { "stringUnit" : { "state" : "translated", "value" : "Letzte Synchronisierung" } },
    "es" : { "stringUnit" : { "state" : "translated", "value" : "Última sincronización" } },
    "fr" : { "stringUnit" : { "state" : "translated", "value" : "Dernière synchronisation" } },
    "pl" : { "stringUnit" : { "state" : "translated", "value" : "Ostatnia synchronizacja" } }
  }
},
```

Provide the analogous translations for every key above. Match the indentation and `sourceLanguage`/`version` shape already in the file; insert keys in the file's existing ordering convention (alphabetical if that's what the file uses — check the top of the file first).

- [ ] **Step 2: Verify the catalog parses (build)**

Run: `cd Packages/ArrCore && swift build`
Expected: SUCCESS (a malformed xcstrings JSON fails resource processing).

- [ ] **Step 3: Commit**

```bash
git add Packages/ArrCore/Resources/Localizable.xcstrings
git commit -m "i18n: strings for the iCloud settings tab"
```

---

## Task 8: Full verification (tests + app build + relaunch)

**Files:** none (verification only).

- [ ] **Step 1: Run the full ArrCore test suite**

Run: `cd Packages/ArrCore && swift test`
Expected: PASS — all suites, including the new SecretStore / KVSyncCoordinator / ConfigStore / SyncedKeys tests.

- [ ] **Step 2: Build the macOS app**

Run:
```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Kill and relaunch (per project workflow)**

Run:
```bash
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```
Expected: app relaunches. Note: this Debug build is **not** `APPSTORE`, so the iCloud tab is intentionally hidden — confirm the app launches cleanly and existing Settings tabs work. (Visual confirmation of the iCloud tab itself requires a `Release-AppStore` build.)

- [ ] **Step 4: Final commit (if any verification fixups were needed)**

```bash
git add -A
git commit -m "chore: iCloud settings tab verification fixups"
```

(Skip if nothing changed.)

---

## Self-Review Notes

- **Spec coverage:** toggle (Task 4), hard secret semantics (Tasks 1–2 + sink in 4), KVS start/stop (Task 3), status: account availability + last sync + last error + what-syncs (Tasks 3, 5), non-APPSTORE hidden (Task 6 gating), localization (Task 7). All spec sections map to a task.
- **Type consistency:** `iCloudSyncEnabledKey` string `"ArrBarr.iCloudSyncEnabled"` is identical in `ConfigStore` (Task 4) and `KeychainSecretStore` (Task 2). `SecretKey.syncable`, `reapplySyncAttribute(for:)`, `setEnabled(_:)`, `KVSyncCoordinator.shared`, `KeychainSecretStore.syncEnabled(in:)` are each defined once and referenced consistently.
- **Verification before completion:** Task 8 runs `swift test` + `xcodebuild` and relaunches; do not claim done before BUILD SUCCEEDED and all tests pass.
