# Phase 1 critique — lens: does it survive ArrBarr's real call sites?

Inputs: the three designs (`design-cache-first.md` = **CF**, `design-transport-first.md` = **TF**,
`design-model-first.md` = **MF**), prompt §0/1/3/4, phase-0 report §3.3/§4/§6, and the 14 consumers
read at their current lines in `Packages/ArrCore/Sources/ArrCore` and `ArrBarrWidgets/`. Every code
block below is written against the design's *own* declared API (section C of each), not against
what it would be nice for the API to have; where a call site cannot be written without inventing a
type the design does not declare, that is the finding.

Scale: 5 = expressible as declared, request count ≤ baseline, isolation and cancellation correct;
3 = expressible with a hack or a missing-but-obvious helper; 1 = the declared API cannot carry the
call site.

## 1. Score table

| # | Consumer (file:line today) | CF | TF | MF |
|---|---|---|---|---|
| 1 | `QueueViewModel.refresh` / `startForegroundPolling` / burst coalescing / `systemDidWake` (QueueViewModel.swift:362–700, 763) | 4 | 4 | 2 |
| 2 | `QueueAggregator.fetch` merge ⨝ `DownloadProgressService` (QueueAggregator.swift:74–150, DownloadProgressService.swift) | 3 | 3 | 2 |
| 3 | `DetailView.load` movie (7 req) / series (9 +1) (DetailView.swift:1333–1407) | 4 | 2 | 4 |
| 4 | `LibraryViewModel.loadIfNeeded` + `LibraryIndex` versions / `fileImported` (LibraryViewModel.swift:153–212, LibraryIndex.swift) | 4 | 3 | 4 |
| 5 | `SearchViewModel.search` ×4 arrs + TMDB person + ownership; `loadOptions` / `addMovie` / `addSeries` / `addAlbum` (SearchViewModel.swift:284–420, 477–620; SearchClient.swift:402) | 3 | 4 | 3 |
| 6 | `SonarrClient.setSeasonMonitored` v5→v3 + untyped monitored PUTs (SonarrClient.swift:400–520) | 2 | 4 | 3 |
| 7 | `LocalToolBackend` `list_download_queue`, `get_title_details`, `media_server_now_playing`, `custom_formats` (LocalToolBackend+*.swift) | 4 | 4 | 4 |
| 8 | `ArrBarrWidgets` timeline providers under Q2(a) (ArrBarrWidgets.swift:95–135, 503–525) | 2 | 4 | 3 |
| 9 | `MediaServerIndex.posterURL(for:)` / `isWatched(_:)` sync in bodies (MediaServerIndex.swift:57–75; ArrTypes.swift:928) | 4 | 4 | 4 |
| 10 | `PosterStore.image(for:tier:apiKey:)` → `ArtworkReference` (PosterStore.swift:179, 367–390; RemotePoster.swift:232) | 5 | 3 | 2 |
| 11 | `ServerStatusModel` diskspace + `ConnectionHealthMonitor` probes + `ServerStatusView` health source (ServerStatusModel.swift, ConnectionHealthMonitor.swift, QueueViewModel.swift:880–960) | 3 | 3 | 3 |
| 12 | `DownloadDropService` (DownloadDropService.swift:36–100) | 4 | 4 | 4 |
| 13 | `RealtimeUpdates` negotiate / websocket / backoff / silence → polling (RealtimeUpdates.swift:357–530, 696–730) | 2 | 5 | 2 |
| 14 | Demo: 92 `DemoMode.isActive` lines → transport choice; demo popover cold start | 4 | 5 | 4 |
| | **Sum (max 70)** | **48** | **52** | **44** |
| | Criterion 18 reachable through the gateway | yes (engine + `arr(_:)` handle) | letter only (`kit.servarr(id)` is callable from a view) | yes (gateway exposes compositions, `connection` is `private(set)`) |
| | Criterion 15 (cold start from SQLite before first request) | `hydrate()` + `.cacheOnly` — yes | `lastKnown()` + `peek` — yes | `last()` sync + `.cacheOnly` — yes, best (sync in `init`) |

Baseline reference (phase 0 §3.3, config Radarr+Sonarr+Lidarr+qBit+SAB+Plex+TMDB): popover cold 25 / 11–14; library 7 / 0; detail movie 7 / 3; detail series 9(+1) / 3; search 8 / 5; add 2 (Lidarr 3) / 0; status 3 / 3.

---

## 2. Per-consumer code and verdicts

### 2.1 QueueViewModel — refresh, foreground polling, realtime bursts, wake

Today: `refresh()` (all sources + calendar + health + media-server index, queue-not-drop via `pendingRefresh`), `refreshQueues()` on a 30 s `Timer` gated by `canSkipForegroundTick` (realtime covers every source **and** nothing is downloading **and** no live optimistic override), `scheduleRealtimeRefresh` (0.25 s burst, 1 s floor open / 30 s closed), `noteQueueStatus` skips a refetch when `queue/status` counts equal the last fetch and the panel is closed, `systemDidWake` → `realtime.forceReconnect()` + `refresh()`.

**CF**
```swift
// ServiceGateway.start(): feeds built once; QueueViewModel consumes.
gateway.queue = LiveFeed(id: .queue, cadence: .init(foregroundInterval: .seconds(30),
    backgroundInterval: .seconds(120), burstWindow: .milliseconds(250),
    foregroundFloor: .seconds(1), silenceBeforePolling: .seconds(300)),
    database: db, encode: …, decode: …, refresh: { prio in await Self.fetchQueueRows(prio) }, clock: .system)

// QueueViewModel
func start() { task = Task { for await v in await gateway.queue.updates() { commit(v) } } }
func startForegroundPolling() { Task { await gateway.queue.setActivity(.foreground) } }
func stopForegroundPolling()  { Task { await gateway.queue.setActivity(.background) } }
func systemDidWake() { Task { await gateway.wake.systemDidWake(); await gateway.queue.pulse() } }
// SignalR frame → EventTagMap → store.invalidate → LiveFeed.pulse() (coalesced by burstWindow)
```
Verdict 4. `setActivity`, `pulse`, `Cadence`, `WakeEventSource.systemDidWake()` map 1:1 onto today's entry points and delete ~200 lines of timer code. Gaps: (a) `canSkipForegroundTick` needs "is anything downloading" — `LiveFeed<Value>` is generic and has no `isActive: (Value) -> Bool` hook, so either every tick fetches (regression to pre-gate traffic) or the VM keeps the timer; (b) F.4 says `queueStatus` frames "feed `pulse()`, invalidate nothing" — that **loses** `noteQueueStatus`'s counts-unchanged skip, so every Servarr status broadcast (~1/min per arr) becomes a refetch while the popover is closed; (c) `silenceBeforePolling` needs per-instance last-push stamps and `pulse()` takes no instance.

**TF**
```swift
let hub = kit.events                                       // EventHub, burst window inside
await hub.attach(SignalRSource(instance: .sonarr0, pipeline: kit.pipeline, clock: .system, log: log), for: .sonarr0)
let queue = kit.liveQueue()                                // LiveStream<QueueRecord>
func start() { task = Task { for await v in await queue.values() { commit(v) } } }
func startForegroundPolling() { Task { await queue.setCadence(.seconds(30)); await queue.refreshNow(priority: .interactive) } }
func stopForegroundPolling()  { Task { await queue.setCadence(nil) } }
func systemDidWake() { Task { await hub.wakeAll() } }      // forceReconnect + .woke → tags → refreshNow
// realtime-covers-every-source: needs hub.lastEventAt(instance) — NOT in EventHub's API
```
Verdict 4. `EventHub` owns burst/floor and `queueStatus → ∅ unless counts differ` keeps the skip. `wakeAll()` is the right shape. Gap: the 300 s silence gate (`realtimeCoversEverySource`) needs per-instance last-event timestamps; `EventHub` exposes `events()` only, so the VM re-derives them from the raw stream — 30 lines that belonged in the hub.

**MF**
```swift
let q = connection.queue(.radarr1)            // LiveStream<ArrQueueRow>, one per instance
Task { for await rows in q.values() { commit(.radarr, rows) } }
// Who pumps it? Nothing in C.6 takes a fetch closure. So QueueViewModel keeps:
foregroundTimer = Timer(30 s) { Task {
    for i in arrs { let rows = try? await store.read(connection.radarr(i).queue, policy: .mustRevalidate, priority: .background)
                    await connection.queue(i).ingest(rows?.value ?? [], from: .network) } } }
realtimeDebounce[source] = Timer(max(0.25, floor - sinceLast)) { … }     // §F4: "stay in ArrCore"
func systemDidWake() { Task { await connection.governor.note(wake: .now); await signalR.forceReconnect() } } // EventSource has no forceReconnect
```
Verdict 2. `LiveStream` is a sink (`ingest`, `apply`, `checkpoint`) with no pump; `PollingEventSource` "2 s floor" exists for download clients but nothing polls the arr queue. F4 explicitly keeps burst/floor/silence in ArrCore, so ~300 lines of `QueueViewModel` timer logic survive, and the VM reads a `volatile` resource through `Store.read` to feed the stream — the very thing §3.5 forbids for compositions. `EventSource` lacks `forceReconnect`. `Governor.note(wake:)` (half-open every host on wake) is the one genuinely good addition.

### 2.2 QueueAggregator merge with download-client progress

Today: 4 arr `/queue` (+ side-loads) in parallel; `trackableIds` = lowercased `downloadId`s; one `DownloadProgressService.snapshot(configs:ids:)` (2 s TTL, in-flight coalescing, `nil` = source failed vs `[:]` = answered-empty; all-failed keeps the last map for ≤60 s; some-failed → those rows fall back to arr values); `overlay` by lowercased id; `unreachable` only on transport failure.

**CF**
```swift
gateway.queue = LiveFeed(…, refresh: { prio in
    let arrs = await engine.values(configuredArrs, priority: prio) { i, ctx in try await ctx.read(arr(i).queue) } // volatile through ctx?! §3.5 says never
    let ids = Set(arrs.values.compactMap { try? $0.get() }.flatMap { $0.value.compactMap { $0.downloadId?.lowercased() } })
    let prog = await gateway.progress.hydrate()                     // last value only; no ids narrowing
    return LiveValue(value: overlay(arrs, prog?.value ?? []), measuredAt: .now, pending: [], origin: .network,
                     partial: Set(arrs.filter { $0.value.isFailure }.map(\.key)))
})
```
Verdict 3. Two feeds (`queue`, `progress`) with a per-feed `refresh` closure is the right split, and `LiveValue.partial` names some-failed. Missing: (a) the closure has no access to the feed's previous value, so "all clients failed → keep last map for ≤60 s" cannot be expressed inside `refresh` — it needs `LiveFeed` to own that rule or hand `previous` in; (b) `progress` cannot narrow to the queue's ids (`SabnzbdClient`/`QbittorrentClient.fetchProgress(ids:)` do today); (c) the queue rows are a `volatile` resource and the only way to read them is `ctx.read` or `store.read` — the design's own rule says compositions never do that, so the refresh closure must call `store.read(…, policy: .reload)` directly, which works but is undocumented.

**TF**
```swift
let queue = LiveStream<QueueRecord>(kind: .queue, instances: arrs, interval: .seconds(30), store: store, clock: clock,
    fetch: { i, pipeline in try await kit.servarr(i).queue.fetch(pipeline) })
let progress = LiveStream<DownloadProgress>(kind: .progress, instances: clients, interval: .seconds(2), store: store, clock: clock,
    fetch: { i, pipeline in try await kit.download(i).progress(ids: []).fetch(pipeline).values })   // ids: unknown here
// QueueViewModel joins the two streams; `partial` + "empty success replaces, full failure does not" is stated in C.8
```
Verdict 3. `partial` and the empty-vs-failed rule are explicit (§C.8), the per-instance `fetch` runs through the pipeline (breaker, limiter). Two conflicts: `DownloadClient.progress(ids:)` is a `Resource` of class `volatile` read via the store (§3.5 forbids), and the per-instance closure signature `(InstanceID, RequestPipeline)` has no channel for the queue's ids, so every progress tick asks qBittorrent for *all* torrents. The 60 s `maxCacheAge` decay ("stop overlaying a dead client's last value") is not stated — a stopped qBittorrent freezes bars until the next successful cycle, the exact bug `DownloadProgressService.freshCache` fixed.

**MF**
```swift
for i in arrs { Task { for await rows in connection.queue(i).values() { arrRows[i] = rows; recompose() } } }
for c in clients { Task { for await rows in connection.progress(c).values() { prog[c] = rows; recompose() } } }
func recompose() { let byID = Dictionary(prog.values.flatMap { $0 }.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { _, n in n })
                   queues = arrRows.mapValues { overlay($0, byID) } }
// "some failed ≠ all failed" claimed as LiveStream.ingest(partial:) — C.6 declares ingest(_:from:) only
```
Verdict 2. Ten streams joined in the view model, no `partial` on `LiveStream` (the `ingest(partial:)` overload in §E.5 is not in §C.6), no pump for either side (see 2.1). The merge is not worse than today's, but nothing in MediaKit carries the `DownloadProgressService` semantics the brief asked about.

### 2.3 DetailView.load

Today, movie: `fetchMovieDetails` + `fetchMovieFile` (async let), `profileName` (SearchOptionsCache 15 min), `CountryProvider.movieCountries` (TMDB), `CastProvider.movieCredits` (Radarr `/credit`, CoalescingCache LRU), `TrailerProvider` (TMDB videos) = 7 first / 3 second; series: details + episodes + episodeFileMap (async let) + profile + TMDB countries + TMDB aggregate_credits (+ `/find` for tvdb→tmdb) = 9(+1) / 3. Plus `watchSearchState` polls `isSearchRunning` (`GET /command`) every 3 s after a search. `.task(id: item.id)` cancels on item change.

**CF**
```swift
struct MovieDetailRequest: Hashable, Sendable { let instance: InstanceID; let id: Int }
let c = try await gateway.engine.value(MovieDetailRequest(instance: .radarr0, id: id)) { ctx in
    async let movie   = ctx.read(radarr.entity(id: id))                     // catalog 6 h
    async let files   = ctx.batch([id], via: radarr.filesBatch)              // catalog
    async let profile = ctx.optional(radarr.qualityProfiles)                 // reference 24 h
    async let credits = ctx.optional(radarr.credits(movieID: id))            // immutable
    let ident = await ctx.identity(.init(namespace: .arr(.radarr0), value: "\(id)"), kind: .movie)
    async let tmdb    = ctx.optional(tmdb.movie(ident.id(in: .tmdbMovie)))   // countries
    async let videos  = ctx.optional(tmdb.videos(ident.id(in: .tmdbMovie)))  // trailer
    return MovieDetail(try await movie, await files[id], await profile, await credits, await tmdb, await videos)
}
// search progress: store.run(radarr.search(ids: [id]))  // Command.tracking polls /command at .background
```
Verdict 4. Requests: 7 cold (F.2's own count of 8 includes a `historyFor` the movie screen does not fetch today — drop it or it is +1 vs baseline, criterion 27), 0 on second open (memo or fresh tiers). `Command.Tracking.arrCommand` replaces the 3 s `watchSearchState` poll — the best answer of the three to a call site nobody asked about. **Defect:** `CompositionContext` is a `final class @unchecked Sendable` with mutable `touched/tags/oldest/failures` and no lock; the `async let` fan-out above (which is how `DetailView.load` is written today and must stay to keep first-open latency) mutates those from four child tasks concurrently. Either the context gets a lock (cheap) or the build is forced sequential (4× RTT). Not stated.

**TF**
```swift
let c = try await engine.compose(DetailInput(.movie(radarr0, id))) { (ctx: borrowing CompositionContext) in
    async let d = ctx.read(radarr.details(id), maxAge: .minutes(10))   // ✗ `borrowing` parameter captured by async let child task
    let files   = try await ctx.read(radarr.files(for: id))
    let prof    = try await ctx.read(radarr.qualityProfiles)
    let credits = await ctx.optional(radarr.credits(movieId: id))
    let facts   = await ctx.optional(tmdb.movie(tmdbID))
    let videos  = await ctx.optional(tmdb.videos(.movie(tmdbID)))
    return MovieDetail(try await d, files, prof, credits, facts, videos)
}
// 20-card grid: ctx.readAll([radarr.files(for: 1), …])  — homogeneous [Resource<V>] only; BatchHint never declared
```
Verdict 2. Two structural problems. (a) `CompositionContext` is `~Copyable` passed `borrowing`; a `borrowing` parameter cannot be captured by an escaping closure, and `async let` initialisers are child-task closures — F2's own example (`async let details = ctx.read(...)`) does not compile as declared, so every composition is serial: movie detail goes from ~1 RTT to ~6 RTT on first open. (b) `readAll<V>(_ rs: [Resource<V>])` is homogeneous, so the heterogeneous detail fan-out cannot use it, and the batching it promises for criterion 17 groups "by `Resource.batch` hint" — `BatchHint` is referenced in `Resource` and never defined, so how `readAll` turns N `files(for:)` into one `moviefile?movieId=…` request is unspecified. Request count 7 / 0 is fine; latency and criterion 17 are not.

**MF**
```swift
let c = try await composer.compose(DetailInput(identity)) { input, ctx in
    async let movie   = ctx.read(radarr.movie(id: id))                              // ctx non-Sendable, captured by child tasks — same race as CF unless serial
    async let files   = ctx.readBatch(radarr.movieFiles, keys: [id])                // one request, chunk 40
    async let prof    = ctx.readOptional(radarr.qualityProfiles)
    async let credits = ctx.readOptional(radarr.credits(movieId: id))
    let tmdbID = await connection.crosswalk.known(.arr(.radarr1, id), in: .tmdbMovie)   // ctx has no `crosswalk`; F2's `ctx.crosswalk` is not declared
    let videos: [TMDBVideo]? = tmdbID == nil ? nil : await ctx.readOptional(tmdb.movieVideos(tmdbID!))
    return MovieDetailFacts(try await movie, await files[id], await prof, await credits, videos)
}
```
Verdict 4. `readBatch` with declared `chunkSize` is the cleanest criterion-17 answer; the crosswalk removes the series `/find` hop after the first visit (harvested from `movie(id:)`'s `tmdbId`). Cold 6–7 / 0. Defects: `CompositionContext` is a non-Sendable class — `async let` children capturing it is a Swift 6 error, so the same serial-or-lock choice as CF, unstated; and `Store.read`'s default `policy: .staleWhileRevalidate` returns the stale row after a `fileImported` invalidation, kicks a background refresh, and `changes(matching:)` fires on *invalidation*, not on the revalidated commit — the open detail keeps showing the stale file banner until something else invalidates. (Only TF's `observe` states "yield cached → yield revalidated".)

### 2.4 LibraryViewModel.loadIfNeeded

Today: `LibraryIndex` (10 min TTL, fingerprint-keyed slot, in-flight join, `versions[source]` bumped on commit and on `invalidate`, `fetchFailed` so the tab can tell "unreachable" from "empty"), `invalidateSoon` from the `fileImported` SignalR event, `alternateTitleMap` (Radarr `/alttitle`), `profileNameMap` via `SearchOptionsCache`.

**CF**
```swift
func loadIfNeeded(source: QueueItem.Source, force: Bool) async {
    let i = gateway.instance(source)
    let gen = await gateway.store.generation()          // "version": bumped on every invalidation
    if !force, indexVersions[source] == gen { return }
    let c = try? await gateway.engine.value(LibraryRequest(i), priority: .interactive, minFreshness: force ? .zero : nil) { ctx in
        let rows = try await ctx.read(radarr.library)                       // catalog 6 h, tag library(.movie)
        let alts = await ctx.optional(radarr.alternateTitles)               // immutable
        let profiles = await ctx.optional(radarr.qualityProfiles)
        return Self.unify(rows, alts, profiles) }
    failed[source] = c?.provenance.isComplete == false; indexVersions[source] = gen
}
```
Verdict 4. `fileImported` → `EventTagMap` → `library(.movie)` tag replaces `invalidateSoon`; `provenance.isOffline` replaces `fetchFailed`. `generation()` is global, not per source, so an unrelated invalidation forces a re-unify of a 3000-title library — cheap to fix by exposing a per-tag generation, but as declared it is a regression of the exact optimisation the file comments explain.

**TF**
```swift
let tick = kit.store.revision.tick(for: .collection("library", i))     // per-tag version — exactly LibraryIndex.versions
if !force, indexVersions[source] == tick { return }
let rows = try? await kit.store.read(kit.servarr(i).library)             // FreshnessClass.archival = 30 d
```
Verdict 3. `StoreRevision.tick(for:)` is the right version primitive. But `library` is classed **archival (30 d)**: `LibraryIndex.ttl` is 10 min precisely as "backstop for changes no event tells us about". A title deleted or unmonitored in Radarr's own UI stays in ArrBarr's grid for a month unless `EventTagMap` maps every `movie|series|artist` `deleted/updated` frame — E.1 does not list those, and the app has never parsed them. Also `StoreRevision` is a plain `@Observable final class` observed through `Observations` — see defect TF-1.

**MF**
```swift
let lib = try? await store.read(radarr.allMovies)      // warm 10 min — matches LibraryIndex.ttl
if lib?.fetchedAt == indexStamp[source], !force { return }
Task { for await _ in store.changes(matching: [.collection(i, .library)]) { await loadIfNeeded(source: source, force: false) } }
```
Verdict 4. Class and TTL match today; `changes(matching:)` is per-tag; `Cached.fetchedAt` is a usable version. Same SWR re-emit gap as 2.3 but here it does not matter (the next `changes` hits after the revalidate commit only if commit bumps — it should be stated that it does).

### 2.5 SearchViewModel.search + SearchAddPanel add flows

Today: `searchTask?.cancel()` per keystroke, four `SearchClient.lookup` in `async let`, each pairs with an *unstructured* `fetchLibraryOwnership` task ("belongs to every caller, isn't cancelled with this search"), TMDB `searchPerson` + person credits for the "Starring" section, `CancellationError`/`URLError.cancelled` swallowed bare; `loadOptions` (`SearchOptionsCache` 15 min per fingerprint); `addAlbum` = `GET /api/v1/search?term=` (find the `foreignAlbumId` row) then `POST /album`; every add then `LibraryIndex.invalidate`.

**CF**
```swift
searchTask = Task { [gen] in
    let results = await gateway.engine.values(scopedArrs.map { SearchRequest($0, term) }, priority: .interactive) { req, ctx in
        async let hits = ctx.read(arr(req.i).lookup(term: req.term))                 // activity 60 s — repeat query = 0 requests
        async let owned = ctx.read(arr(req.i).library)                               // catalog; coalesced with the Library tab's read
        return join(try await hits, try await owned) }
    let people = await ctx.optional(tmdb.searchPerson(term))                         // catalog
    guard gen == generation else { return }; apply(results, people) }
// add
_ = try await gateway.store.run(radarr.add(payload))                                 // INV library(.movie), calendar
let groups = try await gateway.store.read(lidarr.lidarrSearch(term: result.title), policy: .reload)  // step 1
_ = try await gateway.store.run(lidarr.addAlbum(payload(from: groups, foreignId)))  // step 2 — E.1 calls this ONE command; Command has one `plan`
```
Verdict 3. Reads are clean and the repeat-query case beats baseline (8 → 0 within 60 s). Cancellation: cancelling `searchTask` cancels the sole waiter on `lookup`, which cancels the request (today's behaviour), but `library` is shared with the Library tab — the coalescer keeps it alive for the other waiter, which is exactly what the unstructured task in today's code hand-rolls. Good. **Defect:** `Command` carries a single `RequestPlan`; E.1's `addAlbum` (GET→POST) and `setMonitored`/`updateLibraryRecord` (GET→PUT) are listed as commands but are not expressible as one — the caller must read, then build a command from the read value, which means the "typed RMW envelope" (`ArrLibraryRecord.rest`) is assembled in ArrCore, not behind the vocabulary.

**TF**
```swift
let lookups = await ctx.readAll(scopedArrs.map { kit.servarr($0).lookup(term: term) })   // homogeneous — fine here
let owned   = try? await kit.store.read(kit.servarr(i).library)
// add: one Command, two requests inside `run`
let cmd = kit.servarr(.lidarr0).addAlbum(result, profile: pid, metadata: mpid, root: folder)   // run: GET /search → POST /album
try await kit.store.run(cmd)                                                                  // invalidates c:library, g:lookup
```
Verdict 4. `Command.run: (RequestPipeline) async throws -> Void` carries multi-request writes, and `invalidates` fires after `run` returns. `g:lookup` invalidation on add is a nice touch (the added title stops being addable immediately). `loadOptions` = `qualityProfiles`/`rootFolders`/`metadataProfiles` at `reference` 12 h → 0 on reopen. Cancellation: `URLSessionTransport` rethrows `CancellationError` *bare* while `MediaKitError.cancelled` also exists — the VM's `is CancellationError` check keeps working, but the ArrCore mapper must special-case two spellings of one thing.

**MF**
```swift
async let r = ctx.read(connection.radarr(.radarr1).lookup(term: term))      // live 60 s; `harvest` writes tmdb/imdb crosswalks
async let s = ctx.read(connection.sonarr(.sonarr1).lookup(term: term))
let owned = await connection.crosswalk.known(.tmdbMovie(id), in: .arr(.radarr1)) != nil   // ownership without the library payload!
// add
try await store.run(connection.lidarr(.lidarr1).addAlbum(result, …))   // E.3: "GET /search then POST /album" — Command.request builds ONE HTTPRequest
```
Verdict 3. The crosswalk answering "do I own this?" from ids harvested on every lookup is the best idea in the search path (no 3000-row library read for ownership). But `Command` has one `request` closure and `CompositeCommand` (§E.2) is never declared, so the two-step Lidarr add is not expressible as written.

### 2.6 SonarrClient.setSeasonMonitored and the monitored PUTs

Today: `setSeriesMonitored` = `getRawObject` → mutate `[String: Any]` → `put`; `setSeasonMonitored` tries `PUT /api/v5/series/{id}/season`, falls back on 404/405 to v3 = **two** GET+PUT round trips (write the opposite value first to force Sonarr's cascade); `setEpisodesMonitored` = `PUT /episode/monitor`.

**CF**
```swift
let caps = await gateway.capabilities.capabilities(for: .sonarr0, using: store)
if caps.has(.arrSeasonMonitorV5) {
    _ = try await store.run(sonarr.setSeasonMonitoredV5(seriesID: id, season: n, monitored: m))       // one plan — fine
} else {
    for value in [!m, m] {                                                    // v3 double-PUT, 4 requests, in ArrCore
        let rec = try await store.read(sonarr.entity(id: id), policy: .reload).value                  // typed ArrLibraryRecord
        _ = try await store.run(sonarr.updateLibraryRecord(rec.settingSeason(n, monitored: value)))   // PUT with `rest` bag echoed
    }
}
// "on rejected(404|405) the registry drops the capability and the command retries in v3 form exactly once" — no Command can do this
```
Verdict 2. The capability gate and the typed `rest: [String: JSONValue]` envelope are right. But the design's thesis says "client code cannot express call A then B", then E.1 and F.6 promise a single `setSeasonMonitored` command with an in-band v3 fallback and a one-shot demotion retry — neither is possible with `Command { plan: RequestPlan }`. The fallback ends up in ArrCore, in every caller (DetailView has three `setSeasonMonitored` call sites: 336, 516, 1057).

**TF**
```swift
let cmd = await kit.servarr(.sonarr0).setSeasonMonitored(seriesID: id, season: n, monitored: m)   // async: reads CapabilityRegistry
try await kit.store.run(cmd)     // v5: one PUT; else .readModifyWrite(read:edit:then:) = GET,PUT,GET,PUT inside `run`; 404/405 clears cap + reruns v3
```
Verdict 4. Exactly today's semantics, typed, behind one call. Minor: the `.readModifyWrite` helper is shown in E.1 but not in §C's `Command` API (it is a constructor, so acceptable); `RetryDisposition.never` on the PUT but the design retries the *whole* command on the v5 404 — that is a different mechanism and should be named in `Command`, not implied.

**MF**
```swift
let cmd = connection.sonarr(.sonarr1).setSeasonMonitored(seriesId: id, season: n, monitored: m)
// request: (CapabilityIndex) throws -> HTTPRequest  — synchronous capability read, no await: good
try await store.run(cmd)   // "becomes a three-step CompositeCommand" — type not declared; Command.request returns ONE HTTPRequest
```
Verdict 3. The synchronous `CapabilityIndex.has(_:_:)` inside the request builder is the neatest gate of the three, and `Governor.run(idempotent: false)` prevents an accidental double PUT. But the v3 path is three requests and `Command` builds one; `CompositeCommand` appears only in prose. Also: on a fresh install `CapabilityIndex.current` returns the conservative default (no v5) until `CapabilityProbe.ensure` has run, and the runtime correction only goes v5→v3 — nothing promotes v3→v5 except a probe, so `start()` must `ensure` every arr before the first write or v5 Sonarrs get the double-PUT for a while.

### 2.7 LocalToolBackend — four tools (28 unchanged)

Today `list_download_queue` fetches four `/queue`s fresh in a task group (bypasses `QueueViewModel`); `get_title_details` = details + optional `/credit` or TMDB `tv/{id}/credits`; `media_server_now_playing` = `client.nowPlaying()`; `custom_formats` = `fetchCustomFormats()` (no cache). MCP calls arrive from NIO threads through `MCPCallRouter` → `LocalToolBackend` (an actor/async funnel, not MainActor).

**CF**
```swift
func listDownloadQueue(_ args: JSONValue) async throws -> ToolCallOutput {
    await gateway.queue.pulse()                                          // ask for fresh; coalesced
    let v = await gateway.queue.hydrate() ?? LiveValue(value: [], …)     // last known ≤30 s old — hydrate() reads SQLite, not memory
    let items = v.value.map(QueueItem.init); let failures = v.partial.map { "\($0) unreachable" } … }
func customFormats(_ args) async throws -> ToolCallOutput {
    let cf = try await gateway.store.read(arr(i).customFormats).value }   // reference 24 h — today's 0-cache becomes 1/day
func mediaServerNowPlaying() async throws -> ToolCallOutput {
    let s = try await gateway.store.read(plex.nowPlaying, policy: .reload).value }      // volatile, fresh
```
Verdict 4. Everything is expressible off-main; `.reload` gives the tools the fresh reads an LLM answer deserves. Wrinkle: `LiveFeed` has no "current value" accessor besides `hydrate()` (SQLite) and `updates()` (stream) — a tool wanting the in-memory last value must open a stream and take one element. Add `current()`.

**TF**
```swift
let q = kit.liveQueue(); await q.refreshNow(priority: .interactive)
for await v in await q.values() { return format(v.elements, failures: v.partial); }   // first element after refresh
let cf = try await kit.store.read(kit.servarr(i).customFormats).value
let np = try await kit.store.read(kit.mediaServer(.plex0).nowPlaying, maxAge: .zero).value   // volatile; maxAge tightens to "now"
```
Verdict 4. `refreshNow` + `values()` is the honest shape for "fresh queue for an LLM". `maxAge: .zero` is the reload spelling. `get_title_details` with `include_cast` = `details` + `credits` reads, both cached — a repeated chat turn costs 0.

**MF**
```swift
let q = try await store.read(connection.radarr(.radarr1).queue, policy: .mustRevalidate)     // volatile — tools may read the store directly
let cf = try await store.read(connection.radarr(.radarr1).customFormats).value               // cold 6 h
let np = try await store.read(connection.mediaServer(.plex1).sessions, policy: .mustRevalidate).value
```
Verdict 4. `ReadPolicy.mustRevalidate` is the clearest of the three spellings. `ServiceGateway` in MF exposes domain compositions only (`queueRows()`, `detail(_:)`…), so `LocalToolBackend` either grows 28 gateway methods or reaches `gateway.connection.*` — the latter is what the sketch does; fine, it is a Service, not a View.

### 2.8 ArrBarrWidgets timeline providers (owner decision Q2(a): shared SQLite + own refresh)

Today: `LibrarySummaryService` (4× `fetchAll*`) and `UpcomingService` (4× `fetchCalendar`) per timeline, demo via `WidgetDataStore.isDemoActive` + `DemoMocks`, secrets from the group suite through `WidgetDataStore.serviceConfig`. A timeline provider must return before the extension is suspended; fire-and-forget work after `return Timeline(...)` does not reliably run.

**CF** (F.5 verbatim, then what it does)
```swift
let conn = try MediaKitWidgetConnection(group: "group.pl.incred.ArrBarr", maxBytes: 16 << 20)
var entry = await conn.libraryEntry(policy: .cacheOnly)                     // stale row, fine
if entry.isStale { entry = await conn.libraryEntry(policy: .staleWhileRevalidate, priority: .background) }
return Timeline(entries: [entry], policy: .after(…))
// .staleWhileRevalidate returns the SAME stale row immediately and schedules a background refresh
// that the extension process is suspended before finishing. The widget never shows fresh data.
```
Verdict 2. As written the widget is snapshot-only (option Q2(b)) while claiming Q2(a). The fix is one word (`.reload` or `.cacheFirst`, awaited) but the design's flagship widget flow is wrong. Second problem: the 7 MB Plex index in a 16 MB widget cap is handled by "a resource allow-list for the widget" (§J Q8) that no API declares. Third: `FactDatabase` with a custom `DispatchSerialQueue` executor plus WAL from two processes is fine, but `maxBytes` sweep by the widget can delete the app's `catalog` rows — sweeping should be app-only.

**TF** (F5)
```swift
let db = try SQLiteDatabase.open(at: groupURL, readOnly: true); let store = ResourceStore(database: db, pipeline: pipeline, …)
let cal = await store.peek(servarr.calendar(start, end)); let queue = await liveQueue.lastKnown()
if cal.map({ $0.fetchedAt < .now - 30 * 60 }) ?? true {
    let rw = try SQLiteDatabase.open(at: groupURL, readOnly: false)          // re-open read-write
    let fresh = try await ResourceStore(database: rw, …).read(servarr.calendar(start, end), maxAge: .minutes(30), priority: .background)
    return Timeline(entries: [entry(cal), entry(fresh)], …)
}
```
Verdict 4. Awaited read, writes back into the shared DB, second timeline entry. The read-only-then-read-write double open is odd (two `ResourceStore`s, two memory tiers) but harmless. `CredentialProvider` from the group suite is answered in Q4. Library summaries need `servarr(i).library` (`archival`) — for the widget that is the 3000-row payload decoded per timeline; today's `LibrarySummary.radarr(from:)` reduces it to counts, so the widget should read a *count* composition, not the rows — unstated, and the 8 MB widget sweep cap would evict the app's library rows.

**MF** (F5)
```swift
let conn = try MediaKitConnection(.init(role: .widget, databaseLocation: .group, transport: URLSessionTransport(session: s),
                                        credentials: WidgetCredentials(), clock: .system, log: log, limits: .init(maxConcurrent: [.background: 2])))
let rows = conn.queue(.radarr1).last()                                       // sync, from last_known loaded in Store.init
let lib  = try await conn.store.read(conn.radarr(.radarr1).allMovies, policy: .cacheOnly)
if lib.fetchedAt < .now - 30 * 60 { _ = try await conn.store.read(conn.radarr(.radarr1).allMovies, policy: .staleWhileRevalidate) } // returns stale at once; revalidation may never run
```
Verdict 3. `MediaKitConnection(.widget)` with a role is the cleanest construction, `last()` is synchronous, and `WidgetDataStore.isDemoActive` → `FixtureTransport` is one mechanism for two processes. Same SWR-in-an-extension mistake as CF in step 3 (needs `.mustRevalidate`, awaited).

### 2.9 MediaServerIndex.posterURL(for:) / isWatched(_:) — synchronous reads in bodies

Today: `NSLock`-guarded `[MediaServerExternalKey: MediaServerEntry]`, rebuilt every 15 min off the queue poll, called from `Array<ArrImage>.posterURL(baseURL:)` in `Models/ArrTypes.swift:928` (a *pure function in a model file* reaching a singleton), `SeasonDetailView`, `DiscoverSources`, three tools.

**CF**
```swift
let proj: Projection<MediaServerFacts> = await gateway.engine.projection(.mediaServer, tags: [.init(instance: .plex0, scope: .library(.movie)),
                                                                                              .init(instance: .plex0, scope: .sessions)]) { ctx in
    let index = await ctx.optional(plex.index(section)) ?? []; let hist = await ctx.optional(plex.watchHistory(limit: 40)) ?? []
    return MediaServerFacts(byKey: …, watched: …) }
// in a body / pure model function
gateway.mediaServerProjection.value.posterOverride(for: keys)   // NSLock read, no await
```
Verdict 4. Same shape as today, rebuilt by tag instead of timer. Cost: CF's disk tier stores **bytes**, so every rebuild re-decodes the 7 MB Plex payload from SQLite (in `@concurrent`, but a full JSON parse of 7 MB on each `sessions`/`library` invalidation — `sessions` is volatile and is tagged on the same projection, so a now-playing tick would rebuild the whole index unless the tags are split). Split the projection in two.

**TF**
```swift
let snap = Snapshot<MediaServerFacts>(tags: [.collection("library", .plex0)], initial: .empty) { store in
    let idx = try? await store.read(kit.mediaServer(.plex0).libraryIndex(section)); return MediaServerFacts(idx?.value) }
await snap.attach(to: kit.store)
snap.current.value.posterURL(for: keys)          // body read
```
Verdict 4. Declared, lock-guarded, versioned. `identity_map` written by guid parsing means `isWatched`/poster lookups by external id are a dictionary hit. Fine.

**MF**
```swift
let snap = Snapshot<MediaServerProjection>(tags: [.collection(.plex1, .library), .collection(.plex1, .history)], store: store) { store in
    await MediaServerProjection.build(from: store, plex: connection.mediaServer(.plex1)) }
snap.current.value.artwork(for: identity)        // MediaIdentity-keyed; ArrImage extension builds identity from tmdb/imdb ids
snap.current.value.isWatched(identity)
```
Verdict 4. The only design that names the projection type and its two methods. Callers must construct a `MediaIdentity` from the arr record (cheap value). `refreshIfNeeded()` ("a version compare") is odd — who calls it, from a body? Drop it.

### 2.10 PosterStore.image(for:tier:apiKey:) → ArtworkReference

Today: `RemotePoster` passes `apiKey` (arr `X-Api-Key`) and `PosterStore.download` adds media-server headers by host match (`MediaServerPosterAccess.headers(for:)`), `sourceURL(for:tier:)` picks TMDB `w342`/Plex transcode/Jellyfin fill; key = SHA-256(url) so a token in a URL would poison the key.

**CF**
```swift
// producer: wire model + instance → reference (the client stamps baseURL + credential ref, decoder stays pure)
let ref = radarr.artwork(for: movie, kind: .poster)          // ArtworkReference(url: token-free, headers: ["x-api-key": .credential(.radarr0)], sizing: .native)
// PosterStore
public func image(_ ref: ArtworkReference, tier: PosterTier) async -> PlatformImage? {
    let sized = ref.sized(.init(tier)); let headers = await gateway.headers(for: sized)   // resolves .credential per request
    … download(sized.url, headers) … key = sized.cacheKey }
```
Verdict 5. `HeaderRef.credential(InstanceID)` is the one representation that is `Hashable & Codable` *and* cannot leak a token: the reference can sit in a cache row or a Spotlight item indefinitely. `sized(_:)` folds `MediaServerPosterAccess.sizedURL`, `PosterTier.cdnVariant` and `TMDBClient.imageURL`. Only nit: the pure `decode: (Data) -> Value` cannot know the instance's base URL (arr images are relative `/MediaCover/…` paths), so references must be built by a client method, not by the decoder — stated nowhere, but the `Resource.map` closure captured by the client can carry it.

**TF**
```swift
public protocol ArtworkAuthorizing: Sendable { func headers(for: ArtworkReference, tier: ArtworkTier) async -> HTTPHeaders }   // "PosterStore implements the byte layer" — so who implements THIS?
let ref = ArtworkReference(url: u, owner: .plex0, sizing: .plex(...))
let h = await gateway.kit.artworkHeaders(for: ref)      // §I — not a member of `struct MediaKit` in §I's declaration
```
Verdict 3. The reference is token-free and `owner: InstanceID?` is the right idea, but the auth path is described three ways (a protocol whose implementer is unclear, a `kit.artworkHeaders` that does not exist, and "PosterStore asks the gateway"). Pick one: `MediaKit.artworkHeaders(for:) async -> HTTPHeaders` resolving through `SessionBrokerPool`.

**MF**
```swift
public struct ArtworkReference: Hashable, Sendable, Codable {
    public let headers: [String: String]      // "resolved per request by the caller, not stored" — but it IS a stored, Codable, Hashable field
```
Verdict 2. If a client ever fills `headers` with `X-Plex-Token: …`, the value is persisted by any `Codable` path (the crosswalk, a Snapshot cache, a Spotlight attribute) and participates in `Hashable`; if it never fills it, the field is dead and the caller resolves headers some undeclared way. Either way the declaration contradicts its own comment. Adopt CF's `HeaderRef`.

### 2.11 ServerStatusModel diskspace, ConnectionHealthMonitor probes, ServerStatusView's health source

Today: `ServerStatusModel.refresh` fetches `/diskspace` from every arr (no cache; 3 requests per Status open); `ConnectionHealthMonitor.probeIfDue` runs `testConnection()` on download clients, **OpenAI**, TMDB and the media server once per minute while the panel is visible; `ConnectionHealth.shared` (MainActor `@Observable`) is what `ServerStatusView` and the "Needs you" rows read synchronously, with a 3-strike debounce, `forceOK`/`forceDown` from manual tests and from queue-action failures that prove a client down.

**CF**
```swift
// health: breaker is the source of truth; ArrCore mirrors it into ConnectionHealth for the MainActor views
Task { for await (host, state) in await gateway.breaker.changes() {
    for service in gateway.services(on: host) { ConnectionHealth.shared.apply(state, to: service) } } }
// diskspace
let disks = await gateway.engine.values(arrs.map(DiskRequest.init)) { i, ctx in try await ctx.read(arr(i).diskSpace) }   // activity 60 s → Status reopened within a minute = 0 requests
```
Verdict 3. Diskspace goes from 3/3 to 3/0 — better than baseline. Three problems shared by all three designs, stated once here: (a) health is keyed by **host** (`HostKey` = scheme+host+port) while `ConnectionHealth` is keyed by **service** — a homelab with Radarr and Sonarr behind one reverse proxy (`https://nas/radarr`, `https://nas/sonarr`) gets one breaker, one dot, and one 429 shutting both; `InstanceRegistry.host(id)` is a many-to-one map, so "single source of truth" is true only when every service has its own port; (b) `ConnectionHealthMonitor` also probes **OpenAI** — LLM providers are out of scope (§1.7) and the breaker never sees an OpenAI request, so deleting the monitor orphans the AI dot in Settings and the "Needs you" AI row; (c) the breaker only learns about a service that is *asked* — a download client with an idle queue is never requested (the design's own point), so its dot stays `.unknown` forever, where today's probe made it green. `health()` being an actor call means the view needs a MainActor mirror anyway.

**TF**
```swift
Task { for await msg in NotificationCenter.default.messages(of: MediaKitEvents.shared, for: .connectivityChanged) {
    ConnectionHealth.shared.apply(msg.health, hostServices(msg.host)) } }
let disks = try? await kit.store.read(kit.servarr(i).diskSpace)     // live 60 s
```
Verdict 3. `ConnectivityChanged` as a typed message is the tidiest bridge, and `HostHealth.throttled(until:)` correctly keeps a 429 from reading as "down". Same three problems; TF is the most explicit that "no periodic probe at all" is a feature, which makes (b) and (c) regressions by design.

**MF**
```swift
let h = connection.governor.health(hostOf(service))                // nonisolated sync — can be read on the main actor directly
// diskspace: try await store.read(connection.radarr(i).diskSpace)   // live 60 s
```
Verdict 3. `Governor.health(_:)` being a `nonisolated` lock-guarded read is the one API here a `@MainActor` view model can call without a mirror. `Governor.Health.unconfigured` distinguishes the third state the prompt asked for. Same three problems.

### 2.12 DownloadDropService

Today: `destinations` = for each arr, `fetchDownloadClients()` (cached per config signature until `invalidate()`), filter to clients ArrBarr has credentials for; `add` = client-specific multipart/JSON/XML-RPC add with the arr's category; `defaultPaused` = `app/preferences` (qBit) etc.

**CF**
```swift
let clients = await gateway.engine.values(arrs.map(DropRequest.init)) { i, ctx in try await ctx.read(arr(i).downloadClients) }  // reference 24 h; provenance.failures = "arr unreachable"
_ = try await gateway.store.run(qbittorrent.add(magnet, category: dest.client.category, paused: paused))   // RequestPlan.Body.multipart(_, boundary:)
let paused = try? await gateway.store.read(qbittorrent.preferences).value.startPaused                       // reference
// Transmission: download-dir = session-get + "/" + category → ctx.read(transmission.session) then run(add(dir:))
```
Verdict 4. Everything declared. The `reference` 24 h class on `/downloadclient` is longer than today's process lifetime cache in practice but `invalidate(instance:)` on a config edit covers the case the file cares about.

**TF**
```swift
let dc = try? await kit.store.read(kit.servarr(i).downloadClients)
try await kit.store.run(kit.download(.qbittorrent0).add(drop, category: dest.category, paused: paused))   // DownloadClient.add(_:category:paused:) -> Command
let p = try? await kit.store.read(kit.download(.qbittorrent0).defaultAddPaused()).value
```
Verdict 4. `DownloadClient` protocol has exactly the four members `DownloadDropService` needs. Transmission's session-dir two-step fits inside `Command.run`.

**MF**
```swift
try await store.run(connection.downloadClient(.qbittorrent1).add(payload, category: dest.category, paused: paused))
```
Verdict 4. `DownloadService.add` declared; the "Fails." exact-match → `contains(hash:)` probe → `commandRejected` sequence is written out in E.5, which is the one place a hand-written adapter earns its lines.

### 2.13 RealtimeUpdates — negotiate / websocket / backoff / silence → polling

Today (`SignalRConnection`): `POST /signalr/messages/negotiate?negotiateVersion=1` with `X-Api-Key` through an injectable `URLSession`, `webSocketTask` with `access_token` in the query, handshake consume, 15 s ping pump, `receiveWithTimeout`, backoff 1→30 s reset only if the cycle *lived* (frame or `minimumHealthyLifetime`), 5 min cold-start cadence after 10 dead cycles, `.queueChanged` emitted on every (re)connect, `lastEventAt(source)` feeds the 300 s silence gate.

**CF**
```swift
public actor SignalREventSource: EventSource {
    public init(registry: InstanceRegistry, transport: any Transport, clock: any MediaClock, log: MediaLog)
    // negotiate: transport.send(PreparedRequest)   ✓
    // websocket: Transport.send returns (status, headers, bytes) — there is no upgrade primitive.
    //            → the source must own a URLSession for `webSocketTask(with:)`: a second network path outside the injected transport
}
```
Verdict 2. The port keeps the frame parser (good, the 11 tests move) but the socket cannot go through `Transport`, so: the demo/fixture transport cannot replay frames (criterion 4's "test on frame fixtures" is a parser test only), tests of negotiate→handshake→backoff need a real `URLSession` (criterion 3 "tests never touch `URLSession.shared`" survives only if the source takes a session in `init`, which it does not), negotiate requests bypass the pipeline so they are invisible to telemetry (criterion 21) and to the limiter. §J admits "negotiate/handshake/backoff paths are untested today and will be untested after the port". That is the wrong answer to a known gap.

**TF**
```swift
public protocol Transport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    func open(_ request: HTTPRequest) async throws -> any WireSocket      // text/binary/closed frames, cancel()
}
let src = SignalRSource(instance: .sonarr0, pipeline: kit.pipeline, clock: clock, log: log)   // negotiate via pipeline.send, socket via pipeline.socket
await kit.events.attach(src, for: .sonarr0)
await fixture.enqueueFrames(recordedFrames, for: .sonarr0)                                     // criterion 4 end-to-end on fixtures
```
Verdict 5. `WireSocket` is the missing primitive; negotiate through the pipeline means the breaker, limiter and telemetry see it (a proxy that refuses the upgrade answers HTTP, so it does not strike the breaker — correct). `FixtureTransport.enqueueFrames` makes reconnect/backoff testable with a `TestClock`. The silence gate still needs `lastEventAt` (see 2.1).

**MF**
```swift
public actor SignalREventSource: EventSource { … }   // "ported off ArrCore types"; Transport has `send` only — same hole as CF
public struct WakeEventSource: EventSource { … }     // a struct conforming to a protocol with `start()/stop()` and an AsyncStream — fine
```
Verdict 2. Identical hole to CF; the design does not even mention where the socket comes from. `EventSource` lacks `forceReconnect`, which `systemDidWake` needs.

### 2.14 Demo — 92 `DemoMode.isActive` lines → one transport choice; demo popover cold start

Today: 46 branches in six clients return `DemoMocks`, `DemoQueueState.apply` keeps a pause/cancel across refreshes, `DemoMonitorState` keeps monitor toggles, `QueueViewModel.refresh` sleeps 1 s and force-OKs every health dot, six row views return `canControl = true` in demo, widget mirrors the flag through the group suite. Phase 0 found the gating inconsistent (`fetchHealth`, `fetchDiskSpace`, `deleteQueueItem` hit the network in demo; media-server and TMDB clients never check).

**CF** (cold start)
```swift
// AppDelegate
let choice: ServiceGateway.TransportChoice = DemoMode.isActive ? .demo : .live
await ServiceGateway.shared.start(transport: choice, location: choice == .demo ? .inMemory : .macOSAppSupport)
// .demo → FixtureTransport(corpus: .init(root: Bundle.module.url(forResource: "Fixtures")!), seed: .default, clock: .system)
let q = await gateway.queue.hydrate()               // nil: in-memory DB has no last_known → first frame is empty
await gateway.queue.pulse()                         // FixtureTransport answers radarr/fetchqueue.json …; pause → seed delta → next fetch reflects it
```
Verdict 4. All 46 client branches, `DemoMocks*`, `DemoQueueState`, `DemoMonitorState` go; the six `canControl` view checks and the Settings toggle stay as the one badge flag. Fixture matching by `OperationLabel(service, operation, variant)` couples every new resource's label to the *old client method name* the recorder used (`fetchQueue-api-v3-moviefile`), which is a naming tax on the shared `ArrResources` table but not a defect. No SignalR in demo (today's behaviour, acceptable). The first popover frame in demo is empty for one fixture round trip where today it is empty for a deliberate 1 s sleep — equivalent.

**TF**
```swift
ServiceGateway.shared.configure(with: ConfigStore.shared, demo: DemoMode.isActive)
// demo → FixtureTransport(bundleRoot: Bundle.module.fixtures, rules: .demo, mutable: .demoSeed); `open()` replays SignalR frames
let last = await kit.liveQueue().lastKnown()        // nil on a fresh in-memory DB, then refreshNow
```
Verdict 5. Same deletions, plus demo realtime (frames replayed through `open()`) — a demo that shows the "live" badge honestly. The `Rule` table is data; the phase-0 inconsistencies vanish because the *only* socket is the injected transport. One worry: `configure(with:demo:)` is described as "the ONLY construction of MediaKit … called once from AppDelegate and on every ConfigStore change" — if a config change rebuilds the kit (store, hub, sessions) the demo toggle is fine but a Settings keystroke drops the memory tier and reconnects SignalR; §I's bullet says it calls `instances.update` instead. Both cannot be true; say which.

**MF**
```swift
let gw = ServiceGateway.make(role: .app, configStore: .shared)     // picks FixtureTransport(bundle:world:clock:) when DemoMode.isActive
let rows = gw.connection.queue(.radarr1).last()                    // [] on a fresh DB — synchronous, first body renders empty state, no spinner race
```
Verdict 4. `DemoWorld` (JSON overlay rules + ~60-line interpreter) is the most ambitious replacement for `DemoQueueState`/`DemoMonitorState` and the least specified — "recorded mutations (monitor flags, queue statuses, added titles)" applied "to the decoded fixture" means the fixture transport decodes and re-encodes bodies per request, i.e. it knows every wire model. That is fine for a test-support type but pulls the wire models into the transport layer's dependency graph.

---

## 3. Top 10 defects per design

### Cache-first (CF)

1. **`Command` is one `RequestPlan`, but E.1 lists five multi-request commands** (`setMonitored` GET→PUT, `updateLibraryRecord`, `addAlbum` GET→POST, `setSeasonMonitored` v3 = GET,PUT,GET,PUT, plus the "demote and retry in v3 form once" promise in F.6). Breaks 2.5 and 2.6 (`SearchViewModel.addAlbum`, `SonarrClient.setSeasonMonitored`, `DetailView:336/516/1057`): the fallback and the typed RMW assembly move into ArrCore, into every caller.
2. **Widget flow F.5 never fetches.** `.staleWhileRevalidate` returns the stale row and schedules a refresh the extension is suspended before running; the "own refresh" half of owner decision Q2(a) is not delivered. (`ArrBarrWidgets.swift:150,497`.)
3. **`Transport` has no socket primitive.** `SignalREventSource(transport:)` cannot open a WebSocket through `send`, so the source owns a `URLSession`: negotiate bypasses limiter/breaker/telemetry, fixtures cannot drive reconnect/backoff, and §J concedes those paths stay untested. (`RealtimeUpdates.swift:409–530`.)
4. **Coalescer double-decrements on cancellation.** In C.5 the operation's `defer { Task { leave(key) } }` *and* `onCancel: { leaveCancelling(key) }` both run when a waiter is cancelled, so one cancelled reader of a shared fetch can drive `waiters` to 0 and cancel a request another reader is still awaiting — the opposite of criterion 2. (`SearchViewModel.swift:183` cancels per keystroke while the Library tab shares the `library` read.)
5. **`CompositionContext` is `@unchecked Sendable` with unlocked mutable accumulators.** `DetailView.load` fans out with `async let`; four child tasks append to `touched`/`tags`/`failures` concurrently. Add a lock or state that builds are sequential (and eat 4× RTT).
6. **`@concurrent` on actor-isolated methods** (`ResourceStore.sweep/purge`, `FactDatabase.sweep`). SE-0461 restricts `@concurrent` to nonisolated functions; these will not compile as declared. The SQLite work must be a nonisolated `@concurrent` free function the actor awaits.
7. **`Observations` bridge does not compile as sketched.** `Observations({ self.clockBox.generation })` reads actor-isolated state from a `@Sendable` nonisolated closure, and `InvalidationClock` is a non-Sendable `@Observable` class — MF's compile probe (§G) shows exactly this failure. The view bridge needs a lock-guarded `@unchecked Sendable` observable, as MF built.
8. **`queueStatus` frames "invalidate nothing, pulse the feed"** discards `noteQueueStatus`'s counts-unchanged skip (`QueueViewModel.swift:429–445`): every Servarr status broadcast (unconditional, ~1/min/arr) becomes a `/queue` refetch while the popover is closed — the traffic that skip was added to remove.
9. **SWR never re-emits.** `ReadPolicy.staleWhileRevalidate` refreshes in the background; `engine.observe` re-yields only on an invalidation generation bump, so the revalidated value reaches no open view until something else invalidates. (Affects 2.3, 2.4 after a `fileImported`.)
10. **Bytes-on-disk makes every projection rebuild a full re-decode.** `MediaServerIndex` rebuilt by tag means re-parsing the 7 MB Plex index from SQLite on each `library`/`sessions` invalidation (2.9); with `sessions` volatile that is once per now-playing tick unless the projection is split. Today it is a dictionary swap.

Also: `historyFor` in F.2 makes the movie detail 8 requests against a baseline of 7 (criterion 27); `LiveFeed.refresh` has no access to the previous value, so `DownloadProgressService`'s "all failed → keep for ≤60 s" is inexpressible (2.2); `generation()` is global, so an unrelated invalidation re-unifies the library (2.4); `LiveFeed` has no in-memory `current()` for tools (2.7).

### Transport-first (TF)

1. **`borrowing CompositionContext` kills `async let`.** A borrowed `~Copyable` parameter cannot be captured by an escaping closure, and `async let` children are exactly that; F2's own example does not compile. Every composition is serial: `DetailView.load` (movie 6 reads, series 7) goes from ~1 RTT to ~6 RTT on first open, `SearchViewModel.search`'s four-arr fan-out serialises. (2.3, 2.5.)
2. **Criterion 17 has no mechanism.** `Resource.batch: BatchHint?` is referenced and never declared; `readAll` is homogeneous and "groups by hint" into a plural request it has no way to construct. The 20-card grid claim rests on a type that does not exist.
3. **`StoreRevision` cannot be observed as declared.** A plain `@Observable final class` captured in `Observations`'s `@Sendable` closure is a compile error under `defaultIsolation(nil)` (MF §G probe). Both `ResourceStore.observe` and `Snapshot.attach` hang off it.
4. **`library` is `archival` (30 d).** `LibraryIndex.ttl` is 10 min as a backstop for changes no event announces; with 30 d and an `EventTagMap` that lists only `queue`/`fileImported`/`commandCompleted`, a title deleted in Radarr's UI sits in ArrBarr's grid for a month. (2.4; `LibraryIndex.swift:22`.)
5. **`observe` defaults to `.background`** — a `DetailView` or Library screen that uses the SWR surface (the design's recommended surface for views) waits behind every live poll in the limiter's FIFO. Priority inversion on the interactive path.
6. **`DownloadClient.progress(ids:)` is a `volatile` `Resource` read through the store**, contradicting §3.5 ("compositions never read a volatile resource through context") and losing `DownloadProgressService.maxCacheAge` (a stopped client freezes bars until the next success). The `LiveStream.fetch(InstanceID, RequestPipeline)` closure has no channel for the queue's ids, so every progress tick asks for all torrents. (2.2.)
7. **`@concurrent public func sweep()` on the `ResourceStore` actor** — same SE-0461 violation as CF-6.
8. **`ServiceGateway.configure(with:demo:)` is "the ONLY construction… called on every ConfigStore change"** while §I's first bullet says config changes call `instances.update`. If the former, a Settings keystroke rebuilds store, hub and sessions (memory tier dropped, SignalR reconnect, qBittorrent re-login — §5's "one login per run" is broken by the app's own Settings pane).
9. **Cancellation has two spellings.** `URLSessionTransport` rethrows `CancellationError` bare (phase-0 fact 5) *and* `MediaKitError.cancelled` exists; every ArrCore mapper and `SearchViewModel.swift:432`-style check must test both. Pick one and map at the transport.
10. **Artwork auth is described three incompatible ways** (`ArtworkAuthorizing` "implemented by PosterStore", `kit.artworkHeaders(for:)` absent from `struct MediaKit`, "PosterStore asks the gateway"). `PosterStore.download` (`PosterStore.swift:367`) needs one call. (2.10.)

Also: `EventHub` exposes no `lastEventAt(instance)` for the 300 s silence gate (2.1); the widget reads the 3000-row `library` payload where a count composition was meant (2.8); `HostGovernor.enter → Slot / leave` permit objects can leak between `enter` and the cancellation handler where CF's closure form cannot; `contains(hash:)` is a cached `Resource<Bool>` for a duplicate probe that must be live.

### Model-first (MF)

1. **`LiveStream` has no pump.** `init(id:instance:freshness:store:clock:)` takes no fetch closure; `PollingEventSource` covers download clients only; nothing polls the arr queue. `QueueViewModel` keeps its timers, its burst/floor/silence code (F4 says so), and reads a `volatile` resource through `Store.read` to feed `ingest` — the layer split the rewrite exists to fix survives in the most-touched view model. (2.1, 2.2.)
2. **`Command.request` builds one `HTTPRequest`; `CompositeCommand` is prose.** Sonarr v3 season toggle (three requests), Lidarr `addAlbum` (two), `setMonitored` RMW (two) are all declared in E.1–E.3 and none is expressible. (2.5, 2.6.)
3. **`Transport` has no socket primitive** — identical to CF-3; `SignalREventSource` must own a `URLSession`, and `EventSource` lacks `forceReconnect` for `systemDidWake`. (2.13.)
4. **`ArtworkReference.headers: [String: String]` is a stored `Codable`/`Hashable` field** whose comment says it is not stored. If filled it persists tokens; if empty it is dead. (2.10; `PosterStore.swift:380`.)
5. **Widget F5 uses `.staleWhileRevalidate` in an extension** — the revalidation is fire-and-forget in a process that is about to be suspended; same defect as CF-2. (2.8.)
6. **SWR revalidation never reaches an open view.** `Store.read` defaults to `.staleWhileRevalidate`; `changes(matching:)` fires on invalidation, not on the revalidated commit; `Composer.stream` therefore shows the stale detail after a `fileImported` until the next unrelated invalidation. (2.3.)
7. **`CompositionContext` is a non-Sendable class** and F2 fans out with `async let` — Swift 6 rejects capturing it in child tasks; the alternative is serial builds (see TF-1's latency cost). F2 also calls `ctx.crosswalk` (not declared) and `await`s inside `flatMap`.
8. **`ingest(partial:)` (E.5) is not in `LiveStream`'s API (C.6)** — the some-failed/all-failed rule the brief asked about is claimed and not declared. (2.2.)
9. **`CapabilityIndex.current` is conservative until a probe runs, and correction is one-way** (v5→v3 on 404, never v3→v5), so a v5 Sonarr gets the double-PUT until `ensure` has been called; `start()` must probe every arr before the first write and the design does not say it does. (2.6.)
10. **`ServiceGateway` exposes only domain compositions** (`queueRows()`, `detail(_:)`, `library(_:)`…) while `connection` is `private(set)` — good for criterion 18, but the 28 tools, `DownloadDropService`, `ServerStatusModel` and `SpotlightIndexer` each need services the gateway does not list; either the gateway grows ~40 methods or Services reach `gateway.connection.*`, which is what 2.7 and 2.12 had to do. Say which.

Also: `FixtureTransport.log() -> [HTTPRequest]` returns requests *after* `SessionAuth.decorate`, so the test assertion surface carries credential headers (harmless in demo, a scrubber obligation in `RecordingTransport`); `Store.readBatch` defaults to `.background` (interactive detail files wait behind polls); `Store.init` does three SQLite `SELECT`s synchronously on the launching thread.

### Shared (all three)

- **Breaker/health keyed by host, `ConnectionHealth` keyed by service.** Radarr and Sonarr behind one reverse-proxy origin share a breaker and a dot; a 429 on one blocks the other. `InstanceRegistry.host(id)` is many-to-one in every design.
- **Deleting `ConnectionHealthMonitor` orphans the OpenAI dot** (LLM providers are out of scope, §1.7) and leaves an idle download client `.unknown` forever, since the breaker only learns about hosts that get asked. (`ConnectionHealthMonitor.swift:80–100`; `QueueViewModel.swift:929–958`.)
- **ArrCore under `defaultIsolation(MainActor.self)` + `InferIsolatedConformances`**: composition inputs (`Hashable & Sendable`) and outputs (`Sendable`) passed into nonisolated actor methods (`engine.value`, `compose`) cannot use MainActor-isolated conformances. Every domain struct that crosses into MediaKit must be declared `nonisolated`. TF states the opposite ("isolated conformances for the memo key"); none names the rule.
- **Build closures run on the engine actor** under `NonisolatedNonsendingByDefault` unless marked `@concurrent` or spawned into a child task — 20 card compositions would serialise on one actor. Needs a `RunCodeSnippet` probe in phase 3 before the engine is written; no design flags it.
- **`ConfigStore` has 46 `@Published` and is an `ObservableObject`** (phase 0 H5), not `@Observable` as TF §I assumes ("it already is `@Observable`"); the one gateway subscription is a Combine sink, not an `Observations` loop.

---

## 4. Best idea from each design, worth grafting

- **From CF → into the winner:** `ArtworkReference.HeaderRef.credential(InstanceID)` — a `Hashable & Codable` reference that structurally cannot carry a token, with `sized(_:)` folding `MediaServerPosterAccess`, `PosterTier.cdnVariant` and `TMDBClient.imageURL`. Second: `Command.Tracking.arrCommand(idFrom:timeout:)` — the store polls `/command/{id}` at `.background` and re-invalidates on completion, which deletes `DetailView.watchSearchState` (`DetailView.swift:808–850`) and its 3 s timer. Third: `HostLimiter.withPermit(_:priority:_:)` closure form and `interactiveReserve` lanes.
- **From TF → into the winner:** `Transport.open(_:) -> any WireSocket` and `FixtureTransport.enqueueFrames` — the only way SignalR sits inside the transport contract, is counted by telemetry, is throttled by the limiter, and is testable end-to-end on fixtures. Second: `Command.run: (RequestPipeline) async throws -> Void` with `.readModifyWrite(read:edit:then:)` — multi-request writes as one declared command. Third: `observe` yielding "cached → revalidated → per invalidation" (the SWR re-emit the other two lack), and `queueStatus → ∅ unless counts changed` in `EventTagMap`.
- **From MF → into the winner:** the compile-verified isolation facts (`Observations` needs an `@unchecked Sendable` observable with hand-written `access`/`withMutation`; `AsyncMessage.Subject` must be a class; `SQLITE_TRANSIENT` via `unsafeBitCast`), `CapabilityIndex` as a synchronous lock-guarded read inside `Resource.request: (CapabilityIndex) throws -> HTTPRequest`, `Governor.health(_:)` nonisolated, `Governor.note(wake:)` half-opening every host on wake, `LiveStream.last()` synchronous for the first body, and the crosswalk `harvest` on `lookup`/`external_ids` that answers ownership without a library read.

---

## 5. Recommended winner

**Transport-first, with three grafts and four corrections.** TF is the only design whose declared API carries the two consumers that the others cannot carry at all — multi-request writes (`Command.run`; consumers 5 and 6, five call sites in `DetailView`/`SearchViewModel`/`SonarrClient`) and SignalR inside the transport (`Transport.open`; consumer 13, plus the honest demo of consumer 14 and the telemetry of criterion 21) — and it is the only one whose widget flow (consumer 8) actually fetches under owner decision Q2(a). Its defects are real but local: swap `borrowing CompositionContext` for a lock-guarded `final class` and add a heterogeneous batch primitive (`BatchResource` from CF or `readBatch`/`chunkSize` from MF) so `DetailView` keeps its `async let` fan-out and criterion 17 has a mechanism; take MF's `@unchecked Sendable` observable for `StoreRevision`; class `library` as 10 min not 30 d; default `observe` to `.interactive`; move `@concurrent` off actor methods. CF loses on the axis its thesis chose — the store is elegant, but "commands are second-class" is not a trade-off the arrs allow (the Sonarr toggle *is* four requests), and its widget and SignalR flows are wrong as written. MF has the best identity, capability and isolation groundwork and should supply those parts of the spec, but it leaves the queue pump, burst coalescing and silence gate in `QueueViewModel` and declares two of its own commands in prose only; for the consumer that matters most (1, 2 — the popover), it changes the least.
