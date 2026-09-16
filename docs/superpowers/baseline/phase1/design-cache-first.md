# MediaKit design — cache-first angle

Phase 1 architect submission. Inputs: `docs/superpowers/prompts/2026-09-15-mediakit-rewrite-prompt.md`,
`docs/superpowers/baseline/2026-09-15-mediakit-phase0-report.md`, `docs/superpowers/baseline/phase0/*.json`,
`docs/superpowers/baseline/2026-09-15-golden-requests.json` (181 rows), `Packages/MediaKit/Fixtures/**` (109 bodies + sidecars),
and the current ArrCore call sites.

---

## A. Thesis

**The store is the API; a client is a description of data, not a procedure.** Every read in the app is a
`Resource` value — a secret-free key, a set of invalidation tags, a freshness class, a request plan and a pure
decoder — and the only thing that ever touches the network is the store, which owns freshness, coalescing,
stale-while-revalidate, the SQLite tier and the tag index. Clients become tables of `Resource`/`Command`
constructors with no I/O and no state; the composition engine above the store turns "the data DetailView needs"
into a memoised, batched, provenance-carrying read whose worst case is one request per *distinct* resource, ever.
This optimises hard for criteria 1, 2, 3, 6, 15, 17 (offline-first, no request storms) and for testability: a
resource is a value, so almost the whole package is testable without a transport at all. What it deliberately
sacrifices: **commands are second-class** — they are not cached, not composed and not retried, and anything that
needs a genuine multi-round-trip conversation (qBittorrent's SID login, Transmission's 409 handshake, Deluge's
cookie) is pushed *below* the client into a per-instance session actor, so client code cannot express "call A then
B" and a protocol that needed to would have to change the session layer. It also sacrifices decoded-value
persistence: the disk tier stores **response bytes**, not encoded models, so a model change is free but a decoder
must be a pure function of bytes (no response headers, no ambient state). And it spends its complexity budget on
the store — the transport is deliberately the dullest part of the package.

---

## B. Module layout and line budget

Budget from phase 0: MediaKit production code ≤ **8,590** lines (60 % of the 14,317 it replaces).
Production = `Packages/MediaKit/Sources/MediaKit/**` + `Package.swift`. Tests, fixtures (data) and
`RecordingTransport` (test-only, see below) are outside the budget.

| # | File | LOC |
|---|---|---|
| | **Core (12 files)** | |
| 1 | `Package.swift` | 20 |
| 2 | `Core/InstanceID.swift` | 80 |
| 3 | `Core/Fingerprint.swift` | 90 |
| 4 | `Core/MediaKitError.swift` | 110 |
| 5 | `Core/HTTPPrimitives.swift` | 140 |
| 6 | `Core/RequestPlan.swift` | 130 |
| 7 | `Core/ResourceKey.swift` | 80 |
| 8 | `Core/Resource.swift` | 190 |
| 9 | `Core/InvalidationTag.swift` | 120 |
| 10 | `Core/Clock.swift` | 40 |
| 11 | `Core/Telemetry.swift` | 120 |
| 12 | `Core/Log.swift` | 80 |
| | *subtotal* | **1 200** |
| | **Transport (7)** | |
| 13 | `Transport/Transport.swift` | 60 |
| 14 | `Transport/URLSessionTransport.swift` | 120 |
| 15 | `Transport/FixtureTransport.swift` | 180 |
| 16 | `Transport/HostLimiter.swift` | 140 |
| 17 | `Transport/BreakerRegistry.swift` | 170 |
| 18 | `Transport/InstanceSession.swift` | 230 |
| 19 | `Transport/InstanceRegistry.swift` | 130 |
| | *subtotal* | **1 030** |
| | **Store (3)** | |
| 20 | `Store/ResourceStore.swift` | 470 |
| 21 | `Store/FactDatabase.swift` | 470 |
| 22 | `Store/Schema.swift` | 130 |
| | *subtotal* | **1 070** |
| | **Identity & capabilities (4)** | |
| 23 | `Identity/MediaIdentity.swift` | 160 |
| 24 | `Identity/IdentityResolver.swift` | 180 |
| 25 | `Capabilities/Capability.swift` | 70 |
| 26 | `Capabilities/CapabilityRegistry.swift` | 160 |
| | *subtotal* | **570** |
| | **Events & live (5)** | |
| 27 | `Events/DataEvent.swift` | 70 |
| 28 | `Events/EventTagMap.swift` | 90 |
| 29 | `Events/SignalREventSource.swift` | 360 |
| 30 | `Events/WakeEventSource.swift` | 60 |
| 31 | `Live/LiveFeed.swift` | 220 |
| | *subtotal* | **800** |
| | **Composition (2)** | |
| 32 | `Composition/CompositionEngine.swift` | 300 |
| 33 | `Composition/CompositionContext.swift` | 180 |
| | *subtotal* | **480** |
| | **arr clients (5)** | |
| 34 | `Clients/Arr/ArrDialect.swift` | 140 |
| 35 | `Clients/Arr/ArrResources.swift` | 260 |
| 36 | `Clients/Arr/ArrCommands.swift` | 220 |
| 37 | `Models/Arr/ArrCommon.swift` | 280 |
| 38 | `Models/Arr/ArrEntities.swift` | 220 |
| | *subtotal* | **1 120** |
| | **Download clients (8)** | |
| 39 | `Clients/Download/DownloadVocabulary.swift` | 110 |
| 40 | `Clients/Download/RPC.swift` | 90 |
| 41 | `Clients/Download/QBittorrent.swift` | 170 |
| 42 | `Clients/Download/Transmission.swift` | 120 |
| 43 | `Clients/Download/Deluge.swift` | 110 |
| 44 | `Clients/Download/RTorrent.swift` | 130 |
| 45 | `Clients/Download/SABnzbd.swift` | 100 |
| 46 | `Clients/Download/NZBGet.swift` | 100 |
| | *subtotal* | **930** |
| | **Media servers & TMDB (6)** | |
| 47 | `Clients/MediaServer/MediaServerVocabulary.swift` | 100 |
| 48 | `Clients/MediaServer/Plex.swift` | 220 |
| 49 | `Clients/MediaServer/JellyfinEmby.swift` | 200 |
| 50 | `Models/MediaServerWire.swift` | 180 |
| 51 | `Clients/TMDB.swift` | 150 |
| 52 | `Models/TMDBWire.swift` | 120 |
| | *subtotal* | **970** |
| | **Artwork & discovery (3)** | |
| 53 | `Artwork/ArtworkReference.swift` | 150 |
| 54 | `Discovery/Discovery.swift` | 130 |
| 55 | `Discovery/BeaconParsing.swift` | 80 |
| | *subtotal* | **360** |

Arithmetic: 1 200 + 1 030 + 1 070 + 570 + 800 + 480 + 1 120 + 930 + 970 + 360 = **8 530**. Reserve **60** lines.

**What was cut to fit** (each an explicit decision, not a shave):

1. **Per-arr clients collapse into one dialect-driven table.** Radarr, Sonarr, Lidarr and Whisparr are the same
   product; the difference is `apiBase`, entity path names, and three query-parameter spellings. Four `ArrDialect`
   values (≈35 lines each) + one shared resource/command table replace 2 179 lines of ArrCore client code. Saves ≈700.
2. **One shared wire model for the shared shapes.** `queue`, `history`, `calendar`, `health`, `diskspace`,
   `qualityprofile`, `rootfolder`, `customformat`, `downloadclient`, `release`, `command` decode into `ArrCommon`
   types with an `ArrEntityRef` that takes whichever of `movie`/`series`/`episode`/`album` is present. Per-arr wire
   models shrink to entity + file records only. Saves ≈240.
3. **`RecordingTransport` is a test target file**, not production. It exists to re-record fixtures and to run the
   phase-6 parity diff; shipping it would put the section-5 allow-list inside the app. The allow-list stays "in
   transport code, not in a prompt" — it is just transport code that lives in `Tests/`. Saves 200.
4. **The disk tier stores response bytes, not encoded models.** No `Encodable` half of the cache, no second
   representation, no re-encode step, and the fixtures *are* cache payloads. Saves ≈250 across store + 40 models.
5. **No generic `Composition` protocol.** Compositions live in ArrCore; MediaKit exposes a context + an engine
   keyed by any `Hashable`. Saves ≈120 and one conceptual layer.
6. **Polling is a `LiveFeed` cadence, not an `EventSource`.** Only SignalR and system wake are event sources. Saves ≈90.
7. **Memory tier, in-flight coalescing and retry are private types inside `ResourceStore`**, not three files. Saves ≈240.
8. **Jellyfin and Emby are one client with a flavor**; Whisparr is the Radarr dialect plus a capability. Saves ≈380.
9. **Demo mocks become data.** ArrCore's 2 889 lines of `DemoMocks*`/`DemoQueueState`/`DemoMonitorState` are
   replaced by fixture JSON + ≈180 lines of `FixtureTransport`. This single substitution is why the 60 % budget is
   reachable at all; without it the target is not credible.

If the owner refuses CryptoKit (see J/Q1), `Fingerprint.swift` grows by 105 lines to carry a hand-rolled SHA-256
and the reserve is blown by 45. Pre-approved compensating cut in that case: defer `Discovery/*` (210 lines) to
phase 7 — LAN discovery is a Settings convenience with no consumer in the migration path.

---

## C. Public API sketch

All declarations below are the real shapes. Isolation is stated on every type.

### C.1 Primitives

```swift
// Core/HTTPPrimitives.swift — nonisolated value types throughout.
public enum HTTPMethod: String, Sendable, Hashable, Codable { case get, post, put, delete, patch }

public struct HeaderName: Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let canonical: String                 // lowercased; comparison is case-insensitive by construction
    public init(stringLiteral value: StringLiteralType)
}

public struct QueryItem: Hashable, Sendable, Codable {
    public let name: String
    public let value: String
    public init(_ name: String, _ value: String)
    public init(_ name: String, _ value: Int)
}

/// What the transport hands back. Deliberately tiny: status, bytes, headers.
public struct TransportResponse: Sendable {
    public let status: Int
    public let body: Data
    public let headers: [HeaderName: String]
    public func header(_ name: HeaderName) -> String?
}

public enum TransportFailure: Sendable, Equatable, Hashable {
    case cannotConnect, dnsFailure, tlsFailure, timedOut, networkLost, cancelled, other(code: Int)
}

/// A request with every credential already substituted. Only the transport and the
/// session layer ever see one; it never reaches a cache key, a log line or telemetry.
public struct PreparedRequest: Sendable {
    public let url: URL
    public let method: HTTPMethod
    public let headers: [HeaderName: String]
    public let body: Data?
    public let timeout: Duration
    /// Secret-free label used for logging, telemetry, fixtures and the allow-list.
    public let label: OperationLabel
    public var loggableURL: String { /* scheme://host:port + path, never the query */ }
}

/// One field that does four jobs: fixture lookup, recording allow-list entry,
/// telemetry bucket, and the join key for the phase-6 golden-corpus diff.
public struct OperationLabel: Hashable, Sendable, Codable, CustomStringConvertible {
    public let service: ServiceKind          // "radarr"
    public let operation: String             // "fetchQueue" — matches the golden corpus `operation` column
    public let variant: String?              // templated path when one operation has several, e.g. "/api/v3/moviefile"
}
```

### C.2 Transport

```swift
// Transport/Transport.swift
public protocol Transport: Sendable {
    /// Cancellation is cooperative and mandatory: an implementation must abandon the
    /// request when the calling task is cancelled and throw `MediaKitError.cancelled`.
    func send(_ request: PreparedRequest) async throws -> TransportResponse
}

// nonisolated struct — no state beyond the session it was handed.
public struct URLSessionTransport: Transport {
    public init(session: URLSession)                    // caller owns the session; never `.shared`
    public func send(_ request: PreparedRequest) async throws -> TransportResponse
}
```

Cancellation is implemented explicitly rather than relying on `URLSession.data(for:)` propagation, because the
documented contract we can cite is on the task object, not on the async method:
`URLSessionTask.cancel()` — *"Cancels the task… an error in the domain `NSURLErrorDomain` with the code
`NSURLErrorCancelled`"* (Foundation) — paired with
`withTaskCancellationHandler(operation:onCancel:isolation:)` (Swift Concurrency):

```swift
// inside URLSessionTransport.send
let task = session.dataTask(with: urlRequest) { ... }
return try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation { c in /* store c, task.resume() */ }
} onCancel: {
    task.cancel()
}
```

```swift
// Transport/FixtureTransport.swift — actor: it owns mutable demo state (pause/resume/monitor toggles).
public actor FixtureTransport: Transport {
    public struct Corpus: Sendable {
        /// Directory laid out exactly like `Packages/MediaKit/Fixtures/<service>/<operation>[-<variant>].json`
        /// with the recorded `.meta.json` sidecar next to it.
        public init(root: URL)
    }
    public init(corpus: Corpus, seed: DemoSeed = .default, clock: any MediaClock)
    public func send(_ request: PreparedRequest) async throws -> TransportResponse
    /// Every host reached through this transport is imaginary; `hostsTouched` is always empty.
    public func hostsTouched() -> Set<HostKey>
}

// Tests/MediaKitTests/Support/RecordingTransport.swift — NOT shipped.
public actor RecordingTransport: Transport {
    /// Section-5 allow-list as a code table. Anything absent is refused *before* the send.
    static let allowed: Set<AllowedOperation>
    public init(inner: any Transport, writing to: URL)
    public func send(_ request: PreparedRequest) async throws -> TransportResponse
}
```

### C.3 Limiter, breaker, priority

```swift
public struct HostKey: Hashable, Sendable, Codable { public init(_ url: URL) }   // scheme + host + port

public enum RequestPriority: Int, Sendable, Comparable, Codable { case background = 0, interactive = 1 }

// Transport/HostLimiter.swift
public actor HostLimiter {
    public struct Limits: Sendable, Equatable {
        public var maxConcurrent: Int = 4          // matches today's maxConcurrentSideLoads
        public var interactiveReserve: Int = 2     // lanes background work may never occupy
        public var minInterval: Duration = .zero
    }
    public init(defaults: Limits, overrides: [HostKey: Limits] = [:], clock: any MediaClock)
    /// Closure form so a permit cannot leak. Throws `.cancelled` if the task dies while queued.
    public func withPermit<T: Sendable>(
        _ host: HostKey, priority: RequestPriority,
        _ body: @Sendable () async throws -> T
    ) async throws -> T
    /// 429: hold this host until the instant, regardless of priority. Other hosts are untouched.
    public func hold(_ host: HostKey, until: Instant)
}

// Transport/BreakerRegistry.swift
public actor BreakerRegistry {
    public enum State: Sendable, Equatable, Codable {
        case healthy
        case degraded(consecutiveFailures: Int)
        case open(until: Instant)
        case halfOpen                       // exactly one probe in flight
    }
    public enum Admission: Sendable, Equatable { case allow, probe, refuse(until: Instant) }

    public init(clock: any MediaClock, openAfter: Int = 3, baseCooldown: Duration = .seconds(20), maxCooldown: Duration = .seconds(300))
    public func admit(_ host: HostKey) -> Admission
    public func recordSuccess(_ host: HostKey)
    public func recordFailure(_ host: HostKey, _ error: MediaKitError)
    public func state(_ host: HostKey) -> State
    /// The single source of truth about service health. `ConnectionHealthMonitor` and
    /// `ServerStatusModel` read this or disappear.
    public func health() -> [HostKey: State]
    public func changes() -> AsyncStream<(HostKey, State)>
}
```

### C.4 Resource, command, tags, freshness

```swift
// Core/Resource.swift
public enum FreshnessClass: Int, Sendable, Codable, CaseIterable, Comparable {
    case volatile  = 0     // 5 s   — memory only, NEVER written to SQLite
    case activity  = 1     // 60 s  — health, disk space, history page, now-playing
    case catalog   = 2     // 6 h   — library rows, details, calendar, episode/track files
    case reference = 3     // 24 h  — quality profiles, root folders, custom formats, download clients
    case immutable = 4     // 30 d  — credits, videos, alt titles, TMDB person, artwork maps
    public var defaultTTL: Duration
    public var retention: Duration          // how long a stale row survives the sweeper
}

public enum ReadPolicy: Sendable, Equatable {
    case cacheFirst              // fresh → return; stale/absent → fetch and await
    case staleWhileRevalidate    // stale → return now, refresh in the background at `.background`
    case cacheOnly               // never touches the network; the cold-start and offline policy
    case reload                  // ignore freshness; still coalesced, still limited
}

public struct Resource<Value: Sendable>: Sendable {
    public let key: ResourceKey
    public let tags: Set<InvalidationTag>
    public let freshness: FreshnessClass
    public let plan: RequestPlan
    /// Pure. Bytes in, value out. May NOT read response headers or ambient state —
    /// the disk tier replays bytes only, so a header-dependent decoder would be
    /// correct online and wrong after a relaunch.
    public let decode: @Sendable (Data) throws -> Value

    public func map<T: Sendable>(_ f: @escaping @Sendable (Value) throws -> T) -> Resource<T>
}

/// Many keys, one request, when the service offers a batch endpoint or a whole-library index.
public struct BatchResource<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    public enum Strategy: Sendable {
        /// e.g. Radarr `GET /moviefile?movieId=1&movieId=2…` (the golden corpus shows `movieId` repeated 4×)
        case chunked(max: Int,
                     make: @Sendable ([Key]) -> Resource<[Value]>,
                     identify: @Sendable (Value) -> Key?)
        /// e.g. `GET /movie` once, then answer every per-movie read from the index row.
        case index(make: @Sendable () -> Resource<[Value]>,
                   identify: @Sendable (Value) -> Key?)
        case perKey(make: @Sendable (Key) -> Resource<Value>)
    }
    public let strategy: Strategy
}

/// A write. Never cached, never retried unless `isIdempotent`.
public struct Command: Sendable {
    public let plan: RequestPlan
    public let invalidates: Set<InvalidationTag>
    public let isIdempotent: Bool
    /// Optional follow-up: arr `POST /command` returns a command id whose completion
    /// the store polls at `.background` and whose finish re-invalidates `invalidates`.
    public let tracking: Tracking?
    public enum Tracking: Sendable { case arrCommand(idFrom: @Sendable (Data) throws -> Int, timeout: Duration) }
    /// Server reply, decoded. `Void` for the many commands whose body is noise.
    public let confirm: (@Sendable (Data) throws -> Void)?
}

public struct CommandReceipt: Sendable {
    public let acceptedAt: Date
    public let serverMessage: String?
    public let trackingID: Int?
}

/// What a read gives back: the value plus where it came from.
public struct Stamped<Value: Sendable>: Sendable {
    public let value: Value
    public let fetchedAt: Date
    public let origin: Origin
    public let isStale: Bool
    public let freshness: FreshnessClass
    public enum Origin: Sendable, Equatable { case memory, disk, network, coalesced, fixture }
}
```

```swift
// Core/InvalidationTag.swift — the whole invalidation vocabulary is here, in one file.
public struct InvalidationTag: Hashable, Sendable, Codable, CustomStringConvertible {
    public let instance: InstanceID
    public let scope: Scope
    public enum Scope: Hashable, Sendable, Codable {
        case everything
        case queue
        case history
        case calendar
        case health
        case profiles                       // quality/metadata profiles, root folders, custom formats
        case capabilities
        case library(EntityKind)            // "any movie in this Radarr"
        case entity(EntityKind, id: Int)    // one arr row
        case files(EntityKind, id: Int)     // that row's file list
        case sessions                       // media server now-playing / watch history
        case downloads                      // a download client's task list
    }
    /// Storage form: "radarr#0/entity.movie.12". Parsed back for the SQLite tag index.
    public var description: String
}
```

```swift
// Core/ResourceKey.swift
public struct ResourceKey: Hashable, Sendable, CustomStringConvertible {
    public let instance: InstanceID
    public let fingerprint: InstanceFingerprint
    public let digest: String                // sha256(method + path + canonical query + body)[0..<16] hex
    /// "radarr#0|3f9c1a77e2b04d51|GET|9a8b…". Contains no credential by construction:
    /// it is derived from `RequestPlan`, and a `RequestPlan` holds no secret value.
    public var description: String
    public init(instance: InstanceID, fingerprint: InstanceFingerprint, plan: RequestPlan)
}
```

```swift
// Core/RequestPlan.swift — a request with credential *placements*, not credential values.
public struct RequestPlan: Hashable, Sendable {
    public enum Body: Hashable, Sendable { case none, json(Data), form(Data), xml(Data), multipart(Data, boundary: String) }
    public enum AuthPlacement: Hashable, Sendable {
        case none
        case header(HeaderName)      // X-Api-Key, X-Plex-Token, X-Emby-Token
        case bearer                  // TMDB v4, qBittorrent 5 API key
        case basic                   // NZBGet, rTorrent
        case queryItem(String)       // ONLY sabnzbd `apikey` and TMDB v3 `api_key`
        case jellyfinMediaBrowser    // Authorization: MediaBrowser Token="…"
        case session(SessionKind)    // qBittorrent SID, Deluge cookie, Transmission session id
    }
    public var method: HTTPMethod
    public var path: String                        // "/api/v3/movie/12" — api base already applied
    public var query: [QueryItem] = []             // never a secret
    public var headers: [HeaderName: String] = [:] // never a secret
    public var body: Body = .none
    public var auth: AuthPlacement
    public var timeout: Duration = .seconds(15)
    /// JSON-RPC / XML-RPC method name. Drives fixture matching and the allow-list for
    /// the four clients whose path is constant (`/json`, `/jsonrpc`, `/RPC2`, `/transmission/rpc`).
    public var rpcMethod: String? = nil
    public var label: OperationLabel
}
```

### C.5 Store

```swift
// Store/ResourceStore.swift
public actor ResourceStore {
    public init(
        database: FactDatabase,
        registry: InstanceRegistry,
        limiter: HostLimiter,
        breaker: BreakerRegistry,
        telemetry: Telemetry,
        clock: any MediaClock,
        log: MediaLog
    )

    // MARK: reads
    public func read<V>(_ resource: Resource<V>,
                        policy: ReadPolicy = .cacheFirst,
                        maxAge: Duration? = nil,        // may only TIGHTEN the class default
                        priority: RequestPriority = .interactive) async throws -> Stamped<V>

    /// Cache-only, no I/O, no await on the network. Used by cold start and by `.cacheOnly` fast paths.
    public func cached<V>(_ resource: Resource<V>) -> Stamped<V>?

    // MARK: writes
    public func run(_ command: Command, priority: RequestPriority = .interactive) async throws -> CommandReceipt

    // MARK: invalidation
    public func invalidate(_ tags: Set<InvalidationTag>)           // sets stale_at = now; never deletes
    public func invalidate(instance: InstanceID)                   // fingerprint changed
    public func generation() -> UInt64                             // bumped on every invalidation

    // MARK: maintenance — registered with ArrCore's `AppCaches`
    @concurrent public func sweep() async                          // retention + size cap
    @concurrent public func purge(_ freshness: FreshnessClass) async
    @concurrent public func purgeAll() async
    public func statistics() async -> StoreStatistics              // rows, bytes, per-class counts
}
```

Coalescing and its cancellation semantics, in full (this is criteria 2 and 10):

```swift
// private, inside ResourceStore
private struct InFlight {
    let task: Task<(Data, Int), Error>   // payload + status
    var waiters: Int
}
private var inFlight: [ResourceKey: InFlight] = [:]

private func fetch(_ key: ResourceKey, _ plan: RequestPlan, _ priority: RequestPriority) async throws -> (Data, Int) {
    if inFlight[key] != nil {
        inFlight[key]!.waiters += 1
        telemetry.record(.coalesced(key))
    } else {
        let task = Task { try await self.performTransport(key, plan, priority) }
        inFlight[key] = InFlight(task: task, waiters: 1)
    }
    let task = inFlight[key]!.task
    // The last waiter to leave cancels the request; the first to leave does not.
    return try await withTaskCancellationHandler {
        defer { Task { await self.leave(key) } }
        return try await task.value
    } onCancel: {
        Task { await self.leaveCancelling(key) }
    }
}
private func leaveCancelling(_ key: ResourceKey) {
    guard var f = inFlight[key] else { return }
    f.waiters -= 1
    if f.waiters <= 0 { f.task.cancel(); inFlight[key] = nil } else { inFlight[key] = f }
}
```

A cancelled fetch writes **nothing**: the commit to the memory tier and to SQLite happens after `task.value`
returns, inside the store's own isolation, and `Task.isCancelled` is checked once more before the commit.

```swift
// Store/FactDatabase.swift — an actor pinned to its own serial queue so blocking
// sqlite3_step never runs on the cooperative pool (SE-0392 custom actor executors).
public actor FactDatabase {
    nonisolated let queue = DispatchSerialQueue(label: "pl.incred.ArrBarr.mediakit.db")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public struct Location: Sendable {
        public let directory: URL            // injected: ArrCore knows the container, MediaKit does not
        public let fileName: String          // "facts.sqlite"
        public let protectIOSFiles: Bool
        public let maxBytes: Int             // 64 MB app, 16 MB widget
    }
    public init(location: Location, log: MediaLog) throws

    public func entry(_ key: ResourceKey) throws -> StoredEntry?
    public func entries(_ keys: [ResourceKey]) throws -> [ResourceKey: StoredEntry]
    public func put(_ entry: StoredEntry, tags: Set<InvalidationTag>) throws     // rejects .volatile
    public func markStale(tags: Set<InvalidationTag>, at: Date) throws -> Int
    public func markStale(instance: InstanceID) throws -> Int
    public func touch(_ keys: [ResourceKey], at: Date) throws

    public func lastKnown(_ feed: FeedID) throws -> (Data, Date)?
    public func putLastKnown(_ feed: FeedID, instance: InstanceID, payload: Data, at: Date) throws

    public func capabilities(_ instance: InstanceID) throws -> StoredCapabilities?
    public func putCapabilities(_ instance: InstanceID, _ value: StoredCapabilities) throws

    public func crosswalk(from: MediaID, kind: EntityKind) throws -> [CrosswalkEdge]
    public func putCrosswalk(_ edges: [CrosswalkEdge]) throws

    @concurrent public func sweep(now: Date) throws -> SweepReport
}
```

### C.6 Instances, credentials, fingerprints

```swift
// Core/InstanceID.swift — nonisolated value type.
public enum ServiceKind: String, Sendable, Codable, CaseIterable, Hashable {
    case radarr, sonarr, lidarr, whisparr
    case qbittorrent, transmission, deluge, rtorrent, sabnzbd, nzbget
    case plex, jellyfin, emby
    case tmdb
    public var family: Family        // .arr, .downloadClient, .mediaServer, .catalog
}

public struct InstanceID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let kind: ServiceKind
    public let slot: Int              // 0 today; the schema never has to change for a second instance
    public var description: String { "\(kind.rawValue)#\(slot)" }
}

// Core/Fingerprint.swift
public struct InstanceFingerprint: Hashable, Sendable, Codable {
    public let value: String          // "<normalized base URL>|<first 8 bytes of SHA-256(secret) as hex>"
    /// Rotating a key of identical length on the same URL changes the fingerprint —
    /// the defect phase 0 found in `ServiceConfig.identityFingerprint` (URL + key *length*).
    public init(baseURL: URL, secretMaterial: String)
}

// Transport/InstanceRegistry.swift
public struct InstanceDescriptor: Sendable, Hashable {
    public let id: InstanceID
    public let baseURL: URL?
    public let isEnabled: Bool
    public let overrides: HostLimiter.Limits?
}

/// Asked per request; MediaKit never stores a secret and never receives one at
/// configuration time. ArrCore's implementation reads Keychain / group suite.
public protocol CredentialProvider: Sendable {
    func credential(for instance: InstanceID) async -> Credential?
}
public enum Credential: Sendable {
    case apiKey(String)
    case token(String)
    case userPassword(user: String, password: String)
    case none
    /// Never `CustomStringConvertible`; never `Codable`; `debugDescription` is "•••".
}

public actor InstanceRegistry {
    public init(credentials: any CredentialProvider, clock: any MediaClock)
    /// The ONE place configuration enters MediaKit. Recomputes fingerprints, and for every
    /// instance whose fingerprint moved, invalidates its entries before returning.
    public func adopt(_ descriptors: [InstanceDescriptor], store: ResourceStore) async
    public func descriptor(_ id: InstanceID) -> InstanceDescriptor?
    public func fingerprint(_ id: InstanceID) async -> InstanceFingerprint?
    public func session(_ id: InstanceID) -> InstanceSession
    public func host(_ id: InstanceID) -> HostKey?
    public func changes() -> AsyncStream<InstanceID>
}

// Transport/InstanceSession.swift — one actor per instance; owns login/handshake state.
public actor InstanceSession {
    public init(id: InstanceID, descriptor: InstanceDescriptor,
                credentials: any CredentialProvider, transport: any Transport, clock: any MediaClock)
    /// Resolves the auth placement, performs (at most one) login handshake per process,
    /// retries once on 401/403 after re-authenticating, and answers Transmission's 409.
    public func send(_ plan: RequestPlan, priority: RequestPriority) async throws -> TransportResponse
    public func invalidateSession()     // fingerprint changed, or the server told us to re-login
}
```

### C.7 Identity

```swift
// Identity/MediaIdentity.swift — nonisolated, Hashable, Codable, no boxes (flat lineage).
public enum EntityKind: String, Sendable, Codable, CaseIterable, Hashable {
    case movie, series, season, episode, artist, album, track, person
}

public enum IDNamespace: Hashable, Sendable, Codable {
    case tmdbMovie, tmdbSeries, tmdbPerson, tvdb, imdb, musicBrainz
    case server(ServiceKind)      // plex / jellyfin / emby item id
    case arr(InstanceID)          // a library row id
}

public struct MediaID: Hashable, Sendable, Codable {
    public let namespace: IDNamespace
    public let value: String
    public var impliedKind: EntityKind?   // nil where the namespace spans kinds (imdb, arr)
}

public struct MediaIdentity: Hashable, Sendable, Codable {
    public let kind: EntityKind
    public let ids: Set<MediaID>
    public let ordinal: Int?                   // season number / episode number / track number
    /// Nearest ancestor first: an episode carries [season, series]. Flat, so the struct
    /// stays Hashable and Codable with no indirection.
    public let lineage: [Ancestor]
    public struct Ancestor: Hashable, Sendable, Codable {
        public let kind: EntityKind
        public let ids: Set<MediaID>
        public let ordinal: Int?
    }
    public func id(in namespace: IDNamespace) -> MediaID?
    public func merging(_ other: MediaIdentity) -> MediaIdentity
}

public enum Confidence: Int, Sendable, Codable, Comparable { case weak = 1, likely = 2, asserted = 3 }
public enum CrosswalkSource: String, Sendable, Codable { case arrRecord, mediaServerGuid, tmdbFind, tmdbExternalIDs, userPinned }

// Identity/IdentityResolver.swift
public actor IdentityResolver {
    public init(database: FactDatabase, clock: any MediaClock)
    /// Pure, testable: pulls every id out of an arr record / Plex guid list / Jellyfin ProviderIds.
    public nonisolated static func identity(fromPlexGuids: [String], kind: EntityKind) -> MediaIdentity
    public nonisolated static func identity(fromJellyfinProviderIDs: [String: String], kind: EntityKind) -> MediaIdentity

    public func known(_ id: MediaID, kind: EntityKind) async -> MediaIdentity
    public func link(_ edges: [CrosswalkEdge]) async
    /// Network-backed hop: TMDB `/find/{id}?external_source=tvdb_id` or `/tv/{id}/external_ids`.
    /// Returns nil, never throws, when the resolver is offline — identity degrades, features degrade.
    public func resolve(_ identity: MediaIdentity, into namespace: IDNamespace,
                        using store: ResourceStore, tmdb: TMDBClient?) async -> MediaID?
}
```

### C.8 Capabilities

```swift
// Capabilities/Capability.swift
public struct Capability: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String
}
public extension Capability {
    static let arrSeasonMonitorV5: Capability          // Sonarr PUT /api/v5/series/{id}/season
    static let arrQueueGrab: Capability
    static let arrCustomFormats: Capability
    static let whisparrV3: Capability                  // Radarr fork, movieCategory
    static let whisparrV2: Capability                  // Sonarr fork, tvCategory — documented gap
    static let qbittorrentAPIKeyAuth: Capability       // 5.x: bearer key, no /auth/login
    static let qbittorrentStartStopVerbs: Capability   // 5.x start/stop vs 4.x resume/pause
    static let plexIncludeGuids: Capability
    static let jellyfinBareEmbyToken: Capability       // Emby wants bare X-Emby-Token, not MediaBrowser Token=
}

public struct CapabilitySet: Sendable, Codable, Hashable {
    public let capabilities: Set<Capability>
    public let version: String?
    public let probedAt: Date
    public enum Provenance: String, Sendable, Codable { case probe, persisted, conservativeDefault }
    public let provenance: Provenance
    public func has(_ c: Capability) -> Bool
}

// Capabilities/CapabilityRegistry.swift
public actor CapabilityRegistry {
    public init(database: FactDatabase, clock: any MediaClock, log: MediaLog)
    /// Never throws, never surfaces an error. Order: memory → SQLite (same fingerprint) →
    /// probe → last persisted set → conservative default for the kind.
    public func capabilities(for id: InstanceID, using store: ResourceStore) async -> CapabilitySet
    public func invalidate(_ id: InstanceID)                 // fingerprint change or version change
    /// Pure: what a `/system/status` (or `app/version`, `/identity`, `/System/Info`) body implies.
    public nonisolated static func derive(from body: Data, kind: ServiceKind) -> CapabilitySet
}
```

### C.9 Events and live data

```swift
// Events/DataEvent.swift
public struct DataEvent: Sendable, Equatable {
    public let instance: InstanceID
    public let kind: Kind
    public let at: Date
    public enum Kind: Sendable, Equatable {
        case queueChanged
        case queueStatus(QueueStatusPayload)     // counts only; feeds the live feed, invalidates nothing
        case fileImported(entity: EntityKind, id: Int?)
        case entityChanged(entity: EntityKind, id: Int?)
        case healthChanged
        case calendarChanged
        case connectivity(HostKey, up: Bool)
        case systemWoke
        case other(name: String, action: String)
    }
}

public protocol EventSource: Sendable {
    func events() -> AsyncStream<DataEvent>
    func start() async
    func stop() async
    func forceReconnect() async
}

// Events/EventTagMap.swift — ONE place maps an event to tags. Criterion 4 is a test on this function.
public enum EventTagMap {
    public static func tags(for event: DataEvent) -> Set<InvalidationTag>
}

// Events/SignalREventSource.swift — port of RealtimeUpdates with the ArrCore types removed.
public actor SignalREventSource: EventSource {
    public init(registry: InstanceRegistry, transport: any Transport, clock: any MediaClock, log: MediaLog)
    public func reconfigure(_ instances: [InstanceID]) async
    /// Pure frame parser; the existing `RealtimeFrameParsingTests` cases port verbatim.
    /// Servarr nests `action` inside `arguments[0].body`.
    public nonisolated static func parse(frame: String, instance: InstanceID) -> FrameOutcome
}

// Events/WakeEventSource.swift — NSWorkspace/UIApplication live in ArrCore; MediaKit takes the signal.
public actor WakeEventSource: EventSource {
    public func systemDidWake()
}
```

```swift
// Live/LiveFeed.swift — queue, download progress, media-server sessions.
public struct FeedID: Hashable, Sendable, Codable { public let name: String; public let instance: InstanceID? }

public enum PendingIntent: String, Sendable, Codable { case pausing, resuming, deleting, grabbing }
public struct PendingMark: Sendable, Equatable { public let key: String; public let intent: PendingIntent; public let expiresAt: Date }

public struct LiveValue<Value: Sendable>: Sendable {
    public let value: Value
    public let measuredAt: Date
    public let pending: [PendingMark]
    public let origin: Stamped<Value>.Origin
    public let partial: Set<InstanceID>        // instances that failed this round ("some failed" vs "all failed")
}

public actor LiveFeed<Value: Sendable & Equatable> {
    public struct Cadence: Sendable, Equatable {
        public var foregroundInterval: Duration = .seconds(30)
        public var backgroundInterval: Duration = .seconds(120)
        public var burstWindow: Duration = .milliseconds(250)   // was QueueViewModel's 0.25 s
        public var foregroundFloor: Duration = .seconds(1)
        public var silenceBeforePolling: Duration = .seconds(300)
    }
    public init(id: FeedID,
                cadence: Cadence,
                database: FactDatabase,
                encode: @escaping @Sendable (Value) throws -> Data,
                decode: @escaping @Sendable (Data) throws -> Value,
                refresh: @escaping @Sendable (RequestPriority) async -> LiveValue<Value>,
                clock: any MediaClock)

    public func updates() -> AsyncStream<LiveValue<Value>>
    /// Last known value read straight from SQLite — no network, no await on a request.
    public func hydrate() async -> LiveValue<Value>?
    public func pulse()                                  // an event asks for a refresh; coalesced by `burstWindow`
    public func setActivity(_ a: Activity)               // .foreground / .background / .idle
    public func mark(_ key: String, _ intent: PendingIntent, expiresIn: Duration)
    public func clearMark(_ key: String)
}
```

### C.10 Composition

```swift
// Composition/CompositionContext.swift — a nonisolated final class, created per build, never escapes.
public final class CompositionContext: @unchecked Sendable {
    public let priority: RequestPriority
    public var minFreshness: Duration?              // tightens every read in this composition

    public func read<V>(_ r: Resource<V>, maxAge: Duration? = nil) async throws -> V
    public func optional<V>(_ r: Resource<V>, maxAge: Duration? = nil) async -> V?
    /// Partial results are the norm: a failure here is recorded in provenance, not thrown.
    public func batch<K, V>(_ keys: [K], via: BatchResource<K, V>, maxAge: Duration? = nil) async -> [K: V]
    public func live<V>(_ feed: LiveFeed<V>) async -> LiveValue<V>?
    public func capability(_ c: Capability, of id: InstanceID) async -> Bool
    public func identity(_ id: MediaID, kind: EntityKind) async -> MediaIdentity

    // accumulated while building, read by the engine afterwards
    public private(set) var touched: [ResourceKey: Stamped<Never>.Origin]
    public private(set) var tags: Set<InvalidationTag>
    public private(set) var oldest: Date?
    public private(set) var failures: [ResourceKey: MediaKitError]
}

public struct Provenance: Sendable {
    public let oldest: Date?
    public let tags: Set<InvalidationTag>
    public let origins: [Stamped<Never>.Origin: Int]     // how many memory / disk / network reads
    public let failures: [ResourceKey: MediaKitError]
    public var isComplete: Bool { failures.isEmpty }
    public var isOffline: Bool                            // every failure is unreachable/circuitOpen
}
public struct Composed<Output: Sendable>: Sendable {
    public let value: Output
    public let provenance: Provenance
}

// Composition/CompositionEngine.swift
public actor CompositionEngine {
    public init(store: ResourceStore, capabilities: CapabilityRegistry,
                identity: IdentityResolver, telemetry: Telemetry, clock: any MediaClock)

    /// `key` is the composition's *value* — e.g. `DetailRequest(source: .radarr, id: 412)`.
    /// Memoised in memory only, dropped when any tag in its provenance is invalidated.
    public func value<Key: Hashable & Sendable, Output: Sendable>(
        _ key: Key,
        priority: RequestPriority = .interactive,
        minFreshness: Duration? = nil,
        build: @escaping @Sendable (CompositionContext) async throws -> Output
    ) async throws -> Composed<Output>

    /// Batched: builds N compositions under one limiter budget so `BatchResource`
    /// reads from different builds collapse into the same chunked request.
    public func values<Key: Hashable & Sendable, Output: Sendable>(
        _ keys: [Key],
        priority: RequestPriority = .background,
        build: @escaping @Sendable (Key, CompositionContext) async throws -> Output
    ) async -> [Key: Result<Composed<Output>, MediaKitError>]

    /// The bridge to the view. Yields the current value, then a new one after any
    /// invalidation that touches this composition's tags.
    public func observe<Key: Hashable & Sendable, Output: Sendable>(
        _ key: Key,
        build: @escaping @Sendable (CompositionContext) async throws -> Output
    ) -> AsyncStream<Composed<Output>>

    public func invalidate(_ tags: Set<InvalidationTag>)

    /// The two synchronous view-body reads. Rebuilt off the main actor after
    /// invalidation; read under a lock with no `await`.
    public func projection<Value: Sendable>(
        _ id: ProjectionID,
        tags: Set<InvalidationTag>,
        build: @escaping @Sendable (CompositionContext) async -> Value
    ) async -> Projection<Value>
}

/// Synchronous, lock-guarded, versioned. `await` never enters a SwiftUI body.
public final class Projection<Value: Sendable>: @unchecked Sendable {
    public var current: (value: Value, version: UInt64) { get }   // NSLock, uncontended
    public var value: Value { current.value }
}
```

`observe` is where `Observations` earns its place:

```swift
// Composition/CompositionEngine.swift, private
@Observable final class InvalidationClock { var generation: UInt64 = 0 }

public func observe<Key, Output>(...) -> AsyncStream<Composed<Output>> {
    AsyncStream { continuation in
        let task = Task {
            // Observations<UInt64, Never>(_ emit:) — Observation, macOS 26
            for await _ in Observations({ self.clockBox.generation }) {
                if let v = try? await self.value(key, build: build) { continuation.yield(v) }
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
```

Verified declaration: `struct Observations<Element, Failure> where Element : Sendable, Failure : Error`,
`init(_ emit: @escaping @isolated(any) @Sendable () throws(Failure) -> Element)` (Observation, macOS 26.0).

### C.11 Errors, telemetry, artwork, discovery

```swift
// Core/MediaKitError.swift — closed, 12 cases, zero user-facing literals.
public enum MediaKitError: Error, Sendable, Equatable, Hashable {
    case notConfigured(InstanceID)
    case unreachable(HostKey, TransportFailure)
    case timedOut(HostKey)
    case unauthorized(InstanceID, status: Int, serverMessage: String?)
    case rejected(InstanceID, status: Int, serverMessage: String?)      // other 4xx
    case serverFault(InstanceID, status: Int, serverMessage: String?)   // 5xx
    case rateLimited(HostKey, retryAfter: Duration?)
    case circuitOpen(HostKey, until: Date)
    case decoding(ResourceKey, reason: String)
    case unsupported(InstanceID, Capability)
    case persistence(reason: String)
    case cancelled

    /// Stable discriminator for ArrCore's exhaustive catalog-key mapper (criterion 13).
    public var caseName: String
    /// The *server's* words, parsed out of an arr/ASP.NET error body. Never localized here.
    public var serverMessage: String? { get }
}
```

```swift
// Core/Telemetry.swift
public struct TelemetryEvent: Sendable {
    public enum Kind: String, Sendable { case request, response, cacheHit, cacheMiss, staleServed,
                                              coalesced, skipped, failure, invalidated, breakerOpened, rateLimited }
    public let kind: Kind
    public let host: HostKey?
    public let label: OperationLabel?
    public let bytes: Int?
    public let duration: Duration?
}
public actor Telemetry {
    public init(enabled: Bool, signposter: OSSignposter?)
    public func record(_ e: TelemetryEvent)
    public func setEnabled(_ on: Bool)
    public func report() -> TelemetryReport          // data; ArrCore formats and localizes it
    public func reset()
}
public struct TelemetryReport: Sendable {
    public struct HostRow: Sendable {
        public let host: String                       // host:port, never a URL with a query
        public let requests, cacheHits, cacheMisses, coalesced, invalidations, breakerOpens, failures: Int
        public let bytes: Int
        public let p50, p95: Duration
    }
    public let hosts: [HostRow]
    public let resources: [OperationLabel: Int]
    public let since: Date
}
```

Timings go to signposts, not to log lines: `OSSignposter.beginInterval(_ name: StaticString, id: OSSignpostID = .exclusive) -> OSSignpostIntervalState` (os, macOS 12+).

```swift
// Artwork/ArtworkReference.swift — nonisolated value type; the single thing PosterStore consumes.
public struct ArtworkReference: Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable { case poster, fanart, banner, thumbnail, still, profile }
    public enum HeaderRef: Hashable, Sendable, Codable { case literal(String), credential(InstanceID) }
    public enum Sizing: Hashable, Sendable, Codable {
        case native
        case tmdbCDN(pathBase: String)                // /t/p/w342 … chosen per tier
        case plexTranscode(photoPath: String)         // /photo/:/transcode?width=&height=
        case jellyfinFill(itemID: String, tag: String?)
    }
    public let url: URL                               // token-free, always
    public let headers: [HeaderName: HeaderRef]       // resolved at download time, never baked into the URL
    public let sizing: Sizing
    public let kind: Kind
    /// Stable, secret-free. `PosterStore` may hash it further; it does not have to.
    public let cacheKey: String
    public func sized(_ tier: SizeTier) -> ArtworkReference
    public enum SizeTier: String, Sendable, Codable, CaseIterable { case icon, card, full }
}
```

```swift
// Discovery/Discovery.swift
public struct DiscoveredServer: Sendable, Hashable {
    public let kind: ServiceKind
    public let name: String
    public let url: URL
    public let source: Source
    public enum Source: String, Sendable { case bonjour, udpBeacon }
}
public actor Discovery {
    /// NWBrowser(for: .bonjour(type: "_plexmediasvr._tcp", domain: nil), using: .tcp)
    public func browsePlex(for: Duration) -> AsyncStream<DiscoveredServer>
    /// NWConnection(host: "255.255.255.255", port: 7359, using: .udp) → "who is JellyfinServer?"
    public func beaconJellyfinEmby(for: Duration) -> AsyncStream<DiscoveredServer>
    // Pure parsers — criterion 25 tests these with no network at all.
    public nonisolated static func parseBonjour(name: String, txt: [String: String], endpoint: URL?) -> DiscoveredServer?
    public nonisolated static func parseBeacon(_ data: Data) -> DiscoveredServer?
}
```

Verified declarations: `NWBrowser.init(for descriptor: NWBrowser.Descriptor, using parameters: NWParameters)`,
`NWBrowser.Descriptor.bonjour(type:domain:)`, `NWConnection.init(host:port:using:)`, `NWParameters.udp` (Network).

### C.12 Isolation summary

| Type | Isolation | Why |
|---|---|---|
| `Resource`, `Command`, `RequestPlan`, `ResourceKey`, `InvalidationTag`, `MediaIdentity`, `MediaKitError`, `ArtworkReference`, `Stamped`, all wire models | nonisolated `Sendable` struct/enum | values; no state to protect; free to cross any boundary |
| `URLSessionTransport` | nonisolated struct | holds only an injected `URLSession` |
| `FixtureTransport`, `RecordingTransport` | actor | mutable demo / recording state |
| `HostLimiter`, `BreakerRegistry` | actor | shared counters, the point of contention |
| `InstanceSession` | actor, one per instance | login/cookie/session-id state |
| `InstanceRegistry`, `CapabilityRegistry`, `IdentityResolver`, `Telemetry` | actor | small shared maps |
| `ResourceStore` | actor | memory tier + in-flight table |
| `FactDatabase` | actor **with a custom serial executor** | sqlite3 must stay on one thread and off the cooperative pool |
| `CompositionEngine`, `LiveFeed`, `SignalREventSource`, `WakeEventSource`, `Discovery` | actor | streams and memo tables |
| `CompositionContext` | nonisolated final class, never escapes its build | avoids an actor hop per `read` |
| `Projection` | final class, `@unchecked Sendable`, `NSLock` | synchronous view-body reads |
| `@MainActor` | **nowhere** | `defaultIsolation(nil)` |

`@concurrent` functions (SE-0461): `ResourceStore.sweep/purge`, `FactDatabase.sweep`, `ResourceStore.decodeBody`
(JSON decoding of the two payloads that are megabytes — the Plex library index at 7 MB uncompressed and the arr
whole-library reads), `CompositionEngine.rebuildProjection`, `FixtureTransport.loadCorpus`,
`IdentityResolver.indexCrosswalk`.

---

## D. SQLite

One database file per container. DDL in full:

```sql
PRAGMA journal_mode = WAL;          -- iOS widget + app read concurrently
PRAGMA synchronous  = NORMAL;       -- WAL + NORMAL is the durable-enough, cheap combination
PRAGMA busy_timeout = 3000;
PRAGMA foreign_keys = ON;
PRAGMA temp_store   = MEMORY;

CREATE TABLE IF NOT EXISTS entries (
  key         TEXT    PRIMARY KEY,
  instance    TEXT    NOT NULL,
  fingerprint TEXT    NOT NULL,
  class       INTEGER NOT NULL CHECK (class > 0),   -- volatile == 0: the DB itself refuses it
  status      INTEGER NOT NULL,
  payload     BLOB    NOT NULL,
  bytes       INTEGER NOT NULL,
  fetched_at  REAL    NOT NULL,
  stale_at    REAL    NOT NULL,
  last_used   REAL    NOT NULL
) STRICT;
CREATE INDEX IF NOT EXISTS entries_sweep    ON entries(class, last_used);
CREATE INDEX IF NOT EXISTS entries_instance ON entries(instance, fingerprint);

CREATE TABLE IF NOT EXISTS entry_tags (
  tag TEXT NOT NULL,
  key TEXT NOT NULL REFERENCES entries(key) ON DELETE CASCADE,
  PRIMARY KEY (tag, key)
) STRICT, WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS entry_tags_key ON entry_tags(key);

-- survives a cache wipe and every migration
CREATE TABLE IF NOT EXISTS last_known (
  feed        TEXT PRIMARY KEY,
  instance    TEXT NOT NULL,
  payload     BLOB NOT NULL,
  measured_at REAL NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS capabilities (
  instance    TEXT PRIMARY KEY,
  fingerprint TEXT NOT NULL,
  caps        TEXT NOT NULL,          -- JSON array of raw values
  version     TEXT,
  probed_at   REAL NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS crosswalk (
  from_ns    TEXT    NOT NULL,
  from_val   TEXT    NOT NULL,
  kind       TEXT    NOT NULL,
  to_ns      TEXT    NOT NULL,
  to_val     TEXT    NOT NULL,
  confidence INTEGER NOT NULL,
  source     TEXT    NOT NULL,
  fetched_at REAL    NOT NULL,
  PRIMARY KEY (from_ns, from_val, kind, to_ns)
) STRICT, WITHOUT ROWID;

PRAGMA user_version = 1;
```

**Invalidation never deletes.** `invalidate(tags:)` is
`UPDATE entries SET stale_at = ?1 WHERE key IN (SELECT key FROM entry_tags WHERE tag IN (…))` — one statement,
one index seek per tag. The stale row is what the breaker and the first render serve.

**Volatile never reaches disk**, enforced twice: `FactDatabase.put` refuses `class == .volatile` before binding,
and `CHECK (class > 0)` makes a bug a constraint violation rather than a leak (criterion 6 is then testable by
`SELECT COUNT(*) FROM entries WHERE class = 0` returning 0 after a volatile-heavy read series).

**Locations** (injected as `FactDatabase.Location`; MediaKit hardcodes no bundle or group id):

| Platform | Directory | Note |
|---|---|---|
| macOS app | `~/Library/Containers/pl.incred.ArrBarr/Data/Library/Application Support/MediaKit/` | sandbox container; no app group exists on macOS (phase 0, H4) |
| iOS app | `containerURL(forSecurityApplicationGroupIdentifier: "group.pl.incred.ArrBarr")/MediaKit/` | shared with the widget |
| iOS widget | same group container, opened read-write | WAL makes concurrent read + the app's write safe |
| tests | a temp directory per test | no shared state between suites |

**iOS file protection**: `completeUntilFirstUserAuthentication` set on `facts.sqlite`, `facts.sqlite-wal` and
`facts.sqlite-shm` via `FileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath:)`
after `sqlite3_open_v2` creates each file — "*the file is stored in an encrypted format on disk and cannot be
accessed until after the device has booted*" (Foundation). Anything stricter and a widget timeline refresh on a
locked phone fails.

**Migrations** keyed on `PRAGMA user_version`. Rule: `entries` + `entry_tags` may be dropped and recreated on any
schema change (they are a cache — losing them costs one refresh). `last_known`, `capabilities` and `crosswalk`
are migrated with `ALTER TABLE` / copy-and-rename and are **never** dropped, because they are what makes a cold
start after an upgrade render instantly and not re-probe every service.

**Size cap.** `maxBytes` (64 MB app, 16 MB widget). `sweep()` runs on launch + every 6 h + on memory pressure:
1. delete rows past their class retention (`immutable` 30 d, `reference` 7 d, `catalog` 3 d, `activity` 1 d);
2. if still over cap, delete by `(class ASC, last_used ASC)` until under 90 % of cap — cheap data goes first;
3. `PRAGMA incremental_vacuum` when more than 25 % of the file is free.

---

## E. Service vocabularies

Method/path are taken verbatim from `2026-09-15-golden-requests.json` so the phase-6 parity diff joins on
`OperationLabel.operation`. `T` = tags produced (the entry is filed under them); `INV` = tags a command invalidates.
`F` = freshness class.

### E.1 arrs — one dialect, four values

```swift
public struct ArrDialect: Sendable, Hashable {
    public let kind: ServiceKind
    public let apiBase: String            // "/api/v3" | "/api/v1"
    public let libraryPath: String        // "movie" | "series" | "artist"
    public let libraryKind: EntityKind
    public let queueEntityFlag: QueryItem // includeUnknownMovieItems / includeEpisode / includeUnknownArtistItems
    public let historyIncludes: [QueryItem]
    public let filePath: String           // "moviefile" | "episodefile" | "trackfile"
    public let fileParent: String         // "movieId" | "seriesId" | "albumId"
    public static let radarr, sonarr, lidarr, whisparr: ArrDialect
}
```

Whisparr = `radarr` with `kind: .whisparr` (v3). The v2 fork would need `sonarr`'s dialect plus `tvCategory`;
`Capability.whisparrV2` is detected but unimplemented — the documented gap (owner decision Q3).

| Resource | Method / path | F | T |
|---|---|---|---|
| `systemStatus` | `GET {base}/system/status` | reference | `capabilities` |
| `health` | `GET {base}/health` | activity | `health` |
| `diskSpace` | `GET {base}/diskspace` | activity | `health` |
| `queue` | `GET {base}/queue?pageSize=1000&{queueEntityFlag}` | volatile | `queue` |
| `history(page:)` | `GET {base}/history?page=&pageSize=&sortKey=&sortDirection=&{includes}` | activity | `history` |
| `historyFor(ids:)` | `GET {base}/history?{movieIds\|seriesIds\|albumIds}=…` | activity | `history`, `entity(k,id)` |
| `calendar(start:end:)` | `GET {base}/calendar?start=&end=&unmonitored=[&includeSeries]` | catalog | `calendar` |
| `library` | `GET {base}/{libraryPath}` | catalog | `library(k)` |
| `entity(id:)` | `GET {base}/{libraryPath}/{id}` | catalog | `entity(k,id)`, `library(k)` |
| `files(parentID:)` | `GET {base}/{filePath}?{fileParent}=` | catalog | `files(k,id)` |
| `filesBatch(ids:)` | `GET {base}/{filePath}?movieId=1&movieId=2…` (chunk 25) | catalog | `files(k,id)` each |
| `episodes(seriesID:)` (sonarr) | `GET /api/v3/episode?seriesId=` | catalog | `entity(.series,id)` |
| `albums(artistID:)` (lidarr) | `GET /api/v1/album?artistId=` | catalog | `entity(.artist,id)` |
| `tracks(albumID:)` (lidarr) | `GET /api/v1/track?albumId=` | catalog | `entity(.album,id)` |
| `credits(movieID:)` (radarr) | `GET /api/v3/credit?movieId=` | immutable | `entity(.movie,id)` |
| `alternateTitles` (radarr) | `GET /api/v3/alttitle` | immutable | `library(.movie)` |
| `qualityProfiles` | `GET {base}/qualityprofile` | reference | `profiles` |
| `metadataProfiles` | `GET {base}/metadataprofile` | reference | `profiles` |
| `rootFolders` | `GET {base}/rootfolder` | reference | `profiles` |
| `customFormats` | `GET {base}/customformat` | reference | `profiles` |
| `downloadClients` | `GET {base}/downloadclient` | reference | `profiles` |
| `runningCommands` | `GET {base}/command` | volatile | `queue` |
| `lookup(term:)` | `GET {base}/{libraryPath}/lookup?term=` | activity | — (search, not filed under an entity) |
| `lidarrSearch(term:)` | `GET /api/v1/search?term=` | activity | — |
| `releases(for:)` | `GET {base}/release?{movieId\|episodeId\|albumId}=` | volatile, timeout 120 s | — |

| Command | Method / path | INV |
|---|---|---|
| `setMonitored(entity)` | `GET {libraryPath}/{id}` → `PUT {libraryPath}/{id}` (typed round-trip) | `entity(k,id)`, `library(k)`, `calendar` |
| `setSeasonMonitored` | `PUT /api/v5/series/{id}/season` **if** `arrSeasonMonitorV5`, else the v3 double-PUT | `entity(.series,id)`, `calendar` |
| `setEpisodesMonitored` | `PUT /api/v3/episode/monitor` | `entity(.series,id)`, `calendar` |
| `updateLibraryRecord` | `GET {libraryPath}/{id}` → `PUT {libraryPath}/{id}?moveFiles=` | `entity(k,id)`, `library(k)`, `files(k,id)` |
| `add(payload)` | `POST {base}/{libraryPath}` | `library(k)`, `calendar` |
| `addAlbum` (lidarr) | `GET /api/v1/search?term=` → `POST /api/v1/album` | `library(.artist)`, `calendar` |
| `delete(entity)` | `DELETE {libraryPath}/{id}?deleteFiles=&addImportExclusion=&addImportListExclusion=` | `library(k)`, `entity(k,id)`, `files(k,id)` |
| `search(...)` | `POST {base}/command` (`MoviesSearch`/`SeriesSearch`/`SeasonSearch`/`EpisodeSearch`/`AlbumSearch`), tracked | `queue` on completion |
| `grabRelease` | `POST {base}/release` (timeout 120 s) | `queue` |
| `grabQueueItem` | `POST {base}/queue/grab/{id}` | `queue` |
| `deleteQueueItem` | `DELETE {base}/queue/{id}?removeFromClient=&blocklist=` | `queue`, `history` |

Two things the corpus and phase 0 flag that this design makes typed:

* **`getJSONObject` read-modify-write disappears.** `setMonitored` and `updateLibraryRecord` decode the record into
  `ArrLibraryRecord` (a struct with a `rest: [String: JSONValue]` overflow bag captured by a custom `init(from:)`),
  mutate the typed field, and re-encode the bag verbatim. No `[String: Any]` crosses a function boundary, so the
  compiler sees every rename — the blind spot phase 0 called out, and the one memory note about untyped bodies.
* **Sonarr's season toggle is capability-gated, not status-gated.** `arrSeasonMonitorV5` is derived from
  `/system/status`'s version once per fingerprint; on a v3 server the command *is* the double-PUT (write the
  opposite value first to force the cascade, then the intended one), not a 404-triggered fallback. The 404/405
  fallback survives as a one-shot demotion: on `rejected(status: 404|405)` the registry drops the capability and
  the command retries in v3 form exactly once.

### E.2 Download clients — sessions inside the transport contract

The client declares `auth: .session(kind)`; `InstanceSession` owns the handshake, one login per process
(section 5: qBittorrent bans an IP after repeated failed logins).

| Client | Handshake (in `InstanceSession`) | Resources | Commands |
|---|---|---|---|
| qBittorrent | `qbittorrentAPIKeyAuth` present (5.x) → `Authorization: Bearer`, no login. Absent (4.x) → `POST /api/v2/auth/login` form, keep the `SID` cookie, always send `Referer: <baseURL>`. Re-login **once** on 401/403. | `version` `GET app/version` (reference); `preferences` `GET app/preferences` (reference); `tasks` `GET torrents/info` (volatile) | `pause`/`resume` → `POST torrents/stop` + `torrents/start` when `qbittorrentStartStopVerbs`, else `torrents/pause` + `torrents/resume`; `delete` `POST torrents/delete`; `forceStart` `POST torrents/setForceStart`; `add` `POST torrents/add` (multipart / magnet) |
| Transmission | No login. First request may answer `409`; read `X-Transmission-Session-Id` from the response headers, store it in the session, resend once. Header, not body. | `session-get`, `torrent-get` (volatile) | `torrent-start`, `torrent-stop`, `torrent-remove`, `torrent-add` |
| Deluge | `POST /json` `auth.login` once; cookie kept by the session; re-login once on a `false` result or 403 | `daemon.info`, `core.get_torrents_status`, `core.get_config` | `core.pause_torrent`, `core.resume_torrent`, `core.remove_torrent`, `core.add_torrent_magnet` |
| rTorrent | Basic auth per request, no session | XML-RPC `system.client_version`, `d.multicall2` | `d.start`, `d.stop`, `d.erase`, `load.start` |
| SABnzbd | none; `apikey` in the query — one of the two sanctioned query secrets | `GET /api?mode=version&output=json`, `mode=queue`, `mode=history&limit=` | `mode=pause`/`resume` (`name=`,`value=`), `name=delete`, `mode=addfile` (POST multipart) |
| NZBGet | Basic auth header per request | `POST /jsonrpc` `version`, `listgroups`, `status`, `history` | `editqueue`, `append`, `pausedownload`, `resumedownload` |

All six decode into one vocabulary so the queue composition does not branch:

```swift
public struct DownloadTask: Sendable, Hashable, Codable {
    public let id: String                    // lowercased hash / nzo_id / gid — the arr's downloadId
    public let name: String
    public let state: DownloadState          // downloading, paused, queued, seeding, checking, stalled, error, completed
    public let progress: Double
    public let sizeBytes: Int64?
    public let downloadedBytes: Int64?
    public let rateBytesPerSecond: Int64?
    public let etaSeconds: Int?
    public let errorText: String?
    public let category: String?
}
```

`RPC.swift` carries the shared JSON-RPC envelope (Deluge + NZBGet + Transmission) and a 60-line XML-RPC value
codec for rTorrent — enough for `d.multicall2` and four commands, not a general XML-RPC library.

### E.3 Plex / Jellyfin / Emby

| Resource | Plex | Jellyfin / Emby | F | T |
|---|---|---|---|---|
| identity | `GET /identity` | `GET /System/Info` | reference | `capabilities` |
| libraries | `GET /library/sections` | `GET /Users` + `GET /Items?…` | reference | `profiles` |
| index | `GET /library/sections/{id}/all?includeGuids=1` | `GET /Users/{id}/Items?Recursive=true&Fields=ProviderIds,…` | catalog | `library(.movie)`, `library(.series)` |
| nowPlaying | `GET /status/sessions` | `GET /Sessions` | volatile | `sessions` |
| watchHistory | `GET /status/sessions/history/all?sort=&X-Plex-Container-Size=&X-Plex-Container-Start=` | `GET /Users/{id}/Items?IsPlayed=true&SortBy=DatePlayed` | activity | `sessions` |
| seasonPosters | `GET /library/metadata/{id}/children` | `GET /Items?ParentId=` | catalog | `entity(.series,id)` |

Auth: Plex `X-Plex-Token` header; Jellyfin `Authorization: MediaBrowser Token="…"`; **Emby bare `X-Emby-Token`**
— the spike's collapse of both into the MediaBrowser scheme is the discrepancy `read-media.json` found, and here
it is a capability (`jellyfinBareEmbyToken`, default on for `.emby`), not a hardcoded branch. Commands
(`scanLibrary`, `emptyTrash`) exist but are never recorded and never allowed by `RecordingTransport`.

### E.4 TMDB

v4 JWT → `Authorization: Bearer`; v3 hex key → `api_key` query item (the second sanctioned query secret).
Resources: `configuration` (reference), `movie/{id}` and `tv/{id}` (immutable), `…/credits`,
`…/aggregate_credits`, `…/videos`, `person/{id}`, `person/{id}/movie_credits`, `person/{id}/tv_credits`
(immutable), `search/person` (catalog), `discover/movie`, `discover/tv`, `…/recommendations`, `…/similar`
(catalog), `find/{id}?external_source=` and `tv/{id}/external_ids` (immutable, and the crosswalk's network hop).
No commands. `image.tmdb.org` URLs never carry a credential, and `ArtworkReference.sizing == .tmdbCDN` picks the
path segment per tier.

---

## F. Six flows

### F.1 Cold launch, offline — popover renders from SQLite before any request

```swift
// ArrCore, AppDelegate → ServiceGateway.start()
let db   = try FactDatabase(location: .macOSAppSupport, log: log)     // opens, PRAGMAs, migrates: ~4 ms
let store = ResourceStore(database: db, registry: registry, limiter: limiter,
                          breaker: breaker, telemetry: telemetry, clock: .system, log: log)
await registry.adopt(configStore.descriptors(), store: store)         // no I/O

// 1. queue + progress: last known row, straight off disk, no network at all
let queue = await queueFeed.hydrate()          // SELECT payload FROM last_known WHERE feed='queue'
// 2. upcoming + library: cacheOnly reads, so a miss returns nil instead of blocking
let upcoming = try await engine.value(UpcomingRequest(days: 21), priority: .interactive) { ctx in
    ctx.minFreshness = nil
    return try await ctx.batch(sources, via: Arr.calendarBatch, maxAge: .infinity)   // .cacheOnly under the hood
}
```

`ReadPolicy.cacheOnly` is what the first render uses: `ResourceStore.read` looks in the memory tier, then
`FactDatabase.entry(key)`, and returns the row **however stale it is** (`Stamped.isStale == true`) without
touching the limiter. The popover has its three sections before `applicationDidFinishLaunching` returns.

Then the refresh wave starts at `.interactive`. Every host is unreachable. For each, the first attempt fails with
`.unreachable(host, .cannotConnect)`; `BreakerRegistry.recordFailure` takes the host to `.degraded(1)`, then
`.open(until:)` after three. From then on `admit` returns `.refuse(until:)` and `ResourceStore.read` **does not
throw** — it returns the stale row it already has with `origin: .disk`, and records `.skipped` in telemetry.
`Composed.provenance.isOffline` is true, every failure being `unreachable` or `circuitOpen`, and ArrCore renders
the quiet chip (memory: away-from-LAN is expected, not an error). There is no error alert, no retry storm, and
one log line per host at `.notice` with `loggableURL` (no query, so no key).

### F.2 DetailView for a movie, opened twice inside the freshness window

First open:

```swift
struct MovieDetailRequest: Hashable, Sendable { let instance: InstanceID; let movieID: Int }

let composed = try await engine.value(MovieDetailRequest(instance: .radarr0, movieID: 412)) { ctx in
    let movie   = try await ctx.read(radarr.entity(id: 412))                 // catalog, 6 h
    let files   = await ctx.batch([412], via: radarr.filesBatch)             // catalog
    let profile = await ctx.optional(radarr.qualityProfiles)                 // reference, 24 h
    let credits = await ctx.optional(radarr.credits(movieID: 412))           // immutable, 30 d
    let identity = await ctx.identity(.init(namespace: .arr(.radarr0), value: "412"), kind: .movie)
    let countries = await ctx.optional(tmdb.movie(identity.id(in: .tmdbMovie)))   // immutable
    let trailer   = await ctx.optional(tmdb.videos(...))                     // immutable
    let history   = await ctx.optional(radarr.historyFor(ids: [412]), maxAge: .seconds(60))
    return MovieDetail(...)
}
```

Requests on a cold cache: 8 (matching the phase-0 baseline of 7 + 1). Every read is filed under
`entity(.movie,412)`, `files(.movie,412)`, `profiles`, `library(.movie)`, `history`.

Second open, 90 seconds later: the engine finds the memo under the *same* `MovieDetailRequest` value and no tag in
its provenance has been invalidated → it returns the memoised `Composed` with **zero** store reads and **zero**
requests. If the memo has been dropped (memory pressure, an unrelated invalidation): every read hits the memory
tier or SQLite while fresh — `qualityProfiles` at 24 h, `credits`/`countries`/`trailer` at 30 d,
`entity`/`files` at 6 h — so still **zero requests**; only `historyFor` at `maxAge: 60 s` can go out, and the
composition asks for it at `.background` on a second open. That is criterion 1 and the "second open in the
freshness window costs nothing" measure, proven twice over.

### F.3 Pause a download

```swift
// ArrCore
await queueFeed.mark(item.downloadID, .pausing, expiresIn: .seconds(8))     // optimistic, on the FEED only
do {
    _ = try await store.run(qbittorrent.pause(hashes: [item.downloadID]))
} catch {
    await queueFeed.clearMark(item.downloadID)                              // snap back immediately
    throw error
}
```

1. `mark` yields a new `LiveValue` on the feed's stream within a tick; rows carrying a `PendingMark` render as
   "pausing". **The store is not written.** A command never produces a cache entry — criterion "store is never
   written optimistically" is structural, because `run` has no write path into `entries`.
2. `store.run` builds the `PreparedRequest` through `InstanceSession` (SID cookie or bearer), takes a limiter
   permit at `.interactive`, and on 2xx invalidates `{qbittorrent#0/downloads, radarr#0/queue, …}`.
3. That invalidation calls `queueFeed.pulse()`, which coalesces inside `burstWindow` (250 ms) and refreshes.
4. The refreshed value arrives with the task actually paused → `LiveFeed` drops any `PendingMark` whose key now
   agrees with the server, or whose `expiresAt` has passed. A server that silently ignored the command shows the
   row snapping back after 8 s rather than lying forever.

### F.4 SignalR queue event → tags → invalidation → `Observations` → view

```
Sonarr WebSocket frame
  → SignalREventSource.parse(frame:instance:)            // pure; the 11 existing frame tests port verbatim
  → DataEvent(instance: .sonarr0, kind: .fileImported(entity: .series, id: 88))
  → EventTagMap.tags(for:)  ==  { sonarr#0/queue,
                                  sonarr#0/files.series.88,
                                  sonarr#0/entity.series.88,
                                  sonarr#0/library.series,
                                  sonarr#0/history }
  → store.invalidate(tags)          // UPDATE entries SET stale_at = now WHERE key IN (…)
  → engine.invalidate(tags)         // drop memos whose provenance intersects; generation += 1
  → InvalidationClock.generation mutates  → Observations({ clock.generation }) yields
  → engine.observe(DetailRequest(...)) rebuilds and yields a new Composed
  → the SwiftUI view re-renders
```

`queueStatus` frames map to **no** tags at all — they carry counts, feed `LiveFeed.pulse()`, and must not mark the
library stale. That asymmetry is exactly what criterion 4's test asserts: a `queue/status` frame leaves
`entry_tags`-derived `stale_at` untouched while a `moviefile` frame marks five keys and nothing else.

### F.5 Widget timeline

```swift
// ArrBarrWidgets, in timeline(for:in:)
let connection = try MediaKitWidgetConnection(                      // ArrCore, ~60 lines
    group: "group.pl.incred.ArrBarr",                               // the app group the widget DOES have
    maxBytes: 16 * 1024 * 1024
)
// 1. render from the shared snapshot — always, even if the network is gone
var entry = await connection.libraryEntry(policy: .cacheOnly)
// 2. refresh through the widget's OWN MediaKit instance when the snapshot is stale
if entry.isStale {
    entry = await connection.libraryEntry(policy: .staleWhileRevalidate, priority: .background)
}
return Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(6 * 3600)))
```

The widget opens the same `facts.sqlite` in the group container. WAL plus `busy_timeout = 3000` makes the app's
concurrent write and the extension's read safe; the extension writes back the rows it fetched, so the next app
launch starts warm from the widget's work and vice versa. The extension links MediaKit and `SQLite3` only —
`grep -r "RadarrClient\|LibrarySummaryService\|UpcomingService" ArrBarrWidgets` returns zero (criterion 16). Its
limiter is configured with `maxConcurrent: 2` because a widget process has a hard wall-clock budget and must not
fight the app for the six-connections-per-host pool.

### F.6 Capability probe

```swift
let caps = await capabilities.capabilities(for: .sonarr0, using: store)
if caps.has(.arrSeasonMonitorV5) { /* PUT /api/v5/series/{id}/season */ }
else                             { /* v3 double-PUT */ }
```

* **Order**: memory → `SELECT caps FROM capabilities WHERE instance = ? AND fingerprint = ?` → probe
  `GET /api/v3/system/status` (a `reference` resource, so the probe itself is cached 24 h and coalesced) →
  last persisted set regardless of fingerprint → `CapabilitySet(provenance: .conservativeDefault)`.
* **Sonarr without v5**: `derive(from:kind:)` reads `version` `"3.0.10.1567"`, does not add `.arrSeasonMonitorV5`,
  and `setSeasonMonitored` *is* the double-PUT. No 404, no error, no user-visible event.
* **Whisparr v2 vs v3**: the probe reads `/api/v3/system/status`. Success with an `appName`/version of the Radarr
  fork → `.whisparrV3`. A 404 (or a status body whose version starts `2.`) → `.whisparrV2`, and every v2-only
  resource resolves to `MediaKitError.unsupported(.whisparr0, .whisparrV2)` which ArrCore maps to one catalog key.
  This is the documented gap, surfaced as a typed error instead of a wrong request.
* **Probe failure** (host down): returns the last persisted set, marked `.persisted`. With nothing persisted, the
  conservative default per kind — for the arrs, "v3 only, no grab, no custom formats"; for qBittorrent, "4.x
  cookie login, pause/resume verbs"; for Emby, "bare token". Never an error, never an empty capability set that
  would make every endpoint look unsupported.
* **Re-probe** on: fingerprint change (`CapabilityRegistry.invalidate`), a `/system/status` read whose `version`
  differs from the stored one, or a `.arrSeasonMonitorV5` command demoted by a 404/405.

---

## G. Concurrency and isolation

**Which actors exist and why.** Seven kinds of shared mutable state justify an actor and nothing else does:
in-flight requests + memory tier (`ResourceStore`), the SQLite connection (`FactDatabase`), per-host counters
(`HostLimiter`, `BreakerRegistry`), per-instance session state (`InstanceSession`), configuration and fingerprints
(`InstanceRegistry`), memo tables and streams (`CompositionEngine`, `LiveFeed`, `SignalREventSource`,
`Discovery`), and the telemetry/capability/crosswalk caches. Everything else is a value. There are 13 actor
declarations in the package against 55 in ArrCore today, and none of them is a singleton: every one is constructed
by the one gateway in ArrCore and injected downward.

**`FactDatabase`'s custom executor.** `sqlite3_step` blocks. Running it on the cooperative pool with WAL contention
from the widget can starve the pool, so `FactDatabase` overrides `unownedExecutor` with a `DispatchSerialQueue`
(SE-0392, *Custom Actor Executors*). The actor's isolation guarantees still hold; the work simply runs on a thread
the pool does not own. This also makes `sqlite3_open_v2` with `SQLITE_OPEN_FULLMUTEX` unnecessary — one thread,
one connection.

**`NonisolatedNonsendingByDefault` (SE-0461).** With the upcoming feature on, a `nonisolated` async function runs
on its **caller's** actor instead of hopping to the generic executor. Practically: `CompositionContext.read` and
every pure decoder called from a MainActor view build stay on the main actor unless they explicitly leave, which
removes a class of accidental hops (and the accompanying `Sendable` requirements on every intermediate value)
without a single annotation. Work that must *not* run on the caller is marked `@concurrent` — that attribute is
introduced by the same proposal, and without `NonisolatedNonsendingByDefault` it would be a no-op, which is why
the two are enabled together. The `@concurrent` list is the one in C.12: sweeping, purging, decoding the two
multi-megabyte payloads, rebuilding a projection, loading the fixture corpus, indexing the crosswalk.

**`defaultIsolation(nil)` (SE-0466).** MediaKit's manifest sets the package default to *no* isolation, so a type
is nonisolated unless it says otherwise. ArrCore takes `MainActor` in phase 5 (owner decision Q1), which is why
MediaKit must never assume its caller is nonisolated: every public async entry point is either an actor method or
a `nonisolated` function, and none of them is `@MainActor`.

**`InferIsolatedConformances` (SE-0470).** Under a `MainActor` package default this feature makes a conformance
inherit the type's isolation instead of forcing a nonisolated one — it is what saves ArrCore from the
`ArrCredit: Decodable` vs `Sendable` error phase 0 found. In MediaKit, where the default is nil, it is
belt-and-braces: every wire model is a nonisolated `struct` of `let` properties over `Sendable` element types, so
`Decodable` and `Sendable` conformances are both nonisolated and no `@retroactive`/`@preconcurrency` escape hatch
appears anywhere in the package.

**Codable models stay `Sendable` by construction.** Rule enforced by review and by a test that reflects over the
public models: every wire type is a `struct`, every stored property is a `let`, every property type is a value
type or another wire type, and collections are `Array`/`Dictionary`/`Set` of the same. The one exception —
`ArrLibraryRecord.rest` — holds a `[String: JSONValue]` where `JSONValue` is a `Sendable` enum, not `Any`.

**Synchronous view-body reads.** `Projection<Value>` is a `final class`, `@unchecked Sendable`, holding
`(value, version)` behind an `NSLock`. Reads are an uncontended lock plus a dictionary lookup — the same shape as
today's `MediaServerIndex`, which phase 0 confirms is deliberate. Writes happen once per rebuild on a `@concurrent`
function; the lock is held only for the pointer swap. Two consumers exist and the type is not offered for a third
without a reason: artwork overrides and watched state.

**Cancellation.** Three layers, each cooperative:
1. `URLSessionTransport` wraps its continuation in `withTaskCancellationHandler(operation:onCancel:isolation:)`
   and calls `URLSessionTask.cancel()` on cancel; the documented result is an `NSURLErrorCancelled` failure, which
   maps to `MediaKitError.cancelled` and — importantly — is **never** recorded as a breaker failure.
2. `ResourceStore`'s coalescer decrements the waiter count on cancel and cancels the shared task only when the
   count reaches zero (C.5). One of two waiters leaving is invisible to the other.
3. Nothing is committed after cancellation: the memory-tier and SQLite writes happen inside the store's isolation
   after the fetch returns, guarded by a final `Task.isCancelled` check, so a cancelled read leaves no row and no
   `entry_tags` edge. That is criterion 10 in one place instead of six.

Pull-to-refresh, which phase 0 flags as depending on bare `CancellationError` rethrow, keeps working: `.cancelled`
is the only error ArrCore's mapper renders as nothing at all.

---

## H. Test strategy

`swift test` in `Packages/MediaKit`. Swift Testing (`import Testing`, `@Test`/`#expect`). No test constructs a
`URLSession`; the package's only `URLSession`-touching type is `URLSessionTransport`, which is never instantiated
in the suite. A build-level test greps the test target for `URLSession.shared` and fails on a hit.

| # | Acceptance criterion | Test file / test | Fixture or transport |
|---|---|---|---|
| 1 | second read in the freshness window = 0 requests | `StoreFreshnessTests.swift` — `secondReadInsideTTLIssuesNoRequest` | `CountingTransport` |
| 2 | parallel reads coalesce; one waiter's cancellation spares the other | `StoreCoalescingTests.swift` — `twoReadersOneRequest`, `cancellingOneWaiterDoesNotCancelTheOther`, `cancellingLastWaiterCancelsRequest` | `GatedTransport` (blocks until released) |
| 3 | a command's tags force the next dependent read to the network | `StoreInvalidationTests.swift` — `commandTagsMakeDependentReadGoOut`; `ArrCommandTests.swift` — `setMonitoredInvalidatesEntityAndLibrary` | `CountingTransport` + radarr fixtures |
| 4 | a SignalR event invalidates only the described tags | `EventTagMapTests.swift` — `fileImportedTagsExactly`, `queueStatusInvalidatesNothing` | recorded frame strings (ported from `RealtimeFrameParsingTests`) |
| 5 | base-URL change or same-length key rotation invalidates instantly | `InstanceRegistryTests.swift` — `keyRotationSameLengthChangesFingerprint`, `adoptInvalidatesChangedInstance` | none (pure) |
| 6 | volatile never reaches SQLite | `StorePersistenceTests.swift` — `volatileClassNeverPersists` (asserts `SELECT COUNT(*) … class = 0` == 0 and that a forced insert throws `SQLITE_CONSTRAINT`) | temp DB |
| 7 | 429 holds one host to `Retry-After`; others work | `LimiterRateLimitTests.swift` — `retryAfterHoldsOnlyThatHost` | `ScriptedTransport` + `TestClock` |
| 8 | per-host concurrency respected under 100 parallel reads | `HostLimiterTests.swift` — `neverExceedsMaxConcurrent(limit:)` (parameterised 1, 2, 4, 8) | `PeakRecordingTransport` |
| 9 | breaker opens, serves stale, half-opens with one probe | `BreakerTests.swift` — `opensAfterThreeFailures`, `openServesStaleWithoutRequest`, `halfOpenSendsExactlyOne` | `ScriptedTransport` + `TestClock` |
| 10 | task cancellation cancels the request and writes nothing | `StoreCancellationTests.swift` — `cancelledReadLeavesNoRow` | `GatedTransport` + temp DB |
| 11 | capability probed once per fingerprint; persists; v5→v3; Whisparr v2/v3; failure → last/default | `CapabilityTests.swift` — `probesOncePerFingerprint`, `rehydratesFromDiskAfterRelaunch`, `sonarrWithoutV5UsesV3Path`, `whisparrV2Detected`, `probeFailureFallsBackToPersisted`, `noPersistedSetGivesConservativeDefault` | `Fixtures/sonarr/testconnection.json`, synthetic whisparr v2/v3 status bodies |
| 12 | no secret in cache keys, logs, telemetry or repo fixtures | `SecretHygieneTests.swift` — `resourceKeyNeverContainsSecret`, `loggableURLDropsQuery`, `telemetryReportHasNoSecret`, `repoFixturesContainNoSecret` (walks `Fixtures/**` for the four sentinel patterns); `QuerySecretAllowListTests.swift` — `onlySabnzbdAndTMDBv3PutSecretsInQuery` | fixtures + generated plans |
| 13 | every error case has a catalog key | ArrCore `MediaKitErrorMappingTests.swift` — `everyCaseMapsToACatalogKey` (switch over `caseName`), plus `python3 Tools/loc/lint_missing_keys.py` | none |
| 14 | demo is fixtures only | `DemoTransportTests.swift` — `demoQueueRendersFromFixtures`; gate `grep -r DemoMode Packages/MediaKit \| wc -l` == 0 | `FixtureTransport` |
| 15 | cold start renders library + queue from SQLite before the first request | `ColdStartTests.swift` — `firstRenderHappensBeforeAnyRequest` (a `DelayingCountingTransport` that answers after 2 s; asserts count == 0 at first render and that both sections are non-empty) | temp DB seeded from fixtures |
| 16 | widget builds, links MediaKit, no ArrCore clients, shared WAL DB | `GroupContainerTests.swift` — `twoConnectionsReadAndWriteConcurrently`; build `ArrBarrWidgets` + `grep -r "RadarrClient(\|LibrarySummaryService\|UpcomingService" ArrBarrWidgets` == 0 | two `FactDatabase`s on one file |
| 17 | 20-card composition does not scale requests with card count | `BatchCompositionTests.swift` — `twentyCardsIssueTwoRequests` (index + one chunk), `chunkingRespectsMax` | radarr fixtures + `CountingTransport` |
| 18 | no client construction in Views/ViewModels | phase-5 gate: the grep from criterion 18, expected 0 | — |
| 19 | 28 tools work on fixtures, list unchanged | ArrCore `LocalToolBackendFixtureTests.swift` — `allTwentyEightToolsAnswerFromFixtures`, `catalogNamesUnchanged` | `FixtureTransport` |
| 20 | three green test suites, three green schemes, zero MediaKit warnings | CI/verifier: `swift test` ×3, `BuildProject` ×3, `GetBuildLog` severity filter | — |
| 21 | telemetry report per host | `TelemetryReportTests.swift` — `reportCountsEveryKindPerHost` | synthetic events |
| 22 | no macOS/iOS 26 availability guards | phase-3 gate grep == 0 | — |
| 23 | data-layer events use typed messages | `TypedMessageTests.swift` — `invalidationMessagePostsAndObserves`; phase-7 gate grep | `NotificationCenter` |
| 24 | ArrCore `defaultIsolation(MainActor)`, MediaKit `nil`, no `@MainActor` on view types | build + `grep -c "@MainActor" Views ViewModels` == 0 | — |
| 25 | discovery parses Plex/Jellyfin from recorded beacons | `DiscoveryParsingTests.swift` — `parsesPlexBonjourTXT`, `parsesJellyfinUDPBeacon`, `rejectsMalformedBeacon` | `Fixtures/discovery/*.txt`, `*.bin` |
| 26 | golden corpus parity | phase-6 `GoldenCorpusParityTests.swift` — `everyOperationMatchesRecordedShape` (joins on `OperationLabel.operation` + variant; compares method, templated path, sorted query keys, header names, canonical body) | `2026-09-15-golden-requests.json` |
| 27 | per-screen counts, cold start, `swift test` no worse than baseline | phase-6 report from `TelemetryReport` + `GetConsoleOutput` | running app |
| 28 | phase-7 Spotlight / snippet / `@Generable` | phase-7 tests | — |

**Fixture transport matching rules.** Deterministic, three steps, no index file:

1. Directory = `RequestPlan.label.service`.
2. File = `label.operation` lowercased, plus `-` + the templated path with `/` → `-` and `{…}` stripped when
   `label.variant` is set. This is exactly the naming the phase-0 recorder already produced —
   `radarr/fetchqueue.json` for `GET /api/v3/queue` and `radarr/fetchqueue-api-v3-moviefile.json` for the
   side-load of the same operation.
3. For the four RPC clients whose path is constant, `label.variant` is `plan.rpcMethod`, so
   `deluge/fetchprogress-core-get-torrents-status.json` resolves without ambiguity.

The sidecar supplies `status` and, for mutating demo operations, the transport applies a small state delta
(pause/resume/monitor toggles) before answering from the same body — that state is the whole of demo mode.
A missing fixture is a **test failure**, not a fallback: `FixtureTransport` throws
`MediaKitError.persistence(reason: "no fixture for <label>")`, so a new operation cannot silently get demo
behaviour by accident.

**How `RecordingTransport` enforces the allow-list in code.** The section-5 table is a `static let` set of
`AllowedOperation(service:method:pathPattern:rpcMethod:)` values compiled into the type. `send` matches the
`PreparedRequest` against it *before* delegating, and throws `MediaKitError.rejected(status: 403, serverMessage:
"not on the recording allow-list")` on a miss — so a write, a `/release`, or any un-listed path cannot leave the
process even if a client asks. Its own test, `RecordingAllowListTests.swift`, asserts three things:
every allowed row appears in the golden corpus with `allowed: true`; every corpus row with `allowed: false` is
refused; and the scrubber removes the four secret classes plus hostnames before a byte reaches disk.

---

## I. Migration seam

One file in ArrCore owns every MediaKit object. Nothing else constructs one.

```swift
// Packages/ArrCore/Sources/ArrCore/Services/ServiceGateway.swift   (~320 lines, phase 5)
@MainActor public final class ServiceGateway {
    public static let shared = ServiceGateway()

    public let store: ResourceStore
    public let engine: CompositionEngine
    public let capabilities: CapabilityRegistry
    public let identity: IdentityResolver
    public let telemetry: Telemetry
    public let breaker: BreakerRegistry

    public let queue: LiveFeed<[QueueRow]>          // MediaKit vocabulary rows, not QueueItem
    public let progress: LiveFeed<[DownloadTask]>
    public let sessions: LiveFeed<[MediaServerSession]>

    /// Called once, from AppDelegate / iOSAppRoot / the widget, with a transport choice.
    public func start(transport: TransportChoice, location: FactDatabase.Location) async
    /// Called on every ConfigStore change (debounced once, here, not five times in QueueViewModel).
    public func adopt(_ config: ConfigStore) async
    public func arr(_ source: QueueItem.Source) -> ArrDialectHandle?
    public func headers(for ref: ArtworkReference) async -> [String: String]
    public enum TransportChoice { case live, demo }
}
```

* **`ConfigStore` → `InstanceRegistry`.** `adopt` maps the 10 `ServiceConfig`s + one `MediaServerConfig` into
  `[InstanceDescriptor]` (slot 0 each) and calls `registry.adopt(_:store:)`, which recomputes fingerprints and
  invalidates the changed instances' entries before returning. The five duplicated 1.5 s Combine debounce
  pipelines in `QueueViewModel` collapse to one subscription here; secrets never enter a descriptor — the
  gateway also installs a `CredentialProvider` that reads Keychain / group suite per request.
* **Demo becomes a transport choice.** `start(transport: .demo, …)` builds
  `FixtureTransport(corpus: .init(root: Bundle.module.url(forResource: "Fixtures", …)!))` and an in-memory
  `FactDatabase`. `DemoMode.isActive` survives only as a badge flag in ArrCore; `DemoMocks*` (2 889 lines),
  `DemoQueueState`, `DemoMonitorState` and all 46 client-side demo branches are deleted.
* **`PosterStore` consumes `ArtworkReference`.** `PosterStore.image(for: ArtworkReference, tier:)` replaces
  `image(for:tier:apiKey:)`; the URL stays token-free, the headers come from
  `gateway.headers(for:)` at download time, and `PosterStore.key(for:)` can keep its SHA-256 or switch to
  `ref.cacheKey` — both are secret-free. `MediaServerPosterAccess`, `PosterTier.cdnVariant` and
  `TMDBClient.imageURL` all fold into `ArtworkReference.sized(_:)`.
* **The two synchronous reads.** `MediaServerIndex.posterURL(for:)` / `isWatched(_:)` become
  `gateway.mediaServerProjection.value.posterOverride(for:)` / `.isWatched(_:)` — the same lock-guarded snapshot,
  rebuilt by tag rather than by a 15-minute timer.
* **The 28 tools.** `LocalToolBackend+*.swift` stops constructing clients and calls `gateway.engine.value(...)`
  compositions. The tool catalog is untouched, so `ArrMCPServer`'s two bridge files (123 lines) need no change at
  all — the MCP surface migrates for free, which is what `read-consumers.json` predicted.
* **`QueueViewModel`.** Keeps its domain job (grouping, notifications, needs-you) and loses transport: refresh
  becomes `for await v in gateway.queue.updates()`, the 0.25 s burst window and the polling floors move into
  `LiveFeed.Cadence`, `systemDidWake()` becomes `gateway.wake.systemDidWake()`, and `QueueAggregator` (695 lines),
  `DownloadProgressService`, `RealtimeUpdates` and `ConnectionHealthMonitor` are deleted — `ServerStatusModel`
  reads `breaker.health()`.
* **The widget.** `MediaKitWidgetConnection` (≈60 lines in ArrCore, iOS only) opens the group-container database,
  builds a `ResourceStore` with `maxConcurrent: 2`, and exposes the two entry builders. `LibrarySummaryService`
  and `UpcomingService` are deleted.
* **AppIntents** already go through `LocalToolBackend` and `QueueViewModel.shared`; they need no change.

Grep gate after phase 5: `RadarrClient(`, `SonarrClient(`, `LidarrClient(`, `WhisparrClient(`,
`MediaServerClientFactory`, `TMDBClient(` in `Views` and `ViewModels` → 0 (criterion 18). `DetailView`'s 13
construction sites become three `engine.value(...)` calls; `UpcomingRowView`, `LibraryTabContent` and
`SettingsView` stop building clients inside view bodies because the composition for a row is a `read`, not a fetch.

---

## J. Risks, open questions, dropped ideas

### Open questions (each with a recommendation)

**Q1. CryptoKit for SHA-256.** The non-negotiable dependency list is "Foundation, os, Observation, Network,
SQLite3, Swift Concurrency"; CryptoKit is a system framework with the same properties (no SPM dependency, no
reproducibility risk, present in every SDK) but is not on the list.
*Recommendation: add CryptoKit.* `SHA256.hash(data:)` (CryptoKit, macOS 10.15+) is 25 lines of use against 130 for
a hand-rolled implementation, and a hand-rolled hash in a package whose budget is the binding constraint is a bad
trade. If refused, defer `Discovery/*` to phase 7 to pay for the extra 105 lines.

**Q2. Where does download-progress coalescing live?** Phase 0's `read-download.json` asks explicitly whether the
0.25 s burst window / 1 s floor / 300 s silence logic moves into MediaKit or stays in `QueueViewModel`.
*Recommendation: move it into `LiveFeed.Cadence`.* It is a data-layer policy about request rate, it is the
mechanism criterion 2 is measured on, and leaving it in the view model keeps 100 lines of transport policy in the
presentation layer — the exact rot this rewrite exists to stop. ArrCore keeps only `setActivity(.foreground/.background)`.

**Q3. Does `PosterStore` move into MediaKit?** Today it is a second HTTP stack with its own requests, SHA-256 keys
and three tiers.
*Recommendation: no, not now.* MediaKit owns `ArtworkReference` (the URL, the headers, the sizing, the key);
`PosterStore` stays in ArrCore as a byte/image cache, because it holds `PlatformImage` and tier eviction policy
that are presentation concerns. Revisit only if a second consumer appears.

**Q4. Two fingerprint schemes and `CoalescingCache`'s length-only key.** Phase 0 found that a same-length key
rotation serves the old server forever.
*Recommendation: one scheme, the 8-byte digest, everywhere;* `SearchOptionsCache`'s full-key variant and
`ServiceConfig.identityFingerprint` both die with the code that holds them. No migration is needed because
`entries` is a cache.

**Q5. Does `SpotlightIndexer` (508 lines) re-fetch or read the store?**
*Recommendation: read the store at `.cacheOnly` on a `library(_)` invalidation.* It is listed as
`replaced_by_mediakit: true` but is really a consumer; it should never issue a request of its own again. Worth one
line in the phase-5 plan so it does not silently keep its own fetch path.

**Q6. Emby's auth header.** ArrCore sends bare `X-Emby-Token`; the spike wraps both Jellyfin and Emby in
`MediaBrowser Token=`.
*Recommendation: keep ArrCore's behaviour as the default* (`Capability.jellyfinBareEmbyToken` on for `.emby`) and
make the wrapped form the fallback after a 401. We have no Emby instance to test against, so the shipping
behaviour is the safer default.

**Q7. TMDB v3 keys.** `read-media.json` asks whether v3 hex keys must keep working.
*Recommendation: yes, indefinitely.* They are one of only two sanctioned query secrets and users have them pasted
in Settings; forcing v4 is a migration this rewrite should not carry.

**Q8. `entries` payload compression.** The Plex index is 7 MB uncompressed (1.5 MB gzipped, per the fixture
sidecar) and would dominate a 16 MB widget cap.
*Recommendation: store the payload exactly as received, including `Content-Encoding` already decoded by URLSession,
but exempt `Plex.index` from the widget's store by giving the widget a resource allow-list.* Adding a compression
column costs ~60 lines and a zlib dependency question we do not need.

### Risks

* **The 60 % budget has 60 lines of slack.** It only closes because the 2 889 lines of demo mocks become data. If
  any client turns out to need real per-operation code (most likely rTorrent's XML-RPC or SABnzbd's mode-string
  zoo), the reserve is gone in one file. Mitigation: `Discovery` (210 lines) is the pre-agreed thing to defer.
* **`SignalREventSource` at 360 lines is a 52 % cut of a 751-line file** that is only unit-tested at the frame
  level. The negotiate/handshake/backoff paths are untested today and will be untested after the port unless
  phase 3 adds a `ScriptedWebSocket` double. Recommend budgeting that double explicitly in the plan.
* **`stale_at` invalidation plus `cacheOnly` reads can show data from a previous *server*** if a fingerprint change
  is missed. Mitigation is structural — `entries.fingerprint` is in the primary-key-adjacent index and every read
  filters on it — but it must be a test (`StorePersistenceTests.readIgnoresRowsFromAnotherFingerprint`).
* **`Observations` transactional semantics.** The documentation says the sequence tracks changes "*starting from
  the willSet of the first mutation to the next suspension point*". Whether a burst of invalidations inside one
  actor hop yields once or N times decides whether the view rebuilds once or twenty times on a SignalR storm.
  This must be settled by an `RunCodeSnippet` probe in phase 3 before `observe` is written, not assumed.
* **WAL in the App Group on iOS** requires the `-wal` and `-shm` files to carry the same file protection as the
  database, or a widget refresh on a locked device fails with `SQLITE_AUTH`/`SQLITE_CANTOPEN`. The attribute is set
  per file after creation; a test on a real device is the only real proof, and the simulator will not show it.
* **`NonisolatedNonsendingByDefault` changes the meaning of existing async code**, including code ported from
  ArrCore. A function that used to hop off the main actor now stays on it. Every ported function must be reviewed
  for whether it wants `@concurrent` — the SignalR read loop in particular.

### Section-3 ideas dropped

* **`FragmentCache` and the per-field `MediaFieldSet` model.** A field set is a second cache dimension on top of
  the resource key and it does not match how the arrs answer — they return whole records, so field-level freshness
  buys nothing and costs a join. Freshness lives on the resource; the "one record, three read policies" example
  from the prompt is served by `maxAge` on each read, which is simpler and already in the API.
* **`MediaGraph` / the query planner.** The composition engine plus `BatchResource` covers every real batching
  case in this app with two strategies; a planner is a layer with no second caller.
* **Providers with per-field cost and precedence.** Replaced by explicit compositions in ArrCore. Precedence is a
  product decision (media-server artwork beats the arr's) and belongs where the product lives, not in a table in
  the data layer.
* **`ProviderHealth`.** The breaker is the single source of truth about health; a second health type was never
  set in the spike, which is the evidence it was not needed.
* **A separate `RetryPolicy` type.** Retry is four lines in the store's fetch path: idempotent-only, jittered
  backoff, honour `Retry-After`, at most two attempts. A protocol for it would have one implementation.
* **`Resource.encode` / an `Encodable` half of the cache.** Killed by storing response bytes.
* **`BatchMediaProvider`.** Unused in the spike; its job is `BatchResource`.
* **`PollingEventSource`.** Polling is a cadence of `LiveFeed`, not an event source; making it one meant two
  timers for one refresh.
* **A generic `Composition` protocol.** Compositions belong to the app; the engine only needs a `Hashable` key.
* **`intencje katalogowe` / `MediaCatalog` from the spike.** TMDB discover is three resources, not a catalog
  abstraction.
