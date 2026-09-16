# Critique — lean and idiomatic Swift 6.2, compile risk, budget

Phase 1 critic, lens: *is it lean, will it compile under the real settings, will it stay under 8,590 lines.*
Inputs: the three designs, prompt §0/1/3/4, phase-0 report §4/§6, the golden corpus (181 rows, 166 distinct
operations: radarr 31, sonarr 34, lidarr 31, tmdb 20, qbittorrent 10, plex 8, sabnzbd 8, deluge/nzbget/rtorrent/
transmission 6 each), the fixture bundle (218 files, 1.8 MB), and the replaced ArrCore files.

Every compiler claim below was probed with `swiftc -swift-version 6 -target arm64-apple-macosx26.0
-enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances
-Xfrontend -default-isolation -Xfrontend nonisolated` (full `-c`, not `-typecheck`: region-isolation and ownership
diagnostics only run in SIL). Probe files: `scratchpad/probe/p1…p10.swift`.

| Probe | Claim tested | Result |
|---|---|---|
| p1, p10 | `@concurrent func` inside an `actor` (cache-first C.5 `ResourceStore.sweep/purge`, `FactDatabase.sweep`) | **error** — `@concurrent` makes the method nonisolated; it cannot read `db` or the memory tier |
| p2 | `@concurrent` on a non-`async` function (transport-first C.3 `RequestPipeline.decode`, model-first G `decode/commit/rebuild`) | **error**: "cannot use @concurrent on non-async instance method" |
| p3 | `Observations { self.clock.generation }` over a plain `@Observable` class, closure formed inside an actor (cache-first C.10) | compiles (the `@isolated(any)` closure inherits the actor) |
| p4 | non-Sendable non-escaping closure passed into a `@concurrent` function (transport-first D `SQLiteDatabase.read(_:)`) | compiles |
| p5 | `async let` over a `borrowing` `~Copyable` context (transport-first F2) | **compiler crash** ("Found ownership error?!") |
| p6 | `enum Credential { case apiKey(String) }` printed via `"\(c)"` | prints `apiKey("SECRET123")` — reflection leaks unless `CustomStringConvertible` *is* implemented |
| p7 | `NotificationCenter.AsyncMessage` with a `final class` subject; `post(_:subject:)`, `messages(of:for:)` | compiles |
| p8 | `nonisolated let revision = StoreRevision()` (plain `@Observable`) on an actor, read from `@MainActor` (transport-first C.5) | **two errors**: `nonisolated` needs Sendable; `#NonSendableExitingActor` |
| p9 | runtime: 100 mutations in one actor job, observer on another executor; then 10 jobs against a 30 ms consumer | emissions `[0, 28, 100, 101, 110]`: a burst is **not** atomic to an observer on a different executor; a slow consumer coalesces 10 jobs into 2 |

API facts (appledoc): `Observations<Element: Sendable, Failure>` with `init(_ emit: @escaping @isolated(any) @Sendable () throws(Failure) -> Element)` and `untilFinished(_:)`; `NotificationCenter.AsyncMessage: Sendable` (asynchronous delivery), `MainActorMessage: SendableMetatype` (synchronous on main); `post(_:subject:)`, `addObserver(of:for:using:)`, `messages(of:for:bufferSize:)`; `OSAllocatedUnfairLock<State>` (os, macOS 13); `Mutex<Value>` (Synchronization, macOS 15); `NetworkBrowser<Provider>` and `NetworkConnection<ApplicationProtocol>` (Network, macOS 26 — the *Swift* Network API the prompt §1.13 names; all three designs use the older `NWBrowser`/`NWConnection`); SDK SQLite 3.54.0; `SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION` present in both iOS and macOS `sqlite3.h`.

---

## 1. Score table (1 = broken, 5 = ship it)

| Criterion | cache-first | transport-first | model-first |
|---|---|---|---|
| (a) LOC estimate realistic | 3 | 3 | 2 |
| (b) isolation / SE-0461 / `@concurrent` placement | 2 | 3 | 2 |
| (c) `Observations` bridge expressible | 3 | 3 | 4 |
| (d) typed `NotificationCenter` messages | 1 | 4 | 4 |
| (e) SQLite C API usage | 4 | 3 | 3 |
| (f) no over-abstraction | 3 | 2 | 3 |
| (g) zero deps, zero warnings feasible | 3 | 3 | 3 |
| (h) injection everywhere, no singleton | 4 | 3 | 4 |
| (i) secrets cannot reach key/log/telemetry/fixture | 3 | 4 | 3 |
| **Sum** | **26** | **28** | **28** |

The sums are close because each design is strong where the other two are weak; the recommendation in §6 is
therefore a base plus grafts, not a pick.

---

## 2. Cross-cutting findings (apply to all three)

1. **The 8,590 budget is not met by any of them.** All three land at 8,530–8,580 with 10–60 lines of slack by
   moving `RecordingTransport` out of the product and turning 2,889 lines of demo mocks into JSON. My independent
   floor (§3) is 9,200–9,800 for each; the shared under-estimate is the wire layer (see 2).
2. **Wire models are under-estimated by 300–500 lines in every design.** Group E today: 158 Codable declarations
   with ~985 stored properties (ArrTypes 467, ArrDetailTypes 105, TMDB 93, Search 40, Release 32, MediaServer 22,
   others). Even pruned to fields with consumers and shared across the four arrs, a `Decodable`+`Sendable` struct
   costs ~1 line per property + 3 per type: floor ≈ 1,100–1,300, plus `JSONValue` and the `extra` bag for the typed
   read-modify-write (100–150). Claimed: cache-first 910, transport-first 760, model-first ~740.
3. **`@concurrent` is mis-placed in all three** (p1, p2, p10). Rule from SE-0461: only on `nonisolated async`
   functions. The places that genuinely need it are: JSON decoding of the two multi-megabyte payloads, and nothing
   else — SQLite I/O belongs on a custom serial executor (cache-first) or a serial queue (transport-first), not on the
   cooperative pool, and a SHA-256 of 32 bytes or a fixture directory listing costs less than the hop. An actor's
   maintenance work (`sweep`, `purge`) stays isolated; the actor is the executor.
4. **Closures executed inside an actor method run on that actor.** Under SE-0461 a nonisolated async closure
   inherits its *caller's* isolation, and inside `HostLimiter.withPermit(body:)` (cache-first C.3) or
   `Governor.run(body:)` (model-first C.5) the caller is the actor. Every host's request setup, retry loop and
   decode dispatch is serialised through one actor. Transport-first's `enter() -> Slot` / `leave(_:outcome:)` is the
   right shape; graft it.
5. **The lock-guarded snapshot is sound but spelled the pre-6.2 way.** `final class … @unchecked Sendable` + `NSLock`
   works for an immutable `(value, version)` swap. The idiomatic 6.2 spelling is
   `OSAllocatedUnfairLock<(Value, UInt64)>` (os, on the allow-list): a Sendable struct, no `@unchecked`, no class,
   cheaper. `Mutex` (Synchronization) is the stdlib equivalent but is not on the §1.2 list by name — owner question.
6. **Every design hashes the credential into the fingerprint** (`baseURL | SHA-256(secret)[0..<8]`) and persists it
   in `entries.fingerprint` and `capabilities.fingerprint`. For a 32-hex arr key that is fine; for a download-client
   *password* it is an unsalted fast hash of a possibly weak password written to a plaintext SQLite file. It also
   creates the CryptoKit / hand-rolled-SHA-256 question (60–130 lines) in two designs. Alternative that removes both:
   ArrCore's secret store issues an opaque random *credential generation* (UUID) that rotates whenever the secret is
   written; MediaKit's fingerprint is `baseURL | generation` and never sees or hashes the secret. Criterion 5 still
   holds (rotation → new generation → new fingerprint).
7. **`Credential`/`Credentials` types leak through reflection** (p6). Cache-first C.6 says "Never
   `CustomStringConvertible`" — the opposite is required: implement `CustomStringConvertible`,
   `CustomDebugStringConvertible` and `CustomReflectable` returning `•••`, and add a test that
   `String(describing:)`, `String(reflecting:)` and `dump` contain no secret.
8. **Login bodies carry the secret and no design scrubs them.** qBittorrent `POST /auth/login` (form
   `username`/`password`), Deluge `auth.login` (JSON-RPC `params: [password]`). Cache-first hashes `body` into
   `ResourceKey.digest` — if the login is ever a `RequestPlan`, the password enters a cache-key derivation;
   model-first's scrubber lists headers, `apikey`/`api_key`/`access_token` query and hostnames only. Transport-first
   has `Redaction.scrub(Data)` but does not say it knows form and JSON-RPC bodies. Criterion 12's test must include
   the two login bodies and the `access_token` WebSocket query (today's `RealtimeUpdates.swift:510`).
9. **`Observations` is a version counter with an `AsyncSequence` face in all three.** That is acceptable — the prompt
   mandates it — but the reason to use it over an `AsyncStream<Void>` is never stated: p9 shows the real benefit is
   demand-driven coalescing (10 invalidations against a busy consumer → 2 rebuilds) and the real trap is that a burst
   inside one actor job is *not* atomic to an observer on another executor (28 then 100). Consequence: form the emit
   closure inside the mutating actor (p3 shape, cache-first) when a consistent read matters, and accept one hop per
   emission; a lock-guarded `@unchecked Sendable` counter (model-first `ObservableVersionCounter`) is fine for a
   monotonic version. `Observations.untilFinished(_:)` is the right constructor for a stream that ends when the
   composition is dropped; none of the designs uses it.
10. **`NotificationCenter.default` + a singleton subject** (transport-first `MediaKitEvents.shared`, model-first
    `MediaKitCenter.shared`) is the one singleton in the request/event path. Swift Testing runs suites in parallel;
    two stores in two suites posting to the same center with the same subject cross-talk. Inject the center and use
    a per-connection subject instance (`addObserver(of: subjectInstance, for:)` is the documented overload).
11. **`PRAGMA incremental_vacuum` is a no-op unless `auto_vacuum = INCREMENTAL` was set before the first table.**
    Cache-first D and model-first D call `incremental_vacuum` in `sweep` without ever setting `auto_vacuum`;
    transport-first sets it (must be first, before DDL, on the create path only).
12. **iOS file protection via `FileManager.setAttributes` after open is racy** (cache-first D, transport-first D.1):
    SQLite deletes and re-creates `-wal`/`-shm` on clean close and after some checkpoints; the attribute is then
    whatever the container default is. Model-first's `SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION`
    open flag is the correct mechanism (SQLite applies it to every file it creates). Graft.
13. **Statement caching is absent from all three.** With ~10 hot statements (`entry`, `entries(keys)`, `put`,
    `markStale`, `touch`, `lastKnown`, `putLastKnown`, sweep ×2) prepared per call, the cold-start read pays
    `sqlite3_prepare_v2` on every row. A `[String: OpaquePointer]` cache with `sqlite3_reset` + `sqlite3_clear_bindings`
    is ~25 lines and belongs in the spec.
14. **`@concurrent`-decoded 7 MB Plex index on every disk read.** Bytes-on-disk (cache-first) and re-encoded JSON
    (model-first, transport-first Q1) both decode the whole index per cold read. Model-first's "harvest-only decode
    path" (guids only) is the mitigation; the spec should make the index a *projection* row (guid → ids + artwork
    path) written once per network read, so the snapshot rebuild never touches the raw index again.
15. **Discovery uses the pre-26 API.** Prompt §1.13 asks for the Swift `Network` API; that is `NetworkBrowser` /
    `NetworkConnection` (macOS 26), not `NWBrowser`/`NWConnection` with handler closures that fight strict
    concurrency. Also `NSBonjourServices` + `NSLocalNetworkUsageDescription` Info.plist keys (model-first Q5) are
    required on iOS and were only flagged by one design.
16. **`Package.swift` accounting differs** (cache-first counts it, transport-first does not); the second
    `MediaKitRecording` target is outside the budget in all three — say so in the phase-6 report, once.

---

## 3. Independent LOC re-estimate

Method: per area, a floor from the API surface (166 distinct operations, ~985 wire properties, 6 download-client
auth quirks, a SQLite wrapper with statement cache + migrations + file protection, SignalR negotiate/handshake/ping/
backoff/reconnect/wake, a fixture transport that must replace 2,889 lines of demo behaviour). "Claimed" is the
design's own number for the same area.

### 3.1 Cache-first

| Area | Claimed | Re-estimate | Δ | Why |
|---|---|---|---|---|
| Core primitives, keys, tags, plan, errors, telemetry, log, clock | 1,200 | 1,150 | −50 | fair; `Telemetry` actor could shrink |
| Transport + limiter + breaker + sessions + registry | 1,030 | 1,250 | +220 | `InstanceSession` 230 for six handshakes + Referer/CSRF + generation counter is 320; `FixtureTransport` 180 cannot carry demo state deltas for pause/resume/delete/add/monitor/search/releases/progress — 400 |
| Store + SQLite | 1,070 | 1,150 | +80 | statement cache, transactions, migrations, protection, `entries(keys)` batch |
| Identity + capabilities | 570 | 550 | −20 | fine |
| Events + live | 800 | 900 | +100 | SignalR 360 is a 52 % cut of 751 with the negotiate/handshake/ping/backoff paths untested; 450 |
| Composition | 480 | 480 | 0 | |
| arr clients + models | 1,120 | 1,450 | +330 | `ArrCommon` 280 + `ArrEntities` 220 for 64+14 decl / 572 properties is not credible; 800 |
| Download clients | 930 | 950 | +20 | |
| Media servers + TMDB | 970 | 1,050 | +80 | 29 TMDB decls / 93 properties in 120 lines is not credible |
| Artwork + discovery | 360 | 360 | 0 | |
| **Total** | **8,530** | **≈ 9,290** | **+760** | |

### 3.2 Transport-first

| Area | Claimed | Re-estimate | Δ | Why |
|---|---|---|---|---|
| Wire (transport, fixture, builder, redaction; recording moved out) | 690 | 850 | +160 | `RequestBuilder` 180 for URL join, form, multipart, XML-RPC and JSON-RPC encoders is 260; `FixtureTransport` 170 → 350 with demo state |
| Kernel (pipeline, governor, retry, sessions ×2, error, telemetry, log, clock) | 1,380 | 1,400 | +20 | fair; the most carefully sized part |
| Store (key, resource, store, memory, sqlite, schema, snapshot, invalidation) | 1,450 | 1,500 | +50 | fair |
| Instances + capabilities | 590 | 590 | 0 | |
| Identity | 250 | 250 | 0 | |
| Events (wake folded) | 540 | 640 | +100 | SignalR 360 → 450 |
| Live + pending | 320 | 320 | 0 | |
| Compose | 260 | 320 | +60 | `readAll` batching by hint + memo + provenance |
| Servarr | 1,150 | 1,500 | +350 | `ServarrWire` 380 for 78 decl / 572 properties + `JSONValue` is not credible; 750 |
| Download | 800 | 850 | +50 | after the `DownloadWire` fold |
| Media server | 450 | 550 | +100 | |
| TMDB | 320 | 380 | +60 | |
| Artwork + discovery | 290 | 290 | 0 | |
| **Total** | **8,580** | **≈ 9,540** | **+960** | |

### 3.3 Model-first

| Area | Claimed | Re-estimate | Δ | Why |
|---|---|---|---|---|
| Core (error, ids, registry, credentials, clock, telemetry, log, SHA-256, connection) | 870 | 850 | −20 | SHA-256 goes away with finding 6 |
| Identity | 670 | 450 | −220 | the spine is over-built (§5.3); a crosswalk table + parsers is enough |
| Capabilities | 300 | 300 | 0 | |
| Transport (incl. `SessionAuth`, `Governor`, builder) | 1,080 | 1,300 | +220 | `FixtureTransport` 190 + "60-line overlay interpreter" → 450 |
| Store (key, resource, store, sqlite, snapshot, live) | 1,000 | 1,400 | +400 | `Store` 300 + `SQLite` 220 for coalescing, SWR, invalidation, sweep, migrations, statement cache, last-known, capabilities and crosswalk tables is not credible |
| Events | 600 | 650 | +50 | |
| Composition | 280 | 320 | +40 | |
| Arr (4 services + shared + models) | 1,560 | 1,750 | +190 | wire 600 → 800; four services instead of a dialect cost ~150 over the other designs |
| Download | 1,000 | 1,000 | 0 | hand-written XML-RPC inside `RTorrentService` is honest |
| Media server | 660 | 700 | +40 | |
| TMDB | 340 | 400 | +60 | |
| Discovery | 170 | 250 | +80 | UDP + Bonjour + parsers |
| **Total** | **8,530** | **≈ 9,370** | **+840** | |

### 3.4 What must be cut or generated to land under 8,590 (any design)

Ordered by lines saved per unit of regret:

1. **Generate the wire models** from the fixture bodies with `Tools/mediakit/gen_wire.py` (like `Tools/loc/`): every
   Codable struct, `let`-only, Sendable, with the field list pruned to the consumers named in `read-consumers.json`.
   Generated files still count toward the budget unless the owner rules otherwise — ask in the decision pack; if they
   count, the saving is consistency, not lines. Expect −150 from mechanical pruning either way.
2. **Defer `Discovery/*` to phase 7** (−170 to −290). No consumer in the migration path; the parsers can stay (criterion 25) at ~80.
3. **Drop TMDB operations with no live consumer.** Phase 0 §3.3: `DiscoverViewModel.configure` has no call site, so
   `discover/movie|tv`, `*/similar`, `*/recommendations` are dead today (≈ 6 of 20 ops, −80). Verify against
   `LocalToolBackend+TMDB.swift` before cutting.
4. **One identity model**: crosswalk table + `MediaID` + parsers; no `MediaIdentity.lineage`/`Box`/`canonical`/
   `storeKey`/four confidence levels (−200 in model-first, −60 in cache-first).
5. **One event vocabulary, no `EventSource` protocol.** Two sources (SignalR, wake-as-a-call) do not justify a
   protocol + hub/multiplexer (−90 to −150).
6. **`BatchResource` with one strategy (chunked)**; `index` is a composition over `library`, `perKey` is a loop (−60).
7. **Telemetry counts only** (criterion 21 lists requests, hits, misses, coalesced, invalidations, breaker opens); no
   p50/p95 histograms, no 500-event history (−60 to −90).
8. **Demo overlay rules as JSON**, interpreter ≤ 120 lines; every demo state transition is data (already the plan; hold the line).
9. **Merge the pools into their actors** (transport-first `HostGovernorPool`, `SessionBrokerPool` → dictionaries inside one actor each; −80).

Sum of 2–9 ≈ 800–1,000 lines, which is exactly the gap. Without them the 60 % measure fails in phase 6.

---

## 4. Top 10 defects per design

### 4.1 Cache-first

1. **C.5 `ResourceStore`: `@concurrent public func sweep() async`, `purge`, `purgeAll`; `FactDatabase.sweep(now:)
   throws -> SweepReport` (not even async); C.12 `FixtureTransport.loadCorpus`, `IdentityResolver.indexCrosswalk`,
   `CompositionEngine.rebuildProjection`.** Confirmed (p1, p2, p10): `@concurrent` on an actor method is nonisolated
   and cannot touch the actor's state; on a non-async function it is an error. Six declarations do not compile.
   Fix: drop `@concurrent` from every actor member; `FactDatabase` already has a `DispatchSerialQueue` executor, which
   is the whole point — sweep runs *on* it.
2. **C.3 `HostLimiter.hold(_:until: Instant)`, `BreakerRegistry.State.open(until: Instant)`, `Admission.refuse(until: Instant)`.**
   `Instant` is not a type. `ContinuousClock.Instant` is not `Codable` (`State: Codable` is declared) and cannot be
   compared with a `MediaClock` test clock's `Date`. Use `Date` from the injected clock.
3. **C.3 `HostLimiter.withPermit(_:priority:_ body:)`.** The body — the transport send — runs on the limiter actor
   (finding 4). Replace with `acquire(_:priority:) async throws -> Permit` / `release(_:)`, or graft transport-first's
   `enter/leave` with `Slot`.
4. **C.10 `CompositionContext: @unchecked Sendable` with `public var minFreshness` and `private(set) var touched/tags/oldest/failures` mutated from `read`.**
   Two `read`s from `async let` inside one build write the dictionaries concurrently; the `@unchecked` hides a data
   race. Wrap the accumulators in `OSAllocatedUnfairLock<Provenance>`; then the `@unchecked` goes away.
5. **C.6 `Credential`: "Never `CustomStringConvertible`; `debugDescription` is •••".** Backwards (p6): without the
   conformance, `"\(credential)"` prints the key. Implement `CustomStringConvertible`, `CustomDebugStringConvertible`,
   `CustomReflectable`.
6. **C.4 `RequestPlan.AuthPlacement.queryItem` — "ONLY sabnzbd `apikey` and TMDB v3 `api_key`"; C.9 `SignalREventSource`.**
   The Servarr WebSocket upgrade carries `access_token` in the query (`RealtimeUpdates.swift:510`); the design's
   placement enum has no case for it, so either the port breaks or the token is smuggled outside the audited path.
   Add `.queryItem("access_token")` scoped to the WS upgrade and register it in the loggable-URL filter.
7. **C.11 `Telemetry` is an actor with `record(_:)` on every request/hit/miss/coalesce.** One hop per event on the
   hot path, from inside `ResourceStore` (a second actor). Transport-first's lock-guarded `TelemetryRecorder`
   (`TelemetrySink`) is the right shape.
8. **§C.12/§H: typed `NotificationCenter` messages do not exist in the design.** Prompt §1.13 and criterion 23 name
   them for configuration change, invalidation and connectivity; the only mention is a test row (`TypedMessageTests`).
   No message types, no subject, no isolation stated. Graft §C.5 of transport-first (with the center injected).
9. **D: `PRAGMA incremental_vacuum` in `sweep` step 3 without `auto_vacuum = INCREMENTAL` in the DDL** — a no-op
   (finding 11); and iOS protection via `FileManager.setAttributes` after `sqlite3_open_v2` (finding 12).
10. **C.5 `FactDatabase.put(_ entry:tags:)` is per-row; no transaction API.** A `filesBatch` of 25 chunks or a 400-row
    library read commits 400 implicit transactions with WAL fsync `NORMAL` each. Add `put(_ entries: [StoredEntry])`
    inside one `BEGIN IMMEDIATE … COMMIT`, and prepared-statement caching (finding 13).

Also noted: C.4 `Stamped<Never>.Origin` as the shared `Origin` type is legal but obscure — make `Origin` top-level;
B.9 the demo state delta at 180 lines for `FixtureTransport` is the budget's soft spot (§3.1); C.9 `WakeEventSource`
is an actor implementing a four-method protocol for one signal.

### 4.2 Transport-first

1. **C.3 `RequestPipeline.decode<T>(_:from:operation:) throws -> T` marked `@concurrent` but not `async`.** Error
   (p2). Same for the list in §G item 2 wherever the function is synchronous (`Fingerprint.init`'s SHA-256, rTorrent
   XML parse). Only `async` nonisolated functions may carry it.
2. **C.5 `StoreRevision` (`@Observable public final class`, nonisolated, not Sendable) exposed as `ResourceStore.revision` (`nonisolated var`) and observed from ArrCore's `@MainActor` view model (F4 step 4).**
   Two errors (p8). It must be `@unchecked Sendable` with lock-guarded storage and hand-written `access`/`withMutation`
   — exactly model-first's `ObservableVersionCounter`. Graft it.
3. **C.9 `CompositionContext: ~Copyable, Sendable` + `borrowing` in the body signature, and F2's `async let details = ctx.read(...)`.**
   p5: the compiler crashes on a borrowed noncopyable captured by `async let`; even if it compiled, `borrowing`
   forbids the mutation `read` needs to record provenance, so the struct would hold a reference box inside — at
   which point `~Copyable` buys nothing. Make the context a Sendable final class with `OSAllocatedUnfairLock`
   provenance; keep `async let` (it is the only design that tried to parallelise the detail reads, and it should).
4. **D.3 `CREATE TABLE entries (… payload BLOB …) WITHOUT ROWID`.** SQLite documents `WITHOUT ROWID` as a loss for
   tables whose rows exceed ~1/20 of a page; `entries` holds payloads up to 7 MB. Keep `entries` a rowid table with
   `STRICT` (cache-first / model-first DDL); `WITHOUT ROWID` is right only for `entry_tags`.
5. **C.4: `SessionStrategy` protocol + `SessionBroker` actor + `SessionBrokerPool` actor; C.3 `HostGovernor` actor + `HostGovernorPool` actor.**
   Four actor hops per request before the transport, for state that is two dictionaries. One `Governor` actor keyed by
   host and one `Sessions` actor keyed by instance (or `OSAllocatedUnfairLock<[Host: HostState]>` for the
   counters) removes two actors and ~80 lines with no loss of guarantees.
6. **C.5 `MediaKitEvents.shared` + implicit `NotificationCenter.default`.** The one singleton (finding 10). Inject
   the center; subject = the connection instance.
7. **C.1 `Transport.open(_:) -> any WireSocket` on the same protocol as `send`.** Every transport, including the
   fixture and recording ones, must now implement a WebSocket; the design's own risk 2 admits a socket is not a
   request. A separate `SocketTransport` protocol with a default `nil`/unsupported keeps `FixtureTransport` honest and
   keeps §5's "POST negotiate + WebSocket" on the allow-list explicit.
8. **B: `ServarrWire.swift` 380 lines for the shared queue/history/calendar/command/health/profile shapes *and* the four entity families *and* `JSONValue`.**
   Today those are 78 declarations / 572 properties (§2 finding 2). This single line item is where the 10-line slack
   turns into −300; the design's relief valves (−190 total) do not cover it.
9. **D.1 file protection via `FileManager` "re-asserted after the first `PRAGMA journal_mode=WAL`"** — still racy after
   the sidecars are re-created (finding 12); and D.2's "widget opens `SQLITE_OPEN_READONLY` first, re-opens
   read-write to refresh" is two connections, two PRAGMA rounds and a `-shm` creation race for nothing — one
   read-write connection with `busy_timeout` is what WAL is for.
10. **C.2 `Credentials` (struct with `baseURL` + `material`) and `Credential.Material` print their payload** (p6) —
    same fix as cache-first 5. Also `HTTPRequest` (which carries the attached secret after step 3) is the type
    `FixtureTransport.send` and `RecordingTransport.send` receive: the scrubber must be *proven* on form and
    JSON-RPC login bodies (finding 8), not just headers/query.

Also noted: `RetryPolicy` + `RetryDisposition` + `BreakerPolicy` + `HostGovernor.Limits` are four policy structs for
one decision table; `ArtworkAuthorizing` is a protocol with one conformer (`PosterStore`) — a closure on the
gateway suffices; `WakeSource` was correctly folded.

### 4.3 Model-first

1. **§G: `@concurrent func decode(_:as:) throws -> V`, `@concurrent func commit(_ rows:) throws`, `@concurrent func rebuild(_:) -> Projection`** — none is `async`; all three are errors (p2). The design says these were "verified by compilation"; the probe that passed was `@concurrent` on an *async* function.
2. **D "Concurrency" + C.6: one connection opened `SQLITE_OPEN_NOMUTEX`, "all SQL runs in `@concurrent` functions off the actor's executor; the actor serialises them".**
   It does not: `await commit(rows)` suspends the `Store` actor, which is reentrant, so a second `read` can start a
   second `@concurrent` SQL call on the same `NOMUTEX` connection concurrently — undefined behaviour in SQLite. Either
   keep SQL on the actor (then it blocks the cooperative pool) or give the store a `DispatchSerialQueue` executor
   (cache-first `FactDatabase`). The custom executor is the only shape that is both safe and off the pool.
3. **C.6 `Store.peek` (`nonisolated`, "memory tier only"), `Store.changes(matching:)` (`nonisolated`), `LiveStream.values()`/`last()` (`nonisolated`), `Governor.health(_:)` (`nonisolated`), `Composer.stream` (`nonisolated`).**
   A `nonisolated` actor member cannot read isolated stored state; each of these needs a separate lock-guarded box
   (the memory tier, the tag→version map, the last value, the health map) that the design neither names nor counts.
   That is four more `@unchecked Sendable` classes and ~150 lines, or the methods become `async`.
4. **C.5 `Governor.run(_:priority:idempotent:_ body:)` — "Runs the body on the caller's executor".** It runs on the
   `Governor` actor (finding 4), and there is exactly one `Governor` for all hosts: every request's synchronous prefix
   and the retry `sleep` loop serialise through it. Same fix as cache-first 3.
5. **C.8 `CompositionContext` "Not Sendable, not an actor"** — so a body cannot `async let` two reads, and F2's detail
   composition is five sequential round trips on a cold cache (today's `DetailView` fans out). Make it Sendable with
   locked provenance (as for transport-first 3).
6. **C.1 the identity spine: `MediaIdentity` with `Box<MediaIdentity>` parent, `Ordinal`, `canonical`, `storeKey`, `ids(in:...)`, `Crosswalk.Confidence` ×4, `IdentityResolver` with five ordered routes and an undefined `ServiceLocator`.**
   Consumers today: tmdb→tvdb on the add path (`SeriesIdentityResolver`, 201 lines) and guid→ids for
   posters/watched. A crosswalk table, `MediaID`, and the parsers cover both; the rest is the spike's vocabulary
   carried forward (§B says the spike is "a glossary, not code to keep"). −200 lines and one fewer undefined type.
7. **C.7 `PollingEventSource` + `WakeEventSource` + `EventSource` protocol.** Polling is a cadence of `LiveStream`
   (both other designs reached the same conclusion), wake is one call; the protocol has one real conformer.
8. **D: `PRAGMA incremental_vacuum if freelist_count is large` without `auto_vacuum = INCREMENTAL`** — no-op
   (finding 11). Also "Store.init … loads `capabilities` + `last_known` synchronously — no actor hop for the caller
   because they happen in `init`": that is blocking disk I/O on whichever thread constructs the connection (the main
   thread in `AppDelegate`); do it in `start()`.
9. **H: the recording scrubber "strips credential headers, `apikey`/`api_key`/`access_token` query values and hostnames".**
   Form and JSON-RPC login bodies are not on the list (finding 8); `Credential` prints its payload (p6).
10. **C.4 `MediaKitError` with 16 cases, three of which carry a `ServiceMessage` (arr body text) and one carries an `OperationID` plus a `DecodingFailure`.**
    Fine for criterion 13, but `identityUnresolved(MediaID, into:)` and `fixtureMissing` are not user-facing
    conditions and force two catalogue keys nobody will read; fold the first into `serviceRejected`-style handling
    inside the composition (partial result) and keep `fixtureMissing` a precondition failure in tests.

Also noted: C.10 `MediaKitConnection: Sendable` final class holding actors and `CapabilityIndex` — fine, and the
best assembly shape of the three; F4's sentence "yields from `changes(matching:)` … ArrCore wraps that in
`Observations`" is incoherent (an `AsyncStream` is not observable) — §G's `ObservableVersionCounter` is what is meant.

---

## 5. Best idea from each design, worth grafting

- **Cache-first — `FactDatabase` as an actor with a `DispatchSerialQueue` executor (C.5, G).** It is the only shape
  in which `sqlite3_step` is off the cooperative pool *and* the connection is single-threaded by construction
  (`SQLITE_OPEN_NOMUTEX` is then safe). Take it, and take the response-bytes disk tier (B.4: no `Encodable` half,
  fixtures are cache payloads) and the `CHECK (class > 0)` constraint that makes criterion 6 a DB invariant.
- **Transport-first — `RequestPipeline` as a `Sendable` struct over injected actors with an explicit ordered `send`
  (C.3) and `HostGovernor.enter() -> Slot` / `leave(_:outcome:)`.** Credentials attached inside the slot after the
  plan is built (the secret never exists in a `RequestPlan`, `ResourceKey`, telemetry event or log), cancellation
  is not a breaker strike, retry is per-disposition. Also `Redaction` as a registry the log sink and recorder both
  consult, `Host` as a struct that structurally cannot hold a query, and `FixtureTransport.requestLog` recording
  `OperationID` never a URL.
- **Model-first — the verified facts and the SQLite open flags.** `SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION`
  at `sqlite3_open_v2` (D), `wal_autocheckpoint = 256` for the extension, "unknown higher `user_version` → open
  read-only for `capabilities`/`last_known`, skip the cache" (D, migrations), `ObservableVersionCounter`
  (`@Observable` + `@unchecked Sendable` + manual `access`/`withMutation`, §G) as the one observable type, and
  `HTTPRequest.pathTemplate` + `operation` as first-class fields so criterion 26 is a pure function over declared
  resources with no transport. Also `MediaKitConnection.Configuration` with a `Role` (`.app/.widget/.tests`) as the
  single construction point.

---

## 6. Recommended winner

**Cache-first, as the base, with the grafts above and the cut list in §3.4.** On this lens the question is which
shape has the fewest moving parts once the compile errors are fixed, and cache-first's answer — the store is the
API, a client is a table of values, the transport is deliberately dull, SQLite lives on its own serial executor,
the disk tier stores bytes — is the smallest one that still satisfies criteria 1, 2, 6, 10, 15 and 17
structurally rather than by policy. Its defects are local and mechanical: six mis-placed `@concurrent`s (delete
them; the executor already does the job), an undefined `Instant` (use `Date`), a closure-on-actor limiter (take
transport-first's `enter/leave`), a `@unchecked` context (lock the provenance), a backwards `Credential` note, and
the absence of typed messages (take transport-first's §C.5 with the center injected). Transport-first is the most
idiomatic in the request path but pays for it with four actors, five policy structs and three protocols that each
have one real implementation, and its two headline concurrency choices (`~Copyable` context, nonisolated
`@Observable`) do not compile. Model-first has the best-verified API facts and the right SQLite open flags, but its
store is 500 lines too thin, its "`@concurrent` SQL off the actor" is unsafe on a `NOMUTEX` connection, and its
identity spine is the spike re-imported. None of the three is under budget once the wire layer is sized honestly;
the synthesiser should carry the §3.4 cuts into the spec as decisions, not hopes, and put finding 6 (credential
generation instead of a hashed secret) in the decision pack — it removes the CryptoKit question, the hand-rolled
SHA-256 and the unsalted-password-hash-on-disk risk in one move.
