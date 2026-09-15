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
      routes through `URLSession.shared`, `.memory` database, `mustRevalidate` override).
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
- [ ] `ConnectionHealthMonitor` → `HostGovernor.health` + `EventHub.lastEventAt`.
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

## Wave 6 — removal + isolation

- [x] `HTTPClient`, `RealtimeUpdates`, `DownloadProgressService`, the per-arr queue/calendar/
      history wire records and the old client HTTP paths are gone; the client type names remain
      as facades (consumers unchanged). `ConnectionHealthMonitor` stays (it schedules probes,
      not HTTP). `CoalescingCache` and `TitleMetadataStore` stay (in-memory caches over
      MediaKit-backed calls; candidates for a later pass).
- [ ] Migrate the remaining `URLProtocol` stub suites to `ScriptedTransport`/`FixtureTransport`
      (today they run through the shared session with global registration).
- [ ] `.defaultIsolation(MainActor.self)` in `Packages/ArrCore/Package.swift`; fix what the
      compiler reports; `python3 Tools/loc/lint_missing_keys.py`.

## Phase 6 — verification

- [ ] Three schemes build, three `swift test`, relaunch, `TelemetryRecorder.report()` per screen
      read through `GetConsoleOutput`, parity run with `RecordingTransport` (reads only), fixture
      re-anonymisation, phase-6 report under `docs/superpowers/baseline/`.

## Phase 7 — API 26 UI (macOS)

- [ ] Spec §12, four commits, relaunch after each.
