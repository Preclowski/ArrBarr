# MediaKit phase 0: inventory, baseline, hypotheses

Branch `feat/mediakit-foundation`. Input: `docs/superpowers/prompts/2026-09-15-mediakit-rewrite-prompt.md`.
Raw agent outputs: `docs/superpowers/baseline/phase0/` (four reader JSONs with per-file line counts and per-operation tables, the hypothesis verification, timings). Golden request corpus: `docs/superpowers/baseline/2026-09-15-golden-requests.json`. Fixtures: `Packages/MediaKit/Fixtures/`.

## 1. Environment

| Item | Value |
|---|---|
| Xcode | 27.0 (27A266a), SDK macOS 27.0 / iOS 27.0, Swift 6.4; switched from 26.4.1 during phase 0 |
| CI | `.github/workflows/release.yml` pins Xcode 26.4.1 on `macos-26` |
| Consequence | manifests stay `swift-tools-version: 6.2`, floor `.v26` (`.v27` needs PackageDescription 6.4); no 27-only API until CI is bumped |
| Verified on a scratch package | 6.2 + `.v26` + `defaultIsolation(nil)` + `NonisolatedNonsendingByDefault` + `InferIsolatedConformances` + `import SQLite3` with zero dependencies builds under Swift 6.4 |
| SDK 27 breakage | `SwiftUI.Document` collides with `Markdown.Document` in `MarkdownMessage.swift`; ArrCore did not compile until qualified (fixed in this phase, 2 tokens) |
| Xcode MCP server | `xcrun mcpbridge` configured per project; attaches only to a session started after it was added; tool inventory and usage rules in prompt section 6a |
| Worktree isolation | `isolation: 'worktree'` bases on `origin/main` (ac23c34, 32 commits behind); unusable here; coordinator creates worktrees from the branch by hand |

## 2. Hypotheses (prompt section 2) with verdicts

| H | Claim | Verdict | Correction / evidence |
|---|---|---|---|
| H1 | Xcode 26.4.1 local + CI | partially | local is now 27.0; CI 26.4.1 (`release.yml:28`) |
| H2 | package graph, TonightBarr not in ArrBarr scheme, all manifests 6.0 | true | only `ArrBarr` and `Paywall Test` are shared schemes; `ArrBarriOS`/`ArrBarrWidgets`/package schemes are user-local autocreated |
| H3 | widget iOS-only, fetches itself via LibrarySummaryService/UpcomingService, no app snapshot | true | `ArrBarrWidgets.swift:119,520`; demo fallback via `WidgetDataStore.isDemoActive` + `DemoMocks`, not `DemoQueueState` |
| H4 | entitlements: sandbox+network, no app group on macOS | partially | also `files.downloads.read-write`; widget non-AppStore entitlements carry `keychain-access-groups` |
| H5 | one instance per kind, ~56 @Published, Combine debounce, 30 s poll, 0.25 s burst | partially | 46 `@Published`; debounce 1.5 s in 5 identical pipelines; two 30 s timers (foreground/background); `QueueViewModel` is `@Observable`, not `ObservableObject` |
| H6 | X-Api-Key, 15/120 s timeouts, URLCache off, ~58 ops, 6 download clients, TMDB v3 query / v4 Bearer | partially | ops: 68 (arrs+search, 21 writes) + 49 (download clients, 25 writes) + 39 (media/TMDB, 3 writes); URLCache disabled process-wide by replacing `URLCache.shared`; SABnzbd reads via GET, qBittorrent GET + form POST |
| H7 | hand-rolled SignalR, negotiate POST, depends on ArrCore types | true | `RealtimeUpdates.swift` imports Foundation+os only; uses ServiceConfig, QueueItem.Source, DemoMode, Logger |
| H8 | caches as listed | partially | `CoalescingCache` is `@MainActor`, LRU, no TTL; `DownloadProgressService` (2 s TTL, 60 s max age) missing from the list; rest confirmed |
| H9 | fingerprint = URL + key length | true | `ServiceConfig.swift:26`; `SearchOptionsCache` uses the full key instead: two schemes |
| H10 | ~40 files / 58 sites / 28 tools / 103 Codable / 22 shared / 23 actors / 124 @MainActor / 73 nonisolated | partially | canonical: Views 59 sites in 12 files, ViewModels 10 in 3, Services 122 in 37, elsewhere 0; 28 tools; 158 Codable declarations (148 Decodable); other counts confirmed |
| H11 | 46 demo branches in six clients, 17 in Views/VMs, widget uses DemoQueueState | partially | 46 confirmed; Views+ViewModels 22; widget does not use DemoQueueState/DemoMonitorState |
| H12 | apiBase hard-coded, Sonarr v5→v3 fallback, Whisparr v3 only, qBit SID vs key, Lidarr v1 | partially | Whisparr client is v3-only but `ArrDownloadClients` matches v2 `tvCategory` and v3 `movieCategory`, demo reports "Whisparr 2.0.0.548" |
| H13 | only maxConcurrentSideLoads=4, ParallelResolve, backoff only in SignalR, no 429 | true for ArrCore | MediaKit spike maps 429 → `rateLimited(retryAfter:)` but never retries; qBittorrent/Deluge retry once on 401/403; Transmission retries once on 409 session id |
| H14 | 94 test files, Swift Testing, host-filtered URLProtocol stubs, loc lint | true | all 14 `canInit` overrides filter by host |
| H15 | DynamicMCPTool with `{json: String}`, 3 of 6 intents exposed | true | omission is deliberate (`ArrBarrIntents.swift:157`) |
| H16 | spike 3440 LOC, v6, no deps, memory cache, no writes/capabilities/limits | partially | 3459 LOC; has 15 s timeout + 429 mapping; v4 token goes Bearer; Emby gets the Jellyfin `MediaBrowser Token=` header (ArrCore sends bare `X-Emby-Token`) |
| H17 | 11 availability lines in 6 files + 3 @available | partially | canonical grep: 14 lines in 6 files (11 `#available` + 3 `@available`), all in ArrCore |
| H18 | OSS build keeps secrets in UserDefaults group plist | true | `AppCapabilities.keychainSharingAvailable` probe fails on ad-hoc signature |
| H19 | no per-request logging in HTTPClient | true | zero Logger/signpost in `HTTPClient.swift`; per-screen counts cannot be read from `log stream` |
| H20 | SQLite3 importable with zero deps | true | `MacOSX.sdk/usr/include/module.modulemap:13`, iOS SDK too |

## 3. Baseline numbers

### 3.1 Lines MediaKit replaces (the 60 % budget)

| Group | Files | LOC |
|---|---|---|
| A transport, arr clients, search, caches, identity | HTTPClient, ArrAPIClient, Radarr/Sonarr/Lidarr/WhisparrClient, SearchClient, ArrDownloadClients, TitleMetadataStore, LibraryIndex, SearchOptionsCache, CoalescingCache, SeriesIdentityResolver | 4 512 |
| B download clients, realtime, aggregator, progress, health | 6 clients, RealtimeUpdates, QueueAggregator, DownloadProgressService, ConnectionHealthMonitor | 3 113 |
| C media servers, TMDB | MediaServer/*, TMDBClient | 1 853 |
| D demo mocks | DemoMocks*, DemoMonitorState, DemoQueueState, DemoMode | 2 889 |
| E wire models | ArrTypes, ArrDetailTypes, ReleaseTypes, SearchTypes, DownloadClientTypes, DownloadProgress, DownloadDrop, DiskSpace | 1 950 |
| **Total replaced** | | **14 317** |
| **MediaKit production budget (60 %)** | | **≤ 8 590** |
| Not counted | Cast/Country/Trailer providers, PersonStore, LibrarySummaryService, UpcomingService, DownloadDropService (617), MediaKit spike (3 459, to be replaced) | |

ArrCore sources total 64 616 LOC, tests 17 747.

### 3.2 Timings (warm build caches, idle machine, Xcode 27)

| Command | Wall | Result |
|---|---|---|
| `swift test` ArrCore | 8.0 s | 956 tests / 173 suites, 5 pre-existing failures (BrandMarkAssetTests ×2, SectionsTests localized key, UpcomingItem date ×2: SwiftPM does not build `.xcstrings`/asset catalogs) |
| `swift test` ArrMCPServer | 27.1 s | 15 tests pass |
| `swift test` MediaKit (spike) | 5.6 s | 57 tests pass |
| `xcodebuild ArrBarr` incremental | 26.6 s | succeeded |

Cold start and list frame time were not measured: no instrumentation exists (H19) and driving the UI is out of bounds. Phase 3 adds telemetry; the comparison in phase 6 uses the analytic per-screen counts below plus the new counters on the old code path before removal.

### 3.3 Requests per screen (analytic, from code; configuration: Radarr, Sonarr, Lidarr, qBittorrent, SABnzbd, Plex, TMDB)

| Screen | 1st open | 2nd open ≤ 10 min | Notes |
|---|---|---|---|
| Popover queue, cold launch | 25 | 11–14 | 3 queue + 5 side-loads + 2 progress + 3 calendar + 3 health + 3 probes + 3 negotiate + 3 Plex; 30 s tick adds 3 queue + ≤2 progress while open |
| Library grid (3 tabs) | 7 | 0 | LibraryIndex 10 min |
| Upcoming | 0 | 0 | rides on refresh; cold hydrate from WidgetDataStore |
| History | 3 | 3 | refetches on every `.task` |
| Detail movie | 7 | 3 | profiles 15 min; cast/countries/trailer process-lifetime LRU |
| Detail series | 9 (+1 `/find`) | 3 | episode files 15 min |
| Search results (all scope) | 8 | 5 | lookups always go out |
| Add flow | 2 (Lidarr 3) | 0 | SearchOptionsCache 15 min |
| Quiz | 1 LLM + N lookups + 1 library | 1 LLM + N | `DiscoverViewModel.configure` has no call site: TMDB/library sources are dead |
| Settings → Status | 3 | 3 | no cache |

### 3.4 Golden corpus and fixtures

- Corpus: 180 entries (client, operation, method, templated path, query keys, header names, scrubbed body, allowed, intercept reason). Live: radarr 24, sonarr 25, lidarr 25, tmdb 20, plex 7, qbittorrent 4, sabnzbd 4. Intercepted (never sent): every write, `/release`, and all four unconfigured RPC clients. The only live non-GET was `POST /signalr/messages/negotiate`.
- Fixtures: responses + sidecars, arrays truncated to 5 elements by key-set cover, `original_array_count` in the sidecar. Scrub verified in-process: 0 hits for every secret and every hostname/domain; root folders → `/data/<kind>`, Plex ids → `user`/0, tracker passkeys redacted; titles, overviews, external ids, artwork URLs and file names replaced with open-source catalogue entries by `Tools/fixtures/anonymize_fixtures.py` (see Q4).
- Recorder: `Packages/ArrCore/Tests/ArrCoreTests/Phase0RecordingTests.swift` (1 408 lines), inert unless `ARRBARR_RECORD=1`; allow-list is a code table; re-used in phase 6 for the parity diff, then folded into MediaKit's `RecordingTransport`.
- Missing: Whisparr (not configured, no fixtures at all, not even v3); Jellyfin/Emby (owner runs Plex); Transmission/Deluge/rTorrent/NZBGet responses; Lidarr `GET /track`, `GET /search` (not on the allow-list) so `POST /album` body was never encoded; Plex `seasonPosters` (400 on TVDB-keyed children); qBittorrent login never exercised (API-key mode).

## 4. Load-bearing facts for the design (not in the prompt)

1. `URLSession.shared` is load-bearing: 14 stub-based test files rely on `URLProtocol.registerClass`; six download clients own private sessions (cookie jars) that ignore it. New transport must be injectable everywhere and tests move to injected transports.
2. Two untyped `[String: Any]` read-modify-write paths (`getJSONObject`, Sonarr v3 season double-PUT that writes the opposite value first to force the cascade). Must be preserved as typed operations.
3. `ServiceConfig` carries username/password too; download clients authenticate by password, not key. Credential model must be per service kind.
4. qBittorrent sends both `paused` and `stopped` spellings unconditionally (4.x vs 5.2); Transmission needs the 409 `X-Transmission-Session-Id` handshake at header level; qBittorrent/Deluge re-login once on 401/403.
5. Cancellation is special-cased: `CancellationError`/`URLError.cancelled` rethrown bare. Pull-to-refresh depends on it.
6. Poster fetching is a second HTTP stack (`PosterStore` builds its own requests with `X-Api-Key` and media-server headers) with SHA-256 URL keys.
7. Realtime coalescing lives in `QueueViewModel` (0.25 s burst, 1 s floor open / 30 s closed, 300 s silence → polling). Transport emits raw events.
8. Demo gating is inconsistent: `fetchQueue/Calendar/History` have no demo branch (QueueAggregator substitutes), `fetchHealth`, `fetchDiskSpace`, `deleteQueueItem` hit the network in demo mode; media-server and TMDB clients never check demo.
9. Five files duplicate the same `ServiceKind → client` switch; `DetailView` builds 17 clients per call sites; view bodies build clients inline (UpcomingRowView, LibraryTabContent, SettingsView).
10. Two synchronous view-body reads: `MediaServerIndex.posterURL(for:)` and `isWatched(for:)`.
11. AppIntents and MCP never build clients: `LocalToolBackend` is the single funnel (8 files, 3 041 lines; `+ArrTools` 1 000 lines).
12. `ConfigStore` mutates process-global state (`AppleLanguages`, suite migration); the OSS macOS build writes to the group suite without an app group entitlement (writes silently denied in the group container, plist path still resolves).
13. Widget: only `LibrarySummaryService` + `UpcomingService`, no queue/realtime.
14. `CoalescingCache` has no TTL and is keyed by the length-only fingerprint: same-length key rotation serves the old server forever.
15. `DownloadProgressService` distinguishes "some clients failed" from "all failed" so a blip does not snap progress bars to arr values.

## 5. Corrections to the prompt for phases 1–7

- Section 2 numbers: 46 `@Published`; 158 Codable; Views/ViewModels 69 sites in 15 files; 22 demo branches in Views/VMs; 14 availability lines in 6 files; 28 tools.
- Section 1.6 Whisparr: no instance available; v3 fixtures must be synthesised from Radarr (fork) or recorded later.
- Section 3 "snapshot synchroniczny": two consumers confirmed.
- Section 5 allow-list additions worth approving: Lidarr `GET /track`, `GET /search` (reads).
- Section 6: `isolation: 'worktree'` replaced by hand-made worktrees; Xcode MCP rules in 6a.
- Criterion 16 (widget): today's widget does its own fetches; see decision Q2.

## 6. Decision pack (phase 0 → 1), answered by the owner on 2026-09-15

Q1 (decided: a). ArrCore isolation and language mode. Trial: `.defaultIsolation(MainActor.self)` in v5 mode gives 1 error (`ArrCredit` Decodable conformance vs `Sendable` generic) and 402 warnings, 90 % of them in code MediaKit deletes (`url(base:)`, `isConfigured`, `DemoMode.isActive`, queue/history records). Options: (a) keep v5, add `defaultIsolation(MainActor)` in phase 5 after the old clients are gone, v6 later as its own change (recommended: the warnings vanish with the code they sit in); (b) v5 + isolation in phase 3 (402 warnings for two phases); (c) v6 now (hundreds of errors before any MediaKit value). Consequence of (a): criterion 24 is checked at the end of phase 5, not phase 3.

Q2 (decided: a). Widget data path. Options: (a) widget reads the shared SQLite snapshot in the group container and refreshes through its own MediaKit connection when the snapshot is stale (recommended; matches criterion 16, timelines still update when the app is closed); (b) snapshot-only, the app refreshes (zero network in the extension, stale when the app is closed); (c) leave the widget on its own fetch path without SQLite. Consequence of (a): the extension links MediaKit + SQLite and needs the group-container DB with WAL from phase 3.

Q3 (decided: a). Whisparr. Options: (a) v3 client generated from the Radarr client with synthesised fixtures (title-only shapes), probe distinguishes v2/v3, v2 documented gap (recommended); (b) owner provides a Whisparr instance for a one-off recording; (c) drop Whisparr from the rewrite scope. Consequence of (a): Whisparr parity is only test-proven, never live-proven.

Q4. Fixtures in the public repo. Decided: fixtures and corpus bodies committed to the repo carry only open-source titles (the DemoMocks catalogue: Big Buck Bunny, Sintel, Tears of Steel, Elephants Dream, Caminandes, …); the raw recordings with the owner's library stay outside the repo. Lidarr `GET /track` and `GET /search` approved on the allow-list. Implemented by `Tools/fixtures/anonymize_fixtures.py`, re-run after every re-recording.

Q5 (assumed, reversible). CI stays on Xcode 26.4.1: tools-version 6.2, floor 26, no 27-only API. Second instance per kind: schema keyed by `InstanceID` from day one, UI single-instance. Jellyfin/Emby fixtures: synthesised from API docs and marked `synthetic: true` in the sidecar until a live instance exists.

## 7. Floor-raise trial (Xcode 27, worktree from the branch)

Changes: 6+6 deployment-target lines in `project.pbxproj` → 26.0; ArrCore, ArrMCPServer, MediaKit manifests → tools 6.2, `.macOS(.v26)` (+ `.iOS(.v26)`); TonightCore untouched (tools 6.0, `.macOS(.v15)`, not 14 as the prompt said).

| Scheme | Result | Warnings | Floor-caused diagnostics |
|---|---|---|---|
| ArrBarr (macOS) | succeeded, graph incl. TonightCore resolved | 98, pre-existing Swift 6 strict-concurrency futures | 2× `Text +` deprecated in macOS 26 |
| ArrBarriOS | succeeded | 196, same families | `UIScreen.main` deprecated (`RemotePoster.swift:259`), `Text +` (`QuizSettingsPane.swift:120`) |
| ArrBarrWidgets | succeeded | 0 (incremental) | none |
| `swift test` ArrCore | 955 tests, the 5 known failures | | |

No `#available(macOS 26/iOS 26)` guard is flagged as unnecessary by the compiler; the 14 lines are removed by hand in phase 3. TonightCore's lower floor is inert: neither ArrCore nor ArrMCPServer depends on it, and `TonightBarr` is outside the three schemes. `.defaultIsolation(MainActor.self)` in ArrCore (v5 mode): 1 error, 402 warnings; see Q1.
