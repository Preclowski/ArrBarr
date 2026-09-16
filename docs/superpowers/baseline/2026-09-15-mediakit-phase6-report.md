# MediaKit phase 6: verification and final report

Branch `feat/mediakit-foundation`, HEAD after this report's commit. Baseline: `2026-09-15-mediakit-phase0-report.md`.

## 1. What exists and where

| Piece | Location |
|---|---|
| MediaKit package (zero dependencies, tools 6.2, `defaultIsolation(nil)`, strict concurrency, zero warnings) | `Packages/MediaKit` — Core, Wire, Kernel, Store, Instances, Identity, Events, Live, Compose, Artwork, Discovery, Services/{Servarr, Download, MediaServer, TMDB} |
| Recording transport + allow-list (never in the app) | `Packages/MediaKit/Sources/MediaKitRecording` |
| Fixtures, one file per kind, anonymised, open-source titles | `Packages/MediaKit/Sources/MediaKit/Fixtures/{radarr,sonarr,lidarr,whisparr,plex,tmdb,qbittorrent,sabnzbd}.json`; packer `Tools/fixtures/pack_fixtures.py` |
| ArrCore entry point | `Services/ServiceGateway.swift` (owned by `ConfigStore`, reconciles on config change, demo → `FixtureTransport`, `demo(kinds:)` factory, task-local `override` for tests) |
| Facades (value handles, no HTTP) | `RadarrClient`/`SonarrClient`/`LidarrClient`/`WhisparrClient`/`SearchClient`, `DownloadClients.swift`, `TMDBClient`, `MediaServer/MediaServerFacade.swift`; `ServiceHandles` + `ConfigStore.*Client` accessors for views |
| Compositions | `Compositions/ArrCompositions.swift`, `ArrQueueLoader.swift`, `QueueAggregator` on MediaKit |
| Typed in-app messages | `Services/AppNotifications.swift` (`AppMessages.*`), `Views/MessageObserver.swift` |
| Spec / plan | `docs/superpowers/specs/2026-09-15-mediakit-foundation-design.md`, `docs/superpowers/plans/2026-09-15-mediakit-migration-plan.md` |

## 2. Baseline versus end state

| Measure | Phase 0 | Now |
|---|---|---|
| ArrCore sources (LOC) | 64 616 | 56 495 |
| Replaced communication code (LOC) | 14 317 | 0 (deleted) |
| MediaKit production LOC (budget ≤ 8 590) | spike 3 459 | 6 821 (+110 recording target) |
| ArrCore `swift test` | 956 tests, 5 pre-existing failures, 8.0 s | 763 tests, same 5 failures, 15.3 s wall (measured right after edits, includes recompilation) |
| MediaKit `swift test` | 57 tests, 5.6 s | 87 tests, 1.4 s |
| ArrMCPServer `swift test` | 15 tests, 27.1 s | 15 tests, 14.1 s |
| Schemes | ArrBarr, ArrBarriOS, ArrBarrWidgets build | all three build (`CODE_SIGNING_ALLOWED=NO` for iOS/widgets) |
| `URLSession` in ArrCore services | every client | `ServiceGateway` (session construction), `PosterStore` (artwork bytes), `OpenAIProvider` (LLM); the rest are comments |

The five ArrCore failures are the phase-0 ones (asset catalogue and `.xcstrings` are not built by SwiftPM).

## 3. Acceptance criteria (prompt §4)

| # | Evidence | Result |
|---|---|---|
| 1 | `ResourceStoreTests.secondReadInsideTTLIsZeroRequests` | pass |
| 2 | `ResourceStoreTests.concurrentReadersCoalesceIntoOneRequest`, `HostGovernorTests.cancelledWaiterLeavesTheQueue` | pass |
| 3 | `ResourceStoreTests.commandInvalidatesItsTags`, `WriteShapeTests` | pass |
| 4 | `SignalRFrameTests.tagMapKeepsTheStatusSkip`, `liveHubEndToEnd` | pass |
| 5 | `CapabilityTests.registryChangeInvalidatesEverything`, `ResourceStoreTests.rowsFromAnotherFingerprintAreInvisible` | pass |
| 6 | `ResourceStoreTests.volatileRowsNeverReachSQLite` | pass |
| 7 | `HostGovernorTests.rateLimitBlocksOnlyThatHost` (TestClock) | pass |
| 8 | `HostGovernorTests.backgroundShareCannotStarveInteractive`, `sessionLaneNeverWaitsBehindRegularSlots` (limit is a parameter) | pass |
| 9 | `HostGovernorTests.breakerOpensAfterThreeFailuresAndHalfOpensLater`, `ResourceStoreTests.breakerOpenServesStaleAfterOneActorHop` | pass |
| 10 | `PipelineTests.cancellationIsRethrownAsCancellationError`, `writeIsNeverRetried` | pass |
| 11 | `CapabilityTests.probeOncePerFingerprintAndPersisted`, `demoteAndPromoteAreSymmetric`, `deriveRules` | pass |
| 12 | `HygieneTests.redactionScrubsEveryKnownSecretCarrier`, `credentialsNeverPrint`, `telemetryReportCarriesNoURL`; `anonymize_fixtures.py --check` → 0 real values | pass |
| 13 | `MediaKitErrorCatalogTests` (every case → `mediakit.error.*` key, six languages); `Tools/loc/lint_missing_keys.py` → 0 missing | pass |
| 14 | `grep DemoMode Packages/MediaKit` → 0; `DemoDataFlowTests`, `LocalToolBackendFixtureTests` run on `FixtureTransport` | pass |
| 15 | `ResourceStoreTests.coldStartReadsDiskWithoutARequest`, `LiveStreamTests.snapshotIsAvailableBeforeTheFirstRequest` | pass (MediaKit level; no ArrCore-level cold-start integration test) |
| 16 | `ArrBarrWidgets` builds, imports only ArrCore, `grep "Client("` → 0; fetches through `UpcomingService`/`LibrarySummaryService` → gateway → MediaKit; group-container SQLite with WAL on iOS | partial: macOS has no app group entitlement, so the macOS widget keeps its own sandbox database; no `.snapshotReader` role |
| 17 | `CompositionTests`, `ResourceStoreTests.chunkedBatchIsOneRequestPerChunk` | pass |
| 18 | `grep` for `RadarrClient(`…`TMDBClient(`, `MediaServerClientFactory` in Views/ViewModels → 0 | pass |
| 19 | `LocalToolBackendFixtureTests`: 28 tools on fixtures, catalogue unchanged | pass |
| 20 | three `swift test` green (ArrCore minus the 5 pre-existing), three schemes build, MediaKit zero warnings | pass |
| 21 | Settings → About → Developer options → "MediaKit telemetry" shows `TelemetryRecorder.report()` per host (requests, skipped, failures, breaker, 429, bytes) and per instance (hits, misses, stale, coalesced) | pass (owner reads it in the app) |
| 22 | `grep "#available(macOS 26\|#available(iOS 26\|@available(macOS 26"` outside TonightCore → 0 | pass |
| 23 | `grep "NotificationCenter.default.post(\|Notification.Name(\""` in ArrCore Sources + ArrBarr → 0; `AppMessages` typed messages | pass |
| 24 | `.defaultIsolation(MainActor.self)` in `Packages/ArrCore/Package.swift`; no explicit `@MainActor` on Views/ViewModels types | pass |
| 25 | `DiscoveryTests` (Bonjour TXT + UDP beacon fixtures, no network) | pass |
| 26 | `GoldenParityTests.everyCorpusOperationHasAProducer`: every corpus (client, operation) has a MediaKit producer; excluded with reason: `tmdb.similarMovies/similarTV/tvCreators` (replaced by recommendations/credits), `qbittorrent.contains`/`sabnzbd.contains` (old probe ops), `sonarr.realtime.negotiate` (SignalR source, not a resource) | pass with 6 documented exceptions |
| 27 | Per-screen request counters and cold-start time were not read back: `log show` returns nothing in this session's sandbox, so the numbers live in the in-app telemetry report for the owner to read; `swift test` wall times above | not measured here |
| 28 | Not done: intents as Spotlight actions with parameters, queue-status snippet, `@Generable` results for Quiz/`suggest_titles` | open |

## 4. Out of scope / deferred (plan file has the checklist)

- Wave 3 leftovers: `MediaServerIndex` → MediaKit `Snapshot`, `PosterStore` on `ArtworkReference`, `ConnectionHealthMonitor` → `HostGovernor` health, `SpotlightIndexer`/`LibraryIndex` as store consumers.
- Wave 4: `QueueViewModel` on `LiveStream` instead of its timers.
- Remaining `URLProtocol` stub suites (they run through the shared session in the test process; `ServiceGateway.override` is the path to migrate them).
- Phase 7 items 2 and 4: `ConfigStore` is an `ObservableObject` shared by 37 views, moving it to `Observations` is its own change; chat markdown keeps swift-markdown (GFM tables), `Text(.init(markdown:))` would not remove code.
- Criterion 28.

## 5. Decisions taken during the migration

- `ResourceKey` includes the path template: `search.lookup` covered two Lidarr endpoints and coalesced them (flaky `lidarrSearchFormatted`).
- `ServiceGateway` serialises registry reconciliation; adopters arriving mid-run get a second pass.
- A test process gets its own empty-profile gateway (`.memory`, `mustRevalidate`, shared session) so nothing reaches the owner's services from a test.
- Demo profiles carry placeholder origins (`http://<kind>.demo.invalid`) that only `FixtureTransport` sees.
