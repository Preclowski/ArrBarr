# iCloud Sync + Security-Model Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sync ArrBarr settings between macOS and iOS via iCloud (KVS for preferences, iCloud Keychain for secrets), gated behind the `APPSTORE` build flag, while moving all secrets into the Keychain and removing dead migration code.

**Architecture:** Two storage tiers. (1) Secrets resolve through a new `SecretStore` protocol with a single `KeychainSecretStore` impl; `kSecAttrSynchronizable` is enabled only under `#if APPSTORE` (and never for the device-bound MCP token). (2) Preferences stay in UserDefaults; under `#if APPSTORE` a `KVSyncCoordinator` mirrors an explicit allowlist of `ArrBarr.*` keys to/from `NSUbiquitousKeyValueStore`. `ConfigStore` keeps `ServiceConfig` whole in memory; only its persistence layer splits secret vs non-secret fields.

**Tech Stack:** Swift 6, SwiftUI, Combine, Security framework (Keychain), `NSUbiquitousKeyValueStore`, Swift Testing (`import Testing`). Package: `Packages/ArrCore`.

**Spec:** `docs/superpowers/specs/2026-06-08-icloud-sync-security-model-design.md`

**Test command (used throughout):**
```bash
swift test --package-path Packages/ArrCore
```
Single test by name:
```bash
swift test --package-path Packages/ArrCore --filter <testFuncName>
```

**Build/relaunch after UI-affecting changes (per CLAUDE.md):**
```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build
pkill -x ArrBarr 2>/dev/null; sleep 0.5 && open build/Build/Products/Debug/ArrBarr.app
```

---

## File Structure

**Create:**
- `Packages/ArrCore/Sources/ArrCore/Services/SecretStore.swift` — `SecretStore` protocol, `SecretKey` value type, `KeychainSecretStore`, `InMemorySecretStore` (test fake).
- `Packages/ArrCore/Sources/ArrCore/Services/SyncedKeys.swift` — the explicit pref-sync allowlist.
- `Packages/ArrCore/Sources/ArrCore/Services/KVSyncCoordinator.swift` — KVS ↔ UserDefaults mirror (compiled only `#if APPSTORE`).
- `ArrBarr/ArrBarr-AppStore.entitlements` — macOS App Store entitlements (iCloud KVS + keychain group).
- `ArrBarriOS/ArrBarriOS-AppStore.entitlements` — iOS App Store entitlements.
- `Packages/ArrCore/Tests/ArrCoreTests/SecretStoreTests.swift`
- `Packages/ArrCore/Tests/ArrCoreTests/SecretMigrationTests.swift`
- `Packages/ArrCore/Tests/ArrCoreTests/KVSyncCoordinatorTests.swift`
- `Packages/ArrCore/Tests/ArrCoreTests/SyncedKeysTests.swift`

**Modify:**
- `Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift` — inject `SecretStore`; route secrets through it; add one-shot secret migration; add `reloadFromDefaults()` seam; remove legacy keychain migration.
- `Packages/ArrCore/Sources/ArrCore/Services/MCPTokenStore.swift` — reimplement over `SecretStore`.
- `ArrBarr/ArrBarrApp.swift` / `ArrBarr/AppDelegate.swift` — start `KVSyncCoordinator` under `#if APPSTORE`.
- `ArrBarriOS/ArrBarriOSApp.swift` — start `KVSyncCoordinator` under `#if APPSTORE`.
- `ArrBarr.xcodeproj/project.pbxproj` — point `Release-AppStore` configs at the new entitlements files.
- `Packages/ArrCore/Tests/ArrCoreTests/ConfigStoreTests.swift` — inject a shared `InMemorySecretStore` where secrets round-trip.

**Delete:**
- `Packages/ArrCore/Sources/ArrCore/Services/KeychainStore.swift` (`LegacyKeychain`) — after migration code referencing it is removed.

---

## Task 1: `SecretStore` protocol, value type, Keychain impl, in-memory fake

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Services/SecretStore.swift`
- Test: `Packages/ArrCore/Tests/ArrCoreTests/SecretStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

`Packages/ArrCore/Tests/ArrCoreTests/SecretStoreTests.swift`:
```swift
import Testing
import Foundation
@testable import ArrCore

@Suite("SecretStore")
struct SecretStoreSuite {

    @Test("InMemory fake round-trips and deletes")
    func inMemoryRoundTrips() {
        let store = InMemorySecretStore()
        let key = SecretKey.apiKey(for: .radarr)
        #expect(store.read(key) == nil)
        store.set("secret-123", for: key)
        #expect(store.read(key) == "secret-123")
        store.delete(key)
        #expect(store.read(key) == nil)
    }

    @Test("MCP bearer key is device-only and never synced")
    func mcpKeyIsDeviceOnly() {
        let key = SecretKey.mcpBearer
        #expect(key.deviceOnly == true)
        #expect(key.synced == false)
    }

    @Test("Service/openai/tmdb keys request sync and are not device-only")
    func syncedKeysFlags() {
        for key in [SecretKey.apiKey(for: .sonarr),
                    SecretKey.password(for: .qbittorrent),
                    SecretKey.openAIKey,
                    SecretKey.tmdbKey] {
            #expect(key.synced == true)
            #expect(key.deviceOnly == false)
        }
    }

    @Test("Keychain query honors synchronizable only under APPSTORE")
    func keychainSynchronizableGating() {
        let synced = KeychainSecretStore.baseQuery(for: .openAIKey)
        let mcp = KeychainSecretStore.baseQuery(for: .mcpBearer)
        #if APPSTORE
        #expect(synced[kSecAttrSynchronizable as String] as? Bool == true)
        #else
        #expect(synced[kSecAttrSynchronizable as String] as? Bool == false)
        #endif
        // MCP token never syncs, regardless of build.
        #expect(mcp[kSecAttrSynchronizable as String] as? Bool == false)
    }

    @Test("Keychain accessibility: MCP device-only, synced after-first-unlock")
    func keychainAccessibility() {
        let synced = KeychainSecretStore.baseQuery(for: .tmdbKey)
        let mcp = KeychainSecretStore.baseQuery(for: .mcpBearer)
        #expect(synced[kSecAttrAccessible as String] as? String
                == (kSecAttrAccessibleAfterFirstUnlock as String))
        #expect(mcp[kSecAttrAccessible as String] as? String
                == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String))
    }

    @Test("Real Keychain round-trips the MCP token")
    func keychainRoundTrips() {
        let store = KeychainSecretStore()
        let key = SecretKey.mcpBearer
        store.set("kc-token", for: key)
        #expect(store.read(key) == "kc-token")
        store.delete(key)
        #expect(store.read(key) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/ArrCore --filter SecretStore`
Expected: FAIL — `SecretStore` / `SecretKey` / `KeychainSecretStore` / `InMemorySecretStore` undefined.

- [ ] **Step 3: Write the implementation**

`Packages/ArrCore/Sources/ArrCore/Services/SecretStore.swift`:
```swift
import Foundation
import Security

/// A single secret (one Keychain generic-password account) plus the policy for
/// how it is stored: whether it should sync via iCloud Keychain (`synced`, only
/// honored in App Store builds) and whether it is pinned to this device
/// (`deviceOnly`).
public struct SecretKey: Sendable, Equatable {
    public let account: String
    /// Request iCloud Keychain sync. Only takes effect under `#if APPSTORE`;
    /// non-App-Store builds always store locally.
    public let synced: Bool
    /// `true` → `WhenUnlockedThisDeviceOnly`; `false` → `AfterFirstUnlock`
    /// (needed for background / widget reads on iOS).
    public let deviceOnly: Bool

    public static func apiKey(for kind: ServiceKind) -> SecretKey {
        SecretKey(account: "secret.\(kind.rawValue).apiKey", synced: true, deviceOnly: false)
    }
    public static func password(for kind: ServiceKind) -> SecretKey {
        SecretKey(account: "secret.\(kind.rawValue).password", synced: true, deviceOnly: false)
    }
    public static let openAIKey = SecretKey(account: "secret.openai.apiKey", synced: true, deviceOnly: false)
    public static let tmdbKey   = SecretKey(account: "secret.tmdb.apiKey", synced: true, deviceOnly: false)
    /// The MCP server bearer token gates a server bound to one machine, so it is
    /// never synced and stays device-only.
    public static let mcpBearer = SecretKey(account: "secret.mcp.bearer", synced: false, deviceOnly: true)
}

public protocol SecretStore: Sendable {
    func read(_ key: SecretKey) -> String?
    func set(_ value: String, for key: SecretKey)
    func delete(_ key: SecretKey)
}

/// Keychain-backed `SecretStore`. All items share the `service` namespace; the
/// `SecretKey.account` distinguishes them.
public struct KeychainSecretStore: SecretStore {
    static let service = "com.preclowski.ArrBarr"

    public init() {}

    /// The identifying query fields + storage policy for a key. Exposed so tests
    /// can assert the synchronizable/accessibility gating without touching the
    /// real Keychain.
    public static func baseQuery(for key: SecretKey) -> [String: Any] {
        #if APPSTORE
        let synchronizable = key.synced
        #else
        let synchronizable = false
        #endif
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
            kSecAttrSynchronizable as String: synchronizable,
            kSecAttrAccessible as String: key.deviceOnly
                ? (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
                : (kSecAttrAccessibleAfterFirstUnlock as String),
        ]
    }

    public func read(_ key: SecretKey) -> String? {
        var q = Self.baseQuery(for: key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ value: String, for key: SecretKey) {
        delete(key)
        var q = Self.baseQuery(for: key)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    public func delete(_ key: SecretKey) {
        SecItemDelete(Self.baseQuery(for: key) as CFDictionary)
    }
}

/// In-memory `SecretStore` for tests — never touches the real Keychain.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    public init() {}
    public func read(_ key: SecretKey) -> String? {
        lock.lock(); defer { lock.unlock() }; return values[key.account]
    }
    public func set(_ value: String, for key: SecretKey) {
        lock.lock(); defer { lock.unlock() }; values[key.account] = value
    }
    public func delete(_ key: SecretKey) {
        lock.lock(); defer { lock.unlock() }; values[key.account] = nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Packages/ArrCore --filter SecretStore`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/SecretStore.swift \
        Packages/ArrCore/Tests/ArrCoreTests/SecretStoreTests.swift
git commit -m "feat(secrets): add SecretStore (Keychain + in-memory) with APPSTORE-gated sync"
```

---

## Task 2: Reimplement `MCPTokenStore` over `SecretStore`

`MCPTokenStore`'s public API (`read`/`set`/`delete`/`generate`) stays so existing
call sites (`ConfigStore`, `MCPSettingsPane`) are untouched; the implementation
delegates to `KeychainSecretStore` + `SecretKey.mcpBearer`.

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/MCPTokenStore.swift`
- Test: `Packages/ArrCore/Tests/ArrCoreTests/MCPTokenStoreTests.swift` (unchanged — must still pass)

- [ ] **Step 1: Replace the implementation**

`Packages/ArrCore/Sources/ArrCore/Services/MCPTokenStore.swift`:
```swift
import Foundation
import Security

/// Keychain-backed storage for the MCP server's bearer token. Device-only,
/// never synced. Thin wrapper over `SecretStore` so there is one Keychain code
/// path; kept as a named type because several call sites read it as a static.
public enum MCPTokenStore {
    private static let store = KeychainSecretStore()

    public static func read() -> String? { store.read(.mcpBearer) }
    public static func set(_ token: String) { store.set(token, for: .mcpBearer) }
    public static func delete() { store.delete(.mcpBearer) }

    /// Generate a URL-safe random token (base64url, no padding).
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
```

- [ ] **Step 2: Run the existing MCP tests**

Run: `swift test --package-path Packages/ArrCore --filter tokenStore`
Expected: PASS (round-trip + url-safe token tests still green).

- [ ] **Step 3: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/MCPTokenStore.swift
git commit -m "refactor(mcp): back MCPTokenStore with the unified SecretStore"
```

---

## Task 3: Route ConfigStore secrets through an injected `SecretStore`

`ServiceConfig` stays whole in memory. On save, secret fields are written to
`SecretStore` and blanked in the persisted JSON; on load, they are read back from
`SecretStore` and merged into the in-memory value. Same for `openai.apiKey` and
`tmdbApiKey`.

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift`
- Modify: `Packages/ArrCore/Tests/ArrCoreTests/ConfigStoreTests.swift`

- [ ] **Step 1: Update the secret-round-trip test to inject a shared SecretStore**

In `Packages/ArrCore/Tests/ArrCoreTests/ConfigStoreTests.swift`, replace the
`saveAndLoad` test body so both stores share one secret backend:
```swift
    @Test("Service config round-trips through persistence (including secrets)")
    @MainActor func saveAndLoad() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let secrets = InMemorySecretStore()
        let config = ServiceConfig(
            enabled: true, baseURL: "http://localhost:7878",
            apiKey: "test-api-key", username: "u", password: "test-password"
        )

        let store = ConfigStore(defaults: defaults, secrets: secrets)
        store.update(.radarr, with: config)

        let reloaded = ConfigStore(defaults: defaults, secrets: secrets)
        #expect(reloaded.radarr == config)
    }

    @Test("Secrets are not persisted as plaintext in UserDefaults")
    @MainActor func secretsNotInDefaults() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let secrets = InMemorySecretStore()
        let store = ConfigStore(defaults: defaults, secrets: secrets)
        store.update(.radarr, with: ServiceConfig(
            enabled: true, baseURL: "http://h:7878",
            apiKey: "SENSITIVE-KEY", username: "u", password: "SENSITIVE-PW"))

        let blob = defaults.data(forKey: "ArrBarr.config.radarr")!
        let raw = String(data: blob, encoding: .utf8)!
        #expect(!raw.contains("SENSITIVE-KEY"))
        #expect(!raw.contains("SENSITIVE-PW"))
        #expect(secrets.read(.apiKey(for: .radarr)) == "SENSITIVE-KEY")
        #expect(secrets.read(.password(for: .radarr)) == "SENSITIVE-PW")
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path Packages/ArrCore --filter saveAndLoad`
Expected: FAIL — `ConfigStore(defaults:secrets:)` does not exist.

- [ ] **Step 3: Add the `secrets` dependency and split persistence**

In `ConfigStore.swift`:

(a) Add a stored property + update `init` (near `private var defaults`):
```swift
    private var defaults: UserDefaults
    private let secrets: SecretStore
    private var cancellables: Set<AnyCancellable> = []
```
```swift
    public init(defaults: UserDefaults = ConfigStore.resolveDefaults(),
                secrets: SecretStore = KeychainSecretStore()) {
        self.defaults = defaults
        self.secrets = secrets
        Self.migrateSecretsToKeychain(defaults: defaults, secrets: secrets)
        applyValues(from: defaults)
        setupSinks()
    }
```
(Remove the old `keychainMigrationDoneKey` block here — see Task 5.)

(b) Replace `load`/`save` for services so secrets route through `secrets`. Change
the instance `save` and add secret merge on load. Replace the existing private
`save(_:_:)` and the `load` call sites:
```swift
    private func save(_ kind: ServiceKind, _ config: ServiceConfig) {
        secrets.set(config.apiKey, for: .apiKey(for: kind))
        secrets.set(config.password, for: .password(for: kind))
        var stripped = config
        stripped.apiKey = ""
        stripped.password = ""
        if let data = try? JSONEncoder().encode(stripped) {
            defaults.set(data, forKey: Self.key(kind))
        }
    }

    /// Load a service config from `defaults` and merge its secrets back in from
    /// the secret store.
    private func loadService(_ kind: ServiceKind) -> ServiceConfig {
        var cfg = Self.load(kind, from: defaults)   // non-secret fields (secrets blank)
        cfg.apiKey = secrets.read(.apiKey(for: kind)) ?? cfg.apiKey
        cfg.password = secrets.read(.password(for: kind)) ?? cfg.password
        return cfg
    }
```
In `applyValues(from:)`, replace each `Self.load(.radarr, from: defaults)` with
`loadService(.radarr)` (and likewise for every `ServiceKind`).

(c) Route OpenAI + TMDB secrets. In `applyValues`, after decoding `openai`:
```swift
        if let data = defaults.data(forKey: Self.openaiConfigKey),
           let cfg = try? JSONDecoder().decode(OpenAIConfig.self, from: data) {
            self.openai = cfg
        } else {
            self.openai = .empty
        }
        self.openai.apiKey = secrets.read(.openAIKey) ?? self.openai.apiKey
        self.tmdbApiKey = secrets.read(.tmdbKey) ?? (defaults.string(forKey: Self.tmdbApiKeyKey) ?? "")
```
(Remove the now-superseded `self.tmdbApiKey = defaults.string(...)` line.)

In `setupSinks`, change the `$openai` and `$tmdbApiKey` sinks to split secrets:
```swift
        $openai.dropFirst().sink { [weak self] cfg in
            guard let self else { return }
            self.secrets.set(cfg.apiKey, for: .openAIKey)
            var stripped = cfg
            stripped.apiKey = ""
            if let data = try? JSONEncoder().encode(stripped) {
                self.defaults.set(data, forKey: Self.openaiConfigKey)
            }
        }.store(in: &cancellables)
        $tmdbApiKey.dropFirst().sink { [weak self] val in
            self?.secrets.set(val, for: .tmdbKey)
            self?.defaults.removeObject(forKey: Self.tmdbApiKeyKey)
        }.store(in: &cancellables)
```

(d) `OpenAIConfig.apiKey` must be excluded from the persisted JSON or simply
blanked before encoding (done above). Confirm `OpenAIConfig` is a struct we can
copy-and-blank; if `apiKey` is `let`, change it to `var`. (Check
`Packages/ArrCore/Sources/ArrCore/Models/` for `OpenAIConfig`.)

- [ ] **Step 4: Run the ConfigStore tests**

Run: `swift test --package-path Packages/ArrCore --filter ConfigStore`
Expected: PASS, including the new `secretsNotInDefaults` test.

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift \
        Packages/ArrCore/Tests/ArrCoreTests/ConfigStoreTests.swift
git commit -m "refactor(config): route service/openai/tmdb secrets through SecretStore"
```

---

## Task 4: One-shot migration of existing plaintext secrets into the Keychain

Existing installs have secrets inside the UserDefaults JSON. On first launch of
the new build, copy them into `SecretStore` and blank the JSON. Idempotent,
guarded by a flag.

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift`
- Test: `Packages/ArrCore/Tests/ArrCoreTests/SecretMigrationTests.swift`

- [ ] **Step 1: Write the failing tests**

`Packages/ArrCore/Tests/ArrCoreTests/SecretMigrationTests.swift`:
```swift
import Testing
import Foundation
@testable import ArrCore

@Suite("SecretMigration")
struct SecretMigrationSuite {

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "test.secretmig.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("Plaintext secrets in defaults move to the secret store and are blanked")
    @MainActor func migratesAndBlanks() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        // Seed a legacy plaintext config blob.
        let legacy = ServiceConfig(enabled: true, baseURL: "http://h:7878",
                                   apiKey: "LEGACY-KEY", username: "u", password: "LEGACY-PW")
        defaults.set(try! JSONEncoder().encode(legacy), forKey: "ArrBarr.config.radarr")

        let secrets = InMemorySecretStore()
        ConfigStore.migrateSecretsToKeychain(defaults: defaults, secrets: secrets)

        #expect(secrets.read(.apiKey(for: .radarr)) == "LEGACY-KEY")
        #expect(secrets.read(.password(for: .radarr)) == "LEGACY-PW")

        let blob = defaults.data(forKey: "ArrBarr.config.radarr")!
        let raw = String(data: blob, encoding: .utf8)!
        #expect(!raw.contains("LEGACY-KEY"))
        #expect(!raw.contains("LEGACY-PW"))
    }

    @Test("Migration is idempotent and a no-op on a secret-less store")
    @MainActor func idempotentNoOp() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let secrets = InMemorySecretStore()
        ConfigStore.migrateSecretsToKeychain(defaults: defaults, secrets: secrets)
        ConfigStore.migrateSecretsToKeychain(defaults: defaults, secrets: secrets)
        #expect(secrets.read(.apiKey(for: .radarr)) == nil)
        #expect(defaults.bool(forKey: "ArrBarr.secretsMigratedToKeychain") == true)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path Packages/ArrCore --filter SecretMigration`
Expected: FAIL — `migrateSecretsToKeychain` undefined.

- [ ] **Step 3: Implement the migration**

In `ConfigStore.swift`, add the flag key alongside the other keys:
```swift
    private static let secretsMigratedKey = "ArrBarr.secretsMigratedToKeychain"
```
Add the static migration (nonisolated, like the existing migration helpers):
```swift
    /// One-shot: pull secrets out of legacy plaintext config/openai/tmdb values
    /// in `defaults` into `secrets`, then blank them in `defaults`. Idempotent.
    static func migrateSecretsToKeychain(defaults: UserDefaults, secrets: SecretStore) {
        guard !defaults.bool(forKey: secretsMigratedKey) else { return }

        for kind in ServiceKind.allCases {
            guard let data = defaults.data(forKey: key(kind)),
                  var cfg = try? JSONDecoder().decode(ServiceConfig.self, from: data)
            else { continue }
            var changed = false
            if !cfg.apiKey.isEmpty {
                secrets.set(cfg.apiKey, for: .apiKey(for: kind)); cfg.apiKey = ""; changed = true
            }
            if !cfg.password.isEmpty {
                secrets.set(cfg.password, for: .password(for: kind)); cfg.password = ""; changed = true
            }
            if changed, let updated = try? JSONEncoder().encode(cfg) {
                defaults.set(updated, forKey: key(kind))
            }
        }

        if let data = defaults.data(forKey: openaiConfigKey),
           var cfg = try? JSONDecoder().decode(OpenAIConfig.self, from: data),
           !cfg.apiKey.isEmpty {
            secrets.set(cfg.apiKey, for: .openAIKey)
            cfg.apiKey = ""
            if let updated = try? JSONEncoder().encode(cfg) {
                defaults.set(updated, forKey: openaiConfigKey)
            }
        }

        if let tmdb = defaults.string(forKey: tmdbApiKeyKey), !tmdb.isEmpty {
            secrets.set(tmdb, for: .tmdbKey)
            defaults.removeObject(forKey: tmdbApiKeyKey)
        }

        defaults.set(true, forKey: secretsMigratedKey)
    }
```
**Wire it into `init`:** Task 3 intentionally did NOT call this (the function did
not exist yet). Add the call to `ConfigStore.init`, right after `self.secrets =
secrets` and before `applyValues(from: defaults)`:
```swift
        Self.migrateSecretsToKeychain(defaults: defaults, secrets: secrets)
```
Note: `key(_:)`, `openaiConfigKey`, `tmdbApiKeyKey` are already `static`; if any
is currently `private static`, widen to `nonisolated private static` (the helper
is nonisolated). Make `migrateSecretsToKeychain` `nonisolated static`.

- [ ] **Step 4: Run all tests**

Run: `swift test --package-path Packages/ArrCore --filter SecretMigration`
Then full suite: `swift test --package-path Packages/ArrCore`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift \
        Packages/ArrCore/Tests/ArrCoreTests/SecretMigrationTests.swift
git commit -m "feat(config): one-shot migration of plaintext secrets into Keychain"
```

---

## Task 5: Remove `LegacyKeychain` and the dead keychain→defaults migration

**Files:**
- Delete: `Packages/ArrCore/Sources/ArrCore/Services/KeychainStore.swift`
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift`
- Modify: `Packages/ArrCore/Tests/ArrCoreTests/ConfigStoreTests.swift` (remove the
  "Migration flag prevents repeated keychain probing" test, which asserts the
  removed behavior)

- [ ] **Step 1: Delete the legacy code**

```bash
git rm Packages/ArrCore/Sources/ArrCore/Services/KeychainStore.swift
```
In `ConfigStore.swift`, remove:
- `private static let keychainMigrationDoneKey = ...`
- the entire `migrateLegacyKeychainSecrets(defaults:)` method
- any remaining reference to it (the old `init` block was already replaced in
  Task 3 Step 3a; confirm no `keychainMigrationDoneKey` or `LegacyKeychain`
  references remain).

- [ ] **Step 2: Remove the obsolete test**

In `ConfigStoreTests.swift`, delete the `@Test("Migration flag prevents repeated keychain probing")` function (it references `keychainMigrationDoneKey` behavior that no longer exists).

- [ ] **Step 3: Verify no dangling references**

Run:
```bash
grep -rn "LegacyKeychain\|keychainMigrationDoneKey\|migrateLegacyKeychainSecrets" Packages/ArrCore
```
Expected: no matches.

- [ ] **Step 4: Run the full suite**

Run: `swift test --package-path Packages/ArrCore`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A Packages/ArrCore
git commit -m "chore(secrets): remove dead LegacyKeychain migration (0.6.x window closed)"
```

---

## Task 6: `SyncedKeys` allowlist

The single source of truth for which UserDefaults keys cross devices.

**Files:**
- Create: `Packages/ArrCore/Sources/ArrCore/Services/SyncedKeys.swift`
- Test: `Packages/ArrCore/Tests/ArrCoreTests/SyncedKeysTests.swift`

- [ ] **Step 1: Write the failing tests**

`Packages/ArrCore/Tests/ArrCoreTests/SyncedKeysTests.swift`:
```swift
import Testing
@testable import ArrCore

@Suite("SyncedKeys")
struct SyncedKeysSuite {
    @Test("Includes cross-platform prefs and all service configs")
    func includesExpected() {
        #expect(SyncedKeys.all.contains("ArrBarr.config.radarr"))
        #expect(SyncedKeys.all.contains("ArrBarr.arrOrder"))
        #expect(SyncedKeys.all.contains("ArrBarr.whisparrAgeConfirmed"))
        #expect(SyncedKeys.all.contains("ArrBarr.openai"))
    }

    @Test("Excludes platform-specific, MCP, and one-shot keys")
    func excludesLocal() {
        for k in ["ArrBarr.foregroundInterval", "ArrBarr.backgroundInterval",
                  "ArrBarr.fontScale", "ArrBarr.launchAtLogin", "ArrBarr.appLanguage",
                  "ArrBarr.appearance", "ArrBarr.showIndexerIssues",
                  "ArrBarr.mcpEnabled", "ArrBarr.mcpHostPort",
                  "ArrBarr.welcomeSeenVersion", "ArrBarr.groupMigrationDone",
                  "ArrBarr.secretsMigratedToKeychain"] {
            #expect(!SyncedKeys.all.contains(k))
        }
    }

    @Test("isSynced matches membership")
    func isSyncedMatches() {
        #expect(SyncedKeys.isSynced("ArrBarr.arrOrder"))
        #expect(!SyncedKeys.isSynced("ArrBarr.fontScale"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path Packages/ArrCore --filter SyncedKeys`
Expected: FAIL — `SyncedKeys` undefined.

- [ ] **Step 3: Implement**

`Packages/ArrCore/Sources/ArrCore/Services/SyncedKeys.swift`:
```swift
import Foundation

/// The explicit opt-in allowlist of UserDefaults keys mirrored across devices
/// via iCloud KVS. Secrets are NOT here — they sync via iCloud Keychain. Keys
/// not listed (platform-specific prefs, MCP server, one-shot/migration flags)
/// stay device-local.
public enum SyncedKeys {
    public static let all: Set<String> = {
        var keys: Set<String> = [
            "ArrBarr.notifyRadarr", "ArrBarr.notifySonarr", "ArrBarr.notifyLidarr",
            "ArrBarr.notificationSoundName",
            "ArrBarr.blurWhisparrPosters", "ArrBarr.whisparrAgeConfirmed",
            "ArrBarr.aiKnowsAboutWhisparr",
            "ArrBarr.arrOrder", "ArrBarr.showTonight", "ArrBarr.showNeedsYou",
            "ArrBarr.aiEnabled", "ArrBarr.chatProvider", "ArrBarr.openai",
            "ArrBarr.collapsedArrs",
        ]
        for kind in ServiceKind.allCases {
            keys.insert("ArrBarr.config.\(kind.rawValue)")
        }
        return keys
    }()

    public static func isSynced(_ key: String) -> Bool { all.contains(key) }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path Packages/ArrCore --filter SyncedKeys`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/SyncedKeys.swift \
        Packages/ArrCore/Tests/ArrCoreTests/SyncedKeysTests.swift
git commit -m "feat(sync): add SyncedKeys allowlist (single source of truth)"
```

---

## Task 7: `ConfigStore.reloadFromDefaults()` seam + `KVSyncCoordinator`

Add a public reload seam, then the coordinator that mirrors allowlisted keys
between UserDefaults and `NSUbiquitousKeyValueStore`, with a loop guard.

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift`
- Create: `Packages/ArrCore/Sources/ArrCore/Services/KVSyncCoordinator.swift`
- Test: `Packages/ArrCore/Tests/ArrCoreTests/KVSyncCoordinatorTests.swift`

- [ ] **Step 1: Add the reload seam to ConfigStore**

In `ConfigStore.swift`, add (uses the existing sink-teardown + `applyValues`
pattern that `useStore` relies on, so reload assignments don't re-fire writes):
```swift
    /// Reload all published values from the current backing store without
    /// re-firing persistence writes. Used by `KVSyncCoordinator` after it applies
    /// inbound iCloud changes into UserDefaults.
    public func reloadFromDefaults() {
        cancellables.removeAll()
        applyValues(from: defaults)
        setupSinks()
    }
```

- [ ] **Step 2: Write the failing coordinator tests**

The coordinator is testable via a protocol seam over the KVS so tests don't need
a real iCloud account.

`Packages/ArrCore/Tests/ArrCoreTests/KVSyncCoordinatorTests.swift`:
```swift
import Testing
import Foundation
@testable import ArrCore

/// In-memory stand-in for NSUbiquitousKeyValueStore.
final class FakeKVStore: KeyValueSyncing, @unchecked Sendable {
    var storage: [String: Any] = [:]
    var synchronizeCalled = false
    func object(forKey key: String) -> Any? { storage[key] }
    func set(_ value: Any?, forKey key: String) { storage[key] = value }
    func dictionaryRepresentation() -> [String: Any] { storage }
    @discardableResult func synchronize() -> Bool { synchronizeCalled = true; return true }
}

@Suite("KVSyncCoordinator")
struct KVSyncCoordinatorSuite {

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "test.kvsync.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("Outbound: pushing copies only allowlisted keys to KVS")
    @MainActor func outboundAllowlist() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        defaults.set(["needsyou", "radarr"], forKey: "ArrBarr.arrOrder") // synced
        defaults.set(5.0, forKey: "ArrBarr.foregroundInterval")          // local

        let kv = FakeKVStore()
        let coord = KVSyncCoordinator(defaults: defaults, kv: kv, reload: {})
        coord.pushAllToKV()

        #expect(kv.object(forKey: "ArrBarr.arrOrder") != nil)
        #expect(kv.object(forKey: "ArrBarr.foregroundInterval") == nil)
    }

    @Test("Inbound: applying writes allowlisted KVS keys into defaults and reloads")
    @MainActor func inboundApplies() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let kv = FakeKVStore()
        kv.storage["ArrBarr.showTonight"] = false       // synced
        kv.storage["ArrBarr.fontScale"] = 2.0           // NOT synced — must be ignored

        var reloadCount = 0
        let coord = KVSyncCoordinator(defaults: defaults, kv: kv, reload: { reloadCount += 1 })
        coord.applyFromKV(keys: ["ArrBarr.showTonight", "ArrBarr.fontScale"])

        #expect(defaults.object(forKey: "ArrBarr.showTonight") as? Bool == false)
        #expect(defaults.object(forKey: "ArrBarr.fontScale") == nil)
        #expect(reloadCount == 1)
    }

    @Test("Loop guard: a local push does not re-enter on the inbound path")
    @MainActor func loopGuard() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let kv = FakeKVStore()
        var reloadCount = 0
        let coord = KVSyncCoordinator(defaults: defaults, kv: kv, reload: { reloadCount += 1 })

        defaults.set(true, forKey: "ArrBarr.showNeedsYou")
        coord.observeDefault("ArrBarr.showNeedsYou") // simulate outbound observer firing
        // While applying inbound, outbound observers must be suppressed:
        coord.applyFromKV(keys: ["ArrBarr.showNeedsYou"])
        #expect(reloadCount == 1) // exactly one reload, no echo storm
    }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `swift test --package-path Packages/ArrCore --filter KVSyncCoordinator`
Expected: FAIL — `KeyValueSyncing` / `KVSyncCoordinator` undefined.

- [ ] **Step 4: Implement the coordinator**

`Packages/ArrCore/Sources/ArrCore/Services/KVSyncCoordinator.swift`:
```swift
import Foundation
import os

/// Abstraction over `NSUbiquitousKeyValueStore` so the coordinator is testable
/// without a real iCloud account.
public protocol KeyValueSyncing: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func dictionaryRepresentation() -> [String: Any]
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: KeyValueSyncing {}

/// Mirrors the `SyncedKeys` allowlist between UserDefaults (local source of
/// truth) and iCloud KVS. Compiled in all builds for testability; only started
/// (`start()`) by the app under `#if APPSTORE`.
@MainActor
public final class KVSyncCoordinator {
    private let defaults: UserDefaults
    private let kv: KeyValueSyncing
    private let reload: () -> Void
    private var isApplyingRemote = false
    private let logger = Logger(category: "KVSync")

    public init(defaults: UserDefaults, kv: KeyValueSyncing, reload: @escaping () -> Void) {
        self.defaults = defaults
        self.kv = kv
        self.reload = reload
    }

    /// Begin observing inbound KVS changes and outbound UserDefaults changes,
    /// and do an initial two-way reconcile (pull remote, then push local).
    public func start() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(kvChanged(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: kv as AnyObject)
        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification, object: defaults)
        applyFromKV(keys: Array(SyncedKeys.all))
        pushAllToKV()
        kv.synchronize()
    }

    /// Copy every allowlisted key present in UserDefaults into KVS.
    public func pushAllToKV() {
        for key in SyncedKeys.all {
            if let value = defaults.object(forKey: key) {
                kv.set(value, forKey: key)
            }
        }
    }

    /// Apply the given inbound KVS keys (allowlist-filtered) into UserDefaults,
    /// then trigger one reload. Outbound observation is suppressed meanwhile.
    public func applyFromKV(keys: [String]) {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        for key in keys where SyncedKeys.isSynced(key) {
            if let value = kv.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
        reload()
    }

    /// Test seam: simulate the outbound observer for one key.
    public func observeDefault(_ key: String) {
        guard !isApplyingRemote, SyncedKeys.isSynced(key) else { return }
        if let value = defaults.object(forKey: key) { kv.set(value, forKey: key) }
    }

    @objc private func kvChanged(_ note: Notification) {
        let changed = (note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String])
            ?? Array(SyncedKeys.all)
        applyFromKV(keys: changed)
    }

    @objc private func defaultsChanged() {
        guard !isApplyingRemote else { return }
        pushAllToKV()
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
```
Note: `applyFromKV` calls `reload()` exactly once per invocation, matching the
`inboundApplies` / `loopGuard` expectations (one reload, no echo storm).

- [ ] **Step 5: Run to verify pass**

Run: `swift test --package-path Packages/ArrCore --filter KVSyncCoordinator`
Then full suite: `swift test --package-path Packages/ArrCore`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/ArrCore/Sources/ArrCore/Services/KVSyncCoordinator.swift \
        Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift \
        Packages/ArrCore/Tests/ArrCoreTests/KVSyncCoordinatorTests.swift
git commit -m "feat(sync): add KVSyncCoordinator (KVS <-> UserDefaults mirror) + reload seam"
```

---

## Task 8: Wire the coordinator into app launch (APPSTORE only)

Start the coordinator from both app entry points, gated by `#if APPSTORE`, using
the real `NSUbiquitousKeyValueStore` and the shared `ConfigStore`.

**Files:**
- Modify: `ArrBarr/AppDelegate.swift` (macOS) — or `ArrBarr/ArrBarrApp.swift` near the existing `#if APPSTORE` block
- Modify: `ArrBarriOS/ArrBarriOSApp.swift` (iOS) — near the existing `#if APPSTORE` block

- [ ] **Step 1: Add a start helper on the coordinator**

In `KVSyncCoordinator.swift`, add a convenience that binds to the shared store:
```swift
extension KVSyncCoordinator {
    /// Build a coordinator wired to the shared `ConfigStore` and the live iCloud
    /// KVS. Hold the returned instance for the app's lifetime.
    @MainActor
    public static func live() -> KVSyncCoordinator {
        let store = ConfigStore.shared
        let coord = KVSyncCoordinator(
            defaults: ConfigStore.resolveDefaults(),
            kv: NSUbiquitousKeyValueStore.default,
            reload: { store.reloadFromDefaults() })
        coord.start()
        return coord
    }
}
```

- [ ] **Step 2: Start it on macOS**

In `ArrBarr/ArrBarrApp.swift`, inside the existing `#if APPSTORE` block (where
StoreKit is wired — see `ArrBarrApp.swift:19`), retain a coordinator. If the app
uses an `AppDelegate`, store it there instead so it lives for the process:
```swift
        #if APPSTORE
        // ... existing StoreKit wiring ...
        self.kvSync = KVSyncCoordinator.live()
        #endif
```
Add the stored property next to other app/delegate state:
```swift
        #if APPSTORE
        private var kvSync: KVSyncCoordinator?
        #endif
```

- [ ] **Step 3: Start it on iOS**

In `ArrBarriOS/ArrBarriOSApp.swift`, inside the existing `#if APPSTORE` block
(`ArrBarriOSApp.swift:20`), do the same:
```swift
        #if APPSTORE
        // ... existing wiring ...
        self.kvSync = KVSyncCoordinator.live()
        #endif
```
with a matching `#if APPSTORE private var kvSync: KVSyncCoordinator? #endif`.

- [ ] **Step 4: Build both targets**

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug -derivedDataPath build build
```
Expected: BUILD SUCCEEDED (Debug has no `APPSTORE`, so the new code is excluded —
this confirms no accidental non-APPSTORE references).

Then verify the APPSTORE config compiles:
```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Release-AppStore -derivedDataPath build build
```
Expected: BUILD SUCCEEDED (entitlements wiring lands in Task 9; if signing blocks
a full archive, a compile of the sources still validates the `#if APPSTORE` code).

- [ ] **Step 5: Commit**

```bash
git add ArrBarr/ArrBarrApp.swift ArrBarriOS/ArrBarriOSApp.swift \
        Packages/ArrCore/Sources/ArrCore/Services/KVSyncCoordinator.swift
git commit -m "feat(sync): start KVSyncCoordinator at launch under APPSTORE"
```

---

## Task 9: Entitlements + project wiring (Release-AppStore only)

Give only the App Store build the iCloud KVS + keychain-group entitlements.

**Files:**
- Create: `ArrBarr/ArrBarr-AppStore.entitlements`
- Create: `ArrBarriOS/ArrBarriOS-AppStore.entitlements`
- Modify: `ArrBarr.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create the macOS App Store entitlements**

`ArrBarr/ArrBarr-AppStore.entitlements` (current sandbox/network keys + iCloud KVS
+ keychain group; keep the App Group already used elsewhere):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<true/>
	<key>com.apple.developer.ubiquity-kvstore-identifier</key>
	<string>$(TeamIdentifierPrefix)$(CFBundleIdentifier)</string>
	<key>keychain-access-groups</key>
	<array>
		<string>$(AppIdentifierPrefix)com.preclowski.ArrBarr.shared</string>
	</array>
</dict>
</plist>
```
The keychain group is the SHARED group `…ArrBarr.shared` (NOT the bundle id) so the
app and the iOS widget extension read the same Keychain items — see Task 11.

- [ ] **Step 2: Create the iOS App Store entitlements**

`ArrBarriOS/ArrBarriOS-AppStore.entitlements` (keep the existing App Group, add
iCloud KVS + keychain group):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.com.preclowski.ArrBarr</string>
	</array>
	<key>com.apple.developer.ubiquity-kvstore-identifier</key>
	<string>$(TeamIdentifierPrefix)$(CFBundleIdentifier)</string>
	<key>keychain-access-groups</key>
	<array>
		<string>$(AppIdentifierPrefix)com.preclowski.ArrBarr.shared</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 2b: Add the shared keychain group to the iOS widget entitlements**

The widget (`ArrBarrWidgets`, iOS-only, always signed with the team) must share
the same Keychain group to read secrets. In `ArrBarrWidgets/ArrBarrWidgets.entitlements`
add (alongside the existing App Group):
```xml
	<key>keychain-access-groups</key>
	<array>
		<string>$(AppIdentifierPrefix)com.preclowski.ArrBarr.shared</string>
	</array>
```
The widget needs neither iCloud KVS nor the synced-pref machinery — only the
shared Keychain group. (The widget's entitlements file is shared across its build
configs; the team is present in all of them, so this is safe to add unconditionally.)

- [ ] **Step 3: Point the Release-AppStore configs at the new files**

In `ArrBarr.xcodeproj/project.pbxproj`, find the three `Release-AppStore`
`XCBuildConfiguration` blocks (macOS app + iOS app; the widget config does not
need iCloud and stays as-is). Change `CODE_SIGN_ENTITLEMENTS`:
- macOS `Release-AppStore`: `ArrBarr/ArrBarr.entitlements` → `ArrBarr/ArrBarr-AppStore.entitlements`
- iOS `Release-AppStore`: `ArrBarriOS/ArrBarriOS.entitlements` → `ArrBarriOS/ArrBarriOS-AppStore.entitlements`

Leave the `Debug` and `Release` configs pointing at the original (non-iCloud)
entitlements files.

- [ ] **Step 4: Verify the project still parses and the App Store config builds**

```bash
xcodebuild -project ArrBarr.xcodeproj -list
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Release-AppStore -derivedDataPath build build
```
Expected: project lists configs without error; App Store config compiles. (A full
signed archive needs the developer cert/provisioning with the iCloud + Keychain
Sharing capabilities enabled in the App ID — note for the human running it.)

- [ ] **Step 5: Commit**

```bash
git add ArrBarr/ArrBarr-AppStore.entitlements \
        ArrBarriOS/ArrBarriOS-AppStore.entitlements \
        ArrBarr.xcodeproj/project.pbxproj
git commit -m "build(sync): iCloud KVS + keychain-group entitlements for Release-AppStore"
```

- [ ] **Step 6: Manual capability note (human action, not code)**

In the Apple Developer portal, enable **iCloud (Key-Value storage)** and
**Keychain Sharing** capabilities on the App IDs `com.preclowski.ArrBarr` and
`com.preclowski.ArrBarr.iOS`, then regenerate the App Store provisioning
profiles. Record this in the PR description.

---

## Task 10 (ops, separable): Stable self-signed signing for the github macOS build

Not required for the App Store sync feature; required so that moving secrets into
the Keychain does not reintroduce per-release password prompts on the github
(ad-hoc) macOS build. Can land after the code.

- [ ] **Step 1: Generate a stable self-signed code-signing certificate**

Create a self-signed "Code Signing" certificate once (Keychain Access → Certificate
Assistant, or `openssl` + `security import`), export it as a `.p12`, and store it
as a CI secret. This identity is reused across all releases (unlike ad-hoc `-`).

- [ ] **Step 2: Switch the github build configs to the stable identity**

In `ArrBarr.xcodeproj/project.pbxproj`, for the macOS app `Debug` and `Release`
configs, change `CODE_SIGN_IDENTITY = "-";` to the stable certificate's common
name (e.g. `CODE_SIGN_IDENTITY = "ArrBarr Self-Signed";`). Keep
`CODE_SIGN_STYLE = Manual` for these so CI controls the identity.

- [ ] **Step 3: Import the cert in CI before building**

In the release workflow, before `xcodebuild`:
```bash
security create-keychain -p "$KC_PW" build.keychain
security import cert.p12 -k build.keychain -P "$P12_PW" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PW" build.keychain
security list-keychains -s build.keychain
```

- [ ] **Step 4: Verify across two builds locally**

Build twice with the stable identity, run, set an API key, relaunch, and confirm
no Keychain password prompt appears on the second build (the ACL is stable).

- [ ] **Step 5: Commit**

```bash
git add ArrBarr.xcodeproj/project.pbxproj .github/
git commit -m "build(ci): stable self-signed signing for github macOS build"
```

---

## Task 11: Widget secret access via shared Keychain group

Task 3 moved service secrets out of the App Group UserDefaults JSON into the
Keychain. The iOS widget (`ArrBarrWidgets`, iOS-only, always APPSTORE-signed)
reads configs via `WidgetDataStore.serviceConfig` → `ConfigStore.decodeServiceConfig`,
which now returns secret-blank configs → the widget can't authenticate. Fix: under
`#if APPSTORE`, route Keychain items through a shared access group both the app and
widget declare (Task 9), and merge secrets into the widget's config read. Also use
the data-protection keychain so access groups + iCloud Keychain behave uniformly on
macOS and iOS.

**Files:**
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/SecretStore.swift`
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/WidgetDataStore.swift`
- Modify: `Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift` (empty-secret guard)
- Test: `Packages/ArrCore/Tests/ArrCoreTests/SecretStoreTests.swift`, `WidgetDeepLinkTests.swift` (or a new `WidgetSecretMergeTests.swift`)

- [ ] **Step 1: Add shared-access-group + data-protection to `KeychainSecretStore.baseQuery`**

Under `#if APPSTORE` only (non-APPSTORE keeps the per-app default group so local/
github builds keep working standalone). Add a constant and extend `baseQuery`:
```swift
    public static let service = "com.preclowski.ArrBarr"
    /// Shared Keychain access group (team-prefixed) so the app and its iOS widget
    /// extension read the same items. Only applied under `#if APPSTORE`, where the
    /// `keychain-access-groups` entitlement (Task 9) is present. The team prefix is
    /// fixed for this account.
    public static let accessGroup = "9M6DR2Z85Y.com.preclowski.ArrBarr.shared"
```
In `baseQuery(for:)`, after building the dictionary, under `#if APPSTORE` add:
```swift
        #if APPSTORE
        q[kSecAttrAccessGroup as String] = Self.accessGroup
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
```
(`q` being the dictionary the function returns; restructure `baseQuery` to build a
`var q` then return it.) `matchQuery` already copies `baseQuery`, so it inherits both.

- [ ] **Step 2: Test the gating**

Add to `SecretStoreTests`:
```swift
    @Test("Access group + data-protection keychain set only under APPSTORE")
    func keychainAccessGroupGating() {
        let q = KeychainSecretStore.baseQuery(for: .apiKey(for: .radarr))
        #if APPSTORE
        #expect(q[kSecAttrAccessGroup as String] as? String == KeychainSecretStore.accessGroup)
        #expect(q[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #else
        #expect(q[kSecAttrAccessGroup as String] == nil)
        #endif
    }
```
Run `swift test --package-path Packages/ArrCore --filter SecretStore` → PASS (under
`swift test` APPSTORE is undefined, so the `#else` branch is asserted).

- [ ] **Step 3: Merge secrets in `WidgetDataStore.serviceConfig`**

```swift
    public static func serviceConfig(_ kind: ServiceKind) -> ServiceConfig {
        guard let d = groupDefaults() else { return .empty }
        var cfg = ConfigStore.decodeServiceConfig(kind, from: d)
        let secrets = KeychainSecretStore()
        cfg.apiKey = secrets.read(.apiKey(for: kind)) ?? cfg.apiKey
        cfg.password = secrets.read(.password(for: kind)) ?? cfg.password
        return cfg
    }
```
This makes the widget read the same Keychain items as the app (shared group under
APPSTORE). In local non-APPSTORE iOS dev builds the group differs, so the widget
reads blanks and shows the unconfigured state — acceptable for dev.

- [ ] **Step 4: Empty-secret guard in ConfigStore (Minor cleanup from Task 3 review)**

In `ConfigStore.save(_:_:)` and the `$openai` / `$tmdbApiKey` sinks, don't write
empty strings to the Keychain — set when non-empty, delete when empty. Example for
`save`:
```swift
        setOrDelete(config.apiKey, for: .apiKey(for: kind))
        setOrDelete(config.password, for: .password(for: kind))
```
with a small private helper:
```swift
    private func setOrDelete(_ value: String, for key: SecretKey) {
        if value.isEmpty { secrets.delete(key) } else { secrets.set(value, for: key) }
    }
```
Apply the same helper in the `$openai` (`.openAIKey`) and `$tmdbApiKey` (`.tmdbKey`)
sinks. Re-run the full suite — `secretsNotInDefaults` and `saveAndLoad` must still pass.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(widget): shared keychain group so the iOS widget reads secrets; guard empty secrets"
```

- [ ] **Step 6: End-to-end note (human/CI)**

Full widget validation requires a signed APPSTORE build on a device (the shared
access group only resolves with the team-signed entitlement). Verify on-device that
the widget still renders library counts after configuring a service. Record in the PR.

---

## Self-Review Notes

- **Spec coverage:** SecretStore (T1), MCP fold-in (T2), ConfigStore secret split
  (T3), one-shot migration (T4), dead-code removal (T5), allowlist (T6), KVS
  coordinator + reload seam (T7), launch wiring (T8), entitlements/gating (T9),
  stable signing (T10). All spec sections map to a task.
- **MCP token device-only:** enforced in `SecretKey.mcpBearer` (T1) and asserted.
- **`whisparrAgeConfirmed` synced / intervals local:** encoded in `SyncedKeys`
  (T6) and asserted in `SyncedKeysTests`.
- **Type consistency:** `SecretKey`, `SecretStore`, `KeychainSecretStore.baseQuery`,
  `InMemorySecretStore`, `migrateSecretsToKeychain`, `reloadFromDefaults`,
  `KeyValueSyncing`, `KVSyncCoordinator.{start,pushAllToKV,applyFromKV}` are
  defined once and referenced consistently.
- **Known pre-req to verify during T3:** confirm `OpenAIConfig.apiKey` is a `var`
  (needed to blank before encoding); if `let`, widen it in T3 Step 3d.
