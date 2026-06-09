# Runtime APPSTORE Capability Injection — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the dead `#if APPSTORE` gating inside the `ArrCore` SwiftPM package with a runtime capability (`AppCapabilities`) injected by the app targets, so the iCloud tab, secret/Keychain sync, the toggle, and the Whisparr age gate actually activate in App Store builds — without risking secret loss on devices whose entitlements aren't provisioned.

**Architecture:** A new `AppCapabilities` enum in ArrCore holds `isAppStore` (set once at app launch under `#if APPSTORE`) and a cached `keychainSharingAvailable` probe. Every dead package `#if APPSTORE` becomes a runtime `if`. Secret-store activation is additionally gated on the live Keychain-access-group probe, and `migrateSecretsToKeychain` verifies a read-back before blanking UserDefaults.

**Tech Stack:** Swift 6 (lang mode v5), SwiftUI, Security (Keychain), Combine, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-06-09-appstore-runtime-capability-design.md`

**Build/run:** package tests `cd Packages/ArrCore && swift test`; app `xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build`. `APPSTORE` is NOT set during `swift test`, but gating is now runtime so both branches are testable by flipping `AppCapabilities`.

---

## File Structure

- **Create** `Packages/ArrCore/Sources/ArrCore/Services/AppCapabilities.swift` — the capability flag + probe.
- **Modify** `Packages/ArrCore/Sources/ArrCore/Services/SecretStore.swift` — `baseQuery` runtime gating.
- **Modify** `Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift` — secret-store choice, init branch, toggle sink, safe migration.
- **Modify** `Packages/ArrCore/Sources/ArrCore/Services/WidgetDataStore.swift` — secret-store choice.
- **Modify** `Packages/ArrCore/Sources/ArrCore/Views/SettingsView.swift` — 3 tab entry points.
- **Modify** `Packages/ArrCore/Sources/ArrCore/Views/ServiceFields.swift` — Whisparr age gate.
- **Modify** `ArrBarr/ArrBarrApp.swift`, `ArrBarriOS/ArrBarriOSApp.swift`, `ArrBarrWidgets/ArrBarrWidgets.swift` — call `configure`.
- **Modify** tests: `SecretStoreTests.swift`, `ConfigStoreTests.swift`, new `AppCapabilitiesTests.swift`.

---

## Task 1: `AppCapabilities` type

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Services/AppCapabilities.swift`
- Test: `Packages/ArrCore/Tests/ArrCoreTests/AppCapabilitiesTests.swift`

- [ ] **Step 1: Write failing tests**

Create `AppCapabilitiesTests.swift`:

```swift
import Testing
import Foundation
@testable import ArrCore

@Suite("AppCapabilities", .serialized)
struct AppCapabilitiesSuite {

    @Test("isAppStore defaults false and configure flips it")
    func configureFlipsFlag() {
        let original = AppCapabilities.isAppStore
        defer { AppCapabilities.configure(isAppStore: original) }
        AppCapabilities.configure(isAppStore: false)
        #expect(AppCapabilities.isAppStore == false)
        AppCapabilities.configure(isAppStore: true)
        #expect(AppCapabilities.isAppStore == true)
    }

    @Test("keychainSharingAvailable is false when not an App Store build")
    func probeFalseWhenNotAppStore() {
        let original = AppCapabilities.isAppStore
        defer { AppCapabilities.configure(isAppStore: original); AppCapabilities.resetProbeForTesting() }
        AppCapabilities.configure(isAppStore: false)
        AppCapabilities.resetProbeForTesting()
        #expect(AppCapabilities.keychainSharingAvailable == false)
    }

    @Test("keychainSharingAvailable honors an injected probe override")
    func probeOverride() {
        let original = AppCapabilities.isAppStore
        defer {
            AppCapabilities.configure(isAppStore: original)
            AppCapabilities.keychainProbeOverride = nil
            AppCapabilities.resetProbeForTesting()
        }
        AppCapabilities.configure(isAppStore: true)
        AppCapabilities.keychainProbeOverride = { true }
        AppCapabilities.resetProbeForTesting()
        #expect(AppCapabilities.keychainSharingAvailable == true)
        AppCapabilities.keychainProbeOverride = { false }
        AppCapabilities.resetProbeForTesting()
        #expect(AppCapabilities.keychainSharingAvailable == false)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/ArrCore && swift test --filter AppCapabilities`
Expected: FAIL (type does not exist).

- [ ] **Step 3: Implement `AppCapabilities`**

Create `AppCapabilities.swift`:

```swift
import Foundation
import Security
import os

/// Runtime replacement for the dead package-level `#if APPSTORE` gating.
///
/// `APPSTORE` is a compile condition on the Xcode *app targets* only; Xcode does
/// not propagate it to local SwiftPM packages, so `#if APPSTORE` inside ArrCore
/// is always false. Instead the app target sets `isAppStore` at launch and the
/// package branches on this runtime value.
public enum AppCapabilities {
    private static let logger = Logger(category: "AppCapabilities")

    /// True in App Store builds. Set once by the app target at launch via
    /// `configure(isAppStore:)`, before the first `ConfigStore.shared` access.
    /// `nonisolated(unsafe)`: written once at launch before any concurrent read
    /// (same pattern as `KeychainSecretStore.syncEnabledProvider`).
    public nonisolated(unsafe) private(set) static var isAppStore = false

    /// Set the build flavor. Idempotent. MUST run before `ConfigStore.shared`.
    public static func configure(isAppStore: Bool) { self.isAppStore = isAppStore }

    /// Test seam: overrides the live Keychain probe when non-nil.
    public nonisolated(unsafe) static var keychainProbeOverride: (() -> Bool)?

    private nonisolated(unsafe) static var cachedProbe: Bool?

    /// Whether the shared Keychain access group is actually usable at runtime.
    /// Only probes in App Store builds (OSS/dev never probes → never prompts,
    /// always resolves to UserDefaults storage). Cached after first evaluation.
    public static var keychainSharingAvailable: Bool {
        if let cached = cachedProbe { return cached }
        let result: Bool
        if let override = keychainProbeOverride {
            result = override()
        } else if !isAppStore {
            result = false
        } else {
            result = probeKeychainAccessGroup()
        }
        cachedProbe = result
        return result
    }

    /// Test seam: clear the cached probe so a changed flag/override re-evaluates.
    public static func resetProbeForTesting() { cachedProbe = nil }

    /// Throwaway add+copy+delete against the shared access group. Returns false
    /// on any failure (notably `errSecMissingEntitlement` when the entitlement
    /// isn't provisioned). Does not prompt — an entitlement check, not a
    /// login-Keychain access.
    private static func probeKeychainAccessGroup() -> Bool {
        let account = "appcap.__probe__"
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainSecretStore.service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: KeychainSecretStore.accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data("1".utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        defer { SecItemDelete(base as CFDictionary) }
        if status != errSecSuccess {
            logger.notice("Keychain access group unavailable: \(status)")
            return false
        }
        return true
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd Packages/ArrCore && swift test --filter AppCapabilities`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/AppCapabilities.swift Packages/ArrCore/Tests/ArrCoreTests/AppCapabilitiesTests.swift
git commit -m "feat(core): AppCapabilities runtime flag + keychain probe"
```

---

## Task 2: Safe secret migration (verify-before-blank)

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift` (`migrateSecretsToKeychain`, ~line 744)
- Test: `Packages/ArrCore/Tests/ArrCoreTests/ConfigStoreTests.swift`

- [ ] **Step 1: Write failing test**

Add to `ConfigStoreTests.swift`:

```swift
/// A SecretStore whose writes silently fail (simulating a Keychain write with
/// no entitlement), to prove migration never blanks UserDefaults unverified.
final class FailingSecretStore: SecretStore, @unchecked Sendable {
    func read(_ key: SecretKey) -> String? { nil }   // read-back never verifies
    func set(_ value: String, for key: SecretKey) {}  // write is a no-op
    func delete(_ key: SecretKey) {}
}

@Test("migration leaves UserDefaults secrets intact when the Keychain write fails")
@MainActor func migrationVerifiesBeforeBlanking() throws {
    let suite = "test.cfg.migrate.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

    var cfg = ServiceConfig.empty
    cfg.apiKey = "secret-key"
    let data = try JSONEncoder().encode(cfg)
    d.set(data, forKey: ConfigStore.serviceKeyForTesting(.radarr))

    ConfigStore.migrateSecretsToKeychain(defaults: d, secrets: FailingSecretStore())

    // The plaintext apiKey must still be present (NOT blanked) and the migration
    // flag must NOT be set, so a later launch can retry.
    let after = try JSONDecoder().decode(ServiceConfig.self,
                from: d.data(forKey: ConfigStore.serviceKeyForTesting(.radarr))!)
    #expect(after.apiKey == "secret-key")
    #expect(d.bool(forKey: ConfigStore.secretsMigratedKeyForTesting) == false)
}
```

Note: this test needs two test accessors on `ConfigStore`. If `serviceKeyForTesting`/`secretsMigratedKeyForTesting` don't exist, add them (Step 3b).

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/ArrCore && swift test --filter ConfigStore`
Expected: FAIL (accessors missing and/or apiKey blanked).

- [ ] **Step 3a: Make migration verify-before-blank**

In `ConfigStore.swift`, rewrite `migrateSecretsToKeychain` (current body at ~744-779) so each
secret is only blanked after a verified read-back, and the done-flag is only set when every
secret verified:

```swift
    nonisolated static func migrateSecretsToKeychain(defaults: UserDefaults, secrets: SecretStore) {
        guard !defaults.bool(forKey: secretsMigratedKey) else { return }
        var allVerified = true

        /// Write `value` to `secrets`, read it back, and only then report success.
        func store(_ value: String, _ key: SecretKey) -> Bool {
            guard !value.isEmpty else { return true }
            secrets.set(value, for: key)
            if secrets.read(key) == value { return true }
            allVerified = false
            return false
        }

        for kind in ServiceKind.allCases {
            guard let data = defaults.data(forKey: key(kind)),
                  var cfg = try? JSONDecoder().decode(ServiceConfig.self, from: data)
            else { continue }
            var changed = false
            if !cfg.apiKey.isEmpty, store(cfg.apiKey, .apiKey(for: kind)) {
                cfg.apiKey = ""; changed = true
            }
            if !cfg.password.isEmpty, store(cfg.password, .password(for: kind)) {
                cfg.password = ""; changed = true
            }
            if changed, let updated = try? JSONEncoder().encode(cfg) {
                defaults.set(updated, forKey: key(kind))
            }
        }

        if let data = defaults.data(forKey: openaiConfigKey),
           var cfg = try? JSONDecoder().decode(OpenAIConfig.self, from: data),
           !cfg.apiKey.isEmpty, store(cfg.apiKey, .openAIKey) {
            cfg.apiKey = ""
            if let updated = try? JSONEncoder().encode(cfg) {
                defaults.set(updated, forKey: openaiConfigKey)
            }
        }

        if let tmdb = defaults.string(forKey: tmdbApiKeyKey), !tmdb.isEmpty,
           store(tmdb, .tmdbKey) {
            defaults.removeObject(forKey: tmdbApiKeyKey)
        }

        // Only mark migration done when every secret was verified in the Keychain.
        // Otherwise leave the flag false so a later launch (e.g. once entitlements
        // are provisioned) retries the unmigrated items.
        if allVerified { defaults.set(true, forKey: secretsMigratedKey) }
    }
```

- [ ] **Step 3b: Add test accessors (if missing)**

Near the existing `groupMigrationDoneKeyForTesting` accessor in `ConfigStore.swift`, add:

```swift
    nonisolated static var secretsMigratedKeyForTesting: String { secretsMigratedKey }
    nonisolated static func serviceKeyForTesting(_ kind: ServiceKind) -> String { key(kind) }
```

(Check first — if `key(_:)` is already non-private or an accessor already exists, reuse it.)

- [ ] **Step 4: Run to verify pass**

Run: `cd Packages/ArrCore && swift test --filter ConfigStore`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift Packages/ArrCore/Tests/ArrCoreTests/ConfigStoreTests.swift
git commit -m "fix(secrets): verify Keychain write-back before blanking UserDefaults"
```

---

## Task 3: Runtime gating in `SecretStore.baseQuery` + secret-store selection

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/SecretStore.swift`
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift`
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/WidgetDataStore.swift`
- Test: `Packages/ArrCore/Tests/ArrCoreTests/SecretStoreTests.swift`

- [ ] **Step 1: Rewrite the existing `#if APPSTORE` SecretStore tests as runtime, write new ones**

In `SecretStoreTests.swift`, replace the bodies of `keychainSynchronizableGating`,
`keychainAccessGroupGating`, and `keychainSynchronizableRuntimeGating` so they flip
`AppCapabilities` instead of compiling under `#if APPSTORE`. Replace those three tests with:

```swift
@Test("baseQuery synchronizable + access group follow AppCapabilities.isAppStore")
func keychainGatingRuntime() {
    let originalAppStore = AppCapabilities.isAppStore
    let originalProvider = KeychainSecretStore.syncEnabledProvider
    defer {
        AppCapabilities.configure(isAppStore: originalAppStore)
        KeychainSecretStore.syncEnabledProvider = originalProvider
    }
    KeychainSecretStore.syncEnabledProvider = { true }

    AppCapabilities.configure(isAppStore: true)
    let on = KeychainSecretStore.baseQuery(for: .openAIKey)
    #expect(on[kSecAttrSynchronizable as String] as? Bool == true)
    #expect(on[kSecAttrAccessGroup as String] as? String == KeychainSecretStore.accessGroup)
    #expect(on[kSecUseDataProtectionKeychain as String] as? Bool == true)
    // mcpBearer never syncs even when isAppStore
    #expect(KeychainSecretStore.baseQuery(for: .mcpBearer)[kSecAttrSynchronizable as String] as? Bool == false)

    AppCapabilities.configure(isAppStore: false)
    let off = KeychainSecretStore.baseQuery(for: .openAIKey)
    #expect(off[kSecAttrSynchronizable as String] as? Bool == false)
    #expect(off[kSecAttrAccessGroup as String] == nil)
    #expect(off[kSecUseDataProtectionKeychain as String] == nil)
}

@Test("synchronizable also honors the runtime sync provider when isAppStore")
func keychainSynchronizableRespectsProvider() {
    let originalAppStore = AppCapabilities.isAppStore
    let originalProvider = KeychainSecretStore.syncEnabledProvider
    defer {
        AppCapabilities.configure(isAppStore: originalAppStore)
        KeychainSecretStore.syncEnabledProvider = originalProvider
    }
    AppCapabilities.configure(isAppStore: true)
    KeychainSecretStore.syncEnabledProvider = { false }
    #expect(KeychainSecretStore.baseQuery(for: .openAIKey)[kSecAttrSynchronizable as String] as? Bool == false)
    KeychainSecretStore.syncEnabledProvider = { true }
    #expect(KeychainSecretStore.baseQuery(for: .openAIKey)[kSecAttrSynchronizable as String] as? Bool == true)
}
```

Also update the `keychainAccessibility` test (it does not depend on APPSTORE — verify it still
reads accessibility without `#if`; the `kSecAttrAccessible` value does not change with the flag).
Leave `defaultSyncEnabledReadsFlag`, `syncableContents`, `reapplyRewritesPresentOnly`, the
device-only/synced flag tests, and `keychainRoundTrips` as-is.

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/ArrCore && swift test --filter SecretStore`
Expected: FAIL (baseQuery still uses `#if APPSTORE`, so the runtime flips have no effect; the
`true` assertions fail because the package isn't compiled with APPSTORE).

- [ ] **Step 3a: Convert `baseQuery` to runtime gating**

In `SecretStore.swift` `baseQuery(for:)`, replace the `#if APPSTORE` synchronizable block AND
the `#if APPSTORE` access-group block with runtime checks on `AppCapabilities.isAppStore`:

```swift
    public static func baseQuery(for key: SecretKey) -> [String: Any] {
        let synchronizable = AppCapabilities.isAppStore && key.synced && Self.syncEnabledProvider()
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
            kSecAttrSynchronizable as String: synchronizable,
            kSecAttrAccessible as String: key.deviceOnly
                ? (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
                : (kSecAttrAccessibleAfterFirstUnlock as String),
        ]
        if AppCapabilities.isAppStore {
            q[kSecAttrAccessGroup as String] = Self.accessGroup
            q[kSecUseDataProtectionKeychain as String] = true
        }
        return q
    }
```

(Remove the now-unused `#if APPSTORE`/`#else` for `synchronizable`. Keep `matchQuery` as-is —
it overrides synchronizable to `kSecAttrSynchronizableAny`.)

- [ ] **Step 3b: Convert `ConfigStore.makeDefaultSecretStore` + init branch**

In `ConfigStore.swift`, replace the `#if APPSTORE` in `makeDefaultSecretStore` (~289-293):

```swift
    nonisolated static func makeDefaultSecretStore(defaults: UserDefaults) -> SecretStore {
        if AppCapabilities.isAppStore && AppCapabilities.keychainSharingAvailable {
            return KeychainSecretStore()
        }
        return UserDefaultsSecretStore(defaults: defaults)
    }
```

And the `#if APPSTORE` migrate-vs-recover branch in `init` (~271-279):

```swift
        if AppCapabilities.isAppStore && AppCapabilities.keychainSharingAvailable {
            Self.migrateSecretsToKeychain(defaults: defaults, secrets: store)
        } else {
            Self.recoverSecretsFromKeychainIfNeeded(defaults: defaults, secrets: store)
        }
```

- [ ] **Step 3c: Convert `WidgetDataStore.serviceConfig`**

In `WidgetDataStore.swift` (~25-29), replace the `#if APPSTORE` secret-store choice:

```swift
        let secrets: SecretStore = (AppCapabilities.isAppStore && AppCapabilities.keychainSharingAvailable)
            ? KeychainSecretStore()
            : UserDefaultsSecretStore(defaults: d)
```

- [ ] **Step 4: Run to verify pass**

Run: `cd Packages/ArrCore && swift test --filter SecretStore`
Expected: PASS (and run `swift test` to confirm nothing else regressed).

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/SecretStore.swift Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift Packages/ArrCore/Sources/ArrCore/Services/WidgetDataStore.swift Packages/ArrCore/Tests/ArrCoreTests/SecretStoreTests.swift
git commit -m "feat(secrets): runtime-gate Keychain store + baseQuery via AppCapabilities"
```

---

## Task 4: Runtime gating in the ConfigStore iCloud toggle sink

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift` (the `$iCloudSyncEnabled` sink)

- [ ] **Step 1: Convert the sink**

Replace the `#if APPSTORE` inside the `$iCloudSyncEnabled.dropFirst().sink` block with a runtime check:

```swift
        $iCloudSyncEnabled.dropFirst().sink { [weak self] val in
            guard let self else { return }
            self.defaults.set(val, forKey: Self.iCloudSyncEnabledKey)
            guard AppCapabilities.isAppStore else { return }
            KVSyncCoordinator.shared?.setEnabled(val)
            self.secrets.reapplySyncAttribute(for: SecretKey.syncable)
        }.store(in: &cancellables)
```

- [ ] **Step 2: Build + test**

Run: `cd Packages/ArrCore && swift test`
Expected: PASS (existing ConfigStore tests still green; the sink change is covered by build + the existing persistence test which runs with `isAppStore == false` so the sync side-effects are skipped).

- [ ] **Step 3: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift
git commit -m "feat(config): runtime-gate iCloud toggle side-effects via AppCapabilities"
```

---

## Task 5: Runtime gating in the UI (tab entry points + Whisparr age gate)

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/SettingsView.swift`
- Modify: `Packages/ArrCore/Sources/ArrCore/Views/ServiceFields.swift`

- [ ] **Step 1: Convert the 3 SettingsView entry points from `#if APPSTORE` to runtime `if`**

a) `structuredSidebar` (~405-408) — replace the `#if APPSTORE … #endif` around the iCloud Label with:

```swift
        if AppCapabilities.isAppStore {
            Label { Text("iCloud", bundle: .module) } icon: { Image(systemName: "icloud") }
                .tag(SettingsSection.icloud)
        }
```

b) `sidebarEntries` (~440-442) — replace the `#if APPSTORE … #endif` around the append with:

```swift
        if AppCapabilities.isAppStore {
            items.append(.init(section: .icloud, title: String(localized: "iCloud", bundle: .module), kind: nil, systemImage: "icloud"))
        }
```

c) iOS combined form (~662-664) — replace the `#if APPSTORE … #endif` around the link with:

```swift
        if AppCapabilities.isAppStore {
            iosSettingsLink("iCloud", systemImage: "icloud") { ICloudSettingsView() }
        }
```

(`structuredSidebar` and the iOS list are `@ViewBuilder`s, so a plain `if` is valid there. `sidebarEntries` is an array-building computed property, so the `if` wraps the `items.append`.)

- [ ] **Step 2: Convert the Whisparr age gate**

In `ServiceFields.swift` `enableBinding` (~27-34), replace the `#if APPSTORE … #endif` with:

```swift
                if AppCapabilities.isAppStore,
                   newValue, kind == .whisparr,
                   let ageConfirmed = ageConfirmedBinding, !ageConfirmed.wrappedValue {
                    showAgeGate = true
                    return
                }
```

- [ ] **Step 3: Build the package**

Run: `cd Packages/ArrCore && swift build`
Expected: SUCCESS.

- [ ] **Step 4: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Views/SettingsView.swift Packages/ArrCore/Sources/ArrCore/Views/ServiceFields.swift
git commit -m "feat(ui): runtime-gate iCloud tab + Whisparr age gate via AppCapabilities"
```

---

## Task 6: App-target wiring — call `configure` before `ConfigStore.shared`

**Files:**
- Modify: `ArrBarr/ArrBarrApp.swift`
- Modify: `ArrBarriOS/ArrBarriOSApp.swift`
- Modify: `ArrBarrWidgets/ArrBarrWidgets.swift`

No unit tests (app targets). Verified by the app build in Task 7.

- [ ] **Step 1: macOS — set the flag as the FIRST stored property**

`ArrBarrApp` has `@ObservedObject private var configStore = ConfigStore.shared` (a stored
property that initializes before `init()`), so `init()` is too late for the secret-store choice.
Add a capability-init stored property as the **first** member of the struct, before
`@NSApplicationDelegateAdaptor`:

```swift
@main
struct ArrBarrApp: App {
    // Runs before every other stored property (incl. `configStore`), so the
    // App Store flag is set before `ConfigStore.shared` first chooses its
    // secret store. `#if APPSTORE` is live here (app target), unlike in ArrCore.
    #if APPSTORE
    private let _capabilities: Void = { AppCapabilities.configure(isAppStore: true) }()
    #endif

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var queueVM = QueueViewModel.shared
    @ObservedObject private var configStore = ConfigStore.shared

    init() {
        #if APPSTORE
        StoreManager.shared.use(StoreKitBackend())
        KVSyncCoordinator.startShared()
        #endif
    }
```

(Import is already `import ArrCore`. Keep the existing `init()` body.)

- [ ] **Step 2: iOS — set the flag first in `init()`**

`ArrBarriOSApp` has no stored property touching `ConfigStore.shared` (only `@Environment(\.scenePhase)`), so the first line of `init()` is early enough. Add it as the first statement:

```swift
    init() {
        #if APPSTORE
        AppCapabilities.configure(isAppStore: true)
        #endif
        UNUserNotificationCenter.current().delegate = ArrNotificationDelegate.shared
        NotificationActions.register()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #if APPSTORE
        StoreManager.shared.use(StoreKitBackend())
        KVSyncCoordinator.startShared()
        #endif
    }
```

- [ ] **Step 3: Widget — set the flag in the bundle init**

`ArrBarrWidgetsBundle` (a `WidgetBundle`) reads secrets via `WidgetDataStore.serviceConfig` at
timeline time. Add an `init()` that configures before any timeline runs. In
`ArrBarrWidgets/ArrBarrWidgets.swift`, add to `struct ArrBarrWidgetsBundle`:

```swift
    init() {
        #if APPSTORE
        AppCapabilities.configure(isAppStore: true)
        #endif
    }
```

(Confirm `import ArrCore` is present in that file; add it if not. The widget target defines `APPSTORE` in its Release-AppStore config.)

- [ ] **Step 4: Build the macOS app (Debug)**

Run: `xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build`
Expected: BUILD SUCCEEDED. (Debug is non-APPSTORE, so `configure` isn't called and the tab stays hidden — correct. This step only confirms compilation.)

- [ ] **Step 5: Commit**

```bash
git add ArrBarr/ArrBarrApp.swift ArrBarriOS/ArrBarriOSApp.swift ArrBarrWidgets/ArrBarrWidgets.swift
git commit -m "feat(app): inject AppCapabilities.isAppStore at launch (macOS/iOS/widget)"
```

---

## Task 7: Full verification

**Files:** none (verification only).

- [ ] **Step 1: Full package test suites**

Run: `cd Packages/ArrCore && swift test` then `cd ../ArrMCPServer && swift test`
Expected: all PASS.

- [ ] **Step 2: Build macOS Debug + relaunch**

Run:
```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```
Expected: BUILD SUCCEEDED, app runs. Tab hidden (Debug = not App Store) — correct.

- [ ] **Step 3: Verify the tab appears under the App Store flag**

Confirm the runtime gating works by building Release-AppStore (no signing) and checking the
app launches with the flag set. Because secrets now activate the Keychain path under
`isAppStore && keychainSharingAvailable`, run this build in DEMO mode to avoid touching the
real profile's secrets:

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Release-AppStore -derivedDataPath build-appstore CODE_SIGNING_ALLOWED=NO build
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build-appstore/Build/Products/Release-AppStore/ArrBarr.app --args --demo
```
Expected: BUILD SUCCEEDED; app launches; the iCloud tab is now visible in Settings. (Unsigned →
no entitlement → `keychainSharingAvailable` is false → secrets stay in UserDefaults; demo suite
isolates the profile. The migration's verify-before-blank also protects against loss.)

Note: the running app cannot fully sync (no entitlement), but the tab, toggle, and status render.

- [ ] **Step 4: Final commit (if any verification fixups were needed)**

```bash
git add -A
git commit -m "chore: appstore runtime capability verification fixups"
```

(Skip if nothing changed. Stage explicit paths — do NOT sweep unrelated working-tree changes.)

---

## Self-Review Notes

- **Spec coverage:** AppCapabilities + probe (Task 1), safe migration (Task 2), baseQuery +
  secret-store + widget gating (Task 3), toggle sink (Task 4), tab + age gate (Task 5),
  app/widget wiring with init-ordering fix (Task 6), verification incl. tab-visible proof (Task 7).
- **Init ordering:** macOS uses a first-stored-property initializer (runs before `configStore`);
  iOS/widget set it before any `ConfigStore.shared`/`serviceConfig` access. Called out explicitly.
- **Data-loss safety:** secret-store activation gated on the live probe; migration verifies a
  read-back before blanking and only sets the done-flag when all secrets verified.
- **Type consistency:** `AppCapabilities.isAppStore`, `configure(isAppStore:)`,
  `keychainSharingAvailable`, `keychainProbeOverride`, `resetProbeForTesting` are defined once
  (Task 1) and referenced consistently in Tasks 3-6. `KeychainSecretStore.service`/`accessGroup`
  reused by the probe.
- **Paywall stays compile-time** in the app target — untouched.
