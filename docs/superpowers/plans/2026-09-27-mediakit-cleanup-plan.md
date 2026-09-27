# MediaKit cleanup — finish the migration, one path per concern

Source: three read-only audits of the tree at `1db315c2` (2026-09-27), spot-checked against the code.
Supersedes the "done" claims in `2026-09-15-mediakit-migration-plan.md` where they disagree (see Phase H).
Paths: `AC/` = `Packages/ArrCore/Sources/ArrCore/`, `MK/` = `Packages/MediaKit/Sources/MediaKit/`.

Rule for every phase: one model per resource (MediaKit's), one implementation per concern, reads through
the store, facades from `ConfigStore`. Delete what the rule makes redundant; no shims, no typealiases.

## Phase A — bugs (first, small)

- [x] `.volatile` rows are never fresh: `staleAt = fetchedAt + retention(.zero)` marks them invalidated at
      once (`MK/Store/ResourceStore.swift:66,308`, `FreshnessClass.retention`). The 5 s TTL and
      `fetchReleases`' `ttl: 60` never hit.
- [x] Download-client failures never mark the client down: `actionFailureProvesClientDown` matches only
      `HTTPError.transport/.status`, which nothing throws since the clients moved to `MediaKitError`
      (`AC/ViewModels/QueueViewModel.swift:865-875`). Map `MediaKitError` (unreachable, unauthorized).
- [x] `purge`/`purgeAll` bump no tag ticks, so `Snapshot` and observers never rebuild after a purge
      (`MK/Store/ResourceStore.swift:237,243`).
- [x] Criterion 18 is false: views build `TMDBClient(apiKey:)` (`AC/Views/WaitCards.swift:76`,
      `AC/Views/DiscoverCardView.swift:75`); saved-config `ServiceHandles` in `MediaServerSettingsPane:361,405`,
      `MediaEditPanel:400` (now `ConfigStore.searchClient(for:)`). The view-models' saved-config `ServiceHandles`
      moved to Phase C with the services.
- [x] Criterion 24 is false: explicit `@MainActor` on `Views/NativeConfirmAlert.swift:12`,
      `ViewModels/SuggestionCarousel.swift:9`, `Views/MessageObserver.swift:32`. All 31 type-level annotations in
      ArrCore removed (default isolation); the six compiler warnings a clean build showed are fixed too.
- [x] `QueueAggregator.swift:136` logs the error message `.public`; it carries the host and the server's text.
- [x] Catalog keys missing: `Views/AddDownloadView.swift:124,240` (now `addDownload.fileCount`, `addDownload.partialFailure`, six languages).
- [x] `MK/Services/Download/QBittorrentService.swift:59` dead `ids.count == 1 ? nil : nil`.

## Phase B — one model per arr resource (the big one)

ArrCore kept ~25 of its own record types when the clients became facades, and `ArrAPIClient.read<T>`
re-decodes MediaKit's plans into them. Same endpoint, two shapes, one cache key: `movie(id:)` is read as
`ArrMovie` (38 fields, `ArrQueueLoader.swift:87`) and `RadarrMovieDetail` (17 fields, `RadarrClient.swift:20`);
the store keeps whichever re-encoded payload wrote last, so the other reader can get fields silently nil.
Same for `seriesDetails`, `album(id:)`, `movies()/series()/artists()`, lookups, files, health.

- [x] Facades return MediaKit types: `ArrMovie`, `ArrSeries`, `ArrEpisode`, `ArrAlbum`, `ArrArtist`, `ArrTrack`,
      `ArrFile`, `ArrHealth`, `ArrCredit`, `ArrCustomFormat(Detail)`, `ArrQualityProfile`, `ArrImage`, `ArrCommand`.
- [x] Delete ArrCore's parallel types: `Radarr/Sonarr/Lidarr/Whisparr…LibraryRecord`, `…LookupRecord`,
      `…Detail`, `SonarrEpisodeDetail/EpisodeFile/SeasonInfo/SeasonStats`, `LidarrTrackFile/TrackDetail/AlbumDetail`,
      the six rating structs, `ArrHealthRecord`, `ArrLibraryFile.Quality`, `ArrCredit.Image`, `QualityProfile`
      (`AC/Models/ArrTypes.swift`, `ArrDetailTypes.swift`, `SearchTypes.swift`), and the ArrCore
      `ArrImage/ArrFile/ArrCommand/ArrCustomFormat/ArrQualityProfile/ArrCredit` that shadow MediaKit's names.
- [x] Remove `ArrAPIClient.read<T>`'s re-wrap (`ArrAPIClient.swift:33-39`, `TMDBClient.swift:351`): reading the
      service `Resource` as is also restores `harvest`, so the identity crosswalk finally gets written.
- [x] Remove `HTTPError` (`AC/Services/HTTPError.swift`): the three live cases become `MediaKitError` or a small
      local error with catalog strings; `typealias KitJSON` goes with the untyped bridges (Phase C).
- [x] Views read MediaKit fields; file adapters collapse (`ExistingFileBanner:54,71,84`, `UpgradeDiffView:59,68`,
      `UpcomingRowView:212,226`, `ArrCompositions.snapshot:265`, `LibraryFileState:56-70`).
- [x] Also one model for TMDB (`TMDBPerson/Details/Video…`), media-server libraries/sessions, `JSONValue`,
      `DiskSpace` → `ArrDiskSpace`, `Release` → `ArrRelease` + `ReleaseTarget`; the Edit form reads/writes
      MediaKit's typed `ArrRecordSettings`; arr error-body parsing (ProblemDetails too) lives in MediaKit.

## Phase C — one implementation per concern (DRY)

- [x] Poster URL: one function over MediaKit `ArrImage` + media-server override (today `ArrCompositions.posterURL`
      = `Array<ArrImage>.posterURL` line for line, plus wrappers in `DetailViewHelpers:37`, `SearchClient:155`,
      `RichToolResultView:351,426`); Lidarr "cover, then artist poster" fallback written 6× → one helper.
- [x] Media-server keys: one derivation on MediaKit types (today `ArrCompositions.keys` + `ArrMediaServerKeys.swift`
      extensions + inline in `SearchClient:166,177`, `LocalToolBackend+Discover:230,256,499,525`, `WaitCards:170`;
      already drifted: Discover's Sonarr drops `.tmdbSeries`, `SonarrSeriesDetail` lacks the `> 0` guard).
- [x] One arr facade: `fetchQueue/fetchCalendar/fetchAll…/setMonitored/serviceName` are identical across
      `Radarr/Sonarr/Lidarr/WhisparrClient` (Lidarr's `fetchAll` drifted to `try? ?? []`); switches rebuilding
      clients by source (`SearchClient:13-18`, `ServiceHandles:7-37`, `LocalToolBackend+ArrTools:184,275-292,769,884`).
- [x] Clients from `ConfigStore` facades everywhere: 17 services and ~50 tool sites construct clients ad hoc
      (`CastProvider`, `CountryProvider`, `TrailerProvider`, `EpisodeRatingProvider`, `LibraryPosterSampler`,
      `SpotlightIndexer:207`, `ChatLinkRouter:70`, `PersonStore`, `LibraryIndex`, `UpcomingService`,
      `LibrarySummaryService`, `DownloadDropService`, `MediaServerIndex`, `ConnectionHealthMonitor`,
      `ConfigStore:771`, `LocalToolBackend*`), and the view-models' saved-config `ServiceHandles`
      (`SearchViewModel:162-174,381` with its `configSignature` workaround, `LibraryViewModel:279`, `ServerStatusModel:58`).
- [x] Lookup record → `SearchResult`: one mapper (`SearchClient.unify*` copied in `LocalToolBackend+Discover:229-275,
      497-539`, library variants `:301-340`).
- [x] TMDB id from TVDB id: one helper (`CastProvider:75`, `TrailerProvider:36`, `CountryProvider:29`,
      `EpisodeRatingProvider:25`); drop pass-through wrappers.
- [x] Upcoming fetch/merge/sort: one path (`QueueAggregator:223-242`, `UpcomingService:10-54`,
      `LocalToolBackend+ArrTools:735-767`; cutoffs differ).
- [x] Endpoint knowledge back into MediaKit (done in B): `ArrAPIClient.getRawObject:84`, `updateLibraryRecord:122-135`
      (= `ServarrService.readModifyWrite`), `postCommand:150` (untyped body), `fetchReleases` plan edits `:99-101`,
      `TMDBClient:386` plan edit; `MediaServerFacade.nowPlaying:84` bypasses the store (→ `liveSessions` or a resource).
- [x] Artwork sizing: `PosterStore.sourceURL:366-374` and `TMDBClient.imageURL:514` redo `ArtworkReference.tmdbCDN`;
      `PosterStore` stops reaching into `gateway.kit` (`:423,431`) through a gateway method.
- [x] Small: `"S%02dE%02d"` ×6 → one formatter; `formatLibrary` vs `libraryText`; `ConfigStore.serviceConfig(for:)`
      ⊂ `config(for:)`; `ConfigStore.mediaServerClient` = `ServiceHandles.mediaServer`; shared arr helpers out of
      `RadarrClient.swift:55-138`.
- Notes: key-parameterised services (`PersonStore`, `SeriesIdentityResolver`, `LibraryIndex`, `LibrarySummaryService`,
  the connection probes) still build a client from the config they are handed — that is the one factory, not a copy.
  `MediaServerIndex` and `ArrQueueLoader` keep their own queue-gateway fan-out; the widget, the calendar tool and the
  queue share `UpcomingService.curate` (cutoff: start of today).

## Phase D — MediaKit: wire it or delete it

Decided 2026-09-27: delete the composition engine; keep Discovery for a separate UI change
(`docs/superpowers/follow-ups.md`); optimistic effects move into MediaKit. Open items keep a recommendation in brackets.
- [x] `CompositionEngine`/`CompositionContext`/`Provenance` — unused; queue is composed by hand. Delete.
- [x] `IdentityStore` reads/`MediaIdentity` — crosswalk written, never read [after B, use it for
      `SeriesIdentityResolver` and media-server keys, or delete reads].
- [x] `Discovery` (Bonjour/beacon) — parsers only, no UI. Kept; the UI is a follow-up (`docs/superpowers/follow-ups.md`).
- [x] Optimistic effects — `Command.optimistic` stored and never read; `LiveStream.apply/clear` unused while
      `QueueViewModel` keeps its own overrides + `hold(until:)`. Move the overrides into `PendingEffect` carried by
      the command, applied by the stream; delete the VM copy and `hold(until:)`.
- [x] Progress stream — never started, 2 s policy never runs, snapshot written never loaded [make it a plain
      on-demand read, or start it for the open panel].
- [x] `liveSessions`, `.widgetRefresher`, `EventHub.setCadence`, `DataEvent.connectivity`, unhandled `.woke`,
      `ConfigurationChanged`/`ConnectivityChanged` unobserved, `InstanceDescriptor.limits`, `ResourceStore.start/
      seed/purge(_:)/sweepEvery/lastSweep`, `meta` table, unused telemetry API, `Signposts.make`,
      `ServarrService.supportsMovieVocabulary`, `.whisparrV2`, `TMDBService.artwork`, `ServarrService.artwork`,
      `ServiceGateway.engine/tmdb/mediaServer`, `rebuild(demo:)` (no callers), `refreshNow(priority:)` ignoring it,
      `setInstances` (no callers) — wire where a feature needs it, delete the rest.
- [x] Demo `FixtureTransport` rules (`DemoRule`, `queueStatus`) unreachable: gateway passes no rules [wire
      pause/resume in demo, or delete].
- [x] `MediaKitRecording.RecordingTransport` has no runner [add the re-record command CLAUDE.md promises, or
      delete and fix CLAUDE.md].
- [x] Duplicates inside MediaKit: probe plans vs `testConnection` resources (same URL, two cache keys);
      `track` hard-codes `/api/v1|v3` vs `ServarrProfile.apiBase`; tag-tick `Observations` loop ×3; media-server
      auth placement ×2; sweep scheduling ×3; foreground flag in `EventHub` and `LiveStream`; batch error
      fallback differs; `CapabilityProbe.restore` only ordinal 0.
- Outcome: composition engine and the unreferenced API deleted; the crosswalk is read (series tmdb→tvdb, one hop
  through the record); effects are declared by commands and applied by `ServiceGateway.run` to the live streams
  (VM overrides and `hold(until:)` gone); progress is an on-demand read with no checkpoint; demo pause/resume
  stick by download id (`DemoRule` gone); `mediakit-record` is the re-record runner; tick sums and the command
  tracker's API base are shared. Left as is, on purpose: drafts (ordinal > 0) re-probe instead of restoring,
  `EventHub` foreground vs `LiveStream` activity are two different knobs set from one place, the capability probe
  talks to the pipeline (no cache key to collide with).

## Phase E — caches outside MediaKit

- [x] `SearchOptionsCache`, `PersonStore` LRU + in-flight, `IndexerNames`, `LibraryPosterSampler`,
      `MediaServerIndex.seasonPostersByItem`, `DownloadDropService` destinations → store reads.
- [x] `LibrarySnapshotStore`/`WidgetDataStore` file snapshots vs MediaKit `Snapshot`/`live_snapshots` [decide].
- Outcome: `SearchOptionsCache` deleted (store `reference` reads; `.cacheOnly` for the Library's first paint),
  `IndexerNames` and `People` (was `PersonStore`) are stateless read-throughs, drop destinations read the arrs'
  client lists from the store. Kept on purpose: `LibraryPosterSampler`'s memo (one deck per session, shared by
  the warm-up and the view), `MediaServerIndex`'s season-poster map (the synchronous index poster resolution
  needs), and the `LibrarySnapshotStore`/`WidgetDataStore` files (finished projections for first paint and the
  widget, not copies of wire payloads).

## Phase F — demo branches (the plan said they go)

- [ ] ~~`demoDisks`~~ (done in B); `MediaEditPanel:411-417`;
      `SeriesIdentityResolver:52,62`; `QueueViewModel:235,801`; widget library `DemoMocks.librarySummaries`
      (`ArrBarrWidgets.swift:105`) → fixtures; `canControl`/visibility demo gating (`QueueRowView:120`,
      `QueueGroupRowView:50`, `QueueTitleGroupRowView:38`, `QueueListView:1007`, `DetailView:233`,
      `ServiceConfig:44`, `SearchScope:47`).

## Phase G — conventions and leftovers

- [ ] Logging: per-call loggers `PersonView:381`, `IndexerNames:60,72`; instance loggers `PosterStore:146`,
      `PersonStore:27` (wrong category); spelled subsystem `ServiceGateway:424-425`; `"detail"` category case.
- [ ] Localization: hardcoded English in `HTTPError` descriptions, `SearchClient:174` seasons, `ChatViewModel:269`,
      `"Unknown"` fallbacks in `ArrCompositions`, `WelcomeView:484,491,560`, `LLMProvider:100`, `"OK"` fallbacks;
      `nl` missing from CLAUDE.md's language list.
- [ ] Stale/orphan comments: `TMDBClient:327`, `LocalToolBackend+ArrTools:276-297`, `SearchViewModel:437`,
      `DownloadDropService:108`, `PosterStore:136`, `AppCaches:19`, `TrailerProvider:22-24`, `ServiceConfig:42`,
      `UpcomingService:5`, `DetailView:776-781`, `UpgradeDiffLine:355`, `CastProvider:42`; empty MARKs
      `ArrTypes:104,218`; unread fields `ArrDetailTypes:104`, `TMDBClient:560`.
- [ ] Periphery sweep after B–F.

## Phase H — make the old plan true

- [ ] Uncheck or correct in `2026-09-15-mediakit-migration-plan.md`: criterion 18 and 24 (Wave 6c), "`lastEventAt`
      drives the realtime-quiet check" (no caller), `liveProgress` as a live stream (never started), widget role
      vs spec §9.3 (not read-only, no refresher), §6.3 two snapshots (one combined).
- [ ] Criteria partially met, add the missing tests: 2 (cancel one waiter), 8 (100 parallel reads), 10 (last waiter
      cancels the fetch), 15 (ArrCore cold start), 17 (20-card composition on fixtures), 21 (invalidations line,
      per-host counters), 26 (golden parity through recording), 27 (per-screen counters, `swift test` time).
- [ ] Still open from the old plan: `Observations` for `ConfigStore` consumers; criterion 28.
