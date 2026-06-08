# Home-Screen Widgets — Design

**Date:** 2026-06-08
**Status:** Approved (brainstorming + architecture review) — ready for implementation planning
**Platform priority:** iOS first; macOS as a follow-up (same target, WidgetKit is cross-platform)

> **Architecture review (2026-06-08):** on board for Phase 0 + Phase 1, with the
> amendments below folded in. Key correction: **size on disk is not free data** —
> the library-list records don't decode `sizeOnDisk` today, so Phase 1 carries a
> small ArrCore model change. The riskiest item (the `ConfigStore` suite repoint)
> is low-risk given the existing `useStore`/demo-suite seam.

## Goal

Add WidgetKit widgets to ArrBarr so users get glanceable, at-a-glance value
on the iOS home/lock screen without opening the app. Widgets reuse ArrCore's
existing clients, `ConfigStore`, and `LocalToolBackend` — no duplicated data
logic.

Four widgets, built in phases:

1. **Library Status** — library size at a glance (FIRST to implement)
2. **Up Next** — upcoming releases / episodes
3. **Needs You** — items that need user intervention
4. **Quiz / Discover** — pocket recommendation card

### Explicitly out of scope

- **Download-queue widget.** Rejected during brainstorming: WidgetKit's refresh
  budget (a few dozen updates/day) can't keep up with live download progress,
  so the data would always look stale. Live downloads belong in a future
  **Live Activity / Dynamic Island**, not a widget. Not in this spec.

## Shared foundation (Phase 0 — prerequisite for all widgets)

### New target

- `ArrBarrWidgets` — WidgetKit extension.
- Bundle id `com.preclowski.ArrBarr.iOS.Widgets` (must be prefixed by the iOS
  host app id `com.preclowski.ArrBarr.iOS`).
- Links the `ArrCore` package → reuses `SonarrClient`, `RadarrClient`,
  `LidarrClient`, `WhisparrClient`, `ConfigStore`, `LocalToolBackend`,
  `DemoMocks`, service icons, and the design tokens.

### App Group + config sharing

- Add App Group to entitlements of **both** the host app and the widget
  extension.
- **Platform-aware suite name (amendment #5).** Write the suite-name resolution
  platform-aware from the start, in the same `resolveDefaults` seam:
  - iOS: `group.com.preclowski.ArrBarr`
  - macOS (app-sandbox is on — `ArrBarr.entitlements`): the team-id-prefixed
    form `$(TeamIdentifierPrefix)group.com.preclowski.ArrBarr`, since sandboxed
    macOS App Group containers require the prefix and resolve to a different
    container path. macOS ships later, but resolving the name correctly now
    avoids reworking `resolveDefaults`.
- `ConfigStore` currently resolves to `UserDefaults.standard` (with an isolated
  demo suite, `ConfigStore.resolveDefaults()` at `ConfigStore.swift:168`).
  Repoint **only the real branch** from `.standard` to the App Group suite so
  the widget process can read server URLs + API keys. The demo branch
  (`DemoMode.demoDefaults`) is independent and must stay untouched.
- **Migration is copy-all-keys, not "copy values" (amendment #2).** Config blobs
  are JSON under `ArrBarr.config.<kind>` and every key is read with a
  presence-check (`applyValues`, `ConfigStore.swift:230–291`). The migration
  must:
  - Copy **all** `ArrBarr.*` keys (service-config JSON, intervals, toggles,
    `keychainMigrationDoneKey`) from `.standard` into the group suite.
  - Be guarded by a one-shot `groupMigrationDone` flag (idempotent).
  - Run at the **host app's earliest launch point, before** `ConfigStore` reads
    — the widget must never be the first writer to the group suite.
  - **Invariant:** the demo suite `com.preclowski.ArrBarr.demo` is never read or
    written by this migration. See [[project_demo_isolated_suite]].
  - Cover with explicit migration tests (fresh install, upgrade-with-data,
    re-run idempotency, demo-active-during-migration).
- **Secrets:** API keys already live in UserDefaults as plaintext inside the
  `ServiceConfig` JSON (per `migrateLegacyKeychainSecrets`, `ConfigStore.swift:548`),
  so moving to the App Group suite gives the widget key access with no Keychain
  access-group work. (Note: plaintext keys now also sit in the shared group
  container — consistent with the existing design, flagged for awareness.)

### Deep links (net-new — amendment #4)

**None of this exists today.** There is no `CFBundleURLTypes` registered, no
`onOpenURL`, and no URL router (`AppDelegate` only handles notification actions
and Spotlight `NSUserActivity`). The entire scheme + router is Phase 0 work,
budget accordingly:

- Register `CFBundleURLTypes` for `arrbarr` in the iOS target's Info.plist.
- Add an `onOpenURL` handler in `ArrBarrApp` that parses the routes below and
  drives the existing `DetailRequest` pipeline (reuse, don't reinvent, the
  in-app navigation).
- Single URL scheme `arrbarr://`.
- Routes (one per widget action):
  - `arrbarr://library` → app default / library view
  - `arrbarr://upcoming/<source>/<arrId>` → DetailView via existing
    `DetailRequest` pipeline
  - `arrbarr://needs/<source>/<arrId>` → the relevant item
  - `arrbarr://quiz` → open full Quiz
  - `arrbarr://quiz/add/<source>/<foreignId>` → open `SearchAddPanel`
    pre-filled (maps to `DiscoverAction.addToRadarr` / `.addToSonarr`)

### Demo mode

- Widgets respect `DemoMode.isActive` → render `DemoMocks` data. This makes
  App-Store screenshots possible without a live server.

### Refresh & resilience (applies to every widget)

- Each widget has a `TimelineProvider` that fetches via ArrCore clients.
- **Providers must NOT construct `ConfigStore.shared` (amendment #3).** It is
  `@MainActor` and spins up Combine sinks, keychain migration, and
  LaunchAtLogin side-effects unsuitable for an extension. Instead the provider
  reads the App Group `UserDefaults` directly (via a lightweight `nonisolated`
  reader) and calls the per-arr clients, which are `actor`s with plain `async`
  `Sendable`-returning methods — clean to call from a background provider.
- On network failure, the timeline keeps the **last known snapshot** plus a
  discreet "stale" marker rather than showing an error tile.
- The app calls `WidgetCenter.shared.reloadTimelines(...)` after relevant data
  changes (e.g. config saved, library refreshed) so widgets update opportunistically.

---

## Phase 1 — Library Status widget (implement first)

The simplest widget and the natural vehicle for proving Phase 0 (App Group +
target + design system). Library size tolerates infrequent refresh well.

### Content

Per service: service icon + total count + size on disk. Examples:

- `🎬 1,204 movies · 8.4 TB`
- `📺 58 series · 12.1 TB`
- `🎵 91 artists · 2.3 TB`

**⚠️ Size on disk is NOT free data today (amendment #1).** Counts are trivially
the array `.count` of the existing `fetchAll*` methods, but `sizeOnDisk` is
**not decoded** in any library-list record:

- `RadarrLibraryRecord` (`ArrTypes.swift:479`) has `hasFile` only — **no
  `sizeOnDisk`**.
- `SonarrLibraryStatistics` (`ArrTypes.swift:510`) = episode/season counts —
  **no `sizeOnDisk`**.
- `LidarrLibraryStatistics` (`ArrTypes.swift:454`) = album/track counts — **no
  `sizeOnDisk`**.
- `sizeOnDisk` exists only on per-item *detail* types — one round-trip per
  title, a non-starter for a whole library.

The Servarr JSON for `/api/v3/movie`, `/series`, `/artist` **does** include
these fields (Sonarr/Lidarr aggregate size server-side in per-series/artist
`statistics`; Radarr/Whisparr expose per-movie `sizeOnDisk`). The app just
doesn't decode them. **Required ArrCore change:**

1. Add `sizeOnDisk` to `RadarrLibraryRecord` and the Whisparr record; add
   `sizeOnDisk` to `SonarrLibraryStatistics` and `LidarrLibraryStatistics`.
2. Add a **`public` library-summary helper** (e.g. on `LocalToolBackend`, or a
   thin dedicated entry point) returning `(count, totalBytes)` per source. Do
   **NOT** expose the raw `internal` client actors / records to the extension.
   A thin summary entry point also avoids dragging the full tool catalog
   (TMDB, custom-formats, discover) into the extension's memory budget.

Per-source metric (one **bulk** list call per service, summed client-side):

- **Radarr:** count of movies; sum of per-movie `sizeOnDisk`.
- **Sonarr:** count of series; sum of series `statistics.sizeOnDisk` (once
  decoded — server already aggregates it).
- **Lidarr:** count of artists; sum of artist `statistics.sizeOnDisk`.
- **Whisparr:** same shape as Radarr; **off by default** (see configuration).

### Configuration

- `AppIntentConfiguration` widget — user picks which arrs to show.
- The configuration intent's options list only **configured** services
  (read from `ConfigStore` via the App Group).
- **Whisparr is excluded by default**; the user can opt in via the widget's
  configuration (discretion on a visible home screen). See
  [[project_whisparr_appstore_risk]].

### Sizes

- **small:** a single chosen service — large total + size beneath. If the user
  picks "All", show a grand total across selected services.
- **medium:** up to 3–4 rows (one per selected arr): icon + total + size.

### Refresh

- `TimelineProvider` refreshes ~every 6 hours (library grows slowly), plus
  `WidgetCenter.reloadTimelines` when the app foregrounds / library refreshes.
- A full library-list fetch per refresh is acceptable at this cadence.

### Tap target

- Whole widget is one deep link → `arrbarr://library` (no interactive buttons).

### Edge / empty states

- No services configured → "Set up a server in ArrBarr".
- Network error → last known counts + discreet "outdated" marker.
- One service unreachable → that row greyed out with "—".

---

## Phase 2 — Up Next widget

The classic Sonarr/Radarr use case. The concise format already exists in
`ArrIntentSupport.upcomingSummary` (`get_calendar`).

### Content

- Nearest upcoming releases: poster + title + relative date
  ("Severance S2E3 — tomorrow", "Dune — in 3 days").
- Future-dated only (the feed can include past entries — already filtered in
  `upcomingSummary`).

### Sizes

- **small:** the single nearest item — poster + title + date.
- **medium:** 3–4 upcoming items with small posters.
- **Lock screen / StandBy:** strong fit (a future enhancement).

### Data

- `get_calendar` via `LocalToolBackend` (already returns `.calendar` items).

### Refresh

- ~every 2–3 hours; the calendar shifts daily.

### Tap target

- Per-item deep link → `arrbarr://upcoming/<source>/<arrId>` → DetailView.

---

## Phase 3 — Needs You widget

The only action-oriented widget — highest tap-through. Reuses the existing
"Needs you" logic (`NeedsYouItem`, `NeedsYouSectionView`).

### Content

- Count of items needing intervention (stalled/failed downloads, import
  blocked, missing) + top 1–3 titles with the reason.
- Small/empty state: "All clear ✓" when nothing needs attention.

### Sizes

- **small:** count badge + the single most urgent item.
- **medium:** count + top 3 items with reason.

### Data

- Same source that feeds `NeedsYouSectionView` (derive `NeedsYouItem`s in a
  widget-callable helper in ArrCore).

### Refresh

- ~every 1–2 hours.

### Tap target

- Per-item deep link → `arrbarr://needs/<source>/<arrId>`.

---

## Phase 4 — Quiz / Discover widget

A "pocket Quiz" — one recommendation poster on the home screen. Drives
engagement / retention (ties into the paywall work).

### Hard constraint

WidgetKit can't do free-gesture swiping — a widget is a pre-rendered timeline
snapshot, not a live view. But iOS 17+ supports **interactive buttons**
(`Button`/`Toggle` backed by App Intents). So Quiz swipes become **taps**.

### Content & interaction

- **Poster** of a recommended title + title, year, rating, source chip
  (`DiscoverItem.Origin`: "From TMDB" / "From AI").
- **✕ / "Not now"** button → records a skip and **advances to the next**
  pre-fetched candidate, fully in-widget (App Intent runs in the background and
  reloads the timeline; no app launch).
- **❤️ / "Add"** button → **deep-links into the app** at `SearchAddPanel`
  pre-filled with the title (`arrbarr://quiz/add/<source>/<foreignId>`,
  mapping to `DiscoverAction.addToRadarr` / `.addToSonarr`). Real adds need
  quality profile + root folder, which a widget can't present inline — so the
  add is confirmed in-app. (Chosen over one-tap quick-add for safety: no "oops,
  wrong profile".)
- **Tap the poster** → opens the full Quiz in-app at that card
  (`arrbarr://quiz`, seeding the card).

### Why it survives infrequent refresh

Unlike the download queue, recommendations tolerate rare updates. The
`TimelineProvider` pre-fetches a **small batch of candidates** (reusing
`DiscoverSources` + TMDB / `LocalToolBackend`) and builds a multi-entry
timeline rotating every ~1–2 h. The poster changes a few times a day on its
own; taps just advance faster.

### Sizes

- **small:** poster only + a single subtle ❤️; tap poster → Quiz.
- **medium:** poster + metadata + both ✕/❤️ buttons (full pocket Quiz).

### Open considerations (resolve during planning)

- Where the widget's skip/like verdicts are persisted so they feed back into
  `DiscoverViewModel`'s session signal (shared store via App Group).
- Image loading in the extension (download in the App Intent / provider; the
  in-app `ImageCache` is process-local).

---

## Implementation order

1. **Phase 0 + Phase 1 together** (foundation is only exercised once there's a
   real widget): App Group (platform-aware suite name), `ConfigStore` repoint +
   copy-all-keys migration with tests, `ArrBarrWidgets` target, **net-new
   `arrbarr://` scheme + `onOpenURL` router**, **ArrCore `sizeOnDisk` decode +
   `public` library-summary helper**, Library Status widget end-to-end (provider
   reads group `UserDefaults` directly, not `ConfigStore.shared`).
2. Phase 2 — Up Next.
3. Phase 3 — Needs You.
4. Phase 4 — Quiz / Discover (most new logic: interactive App Intents,
   candidate pre-fetch, verdict persistence).
5. (Later) macOS targets for each; Live Activity for downloads.

## Risks / notes

- **`ConfigStore` suite migration** is the riskiest change — it touches where
  every user's real profile lives. Must be backward-compatible and must not
  disturb the demo-suite isolation. Cover with explicit migration tests
  (fresh install, upgrade-with-data, idempotent re-run, demo-active).
- **App Group + extension entitlements require provisioning-profile updates**
  (Apple Developer portal) for the iOS host id `com.preclowski.ArrBarr.iOS` and
  the widget id `com.preclowski.ArrBarr.iOS.Widgets`. The eventual macOS widget
  nests under `com.preclowski.ArrBarr` (different id — "same target,
  cross-platform" oversimplifies the id/provisioning setup).
- **`ImageCache` is process-local** (`actor`), so posters aren't warm in the
  extension. Not a Phase 1 issue (Library Status has no posters) but it bites
  **Phase 2 (Up Next)** and **Phase 4 (Quiz)** — those providers must download
  posters themselves.
