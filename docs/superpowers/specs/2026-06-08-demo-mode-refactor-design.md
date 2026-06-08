# Demo Mode Refactor — Design

**Date:** 2026-06-08
**Status:** Approved (design), pending spec review

## Goal

Refactor the demo mode of ArrBarr/ArrCore in two dimensions:

1. **Curated data** — replace the current loose set of fixtures with a tight, coherent,
   attractive open-source content universe that shows off the app's important features.
2. **Settings isolation** — make configuration part of the demo sandbox. Today all settings
   live in a single `UserDefaults.standard`, so toggling e.g. Whisparr while in demo persists
   `enabled=true` and bleeds into the real profile. Demo must have its own settings store.

The demo layer must also remain usable on iOS later (currently macOS), so no macOS-only
mechanics (e.g. process relaunch) may be load-bearing for correctness.

## Non-goals

- No new app features. This is a data + persistence-routing refactor.
- No emphasis on errors/failures in demo data (kept "clean and sexy", health all green).
- iOS live-swap (relaunch-free demo toggle) is acknowledged but out of scope for this pass;
  the design must not preclude it.

## Background (current state)

- Demo fixtures live in `Packages/ArrCore/Sources/ArrCore/Services/DemoMocks*.swift`
  (`DemoMocks.swift`, `+Queue`, `+Upcoming`, `+History`, `+Details`).
- `DemoMode.isActive` reads `UserDefaults.standard` key `ArrBarrDemo` live; clients/viewmodels
  swap to fixtures when active.
- `DeveloperMode` (`ArrBarrDeveloperMode`) gates the developer panel (launch arg `--demo`,
  env `ARRBARR_DEMO=1`, or iOS 7-tap easter egg).
- `ConfigStore.shared` (@MainActor singleton) holds all settings as `@Published` properties
  that auto-persist to `UserDefaults.standard` via `.dropFirst().sink()`. The single `defaults`
  reference is the central backing store.
- `ServiceConfig.isVisible` = `DemoMode.isActive ? enabled : (isConfigured && !apiKey.isEmpty)`.
  The `enabled` flag is what bleeds.
- `DemoMode.seedConfigsIfNeeded` currently seeds only Radarr+Sonarr, guarded by
  `ArrBarr.demoSeedDone` in `.standard`.

## Part A — Curated content universe

A fixed set of **12 entities**, all open-source / Creative Commons, reused across queue,
calendar/upcoming, history, and detail views. All other surplus titles and search-pool
entries are pruned to this set for coherence.

### Movies (3 — Radarr), real Wikipedia posters

1. Big Buck Bunny (2008)
2. Sintel (2010)
3. Tears of Steel (2012)

### Series → 5 episodes (Sonarr), 2 series

The five episodes are the **active queue** composition (currently downloading/queued).
Future episodes (S02) live in the calendar, not the queue — an episode can't be both
"airing later" and "downloading now".

- **Pioneer One** (2010, CC sci-fi) — 3 **independent** S01 episodes (distinct
  `downloadId`s, so they render as separate rows): S01E03 "Endurance" (a quality
  **upgrade**), S01E04 "Brave New Earth", S01E05 "Foothold" (queued). Multi-season is shown
  via the detail view (S02 listed) and the calendar (S02 airing soon).
- **Caminandes** (2013, Blender animation) — 2 episodes as a **season pack** (shared
  `downloadId`, so they group into one row): S01E02 "Gran Dillama", S01E03 "Llamigos".

This keeps both queue-grouping behaviours (grouped pack vs. independent rows) visible inside
the 5-episode budget.

### Albums (2 — Lidarr), CC-licensed, real cover art

1. Nine Inch Nails — Ghosts I–IV (2008)
2. Brad Sucks — Out of It

### Nature films (2 — Whisparr / cats)

Cat-themed titles with `placecats.com` covers. Off by default, behind the age gate.

1. Kitten Cam: Backyard Drama
2. The Black Cat Chronicles

### Feature exposure (state design)

Priorities to showcase: **quality upgrades, custom format scores, calendar + history.**
Health stays green; failures minimized or omitted.

- **Queue (active downloads):**
  - Tears of Steel as an **upgrade**: Bluray-1080p → Bluray-2160p, custom-format score jump,
    tags HDR10+/DV/Atmos, before/after size (`isUpgrade`, `existing*` fields populated).
  - 1–2 other items mid-download with progress; mix of usenet/torrent and download clients.
- **Calendar / Tonight:** next Pioneer One episode airing "tonight", Caminandes, an album
  release, a movie digital release — each with deterministic IMDb ratings.
- **History:** grabbed/imported events with visible custom-format scores, plus one upgrade
  replacement event. No (or at most one subtle) failure.
- **Details:** every entity has overview, genres, ratings, seasons/tracks fixtures.

### Poster strategy (unchanged mechanics)

- Movies/albums: Wikipedia `Special:FilePath` (extend `realPosters` map to cover the curated set).
- Cats: `placecats.com/<id>/<w>/<h>` via `kitten:<id>` seed.
- Fallback: `placehold.co` text placeholder.

## Part B — Settings isolation (separate UserDefaults suite)

### Mechanism

- Introduce a demo suite: `UserDefaults(suiteName: "ArrBarr.demo")`.
- `ConfigStore` selects its backing `defaults` at init based on `DemoMode.isActive`:
  - active → demo suite
  - inactive → `UserDefaults.standard`
- All existing `@Published` → `sink` persistence flows through this single `defaults`
  reference, so **every** setting (service configs, theme, language, AI config, polling,
  tonightHours, whisparrAgeConfirmed, etc.) is automatically isolated. No per-key changes.
- The real profile (`.standard`) is **never written** while in demo → nothing bleeds.

### Meta flags stay in `.standard`

`ArrBarrDemo` and `ArrBarrDeveloperMode` remain in `.standard` — they identify *which mode*
we're in and must survive across launches independently of the profile being viewed.

### Seeding

- `seedConfigsIfNeeded` writes into the **demo suite** and enables Radarr + Sonarr + Lidarr;
  Whisparr stays OFF (opt-in, behind age gate).
- The seed-done guard key moves into the demo suite, so **resetting demo = wiping the demo
  suite** (one call), which re-arms seeding.

### Safety invariant (hard requirement)

No code path in this refactor may delete, clear, or `removePersistentDomain` the user's real
profile. Every wipe/reset targets **only** the demo suite by passing its suite name to
`removePersistentDomain(forName:)` (which removes the named suite's domain, never
`.standard`'s own bundle-id domain). The user's existing `.standard` profile must survive
enabling demo, toggling Whisparr in demo, and disabling demo, untouched.

### Intended tradeoff

Entering demo shows demo's *own* (seeded) settings, not the user's real ones. This is the
explicit intent of "settings should also be part of demo."

### Live re-point (required, not deferred)

`ConfigStore` selects its backing store at init based on `DemoMode.isActive`. That alone fixes
macOS, which relaunches on demo toggle. **But the iOS demo toggle already exists**
(`iOSAppRoot.swift`) and flips demo *without* relaunching — so an init-only swap would leave
iOS writing demo edits into `.standard` and the bleed would persist there.

Therefore `ConfigStore` gets a `func useDemoStore(_ on: Bool)` that re-points `defaults` to the
demo suite (or back to `.standard`) **and reloads all `@Published` values from the new store**,
in place, so existing `@EnvironmentObject` subscribers keep working. Both toggle paths call it:

- macOS `AppDelegate.setDemoModeAndRelaunch` — calls it before relaunch (belt-and-suspenders;
  the relaunch + init selection would suffice, but calling it keeps pre-relaunch reads correct).
- iOS `iOSAppRoot` toggle — calls it instead of relying on a relaunch.

The load logic is factored into a private `loadAll(from:)` used by both `init` and the reload.

## Affected files (anticipated)

- `Services/DemoMocks.swift` — `realPosters` map, `seedConfigsIfNeeded` (suite + Lidarr),
  seed-done key location.
- `Services/DemoMocks+Queue.swift`, `+Upcoming.swift`, `+History.swift`, `+Details.swift` —
  rewrite fixtures to the curated 12-entity universe and feature states.
- `Services/ConfigStore.swift` — `defaults` selection by `DemoMode.isActive`; reset helper to
  wipe the demo suite.
- `ArrBarr/AppDelegate.swift` — demo reset path uses suite wipe instead of removing the old
  `demoSeedDone` key from `.standard`.
- Possibly `Resources/Localizable.xcstrings` if any demo-facing strings change.

## Risks / open points

- `ConfigStore.shared` is initialized once per process; correctness on macOS relies on the
  existing relaunch on demo toggle (already in place). iOS live-swap deferred (noted above).
- Wiping the demo suite must not touch `.standard`; verify reset path targets the suite only.
- Ensure no code reads service `enabled` directly from `UserDefaults.standard` bypassing
  `ConfigStore` (would re-introduce a bleed). To verify during implementation.
