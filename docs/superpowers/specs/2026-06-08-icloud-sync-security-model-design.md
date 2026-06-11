# iCloud Sync + Security-Model Cleanup (APPSTORE-gated)

**Date:** 2026-06-08
**Status:** Design approved, pending spec review

## Goal

Sync settings between the macOS and iOS apps via iCloud, gated behind the
existing `APPSTORE` build flag — builds without a developer account get no
sync. Take the opportunity to fix the secret-storage model properly
("koszernie") and remove dead code so the topic is closed.

Non-goal: no CloudKit, no custom sync server, no per-record conflict UI.

## Decisions (locked)

| Question | Decision |
| --- | --- |
| Sync scope | Service configs + cross-platform preferences (not platform-specific / one-shot keys) |
| Secret storage model | **C** — Keychain everywhere; `synchronizable` only under `APPSTORE` |
| github macOS signing | Stable self-signed cert in CI (so Keychain ACLs survive across releases → no password prompts) |
| MCP bearer token | Device-only, never synced (`ThisDeviceOnly`, `synchronizable = false`) |
| `whisparrAgeConfirmed` | **Synced** (confirm once across devices) |
| Polling intervals (`foreground/backgroundInterval`) | **Local** (per-device battery/network; iOS overrides anyway) |

## Background (current state)

- `ConfigStore` (`Packages/ArrCore/Sources/ArrCore/Services/ConfigStore.swift`)
  is the single `@MainActor ObservableObject` source of truth, shared by both
  platforms via the `ArrCore` package.
- Persistence: everything in `UserDefaults`, keys prefixed `ArrBarr.*`, in the
  App Group suite `group.com.preclowski.ArrBarr` (falls back to `.standard`).
  Each `@Published` has a Combine sink that writes to defaults.
- Secrets (`apiKey`, `password` per service) live as plaintext JSON inside the
  persisted `ServiceConfig`. They were moved out of Keychain in 0.6.2 because
  ad-hoc signing changed the signature every release → Keychain prompted for the
  login password on every launch (see `KeychainStore.swift` header comment).
- `MCPTokenStore` is the one secret already in Keychain (`WhenUnlockedThisDeviceOnly`).
- `LegacyKeychain` + `migrateLegacyKeychainSecrets` + `keychainMigrationDoneKey`
  exist only to migrate 0.6.0/0.6.1 secrets back into UserDefaults — dead in 2026.
- `APPSTORE` is set by a real, separate build configuration `Release-AppStore`
  (per-target), which also selects the entitlements file. macOS Debug/Release
  use `CODE_SIGN_IDENTITY = "-"`, `DEVELOPMENT_TEAM = ""` (the github build).
- iOS only ever ships as an `APPSTORE` build (can't sideload unsigned), so the
  non-APPSTORE divergence is macOS-only.

## Architecture — two storage tiers

### Tier 1: Secrets — `SecretStore` (single Keychain implementation)

A protocol `SecretStore` with one production impl `KeychainSecretStore`, plus an
in-memory fake for tests.

- Keys: `secret.<service>.apiKey`, `secret.<service>.password`,
  `secret.openai.apiKey`, `secret.tmdb.apiKey`, `secret.mcp.bearer`.
- `kSecAttrSynchronizable`: `true` under `#if APPSTORE` for synced secrets;
  **always `false` for `secret.mcp.bearer`** (device-bound server).
- `kSecAttrAccessible`: `AfterFirstUnlock` for synced secrets (background/widget
  reads on iOS); `WhenUnlockedThisDeviceOnly` for the MCP token.
- In-memory `ServiceConfig` stays whole — only the persistence layer splits:
  non-secret fields (`enabled`, `baseURL`, `username`) stay in the UserDefaults
  JSON; `apiKey`/`password` resolve through `SecretStore`. Same split for the
  OpenAI config (`openai.apiKey` → store) and `tmdbApiKey`.
- `MCPTokenStore` is folded into `SecretStore` (kept as a thin alias if call
  sites are cheaper to leave, otherwise removed).

### Tier 2: Preferences — UserDefaults + `KVSyncCoordinator` (APPSTORE only)

- UserDefaults remains the local source of truth and the write path is
  unchanged (ConfigStore sinks still write `ArrBarr.*` keys).
- `KVSyncCoordinator`, compiled only under `#if APPSTORE`:
  - **Inbound:** observes `NSUbiquitousKeyValueStore.didChangeExternallyNotification`,
    copies changed allowlisted keys → UserDefaults, then triggers a
    `ConfigStore` reload (reuse the sink-teardown + `applyValues` pattern that
    `useStore` already implements, so the reload doesn't re-fire writes).
  - **Outbound:** observes local writes to allowlisted keys → pushes them to KVS.
  - **Loop guard:** an `isApplyingRemote` flag suppresses outbound pushes while
    applying an inbound change (mirrors how `useStore` tears down sinks).
- `SyncedKeys`: an explicit **opt-in allowlist** — the single source of truth for
  what crosses devices.

### Synced-keys allowlist

**Synced (preferences via KVS):** per-service `enabled` / `baseURL` / `username`,
`notifyRadarr` / `notifySonarr` / `notifyLidarr`, `notificationSoundName`,
`blurWhisparrPosters`, `whisparrAgeConfirmed`, `aiKnowsAboutWhisparr`, `arrOrder`,
`showTonight`, `showNeedsYou`, `aiEnabled`, `chatProvider`, OpenAI config
(non-secret fields), `collapsedArrs`.

**Synced (secrets via iCloud Keychain):** per-service `apiKey` / `password`,
`openai.apiKey`, `tmdbApiKey`.

**Local only:** `foregroundInterval`, `backgroundInterval`, `fontScale`,
`launchAtLogin`, `appLanguage`, `appearance`, `showIndexerIssues`, `tonightHours`,
`welcomeSeenVersion`, all MCP keys (`mcpEnabled` / `mcpHostPort` / `mcpRequireAuth`
/ `mcpDisabledTools` / `mcpAuthToken`), and every migration / seed flag.

## Data flow

1. Edit on device A: ConfigStore sink → UserDefaults (non-secret) + SecretStore
   (secret). `KVSyncCoordinator` pushes allowlisted non-secret keys to KVS;
   iCloud Keychain replicates the secret.
2. Device B: KVS external-change notification → coordinator writes UserDefaults →
   ConfigStore reload. iCloud Keychain delivers the secret; secrets are read
   lazily through `SecretStore`, so a later read picks it up (refresh on
   foreground covers the visible-UI case).
3. Conflicts: last-writer-wins (KVS server value; Keychain per-item merge).
   Acceptable for settings — no merge UI.

## Gating

- **Code:** `#if APPSTORE` toggles `synchronizable` and compiles
  `KVSyncCoordinator`. Non-APPSTORE → no KVS, local Keychain.
- **Entitlements:** new `ArrBarr-AppStore.entitlements` and
  `ArrBarriOS-AppStore.entitlements` adding
  `com.apple.developer.ubiquity-kvstore-identifier` and `keychain-access-groups`;
  only the `Release-AppStore` configs point to them. Debug/Release keep the
  current plain entitlements (no iCloud).
- **Signing (separable ops workstream):** switch the github macOS build from
  `CODE_SIGN_IDENTITY = "-"` to a stable self-signed certificate stored as a CI
  secret, so the app-identifier-derived Keychain access group is stable across
  releases and no password prompts appear. Notarization/Gatekeeper is orthogonal
  and unchanged.

## Migration (one-shot, both build types)

On first launch of the new build, guarded by a `secretsMigratedToKeychain` flag:

1. For each service, read `apiKey` / `password` from the existing UserDefaults
   `ServiceConfig` JSON → write to `SecretStore` → blank them in the JSON and
   re-save. Same for `openai.apiKey` and `tmdbApiKey`.
2. MCP token already in Keychain → re-key under the unified `SecretStore`
   naming if it changes.
3. Idempotent; safe to run on a store with no secrets (demo suite).

## Cleanup (dead code)

- Remove `LegacyKeychain`, `migrateLegacyKeychainSecrets`, and
  `keychainMigrationDoneKey`.
- Fold `MCPTokenStore` into `SecretStore`.

## Testing

- `SecretStore`: round-trip read/set/delete; correct `synchronizable` flag
  per-key (MCP false, others APPSTORE-dependent) via an injectable in-memory
  keychain seam so tests never touch the real Keychain.
- Migration: JSON-with-secrets → secrets moved to store + JSON blanked;
  idempotent; no-op on a secret-less store.
- `KVSyncCoordinator`: inbound KVS change applies to defaults and triggers
  reload; loop guard (a local write does not echo back); only allowlisted keys
  cross; reload does not re-fire persistence writes.
- Allowlist: assert platform-specific / one-shot keys are excluded.

## Open / deferred

- Stable self-signed signing is an ops/CI task; it can land after the code so
  the github build keeps working (secrets simply stay device-local until then;
  prompts persist on github macOS until the cert is in place).
- A "Sync now" affordance / status indicator in Settings is out of scope for v1.
