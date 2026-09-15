# MediaKit design — transport-first

Phase 1 architect submission. Angle: **transport-first**. Branch `feat/mediakit-foundation`.
Inputs read: prompt sections 0/1/3/4/5/6a, phase-0 report, the four `phase0/*.json` inventories,
`2026-09-15-golden-requests.json` (181 rows), `Packages/MediaKit/Fixtures/**` (218 files),
and the ArrCore sources named in the brief.

---

## A. Thesis

Every guarantee this package makes is a **transport** guarantee, so the transport is the only
thing in MediaKit that is allowed to be complicated. One choke point — `RequestPipeline.send` —
owns credentials, per-host concurrency and rate, retry with `Retry-After`, the circuit breaker,
session/login handshakes, cancellation, telemetry and signposts; nothing above it may open a
socket, and nothing below it knows what a movie is. The store is then a thin, honest cache in
front of that pipeline (it decides *whether* to call it, never *how*), the clients are declarative
catalogues of `Resource`/`Command` values, and composition is a memoised read context with no
network code at all. What this deliberately sacrifices: the pipeline is a **serialisation point of
policy** — a request that wants behaviour the pipeline has no vocabulary for (a bespoke redirect
dance, a streaming download) has to extend the pipeline rather than route around it; the store
gives up multi-value transactional reads (no "all of these or none"); and the identity layer is
reduced to a cross-walk table with no resolver framework, pushing resolution policy into ArrCore
compositions. In exchange, criteria 7–10, 12 and 21 are provable in unit tests with a fake clock
and no sockets, and every client in the package is ~150 lines of table.

---

## B. Module layout and line budget

Budget: **≤ 8,590** production lines (60 % of the 14,317 phase 0 measured). Estimates are
"lines of Swift including doc comments, at the comment density `CLAUDE.md` mandates" (short,
non-obvious *why* only).

```
Packages/MediaKit/
  Package.swift                                    40   (not counted: manifest)
  Sources/MediaKit/
    Wire/
      Transport.swift                             110   protocol, HTTPRequest/Response, WireSocket, headers
      URLSessionTransport.swift                   150   URLSession + WebSocket, cancellation mapping
      FixtureTransport.swift                      170   matcher, sidecars, mutable demo state
      RecordingTransport.swift                    150   allow-list gate + scrub-before-write
      AllowList.swift                             120   §5 table as code
      RequestBuilder.swift                        180   URL join, "+"→%2B, form, multipart, XML-RPC, JSON-RPC
      Redaction.swift                              80   secret registry, loggableURL, scrub(Data)
                                                  ---- 960
    Kernel/
      RequestPipeline.swift                       250   the single send path
      HostGovernor.swift                          250   limiter + rate gate + breaker, per host
      RetryPolicy.swift                            80   backoff, jitter, Retry-After, idempotence
      SessionStrategy.swift                       190   protocol + SessionBroker actor (generations)
      SessionStrategies.swift                     200   qBit, Deluge, Transmission, Basic, arr, Plex/JF, TMDB, SAB
      MediaKitError.swift                         110   closed enum + classification
      Telemetry.swift                             170   events, counters, report()
      Logging.swift                                80   LogSink, OSLogSink(subsystem:), AppSignpost bridge
      Clock.swift                                  50   MediaClock protocol, SystemClock, TestClock
                                                  ---- 1380   (target 1330 + 50 slack used by Clock)
    Store/
      ResourceKey.swift                            120
      Resource.swift                               110   Resource, Command, Fetched, Origin
      ResourceStore.swift                          400   read/observe/coalesce/SWR/invalidate/sweep
      MemoryTier.swift                             110   LRU by class, volatile tier
      SQLiteDatabase.swift                         300   SQLite3 C API wrapper, WAL, statements
      StoreSchema.swift                            140   DDL, user_version migrations, file location
      Snapshot.swift                               120   lock-guarded sync projection
      Invalidation.swift                           150   tags, StoreRevision (@Observable), typed messages
                                                  ---- 1450
    Instances/
      InstanceID.swift                             110   id, kind, Fingerprint (SHA-256 first 8 bytes)
      InstanceRegistry.swift                       160
      Credentials.swift                             80   CredentialProvider, Credentials
      Capabilities.swift                           240   Capability, CapabilitySet, probe, persistence
                                                  ----  590
    Identity/
      MediaID.swift                                130   kind + namespace + parent + ordinal
      IdentityStore.swift                          120   crosswalk table read/write
                                                  ----  250
    Events/
      EventSource.swift                            100   protocol + EventHub multiplexer
      SignalRSource.swift                          360   negotiate, handshake, frames, backoff (over Transport)
      EventTags.swift                               80   event → tags, one place
      WakeSource.swift                              60   NSWorkspace/UIApplication-free: injected wake signal
                                                  ----  600
    Live/
      LiveStream.swift                             220   queue/progress/sessions, polling, last-known row
      Pending.swift                                100   optimistic overlay with expiry
                                                  ----  320
    Compose/
      CompositionContext.swift                     260   read w/ provenance, tag union, memo, batch
                                                  ----  260
    Services/Servarr/
      ServarrProfile.swift                         120   apiBase, nouns, query-key names per flavour
      ServarrClient.swift                          320   generic request/decode, capability-gated paths
      ServarrCatalog.swift                         260   resources + commands as a declarative table
      ServarrWire.swift                            380   Codable models (queue, calendar, history, details…)
      ServarrFlavors.swift                          70   Radarr/Sonarr/Lidarr/Whisparr deltas
                                                  ---- 1150
    Services/Download/
      DownloadClient.swift                         150   protocol, progress model, shared RPC helpers
      TorrentClients.swift                         300   qBittorrent, Transmission, Deluge
      RtorrentClient.swift                         160   XML-RPC codec + d.multicall2 alignment
      UsenetClients.swift                          200   SABnzbd, NZBGet
      DownloadWire.swift                           110
                                                  ----  920  (target 780 — see overrun below)
    Services/MediaServer/
      MediaServerClient.swift                      300   Plex + Jellyfin/Emby behind one protocol
      MediaServerWire.swift                        150
      MediaServerGuids.swift                        90   guid → MediaID
                                                  ----  540  (target 450 — see overrun below)
    Services/TMDB/
      TMDBClient.swift                             200
      TMDBWire.swift                               120
                                                  ----  320
    Artwork/ArtworkReference.swift                 110
    Discovery/Discovery.swift                      180   NWBrowser + UDP 7359 + parsers
                                                  ----  290
```

**Arithmetic.**
960 + 1380 + 1450 + 590 + 250 + 600 + 320 + 260 + 1150 + 920 + 540 + 320 + 290 = **9,030**.
That is **440 over**. The overrun is real and I close it explicitly rather than by shaving
estimates:

1. **Move `RecordingTransport.swift` + `AllowList.swift` (270) into a second target,
   `MediaKitRecording`**, which the app never links (only `MediaKitTests` and the phase-6 parity
   recorder do). This is not budget-gaming: recording is a developer tool, it must not ship in the
   widget extension, and criterion 12 ("no secret in fixtures") and §5 enforcement are still in
   code and still tested. Production target drops to **8,760**.
2. **Fold `MediaServerGuids.swift` (90) into `MediaServerWire.swift`** and drop the separate
   `DownloadWire.swift` (110) into the three client files that own the shapes: −200, net after
   dedupe ≈ **−120**. → **8,640**.
3. **Drop `WakeSource.swift` (60)**: wake is not a source, it is one call
   (`EventHub.wakeAll()`) that ArrCore's `AppDelegate` makes; it costs 8 lines inside
   `EventHub`. → **8,580**.

Final production total: **8,580 / 8,590**. Ten lines of slack, which is the point: the budget is
binding, and the next feature has to remove something.

**What I cut to fit**, in order of pain:

- **Four hand-written arr clients become one `ServarrClient` + a 70-line flavour table.** The
  golden corpus shows Radarr/Sonarr/Lidarr/Whisparr differ in `apiBase`, the entity noun, and six
  query-key spellings (`includeMovie`/`includeSeries`/`includeAlbum`,
  `includeUnknownMovieItems`/`includeUnknownArtistItems`, `movieIds`/`seriesIds`/`albumIds`,
  `movieId`/`seriesId`/`albumId`, `searchForMovie`/`searchForMissingEpisodes`/`searchForNewAlbum`,
  `movie`/`series`/`artist`). That is a table, not four classes.
- **Whisparr v2**: probe-detected, documented gap (owner decision Q3). Zero lines.
- **Jellyfin and Emby are one client** with a two-case header switch (`X-Emby-Token` bare for Emby,
  `Authorization: MediaBrowser Token="…"` for Jellyfin — ArrCore's live behaviour, which the spike
  got wrong per `read-media.json`).
- **No identity resolver framework.** The spike's provider/precedence machinery is dropped; what
  survives is a cross-walk table and `MediaID`. Resolution policy (e.g. `term=tmdb:<id>` probing
  into Sonarr) is a *composition* in ArrCore, not a MediaKit subsystem.
- **No `BatchMediaProvider`, no `MediaGraph` planner.** Batching is one function on the
  composition context over resources that declare a batch sibling.
- **Polling has no source type**: `LiveStream` polls itself.
- **No separate `ConnectionHealthMonitor`.** Health is `HostGovernor.Health`, read, never probed
  on a timer (criterion: a probe is a request like any other and goes through the breaker).

---

## C. Public API

Isolation is stated on every declaration. Package settings (Swift 6.2, SE-0466):
`.defaultIsolation(nil)`, upcoming `NonisolatedNonsendingByDefault` (SE-0461) and
`InferIsolatedConformances` (SE-0470). Consequence, and the reason `@concurrent` appears below:
under SE-0461 a plain `nonisolated async func` runs **on the caller's actor**, so a decode called
from inside `ResourceStore` would occupy the store actor for the whole decode. Every function that
does real CPU or blocking I/O is therefore `@concurrent`.

### C.1 Wire

```swift
public struct HTTPHeaders: Sendable, Hashable, ExpressibleByDictionaryLiteral {
    public subscript(name: String) -> String? { get set }   // case-insensitive
    public init(dictionaryLiteral elements: (String, String)...)
    public var names: [String] { get }
}

public struct HTTPRequest: Sendable {
    public enum Body: Sendable {
        case none
        case bytes(Data, contentType: String)
        case form([String: String])                          // sorted, RFC-3986-unreserved encoding
        case multipart(fields: [String: String], file: FilePart?)
    }
    public struct FilePart: Sendable {
        public let name: String, filename: String, data: Data, contentType: String
    }
    public var method: String
    public var url: URL
    public var headers: HTTPHeaders
    public var body: Body
    public var timeout: Duration
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: HTTPHeaders
    public let body: Data
    public var isSuccess: Bool { (200..<300).contains(status) }
}

public enum WireFrame: Sendable { case text(String), binary(Data), closed }

public protocol WireSocket: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> WireFrame
    func cancel()
}

/// Everything MediaKit is allowed to know about networking. One request in,
/// one response out; no retries, no limits, no credentials, no logging.
public protocol Transport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    func open(_ request: HTTPRequest) async throws -> any WireSocket
}

public struct URLSessionTransport: Transport {      // nonisolated struct
    public init(session: URLSession)
    public static func makeSession(cookies: Bool) -> URLSession   // no URLCache, per-host jar
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse
    public func open(_ request: HTTPRequest) async throws -> any WireSocket
}
```

`URLSessionTransport.send` is the only place `URLError`/`CancellationError` exist. It maps:
`CancellationError` and `URLError.cancelled` → rethrown **bare** (phase-0 fact 5:
pull-to-refresh depends on it); everything else → `MediaKitError.unreachable(host:underlying:)`.
Non-2xx is **not** an error here — the pipeline classifies status codes, because 409 (Transmission
handshake), 401/403 (qBittorrent session) and 429 are policy, not failure.

```swift
/// Answers from `Fixtures/<kind>/<operation>.json` + `.meta.json`. Owns all demo state.
public actor FixtureTransport: Transport {
    public struct Rule: Sendable {
        public let method: String
        public let pathPattern: String        // "/api/v3/movie/{id}", "*" segments
        public let rpcMethod: String?         // JSON-RPC "core.get_torrents_status", XML-RPC "d.multicall2"
        public let queryMatch: [String: String]?  // SABnzbd mode=queue
        public let fixture: String
    }
    public init(bundleRoot: URL, rules: [Rule], mutable: DemoStateSeed?)
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse
    public func open(_ request: HTTPRequest) async throws -> any WireSocket  // replays SignalR frames
    public func enqueueFrames(_ frames: [String], for instance: InstanceID)  // tests drive criterion 4
    public var requestLog: [(OperationID, Date)] { get }                      // criteria 1/2/15/17
}
```

Matching rules, in order, first match wins:
1. `rpcMethod` if the body is JSON-RPC (`method` key) or XML-RPC (`<methodName>`);
2. `method` + path pattern, where `{…}` matches one segment and `*` matches the rest;
3. `queryMatch` subset (SABnzbd's single `/api` path is disambiguated only by `mode=`);
4. otherwise `throw MediaKitError.fixtureMissing(operation:)` — a missing fixture is a **test
   failure**, never a silent empty array.

```swift
public struct RecordingTransport: Transport {        // lives in target MediaKitRecording
    public init(wrapping: any Transport, allowList: AllowList, output: URL, redaction: Redaction)
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public struct AllowList: Sendable {
    public struct Rule: Sendable {
        public let kind: ServiceKind
        public let method: String
        public let path: String        // template; "*" tail allowed
        public let rpcMethod: String?
        public let query: [String: String]?
    }
    public static let section5: AllowList   // the §5 table, verbatim, as code
    public func permits(_ request: HTTPRequest, kind: ServiceKind) -> Bool
}
```

`RecordingTransport.send` calls `allowList.permits` **before** delegating; a miss throws
`MediaKitError.notPermitted(operation:)` and the request is never built into a URLSession task.
That is criterion-12/§5 enforcement in code, not in a prompt. `POST /signalr/messages/negotiate`
and the `GET /api/v1/track`, `GET /api/v1/search` additions approved in phase 0 are rows in
`section5`.

### C.2 Errors, clock, logging, telemetry

```swift
public enum MediaKitError: Error, Sendable, Hashable {
    case notConfigured(InstanceID)
    case unauthorized(InstanceID, status: Int, serverMessage: String?)
    case http(InstanceID, status: Int, serverMessage: String?)          // 4xx/5xx that is not auth
    case rateLimited(host: Host, retryAfter: Duration?)
    case unreachable(host: Host, kind: UnreachableKind)                 // dns, refused, timeout, tls, offline
    case breakerOpen(host: Host, until: Date)
    case decoding(OperationID, path: String?)
    case unsupported(InstanceID, Capability)                            // probe says the endpoint isn't there
    case service(InstanceID, code: String, message: String?)            // in-band RPC error (Deluge, Transmission)
    case notPermitted(OperationID)                                      // recording allow-list
    case fixtureMissing(OperationID)
    case cancelled
}
```

Closed, no user-facing literals (criterion 13). `serverMessage` carries the *arr body reason*
(memory: "arr errors live in response body") already parsed by `RequestBuilder.serverMessage`,
which keeps the three shapes ArrCore handles today (Servarr array, `{message}`,
ASP.NET `ProblemDetails`) — ArrCore maps each **case**, not each message, to a catalogue key.

```swift
public protocol MediaClock: Sendable {
    var now: Date { get }
    func sleep(for: Duration) async throws
}
public struct SystemClock: MediaClock {}
public final class TestClock: MediaClock, @unchecked Sendable {   // criteria 7, 9, 11
    public func advance(by: Duration)
}

public protocol LogSink: Sendable {
    func log(_ level: LogLevel, _ category: String, _ message: @autoclosure () -> String,
             privateFields: [String: String])
}
public struct OSLogSink: LogSink {
    public init(subsystem: String)      // ArrCore passes "pl.incred.ArrBarr"
}
public struct SignpostRecorder: Sendable {   // wraps OSSignposter (os, macOS 12+)
    public func interval<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T
}
```

Documented API: `OSSignposter.beginInterval(_:id:_:) -> OSSignpostIntervalState`
(`os`, macOS 12.0+). Timings go here, never into log lines (CLAUDE.md).

```swift
public enum TelemetryEvent: Sendable {
    case request(OperationID, InstanceID, RequestPriority)
    case response(OperationID, InstanceID, status: Int, bytes: Int, duration: Duration)
    case cacheHit(ResourceKey, Origin)
    case cacheMiss(ResourceKey)
    case coalesced(ResourceKey, waiters: Int)
    case skipped(ResourceKey, SkipReason)          // .breakerOpen, .offline, .unconfigured
    case failure(OperationID, InstanceID, MediaKitError)
    case invalidated(Set<InvalidationTag>, InvalidationReason)
    case breakerOpened(Host, until: Date)
    case breakerClosed(Host)
    case rateLimited(Host, retryAfter: Duration?)
    case sessionEstablished(InstanceID, generation: Int)
}

public protocol TelemetrySink: Sendable { func record(_ event: TelemetryEvent) }

/// Lock-guarded, not an actor: `record` must be callable from the limiter's
/// critical path without a hop, and the counters are a dictionary of Ints.
public final class TelemetryRecorder: TelemetrySink, @unchecked Sendable {
    public init(clock: any MediaClock, historyLimit: Int = 500)
    public func record(_ event: TelemetryEvent)
    public func counters(for host: Host) -> HostCounters
    @concurrent public func report() async -> String     // criterion 21, secret-free
    public func reset()
}
public struct HostCounters: Sendable {
    public var requests, hits, misses, coalesced, invalidations, breakerOpens, rateLimits, failures: Int
    public var bytes: Int
    public var p50, p95: Duration
}
```

`report()` prints one block per **host** (never per URL) with the fields criterion 21 names, plus
the top ten operations by request count. No `Host` is a URL: `Host` is
`struct Host: Hashable, Sendable { let scheme, name: String; let port: Int? }` — no path, no query,
so a secret cannot reach the report even by accident.

### C.3 Kernel — priority, limiter, retry, breaker

```swift
public enum RequestPriority: Int, Sendable, Comparable {
    case background = 0     // every live-stream poll, every prefetch, the widget
    case interactive = 1    // anything a visible screen is waiting for
    case session = 2        // credential handshakes only; see below
}

public struct RetryPolicy: Sendable {
    public var maxAttempts: Int          // 3 for reads, 1 for writes
    public var base: Duration            // 250 ms
    public var cap: Duration             // 8 s
    public var jitter: ClosedRange<Double>   // 0.8...1.2
    public static let read: RetryPolicy
    public static let writeOnce: RetryPolicy     // maxAttempts 1
    public func delay(attempt: Int, retryAfter: Duration?) -> Duration
}

public enum RetryDisposition: Sendable {
    case idempotent        // GET, and the explicitly safe RPC reads
    case never             // every POST/PUT/DELETE that changes state
    case handshakeOnly     // retried exactly once, only after a session rejection
}

public struct BreakerPolicy: Sendable {
    public var failureThreshold: Int      // 3 consecutive transport failures → open
    public var openFor: Duration          // 30 s, doubled per consecutive open, capped at 5 min
    public var probeTimeout: Duration
}

public enum HostHealth: Sendable, Equatable {
    case unknown
    case healthy
    case degraded(consecutiveFailures: Int)
    case down(since: Date, retryAt: Date)     // breaker open
    case throttled(until: Date)               // 429/503 Retry-After — NOT a failure
}

public actor HostGovernor {
    public init(host: Host, limits: Limits, clock: any MediaClock, telemetry: any TelemetrySink)
    public struct Limits: Sendable {
        public var maxConcurrent: Int = 4
        public var minimumInterval: Duration? = nil      // token bucket floor; nil for LAN arrs
        public var breaker: BreakerPolicy
        public var reservedSessionSlots: Int = 1
    }
    public var health: HostHealth { get }
    /// Acquires a slot, honouring the rate gate and the breaker.
    /// Throws `.breakerOpen` / `.rateLimited` *without* acquiring when the host is shut.
    public func enter(priority: RequestPriority) async throws -> Slot
    public func leave(_ slot: Slot, outcome: Outcome)
    public func healthUpdates() -> AsyncStream<HostHealth>
    public enum Outcome: Sendable { case success, failure(MediaKitError), retryAfter(Duration) }
}

public actor HostGovernorPool {
    public init(defaults: HostGovernor.Limits, overrides: [ServiceKind: HostGovernor.Limits],
                clock: any MediaClock, telemetry: any TelemetrySink)
    public func governor(for host: Host) -> HostGovernor
    public func health(for host: Host) async -> HostHealth
    public func allHealth() async -> [Host: HostHealth]
}
```

Three separate mechanisms, deliberately not merged:

- **Limiter** — a FIFO of continuations per priority band. `interactive` drains before
  `background`; `session` uses `reservedSessionSlots` and **never queues behind** the others.
  Without the reservation a burst of four 401s holds all four slots and the re-login they are all
  waiting for deadlocks; that bug exists in shape in today's qBittorrent client and is only hidden
  because it has no limiter.
- **Rate gate** — `throttled(until:)`, set from `Retry-After` (seconds or HTTP-date) on 429 and
  503. `enter` throws `.rateLimited` for the whole host until then; *other hosts are untouched*
  because the governor is per host (criterion 7).
- **Breaker** — counts consecutive `.unreachable`. HTTP 4xx/5xx does **not** open it: an arr that
  answers 500 is up. `down` → `enter` throws `.breakerOpen` immediately, except one probe after
  `retryAt` (half-open: exactly one `.interactive` request gets a slot; success closes, failure
  re-opens with doubled `openFor`).

```swift
public struct RequestPlan: Sendable {
    public var instance: InstanceID
    public var operation: OperationID          // "radarr.fetchQueue" — stable, secret-free
    public var request: HTTPRequest            // WITHOUT credentials
    public var priority: RequestPriority
    public var retry: RetryDisposition
    public var timeout: Duration?
}

/// The single send path. A value type over actors, so a client holds it for free.
public struct RequestPipeline: Sendable {
    public init(transport: any Transport,
                governors: HostGovernorPool,
                sessions: SessionBrokerPool,
                credentials: any CredentialProvider,
                telemetry: any TelemetrySink,
                log: any LogSink,
                signposts: SignpostRecorder,
                clock: any MediaClock)

    public func send(_ plan: RequestPlan) async throws -> HTTPResponse
    @concurrent public func decode<T: Decodable & Sendable>(_ type: T.Type, from: HTTPResponse,
                                                            operation: OperationID) throws -> T
    public func socket(_ plan: RequestPlan) async throws -> any WireSocket
    public func health(of instance: InstanceID) async -> HostHealth
}
```

`send` in order — this sequence is the design:

1. `credentials.credentials(for:)`; `nil` → `throw .notConfigured` **before** any host work.
2. `governors.governor(for: host).enter(priority:)` — may throw `.breakerOpen` / `.rateLimited`.
3. `sessions.broker(for: instance).authorize(request, credentials:)` — attaches headers/query for
   the current session generation. **Credentials are attached here, inside the slot, after the
   plan was built**, so the secret exists only in the `HTTPRequest` handed to the transport and
   never in `RequestPlan`, `ResourceKey`, telemetry or logs (criterion 12).
4. `signposts.interval("mediakit.request")` around `transport.send`.
5. Classify: 2xx → success; 401/403/409/in-band RPC error → ask the session strategy
   (`rejection(for:)`); one re-auth + one retry (`handshakeOnly`), then surface.
   429/503 → `governor.leave(slot, outcome: .retryAfter(…))` then, if `retry == .idempotent` and
   attempts remain, sleep the policy delay on the **clock** and loop. Other non-2xx →
   `.http`/`.unauthorized` with the parsed body message.
6. Transport throw → `.unreachable` → breaker counts it; retry if idempotent.
7. `CancellationError` → `governor.leave(slot, outcome: .success)` (a cancel is not a host fault)
   and rethrow bare.
8. Telemetry `request`/`response`/`failure` on every path; log at `.debug` for repeating work and
   `.notice` for breaker transitions and session establishment (CLAUDE.md levels).

Cancellation is structured: `send` wraps the transport call in
`withTaskCancellationHandler(operation:onCancel:isolation:)`
(`Swift`, backdeployed) so a cancelled task tears the URLSession task down immediately rather than
at the next suspension.

### C.4 Sessions and logins

```swift
public struct SessionToken: Sendable {
    public var headers: HTTPHeaders
    public var query: [URLQueryItem]
    public var generation: Int
    public var expiresAt: Date?
}
public enum SessionRejection: Sendable, Equatable {
    case unauthenticated                       // qBittorrent 401/403, Deluge in-band
    case handshake(name: String, value: String)  // Transmission 409 X-Transmission-Session-Id
}
public typealias SessionSend = @Sendable (HTTPRequest) async throws -> HTTPResponse

public protocol SessionStrategy: Sendable {
    func authorize(_ request: HTTPRequest, credentials: Credentials,
                   session: SessionToken?) throws -> HTTPRequest
    func rejection(for response: HTTPResponse, body: Data) -> SessionRejection?
    /// Runs at `.session` priority through the same pipeline. `nil` return = no session needed.
    func establish(after rejection: SessionRejection?, credentials: Credentials,
                   send: SessionSend) async throws -> SessionToken?
}

public actor SessionBroker {
    public init(strategy: any SessionStrategy, instance: InstanceID,
                telemetry: any TelemetrySink, clock: any MediaClock)
    public func authorize(_ request: HTTPRequest, credentials: Credentials) async throws -> HTTPRequest
    /// Coalesces a burst: one `establish` per generation, everybody else awaits it.
    public func refresh(after: SessionRejection?, credentials: Credentials,
                        send: SessionSend) async throws
    public func invalidate(generation: Int)     // only if still current
}
public actor SessionBrokerPool { public func broker(for: InstanceID) -> SessionBroker }
```

Concrete strategies (all `nonisolated struct`, all in `SessionStrategies.swift`):

| Service | authorize | rejection | establish |
|---|---|---|---|
| Servarr (all four) | header `X-Api-Key` | 401/403 → `.unauthenticated` | nil (no session) — surfaces as `.unauthorized` |
| Servarr SignalR | header `X-Api-Key` on negotiate; `access_token` **query** on the WS upgrade | — | nil. *URLSession does not add headers on upgrade*, which is why the token is in the query for that one request only; `Redaction` registers it so it never reaches a log. |
| qBittorrent (password) | cookie jar on that host's session; header `Referer: <baseURL>` always (CSRF) | 401/403 → `.unauthenticated` | `POST /api/v2/auth/login` form `username`/`password`; body must literally contain `Ok` |
| qBittorrent (API key) | header `Referer` + `Authorization: Bearer <key>` | 401/403 | nil — a 403 means the key is wrong |
| Transmission | header `X-Transmission-Session-Id` when held; `Authorization: Basic` when a username is set | 409 → `.handshake("X-Transmission-Session-Id", value)` | no request: returns the token from the rejection |
| Deluge | cookie jar | HTTP 200 whose JSON `error.message` contains "not authenticated" → `.unauthenticated` | `POST /json {"method":"auth.login","params":[password]}` |
| rTorrent | `Authorization: Basic` when a username is set | 401 | nil |
| NZBGet | `Authorization: Basic` | 401 | nil |
| SABnzbd | `apikey` **query item** (no header form exists) | body `{"status":false,"error":"API Key Incorrect"}` → `.unauthenticated` | nil |
| Plex | header `X-Plex-Token` + `Accept: application/json` | 401 | nil |
| Jellyfin | header `Authorization: MediaBrowser Token="…"` | 401 | nil |
| Emby | header `X-Emby-Token` | 401 | nil |
| TMDB | v4 JWT → `Authorization: Bearer`; v3 hex → `api_key` query | 401 | nil |

Two consequences worth naming. (a) The "one login per client per run, reuse the session" rule of
§5 falls out of `SessionBroker` holding the token for the process lifetime and re-establishing only
on a rejection — the qBittorrent IP-ban risk is structurally bounded to one login per generation,
and a second rejection at the same generation surfaces instead of looping. (b) Cookie jars are a
**transport** concern: `URLSessionTransport.makeSession(cookies: true)` is used for the
qBittorrent and Deluge instances only; the pipeline never sees a cookie.

### C.5 Store

```swift
public enum FreshnessClass: Int, Sendable, CaseIterable {
    case volatile     // queue rows, download progress, now-playing — memory only, never SQLite
    case live         // health, disk space, command status — 60 s
    case warm         // details, files, history pages, releases — 10 min
    case reference    // quality/metadata profiles, root folders, custom formats — 12 h
    case archival     // library index, title metadata, TMDB facts, cross-walk — 30 d
    public var defaultTTL: Duration { get }
    public var retention: Duration { get }
    public var persists: Bool { self != .volatile }
}

public struct InvalidationTag: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
    public init(rawValue: String)
    public static func instance(_ id: InstanceID) -> Self                 // "i:radarr#0"
    public static func collection(_ name: String, _ id: InstanceID) -> Self  // "c:queue@radarr#0"
    public static func entity(_ id: MediaID) -> Self                      // "e:movie/radarr#0/1525"
    public static func global(_ name: String) -> Self                     // "g:connectivity"
}

public struct OperationID: Hashable, Sendable, RawRepresentable { public let rawValue: String }

public struct ResourceKey: Hashable, Sendable {
    public let instance: InstanceID
    public let operation: OperationID
    public let discriminator: String     // sorted "k=v" pairs of *non-secret* params only
    public var storageKey: String { "\(instance.rawValue)|\(operation.rawValue)|\(discriminator)" }
}

public struct Resource<Value: Codable & Sendable>: Sendable {
    public let key: ResourceKey
    public let tags: Set<InvalidationTag>
    public let freshness: FreshnessClass
    public let batch: BatchHint?          // "this op has a plural sibling"; see Compose
    public let fetch: @Sendable (RequestPipeline) async throws -> Value
}

public struct Command: Sendable {
    public let name: OperationID
    public let instance: InstanceID
    public let invalidates: Set<InvalidationTag>
    public let optimistic: PendingEffect?
    public let run: @Sendable (RequestPipeline) async throws -> Void
}

public enum Origin: Sendable { case memory, disk, network, coalesced, fixture }
public struct Fetched<Value: Sendable>: Sendable {
    public let value: Value
    public let origin: Origin
    public let fetchedAt: Date
    public let isStale: Bool
    public let tags: Set<InvalidationTag>
}

public actor ResourceStore {
    public init(database: SQLiteDatabase?,      // nil = memory-only (tests, previews)
                pipeline: RequestPipeline,
                clock: any MediaClock,
                telemetry: any TelemetrySink,
                log: any LogSink,
                memoryBudget: Int = 8 << 20)

    /// Returns a value at least as fresh as `maxAge` (which can only tighten the
    /// class TTL, never loosen it). On an open breaker or an offline host it
    /// returns the stale value if there is one, and only then throws.
    public func read<V>(_ resource: Resource<V>,
                        maxAge: Duration? = nil,
                        priority: RequestPriority = .interactive) async throws -> Fetched<V>

    /// Cached-first, then revalidated, then one element per matching invalidation.
    public func observe<V>(_ resource: Resource<V>, maxAge: Duration? = nil,
                           priority: RequestPriority = .background) -> AsyncStream<Fetched<V>>

    /// Disk/memory only; never issues a request. Used by the cold-start path.
    public func peek<V>(_ resource: Resource<V>) async -> Fetched<V>?

    public func run(_ command: Command) async throws
    public func invalidate(_ tags: Set<InvalidationTag>, reason: InvalidationReason)
    public func purge(_ class: FreshnessClass) async
    @concurrent public func sweep() async          // retention + size cap; registered in AppCaches
    public nonisolated var revision: StoreRevision { get }
}
```

**Coalescing and cancellation (criteria 2, 10).** `inFlight: [ResourceKey: Pending]` where
`Pending` holds the `Task<Data, Error>` and `waiters: Int`. `read` on a miss:

```swift
// inside ResourceStore, actor-isolated
if let pending = inFlight[key] {
    pending.waiters += 1
    telemetry.record(.coalesced(key, waiters: pending.waiters))
    return try await withTaskCancellationHandler {
        try await pending.task.value                    // shared result
    } onCancel: {
        Task { await self.dropWaiter(key) }             // last waiter out cancels the task
    }
}
```

`dropWaiter` decrements and calls `pending.task.cancel()` only at zero. A partial or cancelled
fetch never reaches `write` — the write happens after the decode returns on the success path only.

**Stale-while-revalidate.** `read` never returns stale when the host is reachable and `maxAge` is
violated; `observe` is the SWR surface (yield cached → yield revalidated). This split is why the
API has two functions instead of a `staleOK:` flag: views that must not flicker use `observe`,
tools and commands that need a real value use `read`.

```swift
/// Synchronous, lock-guarded projection of store rows for view bodies.
/// Two consumers today: poster URLs and watched state (phase-0 fact 10).
public final class Snapshot<Value: Sendable>: @unchecked Sendable {
    public init(tags: Set<InvalidationTag>, initial: Value,
                rebuild: @escaping @Sendable (ResourceStore) async -> Value)
    public var current: (value: Value, version: UInt64) { get }   // NSLock, no await
    public func attach(to store: ResourceStore) async             // subscribes to invalidations
}

/// The documented bridge from invalidation to a SwiftUI body (prompt decision 13).
/// `@Observable`, nonisolated, so `Observations { … }` (Observation, macOS 26+,
/// `init(_ emit: @escaping @isolated(any) @Sendable () throws(Failure) -> Element)`)
/// tracks reads of `tick(for:)` and emits one element per transaction.
@Observable public final class StoreRevision {
    public func tick(for tag: InvalidationTag) -> UInt64
    public var all: UInt64 { get }
}
```

Typed data-layer notifications (Foundation, macOS 26+; `NotificationCenter.AsyncMessage` is
`protocol AsyncMessage : Sendable`, posted with `func post<Message>(_ message: Message)`, observed
with `addObserver(of:for:using:) -> NotificationCenter.ObservationToken` or
`messages(of:for:bufferSize:)`; the subject-instance overloads require `Message.Subject: AnyObject`,
hence the final-class subject):

```swift
public final class MediaKitEvents: Sendable {          // the message subject
    public static let shared = MediaKitEvents()
}
extension MediaKitEvents {
    public struct ConfigurationChanged: NotificationCenter.AsyncMessage {
        public typealias Subject = MediaKitEvents
        public let instance: InstanceID
        public let fingerprintChanged: Bool
    }
    public struct Invalidated: NotificationCenter.AsyncMessage {
        public typealias Subject = MediaKitEvents
        public let tags: Set<InvalidationTag>
        public let reason: InvalidationReason
    }
    public struct ConnectivityChanged: NotificationCenter.AsyncMessage {
        public typealias Subject = MediaKitEvents
        public let host: Host
        public let health: HostHealth
    }
}
```

### C.6 Instances, credentials, capabilities

```swift
public enum ServiceKind: String, Sendable, CaseIterable, Codable {
    case radarr, sonarr, lidarr, whisparr
    case qbittorrent, transmission, deluge, rtorrent, sabnzbd, nzbget
    case plex, jellyfin, emby
    case tmdb
}

public struct InstanceID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let kind: ServiceKind
    public let ordinal: Int                    // 0 today; the schema never has to change
    public var rawValue: String { "\(kind.rawValue)#\(ordinal)" }
}

public struct Fingerprint: Hashable, Sendable, Codable, CustomStringConvertible {
    /// base URL + first 8 bytes of SHA-256(secret), hex. Never the secret.
    public init(baseURL: URL, secret: String?)
    public var description: String             // "https://host/radarr|a3f19c02d4e5b761"
}

public struct Credentials: Sendable {
    public enum Material: Sendable {
        case apiKey(String), userPassword(user: String, password: String), token(String), none
    }
    public let baseURL: URL
    public let material: Material
    public var host: Host { get }
}

public protocol CredentialProvider: Sendable {
    func credentials(for instance: InstanceID) async -> Credentials?
}

public struct InstanceDescriptor: Sendable {
    public let id: InstanceID
    public let baseURL: URL
    public let fingerprint: Fingerprint
    public let limits: HostGovernor.Limits?
}

public actor InstanceRegistry {
    public init(store: ResourceStore, capabilities: CapabilityRegistry, telemetry: any TelemetrySink)
    /// Recomputes the fingerprint. A change invalidates `.instance(id)` immediately and
    /// drops the capability set and the session token (criterion 5).
    public func update(_ id: InstanceID, baseURL: URL?, secret: String?) async
    public func remove(_ id: InstanceID) async
    public func descriptor(_ id: InstanceID) async -> InstanceDescriptor?
    public func configured() async -> [InstanceID]
}
```

Rotating a key at the same URL changes the fingerprint because the hash covers the key value —
the single defect phase 0 named in `ServiceConfig.identityFingerprint` (length only) and in
`CoalescingCache` (same-length rotation serves the old server forever).

```swift
public struct Capability: Hashable, Sendable, RawRepresentable, Codable {
    public static let servarrSeasonEndpointV5: Capability     // Sonarr PUT /api/v5/series/{id}/season
    public static let servarrEpisodeMonitorBulk: Capability   // PUT /api/v3/episode/monitor
    public static let lidarrSearchEndpoint: Capability        // GET /api/v1/search
    public static let whisparrV3: Capability
    public static let whisparrV2: Capability
    public static let qbittorrentApiKeyAuth: Capability
    public static let qbittorrentStopStartVerbs: Capability   // 5.x /torrents/stop|start
    public static let plexGuidChildren: Capability
    public static let jellyfinUserItems: Capability
}

public struct CapabilitySet: Sendable, Codable {
    public let capabilities: Set<Capability>
    public let reportedVersion: String?
    public let probedAt: Date
    public let fingerprint: Fingerprint
    public let source: Source            // .probe, .persisted, .conservativeDefault
    public func has(_ c: Capability) -> Bool
}

public actor CapabilityRegistry {
    public init(store: ResourceStore, pipeline: RequestPipeline, clock: any MediaClock, log: any LogSink)
    /// Never throws and never blocks on the network for longer than one probe:
    /// live probe → persisted set → conservative default for the kind.
    public func capabilities(for instance: InstanceID) async -> CapabilitySet
    public func invalidate(_ instance: InstanceID) async
    public func noteVersion(_ version: String, for instance: InstanceID) async
}
```

Probes are ordinary resources (`GET /api/v{n}/system/status`, `GET /api/v2/app/version`,
`GET /identity`, `POST /json {"method":"daemon.info"}`, `GET /3/configuration`) at
`FreshnessClass.reference`, so a probe obeys the breaker and is cached on disk — "once per
fingerprint, from disk after relaunch" (criterion 11) is a store property, not a new mechanism.

### C.7 Events

```swift
public enum DataEvent: Sendable, Equatable {
    case queueChanged(InstanceID)
    case queueStatus(InstanceID, QueueCounts)
    case fileImported(InstanceID, MediaID?)
    case commandCompleted(InstanceID, name: String)
    case other(InstanceID, resource: String, action: String)
    case woke
    case connectivity(Host, HostHealth)
}

public protocol EventSource: Sendable {
    func events() -> AsyncStream<DataEvent>
    func start() async
    func stop() async
    func forceReconnect() async
}

public actor SignalRSource: EventSource {
    public init(instance: InstanceID, pipeline: RequestPipeline, clock: any MediaClock,
                log: any LogSink)
    // POST /signalr/messages/negotiate?negotiateVersion=1 via the pipeline;
    // pipeline.socket(...) for wss:/signalr/messages?id=&access_token=
    public static func parse(frame: String, instance: InstanceID) -> FrameOutcome   // keeps today's 11 tests
    public enum FrameOutcome: Equatable { case events([DataEvent]), close, ignored }
}

public actor EventHub {
    public init(store: ResourceStore, tagMap: EventTagMap, telemetry: any TelemetrySink)
    public func attach(_ source: any EventSource, for instance: InstanceID) async
    public func detach(_ instance: InstanceID) async
    public func wakeAll() async         // AppDelegate's wake handler: forceReconnect + .woke
    public func events() -> AsyncStream<DataEvent>     // raw, for ArrCore's notification UX
}

public struct EventTagMap: Sendable {
    public func tags(for event: DataEvent) -> Set<InvalidationTag>
}
```

`EventTagMap` is the single place an event becomes tags (criterion 4). `queueChanged(i)` →
`{ .collection("queue", i) }`. `fileImported(i, id)` → `{ .collection("queue", i),
.collection("library", i) }` ∪ `{ .entity(id) }` when the frame carried one. `queueStatus` →
**no tags** unless the counts differ from the last seen ones — the free evidence today's
`QueueViewModel.noteQueueStatus` uses, moved down one layer. Burst coalescing (0.25 s window,
per-instance floor) lives in `EventHub`, not in a view-model.

Running the SignalR socket over `Transport.open` is what makes criterion 4 a fixture test:
`FixtureTransport.enqueueFrames` feeds recorded frames to the same parser.

### C.8 Live streams and pending

```swift
public struct LiveKind: Hashable, Sendable {
    public static let queue: LiveKind          // arr /queue + download-client progress overlay
    public static let progress: LiveKind
    public static let sessions: LiveKind       // media-server now-playing
}

public struct LiveValue<Element: Codable & Sendable>: Sendable {
    public let elements: [Element]
    public let measuredAt: Date
    public let partial: Set<InstanceID>        // instances that failed this cycle
    public let pending: [String: PendingEffect]
}

public actor LiveStream<Element: Codable & Sendable> {
    public init(kind: LiveKind, instances: [InstanceID], interval: Duration,
                store: ResourceStore, clock: any MediaClock,
                fetch: @Sendable (InstanceID, RequestPipeline) async throws -> [Element])
    public func values() -> AsyncStream<LiveValue<Element>>
    public func refreshNow(priority: RequestPriority) async
    public func setCadence(_ interval: Duration?)          // nil = paused (popover closed)
    public func apply(_ effect: PendingEffect) async       // optimistic, expires
    public func lastKnown() async -> LiveValue<Element>?   // from live_snapshots, cold start
}

public struct PendingEffect: Sendable {
    public let elementID: String
    public let change: Change                 // .status(String), .removed
    public let expiresAt: Date
}
```

Rules that fall out of the brief: every live poll is `.background`; the last value is written to
`live_snapshots` (one row per instance+stream) and **only** there — a `volatile` resource never
reaches `entries` (criterion 6); the pending overlay is applied on read of the stream value and
dropped on expiry or on the next value that already reflects it; the store is never written
optimistically. "Some clients failed vs all failed" (phase-0 fact 15) is `partial` plus the rule
that an empty successful cycle replaces the value while a fully failed cycle does not.

### C.9 Composition

```swift
public struct Provenance: Sendable {
    public let minFreshness: Date            // oldest fetchedAt among reads
    public let tags: Set<InvalidationTag>
    public let origins: [ResourceKey: Origin]
    public var isComplete: Bool              // no read failed
    public var failures: [ResourceKey: MediaKitError]
}

public struct Composed<Value: Sendable>: Sendable {
    public let value: Value
    public let provenance: Provenance
}

/// Not an actor: one context per composition, confined to the task that made it.
public struct CompositionContext: ~Copyable, Sendable {
    public func read<V>(_ r: Resource<V>, maxAge: Duration? = nil) async throws -> V
    public func optional<V>(_ r: Resource<V>, maxAge: Duration? = nil) async -> V?    // records the failure
    public func readAll<V>(_ rs: [Resource<V>], maxAge: Duration? = nil) async -> [Result<V, MediaKitError>]
}

public actor CompositionEngine {
    public init(store: ResourceStore, priorityForeground: RequestPriority = .interactive)
    /// Memoised on `input` (Hashable); memory only; dropped when any tag the body read is invalidated.
    public func compose<Input: Hashable & Sendable, Value: Sendable>(
        _ input: Input,
        priority: RequestPriority = .interactive,
        _ body: @Sendable (borrowing CompositionContext) async throws -> Value
    ) async throws -> Composed<Value>

    public func observe<Input: Hashable & Sendable, Value: Sendable>(
        _ input: Input,
        _ body: @Sendable (borrowing CompositionContext) async throws -> Value
    ) -> AsyncStream<Composed<Value>>
}
```

`readAll` is the batching surface: it groups by `Resource.batch` hint, issues one plural request
per group through the store's coalescer, and splits the answer. That is criterion 17 — 20 cards
read `radarr.movieFiles(ids:)` once, not 20 times — and it needs no planner.

### C.10 Artwork and discovery

```swift
public enum ArtworkTier: Sendable { case icon, card, full }
public struct ArtworkReference: Hashable, Sendable {
    public let url: URL                        // token-free, always
    public let owner: InstanceID?              // whose auth header applies, if any
    public let sizing: Sizing?                 // Plex /photo/:/transcode, TMDB wNNN, Jellyfin maxWidth
    public func url(for tier: ArtworkTier) -> URL
    public var cacheKey: String                // SHA-256(url(for:).absoluteString) — no secret
}
public protocol ArtworkAuthorizing: Sendable {     // PosterStore implements the byte layer
    func headers(for reference: ArtworkReference, tier: ArtworkTier) async -> HTTPHeaders
}

public struct DiscoveredServer: Sendable, Hashable {
    public let kind: ServiceKind
    public let name: String
    public let endpoint: URL
    public let source: Source     // .bonjour, .broadcast
}
public actor Discovery {
    /// Bonjour `_plexmediasvr._tcp` via NWBrowser(for:using:) with
    /// `NWBrowser.Descriptor.bonjourWithTXTRecord(type:domain:)` and
    /// `browseResultsChangedHandler`; Jellyfin/Emby via a UDP 7359 datagram on NWConnection.
    public func candidates(timeout: Duration) -> AsyncStream<DiscoveredServer>
    public static func parseBonjour(name: String, txt: [String: String], host: String, port: Int) -> DiscoveredServer?
    public static func parseBroadcast(_ payload: Data, from host: String) -> DiscoveredServer?
}
```

Nothing is written by discovery; results are candidates for Settings (prompt §3.2).

---

## D. SQLite

```swift
public final class SQLiteDatabase: @unchecked Sendable {   // serial queue inside; @concurrent entry points
    public static func open(at url: URL, readOnly: Bool) throws -> SQLiteDatabase
    @concurrent public func write(_ body: (Handle) throws -> Void) async throws
    @concurrent public func read<T>(_ body: (Handle) throws -> T) async throws -> T
}
```

### D.1 File location

| Platform | Path |
|---|---|
| macOS app (sandbox, no app group) | `~/Library/Containers/pl.incred.ArrBarr/Data/Library/Application Support/MediaKit/mediakit.sqlite` |
| iOS app + widget | `<group.pl.incred.ArrBarr>/Library/Application Support/MediaKit/mediakit.sqlite` |
| Tests | a temp directory per suite, or `nil` (memory-only store) |

On iOS, `FileProtectionType.completeUntilFirstUserAuthentication` (Foundation) is set on
`mediakit.sqlite`, `-wal` and `-shm` — the widget's timeline provider runs before first unlock
otherwise cannot open the file. Applied at creation and re-asserted after the first `PRAGMA
journal_mode=WAL` (which creates the sidecars).

### D.2 PRAGMAs

```sql
PRAGMA journal_mode = WAL;          -- two processes (app + widget extension) on iOS
PRAGMA synchronous  = NORMAL;       -- WAL + NORMAL is crash-safe for a cache
PRAGMA busy_timeout = 3000;
PRAGMA foreign_keys = ON;
PRAGMA temp_store   = MEMORY;
PRAGMA auto_vacuum  = INCREMENTAL;  -- sweep can return pages without a full VACUUM
```

The widget opens with `SQLITE_OPEN_READONLY` for its first read and re-opens read-write only when
it decides to refresh.

### D.3 DDL (user_version 1)

```sql
CREATE TABLE IF NOT EXISTS entries (
    key          TEXT    PRIMARY KEY,
    instance     TEXT    NOT NULL,
    fingerprint  TEXT    NOT NULL,
    class        INTEGER NOT NULL,
    payload      BLOB    NOT NULL,
    fetched_at   REAL    NOT NULL,
    stale_at     REAL    NOT NULL,
    last_used    REAL    NOT NULL,
    bytes        INTEGER NOT NULL
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS entries_instance ON entries(instance);
CREATE INDEX IF NOT EXISTS entries_sweep    ON entries(class, last_used);
CREATE INDEX IF NOT EXISTS entries_stale    ON entries(stale_at);

CREATE TABLE IF NOT EXISTS entry_tags (
    tag        TEXT NOT NULL,
    entry_key  TEXT NOT NULL REFERENCES entries(key) ON DELETE CASCADE,
    PRIMARY KEY (tag, entry_key)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS entry_tags_key ON entry_tags(entry_key);

-- survives a cache wipe
CREATE TABLE IF NOT EXISTS capabilities (
    instance     TEXT PRIMARY KEY,
    fingerprint  TEXT NOT NULL,
    payload      BLOB NOT NULL,
    version      TEXT,
    probed_at    REAL NOT NULL
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS identity_map (
    namespace   TEXT    NOT NULL,      -- tmdb, tvdb, imdb, musicbrainz, plex, radarr…
    value       TEXT    NOT NULL,
    kind        INTEGER NOT NULL,      -- MediaID.Kind
    canonical   TEXT    NOT NULL,      -- MediaID.rawValue
    confidence  REAL    NOT NULL,
    source      TEXT    NOT NULL,
    fetched_at  REAL    NOT NULL,
    PRIMARY KEY (namespace, value, kind)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS identity_canonical ON identity_map(canonical);

CREATE TABLE IF NOT EXISTS live_snapshots (
    instance    TEXT NOT NULL,
    stream      TEXT NOT NULL,
    payload     BLOB NOT NULL,
    captured_at REAL NOT NULL,
    PRIMARY KEY (instance, stream)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL) WITHOUT ROWID;
PRAGMA user_version = 1;
```

`live_snapshots` is the one exception to "volatile never on disk": it is not a cache entry, it is
the **last known** row the cold start renders. It is written once per successful live cycle
(debounced to 5 s), never read by `ResourceStore.read`, and carries no `stale_at` — the UI shows it
with its `captured_at` and immediately replaces it.

### D.4 Invalidation, retention, size

- `invalidate(tags:)` is one statement:
  `UPDATE entries SET stale_at = ?now WHERE key IN (SELECT entry_key FROM entry_tags WHERE tag IN (…))`.
  Nothing is deleted, so the breaker and the first render can still serve it (prompt §3.2).
- `sweep()` (`@concurrent`, on `AppCaches`' schedule and on `applicationDidEnterBackground`):
  1. `DELETE FROM entries WHERE stale_at < ?now - retention(class)` per class;
  2. while `SUM(bytes) > cap` (32 MB default, 8 MB in the widget), delete the oldest `last_used`
     rows in class order `warm → live → reference → archival`;
  3. `PRAGMA incremental_vacuum(64)`.
- `purge(class:)` deletes a whole class — Developer options' "clear caches".

### D.5 Migrations

`StoreSchema.migrate(db:)` reads `PRAGMA user_version` and applies steps in order. Policy:
**cache tables may be dropped and rebuilt** (`DROP TABLE entries; DROP TABLE entry_tags;` then
re-create), `capabilities`, `identity_map` and `live_snapshots` must be migrated in place — losing
them means a probe storm and an empty cold start. A future version that cannot migrate them
renames them to `*_v<n>` and re-derives, never drops.

---

## E. Service vocabularies

Every path below is from the golden corpus. `Tags` are the tags the resource carries
(read) / the command invalidates (write). Freshness class in the last column.

### E.1 Servarr — one client, four flavours

`ServarrProfile`: `apiBase` (`/api/v3` for radarr/sonarr/whisparr, `/api/v1` for lidarr), entity
noun (`movie`/`series`/`artist`), child noun (`—`/`episode`/`album`), file noun
(`moviefile`/`episodefile`/`trackfile`), and the six query-key spellings listed in §B.

| Resource | Method / path | Query | Tags | Class |
|---|---|---|---|---|
| `status` | `GET {api}/system/status` | — | `instance` | reference |
| `health` | `GET {api}/health` | — | `instance` | live |
| `diskSpace` | `GET {api}/diskspace` | — | `instance` | live |
| `queue` | `GET {api}/queue` | `pageSize`, `includeUnknown*Items` / `includeEpisode` | `c:queue` | volatile |
| `calendar` | `GET {api}/calendar` | `start,end,unmonitored[,includeSeries]` | `c:calendar` | warm |
| `history(page:)` | `GET {api}/history` | `page,pageSize,sortKey,sortDirection,include*` | `c:history` | warm |
| `historyFor(entity:)` | `GET {api}/history` | + `movieIds`/`seriesIds`/`albumIds` | `c:history`,`e:<id>` | warm |
| `library` | `GET {api}/{entity}` | — | `c:library` | archival |
| `details(id:)` | `GET {api}/{entity}/{id}` | — | `e:<id>` | warm |
| `files(for:)` | `GET {api}/{file}` | `movieId`/`seriesId`/`albumId` | `e:<id>` | warm |
| `episodes(seriesId:)` | `GET /api/v3/episode` | `seriesId` | `e:<series>` | warm |
| `tracks(albumId:)` | `GET /api/v1/track` | `albumId` | `e:<album>` | warm |
| `albums(artistId:)` | `GET /api/v1/album` | `artistId` | `e:<artist>` | warm |
| `qualityProfiles` / `metadataProfiles` / `rootFolders` / `customFormats` / `downloadClients` | `GET {api}/qualityprofile` … | — | `instance` | reference |
| `credits(movieId:)` | `GET /api/v3/credit` | `movieId` | `e:<movie>` | archival |
| `alternateTitles` | `GET /api/v3/alttitle` | — | `c:library` | archival |
| `lookup(term:)` | `GET {api}/{entity}/lookup` | `term` | `g:lookup` | warm |
| `lidarrSearch(term:)` | `GET /api/v1/search` | `term` | `g:lookup` | warm |
| `releases(for:)` | `GET {api}/release` | `movieId`/`episodeId`/`albumId` | `e:<id>` | volatile (120 s timeout) |
| `commandStatus` | `GET {api}/command` | — | `c:commands` | live |

| Command | Method / path | Body | Invalidates |
|---|---|---|---|
| `deleteQueueItem(id:removeFromClient:blocklist:)` | `DELETE {api}/queue/{id}` | query `removeFromClient,blocklist` | `c:queue` |
| `grabQueueItem(id:)` | `POST {api}/queue/grab/{id}` | `{}` | `c:queue` |
| `grabRelease(guid:indexerId:)` | `POST {api}/release` | `{guid,indexerId}` | `c:queue` |
| `search(entity:)` | `POST {api}/command` | `{name:"MoviesSearch"/"SeriesSearch"/"AlbumSearch"/"EpisodeSearch"/"SeasonSearch", …}` | `c:commands`, `e:<id>` |
| `refresh(entity:)` | `POST {api}/command` | `{name:"RefreshMovie", movieId}` | `e:<id>` |
| `setMonitored(entity:)` | `GET {api}/{entity}/{id}` then `PUT {api}/{entity}/{id}` | full record, `monitored` flipped | `e:<id>`, `c:library` |
| `setEpisodesMonitored(ids:)` | `PUT /api/v3/episode/monitor` | `{episodeIds,monitored}` | `e:<series>` |
| `setSeasonMonitored(seriesId:season:)` | capability-gated, below | | `e:<series>` |
| `add(title:)` | `POST {api}/{entity}` | add payload | `c:library`, `g:lookup` |
| `addAlbum(...)` | `GET /api/v1/search?term=` then `POST /api/v1/album` | two-step (release-group id) | `c:library` |
| `update(entity:)` | `GET` then `PUT {api}/{entity}/{id}?moveFiles=` | full record | `e:<id>`, `c:library` |
| `delete(entity:)` | `DELETE {api}/{entity}/{id}` | query `deleteFiles`, **both** `addImportExclusion` and `addImportListExclusion` | `c:library`, `e:<id>` |

**Sonarr season monitoring — capability-gated, not version-sniffed.**

```swift
func setSeasonMonitored(seriesID: Int, season: Int, monitored: Bool) async -> Command {
    let caps = await capabilities.capabilities(for: instance)
    if caps.has(.servarrSeasonEndpointV5) {
        return .put("/api/v5/series/\(seriesID)/season",
                    body: SeasonMonitorBody(seasonNumber: season, monitored: monitored), …)
    }
    return .readModifyWrite(                       // the v3 double-PUT, typed
        read:  servarr.details(seriesID),
        edit:  { series in series.flippingSeason(season, to: !monitored) },   // force the cascade
        then:  { series in series.flippingSeason(season, to: monitored) })
}
```

The probe sets `.servarrSeasonEndpointV5` from `/system/status`'s reported version; a 404/405 from
the v5 path **clears** the capability and retries once on the v3 path, so a wrong probe self-heals
without ever surfacing an error (criterion 11).

**The two untyped read-modify-write paths become typed.** `ArrAPIClient.getRawObject` +
`[String: Any]` mutation is replaced by a `ServarrRecord` protocol whose conformers are the full
`Codable` movie/series/artist/album models, edited by a function, re-encoded with
`JSONEncoder` configured to preserve unknown keys via a `AdditionalFields: [String: JSONValue]`
catch-all property. That last part is load-bearing and is the main new work in `ServarrWire.swift`:
a Servarr `PUT` must echo back fields we do not model, and the memory note "untyped JSON bodies
escape renames" is exactly the failure mode we are buying out. `JSONValue` is a small
`enum JSONValue: Codable, Sendable, Hashable` — ~60 of the 380 lines of `ServarrWire.swift`.

**Whisparr** is `ServarrProfile.radarr` with `kind = .whisparr` and the probe distinguishing
`.whisparrV3` (movie vocabulary, `movieCategory`) from `.whisparrV2` (series vocabulary,
`tvCategory`). A v2 instance yields `CapabilitySet{.whisparrV2}`, and every v3-only resource
throws `.unsupported(instance, .whisparrV3)` — the documented gap, surfaced as one localised
string, not as a broken screen.

### E.2 Download clients

All six conform to one protocol; the session mechanics live in the strategies from §C.4.

```swift
public protocol DownloadClient: Sendable {
    var instance: InstanceID { get }
    func progress(ids: Set<String>) -> Resource<[String: DownloadProgress]>   // volatile
    func version() -> Resource<String>                                        // reference
    func command(_ action: DownloadAction, hash: String) -> Command
    func add(_ drop: DownloadDrop, category: String?, paused: Bool) -> Command
    func defaultAddPaused() -> Resource<Bool?>                                // reference
    func contains(hash: String) -> Resource<Bool>
}
```

| Client | Progress read | Actions | Notes preserved from the corpus |
|---|---|---|---|
| qBittorrent | `GET /api/v2/torrents/info` | `POST /torrents/stop\|start\|delete\|setForceStart` (form) | `Referer` always; both `paused` and `stopped` fields on add; 409 on add = duplicate, not failure; "Fails." body compared exactly, never as a substring |
| Transmission | `POST /transmission/rpc {"method":"torrent-get","arguments":{"fields":["hashString","percentDone","rateDownload"],"ids":[…]}}` | `torrent-stop\|start\|remove\|add` | 409 handshake is a `SessionRejection.handshake`; `download-dir` = session dir + `/category` on add |
| Deluge | `POST /json {"method":"core.get_torrents_status"}` | `core.pause_torrent\|resume_torrent\|remove_torrent\|add_torrent_*` | in-band error envelope over HTTP 200; label plugin call after add is non-fatal |
| rTorrent | `POST /RPC2 d.multicall2` | `d.stop\|start\|erase`, `load.start` | XML-RPC codec with the alignment check the current client does (fields returned in declaration order) |
| SABnzbd | `GET /api?mode=queue&output=json&apikey=` | `mode=pause\|resume`, `name=delete` | the **only** GET-with-secret-in-query besides TMDB v3; `Redaction` registers `apikey` so the logged URL has no query |
| NZBGet | `POST /jsonrpc {"method":"listgroups","params":[0]}` | `editqueue` `GroupPause/GroupResume/GroupDelete`, `append` | HTTP Basic, no session |

`DownloadDrop` (magnet or file bytes + filename) and `DownloadProgress` (`progress`,
`downloadSpeed`) move into MediaKit unchanged in shape.

### E.3 Plex / Jellyfin / Emby

| Resource | Method / path | Tags | Class |
|---|---|---|---|
| `identity` | `GET /identity` (Plex), `GET /System/Info` (JF/Emby) | `instance` | reference |
| `libraries` | `GET /library/sections`, `GET /Users` + `GET /Items` | `c:library` | reference |
| `libraryIndex(section:)` | `GET /library/sections/{key}/all?includeGuids=1`, `GET /Users/{id}/Items` | `c:library` | archival |
| `nowPlaying` | `GET /status/sessions`, `GET /Sessions` | `c:sessions` | volatile |
| `recentlyWatched` | `GET /status/sessions/history/all?sort&X-Plex-Container-*` | `c:history` | warm |
| `seasonPosters(item:)` | `GET /library/metadata/{id}/children` | `e:<series>` | warm |

Commands `scanLibrary` and `emptyTrash` exist but are **not** on the allow-list; they run only
through `FixtureTransport` in tests. Guid parsing (`plex://`, `tvdb://`, `imdb://`, `tmdb://`)
produces `MediaID`s written into `identity_map`, which is what makes poster/watched lookups a
`Snapshot` read rather than a fetch.

### E.4 TMDB

`GET /3/...` with `Authorization: Bearer` (v4 JWT) or `api_key=` query (v3 hex). Resources:
`configuration` (reference), `movie/{id}`, `tv/{id}`, `movie/{id}/credits`,
`tv/{id}/aggregate_credits`, `*/videos`, `*/recommendations`, `*/similar`, `person/{id}`,
`person/{id}/movie_credits`, `person/{id}/tv_credits`, `search/person`, `discover/movie`,
`discover/tv`, `find/{id}?external_source=`, `tv/{id}/external_ids` — all `archival` except
`discover/*` (`warm`) and `configuration` (`reference`). TMDB is the one host that gets
`minimumInterval` (a real rate limit) and the one that will exercise criterion 7 in the field.
Image URLs are `ArtworkReference`s with `Sizing.tmdb(w342/w185/original)` and carry no credential.

---

## F. Six flows

### F1. Cold launch, off-LAN

1. `AppDelegate` builds the kit: `SQLiteDatabase.open(at: …, readOnly: false)`,
   `ResourceStore(database:…)`, `InstanceRegistry.update(…)` from `ConfigStore` (no network).
2. `PopoverContentView.task` calls `gateway.queueStream.lastKnown()` →
   `SELECT payload FROM live_snapshots WHERE stream='queue'` → the last queue renders. One SQLite
   read, no request. Upcoming: `store.peek(servarr.calendar(...))` for each configured instance →
   `entries` rows, stale, rendered with their `fetchedAt`. Library grid: `store.peek(servarr.library)`.
3. Only then does `queueStream.refreshNow(priority: .interactive)` fire. Each instance's first
   request hits `URLSessionTransport`, fails with `URLError.cannotConnectToHost` →
   `.unreachable(host:.refused)`. After three (the breaker threshold is reached per host on the
   first refresh because queue+calendar+health are three requests), `HostGovernor` → `.down`,
   `TelemetryEvent.breakerOpened`, `MediaKitEvents.ConnectivityChanged` posted once per host.
4. Every subsequent read for 30 s throws `.breakerOpen` **before** any socket — and
   `ResourceStore.read` catches exactly that case and returns the stale `Fetched` it already has,
   with `isStale = true`. No error reaches a view. The offline chip (memory: "offline UX must be
   subtle") reads `pool.allHealth()`; no alert, no retry storm, no spinner.
5. `EventHub` attaches `SignalRSource`s, which fail negotiate through the same pipeline and back
   off; the backoff is the source's (1 s → 30 s, 300 s cold-start throttle after ten dead cycles),
   unchanged from today.

### F2. DetailView opened twice inside the freshness window

First open, movie `1525` on `radarr#0`:

```swift
let composed = try await engine.compose(DetailInput(id: .movie(radarr0, 1525))) { ctx in
    async let details = ctx.read(radarr.details(1525), maxAge: .minutes(10))
    async let files   = ctx.read(radarr.files(for: 1525), maxAge: .minutes(10))
    async let profiles = ctx.read(radarr.qualityProfiles, maxAge: .hours(12))
    async let history = ctx.optional(radarr.historyFor(entity: 1525, page: 1), maxAge: .minutes(10))
    async let tmdbFacts = ctx.optional(tmdb.movie(tmdbID), maxAge: .days(30))
    return MovieDetail(try await details, try await files, try await profiles, await history, await tmdbFacts)
}
```

Requests: `details`, `files`, `history`, `tmdb.movie` = 4 (profiles come from `reference`, usually
cached; cold, 5). Baseline for "Detail movie" is 7 first-open, so this is not worse.

Second open within ten minutes: the engine's memo is hit on `DetailInput` (nothing invalidated it)
and returns `Composed` with **zero** store reads. Even with the memo cleared — say a queue event
invalidated `c:queue`, which is not in this composition's tag union, so it does not — every `read`
finds a fresh `entries`/memory row: `Origin.memory`, `TelemetryEvent.cacheHit` ×5, **0 requests**
(criterion 1). `FixtureTransport.requestLog` is the assertion.

The 17 client construction sites in `DetailView` collapse to one `engine.observe(DetailInput(...))`
in the view model; the view body has no `await` and no client (criterion 18).

### F3. Pause a download

```swift
let cmd = qbittorrent.command(.pause, hash: item.downloadID)      // POST /api/v2/torrents/stop
try await queueStream.apply(cmd.optimistic!)                      // pending .status("paused"), expires +30 s
try await store.run(cmd)
```

1. `apply` puts a `PendingEffect` on the live stream's last value; every subscriber re-renders with
   the row already showing "paused". The store is untouched.
2. `store.run` → `pipeline.send(plan)` with `retry: .never` (a pause is not idempotent in the
   sense that matters: a failed pause must not be silently repeated). `SessionBroker` attaches the
   SID cookie or the Bearer key; a 403 triggers exactly one re-login + one retry.
3. Success → `store.invalidate(cmd.invalidates)` → `c:queue@qbittorrent#0` and
   `c:queue@radarr#0` (the arr row mirrors the client state) → `StoreRevision.tick` bumps →
   `queueStream.refreshNow(.interactive)`.
4. The next live value that reports the row as paused clears the pending effect. If nothing
   confirms it by `expiresAt`, the overlay drops and the row snaps back to the server's truth —
   which is the honest outcome and the current 30 s `OptimisticOverride` behaviour.
5. Failure → the pending effect is dropped immediately, `MediaKitError` surfaces, ArrCore maps the
   case to a catalogue key.

### F4. SignalR queue event → view

1. `SignalRSource` receives `{"type":1,"target":"receiveMessage","arguments":[{"name":"queue","body":{"action":"sync"}}]}`
   → `parse` → `.events([.queueChanged(sonarr#0)])` (the `arguments[0].body` envelope, unchanged).
2. `EventHub` coalesces the burst (0.25 s window, 1 s floor) and asks
   `EventTagMap.tags(for:)` → `{ .collection("queue", sonarr#0) }`. A `queue/status` frame whose
   counts equal the last seen ones maps to **∅** and costs nothing.
3. `store.invalidate(tags, reason: .event)` → one `UPDATE entries SET stale_at` (no rows for a
   volatile resource — the queue is volatile — but the *calendar* and *history* rows that carry the
   same tag are marked), `StoreRevision.tick(for:)` bumps, `MediaKitEvents.Invalidated` posted.
4. ArrCore's `QueueViewModel` is iterating
   `for await _ in Observations({ kit.store.revision.tick(for: .collection("queue", .sonarr0)) })`
   and calls `queueStream.refreshNow(.background)`. The view body reads the `@Observable`
   view-model as it does today; no `await` enters a body.
5. Criterion 4's test replays a recorded frame through `FixtureTransport.enqueueFrames` and asserts
   the invalidated tag set is exactly `{c:queue@sonarr#0}` — not `library`, not `calendar`.

### F5. Widget timeline

1. `TimelineProvider.timeline(for:in:)` opens the group-container DB read-only:
   `SQLiteDatabase.open(at: groupURL, readOnly: true)`, builds a `ResourceStore` with
   `memoryBudget: 2 << 20` and `pipeline` disabled (`transport: .none` is not a thing — it uses a
   `RequestPipeline` whose governor limits are `maxConcurrent: 2`).
2. It calls `store.peek(servarr.calendar(...))` and `liveStream.lastKnown()` and returns entries
   **immediately** — a timeline is produced even with no network and no unlocked keychain.
3. If the newest row is older than 30 minutes and the extension has budget, it re-opens read-write,
   runs `store.read(servarr.calendar(...), maxAge: .minutes(30), priority: .background)`, which
   writes `entries` under WAL (the app may be writing concurrently; `busy_timeout` 3 s covers it),
   then returns a second timeline.
4. Criterion 16's grep: no `LibrarySummaryService`, no `UpcomingService`, no arr client in
   `ArrBarrWidgets/`; the target links `MediaKit` and `libsqlite3.tbd` only.

### F6. Capability probe

1. `capabilities(for: sonarr#0)`: `store.read(servarr.status, maxAge: .hours(12))` — a
   `reference` resource, so after a relaunch it comes from `entries` and costs **zero** requests
   (criterion 11's "from disk after relaunch").
2. The reported version parses to `4.x` → `.servarrSeasonEndpointV5` **absent**. `setSeasonMonitored`
   takes the v3 double-PUT branch with no request wasted on a 404.
3. If the probe *claims* v5 but the endpoint answers 404/405, the command clears the capability
   (`CapabilityRegistry.invalidate`) and re-runs on v3 in the same call. The user sees one
   successful toggle.
4. Whisparr: `/api/v3/system/status` answering with an `appName` of `Whisparr` and a version
   `3.x` → `.whisparrV3`; a `2.x` version (or a 404 on `/api/v3/movie` with a 200 on
   `/api/v3/series`) → `.whisparrV2`. Fixtures for both shapes are synthesised (owner decision Q3).
5. Probe failure: `capabilities(for:)` catches every error. Order: persisted row for the *same
   fingerprint* → conservative default per kind (`servarr`: no v5, no bulk episode monitor;
   `qbittorrent`: password login, `pause`/`resume` verbs sent under both spellings) → never an
   error, never a UI message. `source` on the returned set says which, and the telemetry report
   prints it.

---

## G. Concurrency and isolation

**Actors and why each one exists.**

| Type | Isolation | Why |
|---|---|---|
| `HostGovernor` | actor, one per host | the limiter/gate/breaker state is a single mutable cell that every request touches |
| `HostGovernorPool` | actor | the host→governor map |
| `SessionBroker` | actor, one per instance | the login generation counter and the shared in-flight `establish` task |
| `ResourceStore` | actor | the in-flight map + memory tier; the only writer of `entries` |
| `CapabilityRegistry`, `InstanceRegistry`, `IdentityStore` | actors | small, rarely contended, own persisted state |
| `EventHub`, `SignalRSource`, `LiveStream`, `Discovery` | actors | long-lived loops with cancellation and reconnect state |
| `CompositionEngine` | actor | the memo table |
| `FixtureTransport` | actor | mutable demo state |

**Nonisolated (no actor at all):** `RequestPipeline`, `URLSessionTransport`, `RequestBuilder`,
every `SessionStrategy`, `RetryPolicy`, `EventTagMap`, `AllowList`, `Redaction`, every wire model,
`Resource`, `Command`, `ResourceKey`, `ArtworkReference`, `MediaKitError`, `TelemetryRecorder`
(lock-guarded class), `Snapshot` (lock-guarded class), `StoreRevision` (`@Observable` class),
`SQLiteDatabase` (serial `DispatchQueue` inside, `@unchecked Sendable`).

**Nothing in MediaKit is `@MainActor`.** The package builds with `.defaultIsolation(nil)`
(SE-0466), so the only isolation is what a declaration states.

**What `NonisolatedNonsendingByDefault` changes (SE-0461).** A `nonisolated async func` now runs on
the **caller's** actor rather than hopping to the global concurrent pool. Two consequences this
design depends on:

1. `RequestPipeline.send` is nonisolated async and therefore inherits the caller's isolation — it
   does *not* force a hop per request. That is the whole reason a struct-over-actors pipeline is
   cheap: the hops that happen are the ones into `HostGovernor` and `SessionBroker`, which are the
   hops we actually want.
2. Work that must *not* run on the caller is marked `@concurrent`: `RequestPipeline.decode`,
   `SQLiteDatabase.read/write`, `ResourceStore.sweep`, `TelemetryRecorder.report`,
   `RtorrentClient`'s XML parse, `Fingerprint.init`'s SHA-256, `FixtureTransport`'s file load.
   Without the upcoming feature, `@concurrent` would be a no-op (prompt §1.3); with it, a 3 MB
   `/api/v3/movie` decode does not sit on the store actor while twenty other reads queue behind it.

**Codable models stay `Sendable`** because they are frozen value types with `let` stored
properties of `Sendable` type — no `[String: Any]` anywhere (phase-0 fact 2 is retired by
`JSONValue`). `InferIsolatedConformances` (SE-0470) matters at the ArrCore boundary, where
`@MainActor` composition types conform to `Hashable`/`Equatable` for the memo key without an
explicit `nonisolated` on every conformance.

**The synchronous view-body read.** `Snapshot<Value>` keeps `(value, version)` behind an `NSLock`
and is refreshed by a detached task subscribed to `StoreRevision`. `current` takes the lock,
copies two words, and returns — no `await`, no actor, exactly the argument
`MediaServerIndex`/`MediaServerPosterAccess` make today for being lock-guarded rather than actors.
The version lets a view detect a change without diffing the value.

**Cancellation.** Three layers, each testable.
`URLSessionTransport` rethrows `CancellationError`/`URLError.cancelled` bare and cancels the
URLSession task via `withTaskCancellationHandler(operation:onCancel:isolation:)`.
`RequestPipeline` treats cancellation as *not* a host failure (no breaker strike) and releases the
limiter slot.
`ResourceStore` counts waiters on the coalesced task and cancels the underlying fetch only when
the **last** waiter leaves; a cancelled fetch writes nothing (criteria 2, 10).

---

## H. Test strategy

`Tests/MediaKitTests/` — Swift Testing (`import Testing`, `@Test`, `#expect`). Every test injects
a transport; none touches `URLSession.shared` (criterion 3's measure). Shared helpers:
`TestClock`, `CountingTransport` (records `[RequestPlan]`, answers from a closure),
`FixtureTransport(bundleRoot: fixturesURL)`, `HostileTransport` (throws on any real host).

| # | Criterion | Test file · test | Transport / fixture |
|---|---|---|---|
| 1 | second read in window = 0 requests | `StoreFreshnessTests.swift` · `secondReadInsideWindowIssuesNoRequest` | CountingTransport |
| 2 | parallel reads coalesce; one cancel does not break the other | `StoreCoalescingTests.swift` · `twoReadersOneRequest`, `cancellingOneWaiterKeepsTheFetch` | CountingTransport + TestClock |
| 3 | command invalidates → next read goes out | `StoreInvalidationTests.swift` · `commandTagsForceRefetch`; `ServarrCommandTests.swift` · `pauseInvalidatesQueueTag` | Fixture radarr |
| 4 | SignalR event invalidates only its tags | `EventTagMapTests.swift` · `queueFrameInvalidatesOnlyQueue`; `SignalRFrameTests.swift` (the 11 ported cases) | FixtureTransport.enqueueFrames |
| 5 | URL or key change invalidates instantly | `InstanceRegistryTests.swift` · `keyRotationAtSameURLInvalidates`, `fingerprintExcludesSecret` | none |
| 6 | volatile never on disk | `StorePersistenceTests.swift` · `volatileReadsLeaveEntriesEmpty` | Fixture + temp SQLite |
| 7 | 429 blocks one host only | `HostGovernorTests.swift` · `retryAfterGatesOneHost`, `otherHostsKeepWorking` | CountingTransport + TestClock |
| 8 | per-host concurrency cap under 100 reads | `HostGovernorTests.swift` · `concurrencyNeverExceedsLimit(limit:)` (parameterised 1/4/8) | BlockingTransport |
| 9 | breaker open/half-open | `BreakerTests.swift` · `threeFailuresOpen`, `openServesStaleWithoutRequest`, `halfOpenSendsExactlyOne` | CountingTransport + TestClock |
| 10 | cancel → request cancelled, nothing stored | `CancellationTests.swift` · `lastWaiterCancelsRequest`, `cancelledFetchWritesNothing` | BlockingTransport |
| 11 | capabilities: once per fingerprint, disk after relaunch, Sonarr v3 path, Whisparr v2/v3, failure fallback | `CapabilityTests.swift` · 5 tests | Fixture sonarr/whisparr (synthetic) |
| 12 | no secret in key/log/telemetry/fixtures | `SecretLeakTests.swift` · `resourceKeysCarryNoSecret`, `telemetryReportCarryNoSecret`, `logSinkRedactsQuery`, `repoFixturesCarryNoSecret` (walks `Fixtures/**`) | all four |
| 13 | every error case has a catalogue key | ArrCore `MediaKitErrorMappingTests.swift` + `Tools/loc/lint_missing_keys.py` | — |
| 14 | demo only via FixtureTransport | `grep -r DemoMode Packages/MediaKit \| wc -l` = 0 (verifier step) | — |
| 15 | cold start renders from SQLite before first request | `ColdStartTests.swift` · `popoverDataAvailableBeforeFirstRequest` | DelayingCountingTransport |
| 16 | widget builds, links MediaKit, own connection | `xcodebuild ArrBarrWidgets` + grep; `WidgetStoreTests.swift` · `readOnlyOpenServesLastKnown` | temp group dir |
| 17 | 20 cards do not scale requests | `CompositionBatchTests.swift` · `twentyCardsIssueOneBatchRequest` | Fixture radarr |
| 18 | no client construction in Views/ViewModels | grep gate (verifier) | — |
| 19 | 28 tools on fixtures | ArrCore `LocalToolBackendFixtureTests.swift` | FixtureTransport |
| 20 | three `swift test` green, zero MediaKit warnings | `GetBuildLog` after `BuildProject` scheme MediaKit | — |
| 21 | telemetry report per host | `TelemetryReportTests.swift` · `reportCountsEveryCategory` | CountingTransport |
| 22 | no `#available(macOS 26…)` | grep gate | — |
| 23 | typed messages | `TypedMessageTests.swift` · `invalidationPostsAsyncMessage` + grep gate | — |
| 24 | manifest isolation settings | build gate | — |
| 25 | discovery parsers without a network | `DiscoveryParserTests.swift` · `parsesPlexBonjourRecord`, `parsesJellyfinBroadcast` | recorded payload bytes |
| 26 | golden-corpus parity | `GoldenParityTests.swift` · one parameterised test over the 181 rows: build every operation's `RequestPlan`, compare method + templated path + sorted query keys + header names against the JSON | RecordingTransport's plan builder |
| 27 | counters/timings not worse | phase-6 report from `TelemetryRecorder.report()` + `GetConsoleOutput` | — |
| 28 | phase 7 | out of this design's scope | — |

**Fixture transport matching** is specified in §C.1. Two rules worth restating because tests depend
on them: a request that matches no rule **throws** (a silent `[]` would make criteria 15 and 17
pass for the wrong reason), and `requestLog` is the assertion surface for every "how many
requests" criterion — it records `OperationID`, never a URL, so a leaking test cannot print a
secret.

**Criterion 26 in particular** is cheap because `RequestPlan` exists: the parity test never sends
anything. It asks each client for its plan and diffs the tuple
`(method, templatedPath, sorted(queryKeys), sorted(headerNames))` against the corpus row, with an
explicit `knownDeviations: [OperationID: Reason]` table (today: none expected except Sonarr's
season command, which is now capability-gated rather than try-then-fallback, so the v5 row appears
only when the capability is set).

**The allow-list is enforced in code, not in a prompt.** `RecordingTransport.send` calls
`AllowList.section5.permits(request, kind:)` and throws `.notPermitted` on a miss, before the
request is handed to the wrapped transport. `AllowListTests.swift` asserts, row by row, that every
"forbidden" cell of the §5 table is refused — including `GET /release` on all four arrs, every
`POST`/`PUT`/`DELETE`, `torrents/delete`, `core.remove_torrent`, `d.erase`, `mode=addfile`,
`editqueue`, `/library/sections/{id}/refresh`, `/library/sections/{id}/emptyTrash`,
`/Library/Refresh` and `/authentication/*`.

---

## I. Migration seam (phase 5)

One file in ArrCore: `Services/ServiceGateway.swift`.

```swift
@MainActor public final class ServiceGateway {
    public static let shared = ServiceGateway()
    public private(set) var kit: MediaKit
    /// The ONLY construction of MediaKit in the app. Called once from AppDelegate
    /// and on every ConfigStore change.
    public func configure(with config: ConfigStore, demo: Bool)
}

public struct MediaKit: Sendable {
    public let store: ResourceStore
    public let pipeline: RequestPipeline
    public let instances: InstanceRegistry
    public let capabilities: CapabilityRegistry
    public let events: EventHub
    public let telemetry: TelemetryRecorder
    public func servarr(_ id: InstanceID) -> ServarrClient
    public func download(_ id: InstanceID) -> any DownloadClient
    public func mediaServer(_ id: InstanceID) -> MediaServerClient
    public func tmdb() -> TMDBClient
    public func engine() -> CompositionEngine
    public func liveQueue() -> LiveStream<QueueRecord>
}
```

- **ConfigStore → InstanceRegistry.** `ServiceGateway` owns one `Observations` loop over
  `ConfigStore`'s `@Observable` state (it already is `@Observable`; `QueueViewModel`'s five
  1.5 s Combine debounce pipelines collapse into this one loop) and calls
  `instances.update(id, baseURL:secret:)` per kind. `ConfigStore` also implements
  `CredentialProvider` — the only place a secret leaves it. The recomputed fingerprint does the
  invalidation; no view-model participates.
- **Demo becomes a transport choice.** `configure(with:demo:)` picks
  `FixtureTransport(bundleRoot: Bundle.module.fixtures, rules: .demo, mutable: .demoSeed)` instead
  of `URLSessionTransport`. `DemoMocks`, `DemoQueueState`, `DemoMonitorState` and the 46
  `DemoMode.isActive` branches die with the old clients; ArrCore keeps one `isDemo` flag for
  badges. The three inconsistencies phase 0 found (`fetchQueue/Calendar/History` ungated,
  `fetchHealth`/`fetchDiskSpace`/`deleteQueueItem` hitting the network in demo) vanish by
  construction: nothing can reach the network except through the injected transport.
- **PosterStore consumes `ArtworkReference`.** It keeps the byte layer (tiers, disk, memory) and
  loses its private request building: `download(_ ref: ArtworkReference, tier:)` asks
  `gateway.kit.artworkHeaders(for: ref)` and fetches `ref.url(for: tier)`. `cacheKey` is the
  reference's, so a rotated media-server token no longer invalidates the poster cache.
- **The 28 tools.** `LocalToolBackend` is already the single funnel for chat, MCP and AppIntents
  (phase-0 fact 11). Each tool's body becomes `engine.compose(...)`/`store.run(...)`; the tool
  list, argument schemas and result shapes do not change, so `ArrMCPServer`'s two bridge files
  (123 lines) are untouched.
- **The widget** links `MediaKit` and builds its own `MediaKit` with a read-only-first store
  (flow F5). `WidgetDataStore` keeps only the demo flag and the app-group `ServiceConfig` mirror
  that feeds `CredentialProvider`.
- **Domain types stay.** `QueueItem`, `UpcomingItem`, `HistoryItem` are built in ArrCore from
  `Composed<…>` values; `QueueAggregator`'s merge (arr queue ⨝ client progress by lowercased
  download id) becomes a composition over `LiveStream<QueueRecord>` and the download clients'
  progress resource.
- **Health.** `ConnectionHealthMonitor` is deleted; `ConnectionHealth`/`ServerStatusModel` read
  `pool.allHealth()` and the `ConnectivityChanged` message. The 60 s probe timer goes away: a host
  is healthy because requests to it succeed, not because a separate timer says so.

---

## J. Risks, open questions, dropped ideas

### Risks

1. **The budget is 10 lines of slack.** If `ServarrWire.swift` needs more than 380 lines (the
   `JSONValue` catch-all for `PUT` round-trips is the risk), something else must go. Relief valves
   in order: move `FixtureTransport` rules into JSON data files (−60), drop
   `Discovery` to parsers only and defer `NWBrowser` (−90), merge `Compose` into `Store` (−40).
2. **`Transport.open` for WebSockets** means `URLSessionWebSocketTask` semantics leak one level up
   (a socket is not a request). If the SignalR source turns out to need redirect or cookie
   behaviour the protocol cannot express, the honest fix is a second protocol, not a flag.
3. **Two processes on one SQLite file** (iOS app + widget). WAL plus `busy_timeout` covers it, but
   a long `sweep()` in the app while the widget reads can still hit the 3 s timeout. Mitigation:
   `sweep` runs in bounded batches (`LIMIT 200` per transaction).
4. **Servarr `PUT` round-trips.** Echoing unmodelled fields through `JSONValue` is correct but
   fragile against a Servarr release that rejects a field it previously sent. Only the golden
   corpus protects us, and the corpus has the *bodies* intercepted, not accepted.
5. **`Observations` granularity.** `StoreRevision.tick(for:)` reads one dictionary property, so
   every observer wakes on every invalidation and re-reads its own tick. At ArrBarr's scale
   (single-digit observers) that is fine; at ten times that it is a thundering herd.

### Open questions (with my recommended answer)

1. **Does `entries.payload` store the decoded value re-encoded, or the raw response bytes?**
   Recommend **re-encoded value**: it is smaller (the truncation of unused fields is free), it
   makes the disk format independent of the service, and a decoder change invalidates via
   `user_version` rather than silently mis-decoding. Cost: one extra encode per network read.
2. **Should `interactive` reads ever be allowed to jump an in-flight `background` request?**
   Recommend **no preemption, but priority ordering in the queue** plus a separate slot budget:
   `maxConcurrent: 4` of which at most 2 may be `background`. Simpler to reason about than
   cancel-and-restart.
3. **Is `RecordingTransport` in its own target acceptable** for the 60 % budget, given it is
   developer tooling that must not ship in the widget? Recommend **yes**, stated in the phase-6
   report as a line-count note so the number is not silently flattering.
4. **Does the widget get a `CredentialProvider` at all**, given the OSS macOS build's keychain
   probe fails and iOS keeps secrets in the group suite? Recommend **yes on iOS** (group suite,
   same as today) and accept that a first-launch-before-unlock timeline is snapshot-only.
5. **`FreshnessClass.volatile` for `/release`** (indexer search, 120 s timeout): it is volatile in
   content but expensive in time. Recommend volatile **with a 60 s memory-only TTL** so a back-out
   and re-open of the release list does not re-fan-out to every indexer.
6. **Whisparr v2 detection without an instance.** The probe rule above (`appName` + version, with
   an entity-noun fallback) is designed against documentation and the fork relationship, not
   against a live server. Recommend shipping it behind `.whisparrV2` → `.unsupported` and marking
   the fixtures `synthetic: true`, as phase 0 decided for Jellyfin/Emby.

### Section-3 ideas I dropped

- **`ConnectionHealthMonitor`/`ServerStatusModel` reading from the breaker** — kept the reading,
  dropped the *monitor*: no periodic probe at all, health is a by-product of real traffic.
- **A `MediaGraph` query planner** (spike) — replaced by `CompositionContext.readAll` plus a
  `BatchHint` on the resource; a planner buys nothing when the batch sets are known statically.
- **Per-field providers with cost and precedence** (spike) — dropped; the field-level merge
  belongs in ArrCore's composition where the product decision ("prefer the media server's poster")
  actually lives.
- **`ProviderHealth`** (spike) — never set in the spike, and now subsumed by `HostHealth`.
- **A generic identity resolver protocol** — dropped for a cross-walk table plus per-client guid
  parsing; resolvers were a framework with two implementations.
- **`AsyncStream`-based `WakeSource`** — wake is one method call on `EventHub`, not a source.
- **Separate `ConnectionHealthState` enum in MediaKit** — `HostHealth` is the only health type.
- **`CoalescingCache` semantics (no TTL, LRU, `@MainActor`)** — dropped entirely; it is the bug in
  phase-0 fact 14, not a design to port.
- **Retry on writes** — §3 allows "explicitly idempotent writes"; I allow none. The only retried
  non-GET is the one-shot re-send after a session rejection, which is a different mechanism with
  its own name (`RetryDisposition.handshakeOnly`).
