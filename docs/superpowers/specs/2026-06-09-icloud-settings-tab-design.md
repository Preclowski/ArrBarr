# iCloud Settings Tab — Design

**Date:** 2026-06-09
**Status:** Approved (pending implementation)
**Related:** `docs/superpowers/specs/2026-06-08-icloud-sync-security-model-design.md` (the underlying sync model)

## Goal

Add an **iCloud** tab to Settings where the user can:

- Toggle iCloud sync on/off (currently sync is always-on under `#if APPSTORE`, with no user control).
- See sync status: iCloud account availability, last sync time, and last error.
- See a static explanation of *what* gets synced.

The tab exists **only in App Store builds** (`#if APPSTORE`). In GitHub/OSS builds the
iCloud sync code is not compiled in, so the tab is hidden entirely.

## Scope decisions

- **Full on/off toggle** — a real device-local switch, default ON, that starts/stops sync.
- **Hard secret semantics** — turning sync OFF stops replicating *both* preferences (KVS)
  *and* secrets (iCloud Keychain) to other devices. Existing Keychain items are rewritten
  to non-synchronizable on OFF and back to synchronizable on ON. Secrets remain encrypted
  at rest in the local Keychain in both states; only cross-device replication is toggled.
- **Status surfaced:** account availability, last sync date, last error, and a static
  "what syncs" list — all four.
- **Non-App-Store builds:** tab hidden completely (no "App Store only" placeholder).

## Architecture (overview)

Single owner for sync runtime state is `KVSyncCoordinator`. A new device-local flag in
`ConfigStore` drives both the preference coordinator and the secret re-sync. A new isolated
view (`ICloudSettingsView`) binds to both.

```
ConfigStore.iCloudSyncEnabled (device-local flag, default true)
        │  on change (Combine sink)
        ├──> KVSyncCoordinator.shared?.setEnabled(_:)      // preferences (KVS)
        └──> secretStore.reapplySyncAttribute(for: .syncable)  // secrets (Keychain)

KVSyncCoordinator (ObservableObject)  ── @Published lastSyncDate / lastError / isRunning
        │                                  accountAvailable (FileManager ubiquityIdentityToken)
        └──> ICloudSettingsView binds for status display
```

## Components

### 1. `ConfigStore` — the enable flag

- `@Published public var iCloudSyncEnabled: Bool = true`.
- Static key `ArrBarr.iCloudSyncEnabled`.
- Read in `load()` with the existing `object(forKey:) != nil ? bool : true` default pattern.
- **Not** added to `SyncedKeys.all` — it is per-device, so it must never mirror through KVS.
- Combine sink (mirroring the existing `$prop.dropFirst().sink { ... }` pattern):
  1. Persist to `defaults`.
  2. `KVSyncCoordinator.shared?.setEnabled(val)`.
  3. `secretStore.reapplySyncAttribute(for: SecretKey.syncable)`.

### 2. `SecretStore` / `KeychainSecretStore` — hard secret toggle

The current `baseQuery` hardcodes `synchronizable = key.synced` (under APPSTORE) at write
time. To make the toggle effective it must also factor a runtime flag, and existing items
must be rewritten when the flag flips.

- **`SecretKey.syncable: [SecretKey]`** — the full list of keys that may sync:
  for every `ServiceKind.allCases` → `.apiKey(for:)` + `.password(for:)`, plus `.openAIKey`
  and `.tmdbKey`. `.mcpBearer` is excluded (it is `deviceOnly` / never synced).
- **Runtime flag in `baseQuery`:**
  `synchronizable = key.synced && syncEnabled` (still wrapped in the existing `#if APPSTORE`
  block; non-APPSTORE stays `false`). `syncEnabled` comes from an injectable provider
  `KeychainSecretStore.syncEnabledProvider: @Sendable () -> Bool`, defaulting to reading the
  device-local `ArrBarr.iCloudSyncEnabled` key from the group UserDefaults (default `true`
  when unset). Tests override the provider so `baseQuery` gating is assertable without
  touching UserDefaults.
- **`reapplySyncAttribute(for keys: [SecretKey])`** (extension on `SecretStore`): for each
  key, if `read(key)` returns a value, call `set(value, for: key)` again. Because `set`
  deletes then re-adds using `baseQuery` (which now reads the just-updated flag), the item
  is rewritten with the correct `synchronizable` attribute. No-op for keys with no value.
- Ordering in the ConfigStore sink: persist the flag **first**, then `reapplySyncAttribute`,
  so the provider sees the new value.

### 3. `KVSyncCoordinator` — observable status + stop/setEnabled

- Conform to `ObservableObject` (already `@MainActor`).
- `@Published private(set) var lastSyncDate: Date?`
- `@Published private(set) var lastError: String?`
- `@Published private(set) var isRunning: Bool = false`
- `var accountAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil }`
- `func stop()` — removes observers, clears `observers`, sets `isRunning = false`.
- `func setEnabled(_ enabled: Bool)` — idempotent; `enabled` ? `start()` : `stop()`.
- `start()` sets `isRunning = true`; on each successful `pushAllToKV` / `applyFromKV`
  stamp `lastSyncDate` and clear `lastError`. (Timestamp is set from `Date()` at runtime —
  this is app code, not a workflow script, so `Date()` is fine here.)
- `static var shared` exposed (already retained via `_shared`) so the UI can observe it.
- `startShared()` only calls `start()` when the device-local flag is `true`; otherwise it
  creates/retains the coordinator with `isRunning = false` so the UI still has an instance.

### 4. `ICloudSettingsView.swift` (new file)

Isolated pane (SettingsView is already large). Observes `ConfigStore.shared` and
`KVSyncCoordinator.shared`.

- **Toggle** "Sync with iCloud" → `ConfigStore.iCloudSyncEnabled`.
- **Status section:**
  - iCloud account availability — warning row when `accountAvailable == false`
    ("Sign in to iCloud in System Settings to enable sync").
  - "Last sync: <relative time>" from `lastSyncDate` (or "Never").
  - Error row (red) when `lastError != nil`.
  - Status rows are dimmed/hidden when the toggle is off.
- **"What syncs" section** (static, educational): service configurations; passwords & API
  keys (via iCloud Keychain, encrypted); notification settings; AI/assistant settings;
  layout & visibility preferences. Note that device-local settings (intervals, appearance,
  MCP) do **not** sync.

### 5. `SettingsView` — wire the tab

- macOS: add `case icloud` to `SettingsSection`; add a sidebar row (following the `.mcp`
  pattern), a `navTitle(for:)` case, an `icloudPane` property returning `ICloudSettingsView`,
  and a `detailPane(for:)` case.
- iOS: add an `iosSettingsLink("iCloud", systemImage: "icloud")` → `ICloudSettingsView`.
- **All of the above wrapped in `#if APPSTORE`** so the tab does not exist in OSS builds.

### 6. Localization

All user-facing strings added to `ArrCore/Resources/Localizable.xcstrings` (en/de/es/fr/pl),
used via `Text("…", bundle: .module)` / `String(localized:bundle:.module)`. No inline literals.

## Data flow

1. User flips the toggle in `ICloudSettingsView`.
2. `ConfigStore.iCloudSyncEnabled` setter fires → persists → sink runs.
3. Sink calls `KVSyncCoordinator.shared?.setEnabled(value)` → start/stop preference sync.
4. Sink calls `secretStore.reapplySyncAttribute(for: .syncable)` → rewrites Keychain items
   to the new `synchronizable` state.
5. Status `@Published` props on the coordinator update the view as pushes/pulls happen.

## Error handling

- KVS push/pull failures captured into `lastError` (string), surfaced in the status row;
  cleared on the next successful sync.
- No iCloud account → `accountAvailable == false` → warning row; sync simply no-ops at the
  KVS layer (NSUbiquitousKeyValueStore tolerates this) and Keychain rewrites stay local.
- Keychain rewrite failures already logged by `KeychainSecretStore` via `os.Logger`; the
  bulk reapply is best-effort and does not block the toggle.

## Testing

- `SecretKey.syncable` contains exactly the expected keys and excludes `.mcpBearer`.
- `baseQuery` `synchronizable` follows `key.synced && syncEnabled` for both provider states
  (override the provider in tests).
- `reapplySyncAttribute` re-writes only keys that currently hold a value (InMemory store).
- `KVSyncCoordinator.setEnabled(false)` stops outbound pushes (no further `kv.set` after a
  `defaults` change); `setEnabled(true)` resumes and stamps `lastSyncDate`.
- `iCloudSyncEnabled` is absent from `SyncedKeys.all`.
- `accountAvailable` reflects a stubbed identity token (inject via seam if needed, else
  treat as integration-only).

## Out of scope (YAGNI)

- Manual "Sync Now" button (toggle + automatic reconcile is enough for now).
- Per-key / per-category sync selection.
- Conflict-resolution UI (last-writer-wins stays as in the underlying sync model).
- Migrating the entitlements/project config (tracked separately in the sync-model plan).
