# Replace Dead `#if APPSTORE` Package Gating with Runtime Capability Injection — Design

**Date:** 2026-06-09
**Status:** Approved (pending implementation)
**Branch:** `feat/icloud-settings-tab`
**Related:** `2026-06-09-icloud-settings-tab-design.md`, `2026-06-08-icloud-sync-security-model-design.md`

## Problem

`APPSTORE` is defined only in the Xcode **app targets'** `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
(Release-AppStore config). Xcode does **not** propagate compilation conditions to local
SwiftPM packages. Verified from the Release-AppStore build manifest: the `ArrCore` package
target compiles with **zero** `-D` flags. Therefore **every `#if APPSTORE` inside
`Packages/ArrCore` (and `ArrMCPServer`) is dead** — the `#else` branch always compiles, in
all configurations including Release-AppStore.

Consequences in the shipping App Store build (from the audit):
- `makeDefaultSecretStore` always returns `UserDefaultsSecretStore` — secrets never use the
  Keychain; the entire iCloud-Keychain secret-sync model is inert.
- `baseQuery` forces `synchronizable = false` and never adds the shared access group.
- The iCloud sync toggle sink is dead (flag persists but never starts/stops sync live).
- The iCloud Settings tab never appears (its 3 entry points are gated).
- The Whisparr 18+ age gate is never enforced (compliance-relevant).
- The `#if APPSTORE` branches in tests never compile → that behavior is untested.

Working today: the paywall (gated in app-target/`Shared/`), and KVS **preference** sync
(`KVSyncCoordinator.startShared` is called from the live app-target gate and its body is
ungated).

## Why runtime injection (not fixing the compile flag)

SwiftPM only knows `debug`/`release`, not the custom `Release-AppStore` Xcode config, so
`Package.swift` cannot define `APPSTORE` for only that config (`.when(.release)` would also
enable it for the OSS Release build). Xcode forwards neither `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
nor `OTHER_SWIFT_FLAGS` to local packages. Env-var tricks are fragile and break
`swift build`/`swift test`/CI. A runtime value set by the app target (which *does* know
`APPSTORE`) works across every build path, matches the existing `StoreManager`/`StoreKitBackend`
injection pattern, and makes both branches testable. The paywall stays compile-time gated in
the app target so StoreKit is not linked into OSS builds.

## Architecture

### `AppCapabilities` (new, in ArrCore)

```swift
public enum AppCapabilities {
    /// True in App Store builds. Set once by the app target at launch via
    /// `configure(isAppStore:)` under `#if APPSTORE`. Default false (OSS/dev).
    /// Read everywhere the old `#if APPSTORE` package gating lived.
    public nonisolated(unsafe) static private(set) var isAppStore = false

    /// Set the build flavor. MUST be called before the first `ConfigStore.shared`
    /// access (the secret-store choice happens in ConfigStore.init). Idempotent.
    public static func configure(isAppStore: Bool) { self.isAppStore = isAppStore }

    /// Whether the shared keychain-access-group is actually usable at runtime
    /// (entitlement present AND provisioned). Probed once and cached. Only probes
    /// when `isAppStore` is true — OSS/dev never probes, so it never prompts and
    /// always resolves to UserDefaults storage. The probe does a throwaway
    /// SecItemAdd+copy+delete in the shared access group; `errSecMissingEntitlement`
    /// (or any add failure) → false.
    public static var keychainSharingAvailable: Bool { /* cached probe */ }
}
```

`nonisolated(unsafe) static var` mirrors the existing `KeychainSecretStore.syncEnabledProvider`
precedent (a mutable static set once at launch). It is written once before any concurrent read.

The probe is cached (compute-once) to avoid repeated Keychain calls. Cache via a
`static let _probe: Bool = { ... }()` computed lazily on first read, guarded by `isAppStore`.

### Conversion of each dead gate (`#if APPSTORE` → runtime)

| Site | New condition |
|---|---|
| `ConfigStore.makeDefaultSecretStore` | `AppCapabilities.isAppStore && AppCapabilities.keychainSharingAvailable` → `KeychainSecretStore`, else `UserDefaultsSecretStore` |
| `ConfigStore.init` migrate-vs-recover | same condition → `migrateSecretsToKeychain` else `recoverSecretsFromKeychainIfNeeded` |
| `ConfigStore` iCloud toggle sink | `if AppCapabilities.isAppStore { setEnabled + reapply }` |
| `SecretStore.baseQuery` synchronizable | `let synchronizable = AppCapabilities.isAppStore && key.synced && syncEnabledProvider()` |
| `SecretStore.baseQuery` access group + data-protection | added when `AppCapabilities.isAppStore` |
| `WidgetDataStore.serviceConfig` secret store | same Keychain-vs-UserDefaults condition |
| `SettingsView` 3 entry points (mac row, search entry, iOS link) | `if AppCapabilities.isAppStore` |
| `ServiceFields` Whisparr 18+ age gate | `if AppCapabilities.isAppStore` |

### Prerequisite bug fix — safe migration

`migrateSecretsToKeychain` currently writes to the secret store then **unconditionally blanks**
the UserDefaults copy, even if the Keychain write silently failed (no entitlement) → data loss.

Fix: after `secrets.set(value, for: key)`, **read it back** (`secrets.read(key) == value`).
Only blank the UserDefaults copy when the read-back verifies. If any secret fails verification,
leave all UserDefaults copies intact and do **not** set `secretsMigratedKey`, so migration
retries on a later launch (e.g. once entitlements are provisioned). This makes activation safe
on a device whose entitlements aren't live yet.

### App-target wiring

Under `#if APPSTORE`, as the **first** statement of app launch (before any `ConfigStore.shared`
access), call `AppCapabilities.configure(isAppStore: true)`:
- macOS: `ArrBarrApp` `init()` (or the earliest point before the MenuBarExtra scene/StateObjects).
- iOS: `ArrBarriOSApp` `init()`.
- Widget: the WidgetKit `@main` entry (the bundle's `init`), since the widget is a separate
  process that also reads secrets via `WidgetDataStore`.

The existing app-target `#if APPSTORE` blocks (StoreManager injection, `startShared()`) stay;
the `configure` call is added ahead of them.

Init-ordering is the critical risk: the secret-store choice runs in `ConfigStore.init` at first
`ConfigStore.shared` access. The plan must verify the `configure` call precedes that access on
every target (macOS menu-bar scene, iOS WindowGroup, widget timeline).

## Testing

The big win: gates become runtime, so both branches run under `swift test` (today the
`#if APPSTORE` test branches never compile).

- `AppCapabilities.isAppStore` defaults false; `configure(isAppStore:)` flips it; tests reset it.
- `baseQuery`: with `isAppStore` true, `synchronizable == key.synced && provider()` and the
  access group is present; with false, `synchronizable == false` and no access group. Both
  asserted directly (replacing the old `#if APPSTORE`/`#else` test split).
- `makeDefaultSecretStore`: returns `UserDefaultsSecretStore` when `!isAppStore`. The Keychain
  branch is gated behind the live probe; test the decision via an injectable probe seam
  (`AppCapabilities` exposes an overridable `keychainProbe` closure for tests).
- **Migration safety**: with a secret store whose `set` does nothing (write fails), the
  UserDefaults copies are left intact and `secretsMigratedKey` stays false. Use an injectable
  failing store.
- Whisparr age-gate gating logic, if extractable from the view, otherwise rely on build.
- `SecretStoreSuite` and any `AppCapabilities`-touching tests run `.serialized` (shared static).

## Risks & mitigations

- **Secret loss on a device without provisioned entitlements** → mitigated by (a) the probe
  (Keychain only activates when the access group truly works) and (b) verify-before-blank
  migration (never blanks unless the Keychain holds the value).
- **Init ordering** → verified per target in the plan; `configure` is the first launch statement.
- **APPSTORE leaking into OSS** → impossible: OSS app targets don't define `APPSTORE`, so they
  never call `configure(isAppStore: true)`; the flag stays false; the probe never runs.
- **Widget process** → configured in the widget `@main`; reads secrets consistently with the app.

## Out of scope

- Developer-portal capability provisioning (iCloud + keychain sharing for the App ID) — cannot
  be done from the repo; the probe degrades gracefully until it's live.
- The actual on-device iCloud sync verification (needs provisioned entitlements + two devices).
- Building/installing to the phone — a follow-up after this lands (Debug iOS build; the tab
  shows via the flag set in the iOS app target; secrets stay UserDefaults until the probe passes).
