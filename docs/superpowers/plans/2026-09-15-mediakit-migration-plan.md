# MediaKit migration plan (phases 5–7)

State on 2026-09-15 after `c68706e`: `Packages/MediaKit` is complete for phases 3–4
(6,766 production lines, 81 tests, zero warnings, zero dependencies). ArrCore still runs on the
old clients. Spec: `docs/superpowers/specs/2026-09-15-mediakit-foundation-design.md` (§9–§12
describe the gateway, the waves, the parity run and phase 7). This file is the working list;
tick items as commits land.

## Rules that hold for every wave

- One commit per wave; every commit builds `ArrBarr`, `ArrBarriOS`, `ArrBarrWidgets` and passes
  `swift test` in ArrCore, ArrMCPServer, MediaKit. Relaunch the macOS app after each wave.
- MediaKit changes are allowed when a consumer needs a resource that is missing; keep the
  budget (≤ 8,590 lines) and the parity test green.
- No new agents. Read files by section (`sed -n`), never whole.
- Old code is deleted in wave 6 only; until then the old clients stay compilable.

## Wave 1 — gateway + queue path

- [x] `Packages/ArrCore/Package.swift`: add `.package(path: "../MediaKit")`, product `MediaKit`.
- [x] `Services/ServiceGateway.swift` (@MainActor): builds `MediaKit` from `ConfigStore`
      (`ServiceKind` → `InstanceKind`, media server, TMDB), `ConfigCredentialProvider` reading
      `ConfigStore` + `SecretStore` with a generation stamp per secret write,
      `reconcile()` on every config publisher (debounced 1.5 s as today), demo → `FixtureTransport`
      (`DemoMode.isActive`), `OSLogSink(subsystem: "pl.incred.ArrBarr")`, `TelemetryRecorder`.
- [x] `Compositions/ArrCompositions.swift`: `unify(ArrQueueRecord, source:baseURL:files:meta:)`
      → `QueueItem` (one function for the four flavours; Sonarr season-pack poster and
      `packSeasons` kept), `unifyCalendar` → `UpcomingItem`, `unifyHistory` → `HistoryItem`.
- [x] `QueueAggregator` internals on MediaKit: queue via `kit.servarr(id).queue()` through the
      store (volatile) + `files` batch + `TitleMetadataStore` resolution via `movie/series/album`
      details resources; progress overlay via `kit.download(id).fetchTasks`; health via
      `health()`; history via `history()/historyFor()`; upcoming via `calendar()`; actions via
      `Command`s. Public API (`QueueDataProviding`) unchanged so `QueueViewModel` and views
      compile untouched.
- [x] Realtime: `RealtimeManager` replaced by `EventHub` + `SignalRSource` per arr;
      `QueueViewModel.bootstrapRealtime` subscribes to `events.events()`.

## Wave 2 — details, library, search, add/edit/delete

Approach: the old client types (`RadarrClient`, `SonarrClient`, `LidarrClient`, `WhisparrClient`,
`SearchClient`) keep their method signatures and return types; their bodies become
`store.read(Resource<OldType>.json(service.<x>().plan, ...))` and `store.run(command)` through
`ServiceGateway.current`. Consumers stay untouched; `HTTPClient`, `ArrAPIClient`,
`CoalescingCache` and the `DemoMode` branches go. The assembly class is `MediaStack`
(the name `MediaKit` collides with the module for qualified lookups).

- [x] `RadarrClient`, `SonarrClient`, `LidarrClient`, `WhisparrClient`, `SearchClient`,
      `ArrAPIClient` (+ `ArrDownloadClients`) are facades over MediaKit; every view, tool and
      service that built a client keeps working. A config that is not the saved one (Settings
      draft, tests) becomes its own instance ordinal via `ServiceGateway.adopt`.
- [x] Tests: `QueueUnificationTests`, `SeasonPackArtworkTests`, `LidarrWireDecodingTests` on
      `ArrCompositions`; stub suites keep global `URLProtocol` registration (a test process
      routes through `URLSession.shared`, `.memory` database, `mustRevalidate` override; migrated off
      global registration in Wave 6).
- [ ] Later: `LibraryIndex`/`LibraryViewModel` as store consumers (today they call the facades
      with `mustRevalidate` and keep their own snapshot).

## Wave 3 — tools, MCP, settings, health, intents, widget

- [x] Tools, MCP, settings probes and the health monitor reach MediaKit through the facades.
- [x] Six download clients, `TMDBClient` and the Plex/Jellyfin/Emby client are facades
      (`DownloadClients.swift`, `MediaServerFacade.swift`); their HTTP-level tests retired,
      add-request shapes covered in MediaKit `DownloadAddShapeTests`. `DownloadProgressService`
      and the phase-0 recorder test deleted (parity now uses `MediaKitRecording`).
- [ ] `MediaServerIndex` → `Snapshot` over `libraryIndex`/`watchHistory`; `PosterStore` consumes
      `ArtworkReference` + `kit.artworkHeaders` (today the facade feeds the old index).
- [x] `ConnectionHealthMonitor` → `HostGovernor.health` + `EventHub.lastEventAt`: the monitor keeps its
      probes; `ServiceGateway.breakerChanges()`/`hostHealth(of:)` feed `ConnectionHealth`, which shows a
      service down while its host's breaker is open (worse of recorded and governor). `lastEventAt`
      already drives the realtime-quiet check in `QueueViewModel`.
- [ ] Widget: `MediaKit(role: .snapshotReader)` on the group container database.
- [ ] `SpotlightIndexer` as a store consumer.

## Wave 4 — QueueViewModel on LiveStream

- [ ] Replace the timers/debounce/burst logic with `liveQueue` + `liveProgress` + `EventHub`;
      `systemDidWake` → `events.wakeAll()` + `governor.noteWake`.

## Wave 5 — demo

- [x] Queue, calendar, history, health, details, library, search, releases and TMDB in demo come
      from `FixtureTransport` (placeholder origins per enabled kind, PUT bodies remembered so
      monitor toggles stick); `DemoQueueState`, `DemoMonitorState` and the queue/upcoming/
      history/details/releases/library mocks are deleted. `DemoMocks` (+People, +Search) stay for
      the chat persona and people search, which are outside the communication layer.
- [x] `DemoDataFlowTests`: a gateway built with `demo: true` (no global flag) serves queue, upcoming
      and history for all four arr flavours from the bundled fixtures. (`log show` returns nothing
      in this environment, so the gateway notice could not be read back; the test is the evidence.)

## Wave 6 — removal + isolation

- [x] `HTTPClient`, `RealtimeUpdates`, `DownloadProgressService`, the per-arr queue/calendar/
      history wire records and the old client HTTP paths are gone; the client type names remain
      as facades (consumers unchanged). `ConnectionHealthMonitor` stays (it schedules probes,
      not HTTP). `CoalescingCache` and `TitleMetadataStore` stay (in-memory caches over
      MediaKit-backed calls; candidates for a later pass).
- [x] Migrate the remaining `URLProtocol` stub suites to `ScriptedTransport`/`FixtureTransport`:
      eight suites answer through a test `ScriptedTransport` on a fresh gateway per test
      (`.gateway(_:)` suite trait over `ServiceGateway.override`, `ServiceGateway(transport:)`);
      no suite registers a global stub. `OpenAIProviderTests` already used an ephemeral session.
      Remaining full-run flakes (LibraryViewModel, SeriesIdentityResolver) reproduce on the
      pre-migration tree too: `LibraryIndex.shared` keeps one slot and version per source.
- [x] Add flow on typed payloads: `SearchClient` adds (movie, series, scene, artist) run
      `ServarrService.add(ArrAddPayload)` through the store; `ArrAddPayload` gained top-level
      `monitor` and `foreignId`; the untyped `ArrAPIClient.post` is gone. `AddRequestBodyTests`
      pins each whole body.
- [x] Data cache purge: `AppCaches.purgeExpired()` also sweeps the resource store
      (`ServiceGateway.sweepDataCache()`); `ServiceGateway.purgeDataCache()` → `purgeAll()`.
      Not in the UI: Settings' button clears images only and Developer options has no cache control.
- [x] `.defaultIsolation(MainActor.self)` in `Packages/ArrCore/Package.swift`. Wire models, the
      helper enums, the facades, the lock-guarded stores and the statics inside actors are
      `nonisolated`; MainActor default arguments (`ConfigStore.shared`) dropped; `MediaServerIndex`
      locks scoped with `withLock`. ArrCore compiles with zero warnings; `lint_missing_keys.py`
      clean (arr add operations renamed so the lint stops reading them as catalogue keys).
- [x] Widget demo: `UpcomingService.demo(sources:limit:)` over `ServiceGateway.demo(kinds:)` (bundled
      fixtures, no global flag); the dead `DemoMocks` queue/upcoming/history builders deleted.

## Wave 6c — criteria sweep

- [x] Criterion 18: views and view-models take facades from `ConfigStore` (`radarrClient`, `arrClient(for:)`,
      `tmdbClient`, `mediaServerClient`) or `ServiceHandles` for drafts; `grep "Client("` in Views/ViewModels = 0.
- [x] Criterion 19: `LocalToolBackendFixtureTests` runs all 28 tools on the bundled fixtures through
      `ServiceGateway.override` (task-local), a demo gateway with placeholder origins.
- [x] Criterion 21: Developer options → "MediaKit telemetry" shows `TelemetryRecorder.report()`.
- [x] Criterion 24: explicit `@MainActor` on Views/ViewModels types removed (default isolation).
- [x] `ServiceGateway.reconcileRegistry()` serialises reconciles; two adopters racing produced a second
      concurrent `MediaStack.reconcile` that dropped an in-flight read (flaky `lidarrSearchFormatted`).
- [x] Dead `SeriesIdentityResolver` session override removed.

## Phase 6 — verification

- [x] Three schemes build, three `swift test`, relaunch; `GoldenParityTests` (criterion 26) with six
      documented exclusions; `anonymize_fixtures.py --check` clean; error presenter on catalogue keys
      (`MediaKitErrorCatalogTests`); `DiscoveryTests`; report:
      `docs/superpowers/baseline/2026-09-15-mediakit-phase6-report.md`.
- [x] Criterion 27 (2026-09-27, `log show`): first queue load 1287 / 1218 ms after process start;
      44 / 37 requests in the first 60 s (DEBUG `Gateway` notice). Per-screen counters need UI navigation and stay
      owner-read in Developer options → "MediaKit telemetry".

## Phase 7 — API 26 UI (macOS)

- [x] Typed `AppMessages` replace every `Notification.Name` post (criterion 23).
- [x] `GlassEffectContainer` around the popover islands; queue selection bar as `safeAreaBar` with
      `.scrollEdgeEffectStyle(.soft, for: .top)`.
- [ ] `Observations` for `ConfigStore` consumers (37 views on an `ObservableObject`; separate change).
- [x] ~~Markdown via `Text(.init(markdown:))`~~ won't do: swift-markdown stays for GFM tables, nothing to remove.
- [ ] Criterion 28 (Spotlight intents with parameters, queue snippet, `@Generable` results).
