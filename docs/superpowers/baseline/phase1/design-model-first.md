# MediaKit — model-first design

Phase 1, architect angle: **model first**. Inputs read in full: prompt sections 0/1/3/4/5/6a,
phase-0 report, the four `phase0/*.json` inventories, the 181-entry golden corpus, the fixture
sidecars, and the ArrCore call sites listed below. API facts were taken from Apple's documentation
JSON and from four compiler probes built under the real settings (tools 6.2, `.macOS(.v26)`,
`defaultIsolation(nil)`, `NonisolatedNonsendingByDefault`, `InferIsolatedConformances`, SDK 27).

---

## A. Thesis

This design treats the **identity of a work, the vocabulary of each service, and the capability set
of each instance as the primary types**, and derives the cache, the transport and the composition
engine from what those three need — the opposite of starting at the socket. Every resource is named
by `(InstanceID, operation, typed parameters)` and every value is tagged by *what it is about*
(`entity(radarr, .movie, 1525)`, `collection(sonarr, .queue)`, `identity(tmdb-movie:603)`), so
invalidation, SignalR events, commands, the widget's snapshot and the synchronous view-body
projections all speak one language and the store never has to guess. What it deliberately sacrifices:
**generality of the wire layer**. There is no generic JSON-RPC framework, no generic XML-RPC codec,
no pluggable auth pipeline and no schema-driven decoder — each of the six download clients and three
media servers gets a hand-written 130–220-line adapter shaped exactly like its recorded fixtures,
because six hand-written adapters are smaller and far more debuggable than one framework that can
express all six. It also sacrifices *freedom at the call site*: ArrCore may only reach MediaKit
through one gateway and may only ask for declared resources and commands, which is what makes
criteria 18 and 19 mechanical rather than aspirational. The bet is that the expensive part of this
layer was never the HTTP — it was 14,317 lines of per-call-site improvisation about identity,
freshness and demo mode.

---

## B. Module layout

`Packages/MediaKit/Sources/MediaKit/` — one target, one product. Estimates are production lines
(no tests, no fixtures). Budget from phase 0: **≤ 8,590** (60 % of 14,317).

| Group | Files | Files and estimated LOC | Σ |
|---|---|---|---|
| `Core/` | 9 | `MediaKitError` 110, `InstanceID` 100, `InstanceRegistry` 140, `Credentials` 60, `Clock` 40, `Telemetry` 160, `LogSink` 70, `SHA256` 60, `MediaKitConnection` 130 | **870** |
| `Identity/` | 5 | `MediaID` 130, `MediaIdentity` 140, `IdentityCrosswalk` 150, `IdentityResolver` 160, `ExternalIDParsing` 90 | **670** |
| `Capabilities/` | 2 | `Capability` 110, `CapabilityProbe` 190 | **300** |
| `Transport/` | 6 | `Transport` 120, `URLSessionTransport` 160, `FixtureTransport` 190, `SessionAuth` 190, `Governor` 280, `RequestBuilder` 140 | **1080** |
| `Store/` | 6 | `ResourceKey` 110, `Resource` 90, `Store` 300, `SQLite` 220, `Snapshot` 110, `LiveStream` 170 | **1000** |
| `Events/` | 4 | `EventSource` 110, `SignalREventSource` 300, `EventTagMap` 100, `Messages` 90 | **600** |
| `Composition/` | 1 | `Composition` 280 | **280** |
| `Services/Arr/` | 7 | `ArrShared` 190, `ArrWireModels` 320, `ArrEntityModels` 280, `RadarrService` 200, `SonarrService` 260, `LidarrService` 230, `WhisparrService` 80 | **1560** |
| `Services/Download/` | 7 | `DownloadService` 120, `QBittorrentService` 170, `TransmissionService` 150, `DelugeService` 150, `RTorrentService` 150, `SABnzbdService` 130, `NZBGetService` 130 | **1000** |
| `Services/MediaServer/` | 4 | `MediaServerService` 110, `PlexService` 220, `JellyfinService` 200, `Artwork` 130 | **660** |
| `Services/TMDB/` | 2 | `TMDBService` 200, `TMDBModels` 140 | **340** |
| `Discovery/` | 1 | `Discovery` 170 | **170** |
| **Total** | **54** | 870+670+300+1080+1000+600+280+1560+1000+660+340+170 | **8 530** |

Headroom **60 lines**. Two extra targets that do **not** count against the production budget:

- `MediaKitRecording` (test-support target, ~260 lines) — `RecordingTransport` and the section-5
  allow-list table. It is a separate target so a release build of the app cannot link a type whose
  only purpose is talking to the owner's live servers, and so the allow-list still lives *in code*
  (criterion: section 5). It depends on MediaKit; MediaKit does not depend on it.
- `MediaKitTests` — everything else.

Fixtures ship as `Resources/` (JSON, `.copy`), not Swift.

**What was cut to fit** (all of it real, all of it named so the critic can push back):

1. **No generic RPC layer.** `RTorrentService` hand-encodes the six XML-RPC calls in the corpus
   (`system.client_version`, `d.multicall2`, `d.start`, `d.stop`, `d.erase`, `load.*`) and parses
   the two reply shapes it can get. A general `XMLRPCValue` codec was ~250 lines for six calls.
2. **Demo state is data, not Swift.** `DemoMocks`+`DemoMonitorState`+`DemoQueueState` (2,889 lines
   in phase 0's group D) become fixture JSON plus a ~60-line overlay interpreter inside
   `FixtureTransport`. This single decision is what makes the 60 % budget reachable at all.
3. **One wire-model file per family, not per arr.** Servarr's queue/history/calendar/command/health/
   diskspace/profile/rootfolder/customformat shapes are identical across Radarr/Sonarr/Lidarr/
   Whisparr; only the entity payload differs. `ArrWireModels` is written once, generic over the
   entity (`ArrQueueRecord<Entity>`), and `ArrEntityModels` holds the four entity families.
4. **Whisparr v3 is 80 lines** — a vocabulary that re-exports Radarr's resources with a different
   `InstanceID` and one capability gate (decision Q3).
5. **No `ConnectionHealthMonitor` port.** Host health is the breaker's state; ArrCore reads it.
6. **No generic migration engine.** `user_version` plus a switch with one arm per version.

---

## C. Public API sketch

Isolation is stated per type. The package is built with `defaultIsolation(nil)`, so *unannotated*
types and functions are `nonisolated`, and unannotated `async` functions run on the caller's
executor (SE-0461 `NonisolatedNonsendingByDefault`); `@concurrent` is what moves work off the
caller (SE-0461). Isolated conformances are inferred (SE-0470 `InferIsolatedConformances`) — used
only in ArrCore, never inside MediaKit.

### C.1 Identity — the spine

```swift
// nonisolated value types throughout.

public enum MediaKindID: String, Sendable, Codable, CaseIterable, Hashable {
    case movie, series, season, episode, artist, album, track, person
}

/// A namespace an id lives in. Arr and media-server namespaces carry the instance,
/// because "Radarr movie 12" is only meaningful next to the Radarr it came from —
/// this is the change from the 2026-09-13 spike, which keyed them by flavour.
public enum IDNamespace: Hashable, Sendable, Codable {
    case tmdbMovie, tmdbSeries, tmdbPerson
    case tvdb, imdb
    case musicBrainzArtist, musicBrainzAlbum, musicBrainzTrack
    case arr(InstanceID)
    case mediaServer(InstanceID)

    /// The kind a namespace can only ever name, or nil when it spans kinds.
    public var impliedKind: MediaKindID? { get }
    /// Portability rank for canonical-id selection: global ids beat local ones.
    public var portability: Int { get }
}

public struct MediaID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let namespace: IDNamespace
    public let value: String              // "603", "tt0068646", "8fa3…", never a secret
    public init(_ namespace: IDNamespace, _ value: String)

    public static func tmdbMovie(_ id: Int) -> MediaID
    public static func tmdbSeries(_ id: Int) -> MediaID
    public static func tvdb(_ id: Int) -> MediaID
    public static func imdb(_ id: String) -> MediaID          // normalised to lowercase "tt…"
    public static func arr(_ instance: InstanceID, _ id: Int) -> MediaID
    public static func server(_ instance: InstanceID, _ id: String) -> MediaID

    /// Round-trips; used in cache keys, tags and logs. "tmdb-movie:603", "arr:radarr#1:1525".
    public var token: String { get }
    public init?(token: String)
}

/// Everything known about ONE work, plus where it sits when it is a part.
public struct MediaIdentity: Hashable, Sendable, Codable {
    public let kind: MediaKindID
    public private(set) var ids: Set<MediaID>
    /// Set for season/episode/track/album: the work this one belongs to.
    public let parent: Box<MediaIdentity>?
    /// Season number, episode number, track number. nil for whole works.
    public let ordinal: Ordinal?

    public struct Ordinal: Hashable, Sendable, Codable {
        public let season: Int?
        public let number: Int?
    }

    public init(kind: MediaKindID, ids: Set<MediaID>,
                parent: MediaIdentity? = nil, ordinal: Ordinal? = nil)

    public func id(in namespace: IDNamespace) -> MediaID?
    public func ids(in kind: IDNamespace...) -> [MediaID]
    /// Provable sameness only: shared id, same kind, same ordinal. Never title/year.
    public func matches(_ other: MediaIdentity) -> Bool
    @discardableResult public mutating func merge(_ other: MediaIdentity) -> Bool
    /// Most portable id — a value keyed on a server-local id would be lost the
    /// moment the same work is reached through TMDB.
    public var canonical: MediaID { get }
    public var storeKey: String { get }   // "episode/tvdb:121361/s2e1"
}
```

`Box` is a 12-line indirect wrapper (a `MediaIdentity` cannot contain itself by value).

**Cross-walk.** One SQLite-backed table and one actor; it is *the* replacement for `MediaRef`,
`MediaServerExternalKey`, `MediaServerGuidParser` and `SeriesIdentityResolver`.

```swift
public struct Crosswalk: Hashable, Sendable, Codable {
    public let from: MediaID
    public let to: MediaID
    public let kind: MediaKindID
    public let confidence: Confidence
    public let source: Source
    public let fetchedAt: Date

    public enum Confidence: Int, Sendable, Codable, Comparable {
        case asserted = 100   // the record carries both ids (arr /movie, Plex guid, TMDB external_ids)
        case verified = 80    // we asked by id and the answer echoed the id back
        case inferred = 40    // a library-map join
        case unproven = 0     // never stored, never used to substitute
    }
    public enum Source: String, Sendable, Codable {
        case arrRecord, mediaServerGuid, tmdbExternalIDs, arrLookupByID, libraryIndex
    }
}

public actor IdentityCrosswalk {
    public init(store: Store, telemetry: Telemetry)

    /// Pure lookup — no network. The only call allowed on a cold, offline launch.
    public func known(_ id: MediaID, in namespace: IDNamespace) async -> MediaID?
    public func identity(for id: MediaID, kind: MediaKindID) async -> MediaIdentity
    public func record(_ walks: [Crosswalk]) async            // upsert, max(confidence) wins
    public func forget(instance: InstanceID) async            // fingerprint change
}

/// The resolution policy that used to be SeriesIdentityResolver, minus the singletons.
/// Ordered cheapest-first; each route states the confidence it can produce.
public struct IdentityResolver: Sendable {
    public init(crosswalk: IdentityCrosswalk, store: Store,
                capabilities: CapabilityIndex, services: ServiceLocator)

    /// tmdb-series → tvdb, for the add path. Routes, in order:
    ///  1. crosswalk (asserted/inferred)  2. Sonarr library index join
    ///  3. Sonarr `term=tmdb:N` — only when `.sonarrTMDBTermLookup` is a proven capability,
    ///     and only if the returned record echoes the tmdb id (verified)
    ///  4. TMDB `/tv/{id}/external_ids` (asserted)  5. nothing.
    public func resolve(_ id: MediaID, into namespace: IDNamespace,
                        minimum: Crosswalk.Confidence = .verified) async throws -> MediaID?
}
```

`ExternalIDParsing` holds the pure functions: Plex guid strings (modern `tmdb://`, legacy
`com.plexapp.agents.themoviedb://…?lang=en`, `…thetvdb://121361/2/1` with season/episode),
Jellyfin/Emby `ProviderIds` dictionaries, Servarr `imdbId`/`tmdbId`/`tvdbId`/`foreignAlbumId`
fields, and TMDB `external_ids`. All `nonisolated` free functions over `String`/`[String: String]`
— which is what makes criterion 25's parser tests trivial and offline.

### C.2 Instances, credentials, fingerprints

```swift
public struct InstanceID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let kind: ServiceKindID        // .radarr, .sonarr, …, .plex, .tmdb
    public let ordinal: Int               // 1 today; schema is ready for 2
    public var description: String { "\(kind.rawValue)#\(ordinal)" }   // safe in logs
}

public enum ServiceKindID: String, Sendable, Codable, CaseIterable {
    case radarr, sonarr, lidarr, whisparr
    case qbittorrent, transmission, deluge, rtorrent, sabnzbd, nzbget
    case plex, jellyfin, emby
    case tmdb
    public var family: ServiceFamily { get }     // .arr / .downloadClient / .mediaServer / .metadata
}

/// What the credential IS, per family — phase-0 fact 3: download clients authenticate by password.
public enum Credential: Sendable, Equatable {
    case none
    case apiKey(String)                    // arrs (header), SABnzbd (query), TMDB v3 (query)
    case bearer(String)                    // TMDB v4, qBittorrent 5 API-key mode
    case login(user: String, password: String)   // qBittorrent 4, Deluge, Transmission, NZBGet, rTorrent
    case token(String)                     // Plex / Jellyfin / Emby
}

/// Asked per request. Never stored by MediaKit, never logged, never in a key.
public protocol CredentialProvider: Sendable {
    func credential(for instance: InstanceID) async -> Credential
}

public struct InstanceDescriptor: Sendable, Equatable {
    public let id: InstanceID
    public let baseURL: URL
    public let host: HostID                // scheme+host+port, the breaker/limiter key
    public let enabled: Bool
}

/// Fingerprint = base URL + first 8 bytes of SHA-256(credential material). Rotation of a
/// same-length key on the same URL is detected — today's `baseURL|apiKey.count` cannot.
public struct InstanceFingerprint: Hashable, Sendable, Codable {
    public let base: String                // normalised absoluteString, no query
    public let digest: String              // 16 lowercase hex chars = 8 bytes
    public static func make(baseURL: URL, credential: Credential) -> InstanceFingerprint
}

public actor InstanceRegistry {
    public init(credentials: any CredentialProvider, store: Store,
                crosswalk: IdentityCrosswalk, clock: any Clock, telemetry: Telemetry)

    public func apply(_ descriptors: [InstanceDescriptor]) async
    public func descriptor(_ id: InstanceID) async -> InstanceDescriptor?
    public func fingerprint(_ id: InstanceID) async -> InstanceFingerprint?
    public func configured(family: ServiceFamily) async -> [InstanceID]

    /// Recomputes every fingerprint; for each changed one: invalidate `.instance(id)`,
    /// drop the capability row, forget the crosswalk's instance-local ids, post
    /// `InstanceConfigurationDidChange`. Called once, from ArrCore's gateway.
    @discardableResult
    public func reconcile() async -> Set<InstanceID>
}
```

### C.3 Capabilities

```swift
public struct Capability: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String
}

extension Capability {
    // arrs
    public static let arrQueueGrab: Capability                 // POST /queue/grab/{id}
    public static let sonarrSeasonEndpointV5: Capability       // PUT /api/v5/series/{id}/season
    public static let sonarrTMDBTermLookup: Capability         // /series/lookup?term=tmdb:N is honoured
    public static let lidarrSearchLookup: Capability           // GET /api/v1/search
    public static let whisparrMovieVocabulary: Capability      // v3 (Radarr fork)
    public static let whisparrSeriesVocabulary: Capability     // v2 (Sonarr fork) — read-only subset
    public static let arrSignalR: Capability
    // download clients
    public static let qbittorrentAPIKeyAuth: Capability        // 5.x, no /auth/login
    public static let qbittorrentStoppedSpelling: Capability   // 5.x parameter rename
    public static let sabnzbdHistorySlots: Capability
    // media servers
    public static let plexLegacyAgentGuids: Capability
    public static let mediaServerSeasonImages: Capability
    // metadata
    public static let tmdbV4Auth: Capability
}

public struct CapabilitySet: Sendable, Equatable, Codable {
    public let instance: InstanceID
    public let fingerprint: InstanceFingerprint
    public let version: ServiceVersion?     // parsed major.minor.patch.build, never trusted directly
    public let capabilities: Set<Capability>
    public let probedAt: Date
    public let origin: Origin
    public enum Origin: String, Sendable, Codable { case probed, restored, conservativeDefault }

    public func has(_ c: Capability) -> Bool
}

/// Reads are synchronous against a lock-guarded snapshot: a client picking an endpoint
/// must not await. Writes go through the probe.
public final class CapabilityIndex: @unchecked Sendable {
    public func current(_ instance: InstanceID) -> CapabilitySet   // never nil: falls back to default
    public func has(_ c: Capability, _ instance: InstanceID) -> Bool
}

public actor CapabilityProbe {
    public init(store: Store, index: CapabilityIndex, registry: InstanceRegistry,
                transport: any Transport, clock: any Clock, telemetry: Telemetry)

    /// Once per fingerprint. Restored from SQLite on launch before any request.
    /// A failure is never surfaced: last stored set, else the conservative default
    /// for the kind. Re-probes after the next successful status read or a version change.
    @discardableResult
    public func ensure(_ instance: InstanceID) async -> CapabilitySet
    public func invalidate(_ instance: InstanceID) async
    /// Conservative default per kind, used when nothing is known: the intersection of
    /// what every supported version of that service can do.
    public nonisolated static func conservativeDefault(for kind: ServiceKindID) -> Set<Capability>
}
```

Probe inputs are one request each and are themselves cached resources (`systemStatus`, freshness
`.live`): arrs `GET {apiBase}/system/status`, qBittorrent `GET /api/v2/app/version`, SABnzbd
`mode=version`, Transmission `session-get`, Deluge `daemon.info`, NZBGet `version`, rTorrent
`system.client_version`, Plex `GET /identity`, Jellyfin/Emby `GET /System/Info`, TMDB
`GET /3/configuration`. Every one of them is on the section-5 allow-list and has a recorded fixture
(except Whisparr/Jellyfin/Emby/the four unconfigured RPC clients → synthetic, `synthetic: true`).

### C.4 Errors — closed enum, 16 cases, one catalog key each

```swift
public enum MediaKitError: Error, Sendable, Hashable {
    case notConfigured(InstanceID)
    case missingCredential(InstanceID)
    case unreachable(HostID, ReachabilityCause)
    case timedOut(HostID, seconds: Double)
    case cancelled
    case unauthorized(HostID, status: Int)          // 401/403
    case notFound(HostID, operation: OperationID)   // operation, never a URL
    case rateLimited(HostID, retryAfter: Duration?)
    case serviceRejected(HostID, status: Int, message: ServiceMessage?)  // 4xx with a body
    case serviceFailed(HostID, status: Int, message: ServiceMessage?)    // 5xx
    case breakerOpen(HostID, until: Date)
    case decoding(OperationID, DecodingFailure)
    case unsupportedCapability(InstanceID, Capability)
    case identityUnresolved(MediaID, into: IDNamespace)
    case commandRejected(InstanceID, command: String, message: ServiceMessage?)
    case fixtureMissing(OperationID)                // FixtureTransport only; demo/test

    public var isRetryable: Bool { get }
    public var host: HostID? { get }
    public var instance: InstanceID? { get }
}

/// The reason the *arr* gave, parsed out of the body — Servarr array, Servarr object and
/// ASP.NET ProblemDetails, exactly as `HTTPError.serverMessage` does today. Never localised
/// inside MediaKit and never a user string of our own.
public struct ServiceMessage: Hashable, Sendable, Codable {
    public let text: String
    public let field: String?
}

public enum ReachabilityCause: String, Sendable, Codable, Hashable {
    case offline, hostUnresolvable, connectionRefused, tlsFailure, unknown
}
```

`cancelled` is produced only by cancellation and is re-thrown bare through every layer, so
pull-to-refresh keeps working (phase-0 fact 5).

### C.5 Transport

```swift
public struct HostID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let scheme: String, host: String, port: Int
    public var description: String { "\(host):\(port)" }   // safe in logs, no path, no query
}

public struct OperationID: Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let rawValue: String    // "radarr.fetchQueue" — matches the golden corpus `operation`
}

public enum RequestPriority: Int, Sendable, Comparable { case background = 0, interactive = 1 }

public struct HTTPRequest: Sendable {
    public var operation: OperationID
    public var instance: InstanceID
    public var host: HostID
    public var method: HTTPMethod                 // get, post, put, delete
    public var path: String                       // already joined, no query
    public var pathTemplate: String               // "/api/v3/movie/{id}" — logs, fixtures, corpus
    public var query: [URLQueryItem]
    public var headers: [String: String]
    public var body: HTTPBody                     // .none, .json(Data), .form([String:String]), .multipart(…), .xml(Data)
    public var timeout: Duration
    public var priority: RequestPriority
    public var idempotent: Bool                   // retry gate; false for every write except the two below
    /// RPC discriminator, so a fixture/allow-list can address one of the N calls that
    /// share a path: "core.get_torrents_status", "torrent-get", "d.multicall2", "listgroups".
    public var rpcMethod: String?
}

public struct HTTPResponseBytes: Sendable {
    public let status: Int
    public let headers: [String: String]          // lowercased keys
    public let body: Data
}

public protocol Transport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponseBytes
}
```

Three implementations, all `nonisolated struct`s except where session state forces otherwise:

```swift
public struct URLSessionTransport: Transport {
    public init(session: URLSession)     // injected; tests never touch URLSession.shared
    /// Explicit task + withTaskCancellationHandler: cancellation of the *last* waiter cancels
    /// the URLSessionTask (URLSessionTask.cancel() → NSURLErrorCancelled) and nothing is stored.
    public func send(_ request: HTTPRequest) async throws -> HTTPResponseBytes
}

public actor FixtureTransport: Transport {
    public init(bundle: FixtureBundle, world: DemoWorld = .empty, clock: any Clock)
    public func send(_ request: HTTPRequest) async throws -> HTTPResponseBytes
    /// Every request seen, for assertions ("zero requests on the second open").
    public func log() -> [HTTPRequest]
    public func reset() async
}

/// Test-support target only. The section-5 allow-list is a table in this file; anything
/// outside it throws before a socket is opened.
public struct RecordingTransport: Transport {
    public init(live: any Transport, allowList: AllowList = .section5, sink: FixtureWriter)
}
```

`SessionAuth` is where the six download clients' handshakes live, *inside* the transport contract
rather than in the service vocabularies:

```swift
/// A per-instance authenticator the transport consults before sending and after a rejection.
public protocol SessionAuthenticator: Sendable {
    func decorate(_ request: inout HTTPRequest, credential: Credential) async throws
    /// Returns true when the caller should retry once with a refreshed session.
    func recover(from response: HTTPResponseBytes, request: HTTPRequest,
                 credential: Credential) async throws -> Bool
}

public actor SessionAuth: SessionAuthenticator {
    public init(kind: ServiceKindID, transport: any Transport, telemetry: Telemetry)
    // qBittorrent: login-mode POST /api/v2/auth/login once per launch, SID cookie held on the
    //   actor + a generation counter so a burst of 403s re-logs in once; key-mode sets Bearer
    //   and never logs in (Capability.qbittorrentAPIKeyAuth). Referer header always set.
    // Deluge: POST /json auth.login once, session cookie, same generation rule.
    // Transmission: sends X-Transmission-Session-Id when known; on 409 takes the header from
    //   the response and retries once (the one place a *response header* is load-bearing).
    // NZBGet / rTorrent: Basic auth header, no session.
    // SABnzbd: apikey in query (the documented exception), no session.
}
```

`Governor` is the one type holding limiter, retry and breaker, because all three are keyed by
`HostID` and any split makes them argue:

```swift
public actor Governor {
    public struct Limits: Sendable {
        public var maxConcurrent: [RequestPriority: Int] = [.interactive: 4, .background: 2]
        public var minimumInterval: Duration = .milliseconds(0)
        public var breakerFailureThreshold = 4
        public var breakerCooldown: Duration = .seconds(30)
        public var retryAttempts = 2
        public var retryBaseDelay: Duration = .milliseconds(250)
    }
    public enum Health: Sendable, Equatable { case healthy, degraded(since: Date), down(until: Date), unconfigured }

    public init(limits: Limits, clock: any Clock, telemetry: Telemetry)

    /// The single entry point every request goes through. Enforces per-host concurrency and
    /// rate, honours Retry-After, retries reads and explicitly idempotent writes only,
    /// and trips/half-opens the breaker. Runs the body on the caller's executor;
    /// `@concurrent` lives one level down, in the transport's decode step.
    public func run<T: Sendable>(_ host: HostID, priority: RequestPriority,
                                 idempotent: Bool,
                                 _ body: @Sendable () async throws -> T) async throws -> T

    public nonisolated func health(_ host: HostID) -> Health      // lock-guarded snapshot read
    public func note(wake: Date) async                             // half-open every host on wake
}
```

Breaker semantics (criterion 9): `healthy → degraded` on the first failure, `→ down(until:)` after
`breakerFailureThreshold` consecutive transport failures; while `down`, `Governor.run` throws
`.breakerOpen` **without sending**, and the store answers from stale rows instead (criterion 15 and
goal 1: no error UI, a quiet chip). After the cooldown one probe request is allowed through
(half-open); success resets, failure re-arms with doubled cooldown, capped at 5 minutes. HTTP 429
sets `down(until: now + retryAfter)` for **that host only** (criterion 7).

### C.6 Store, resources, commands

```swift
public enum FreshnessClass: String, Sendable, Codable, CaseIterable {
    case volatile   // queue rows, progress, sessions   TTL 5 s    MEMORY ONLY, never SQLite
    case live       // health, disk space, command state TTL 60 s  disk retention 1 d
    case warm       // library index, calendar, history  TTL 10 min disk retention 7 d
    case cold       // details, files, credits, profiles TTL 6 h   disk retention 30 d
    case frozen     // title metadata, crosswalk, TMDB   TTL 30 d  disk retention 180 d

    public var defaultTTL: Duration { get }
    public var retention: Duration? { get }
    public var persists: Bool { self != .volatile }
}

public struct InvalidationTag: Hashable, Sendable, Codable {
    public let raw: String    // stable, printable, secret-free
    public static func instance(_ id: InstanceID) -> InvalidationTag
    public static func collection(_ id: InstanceID, _ c: CollectionID) -> InvalidationTag  // .queue,.library,.calendar,.history,.health,.profiles
    public static func entity(_ id: InstanceID, _ kind: MediaKindID, _ entityID: Int) -> InvalidationTag
    public static func identity(_ mediaID: MediaID) -> InvalidationTag
    public static func capability(_ id: InstanceID) -> InvalidationTag
}

public struct ResourceKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public let instance: InstanceID
    public let operation: OperationID
    public let parameters: String      // canonical, sorted, secret-free ("movieId=1525")
    public var description: String { "\(instance)/\(operation.rawValue)?\(parameters)" }
}

public struct Resource<Value: Decodable & Sendable>: Sendable {
    public let key: ResourceKey
    public let tags: Set<InvalidationTag>
    public let freshness: FreshnessClass
    public let request: @Sendable (CapabilityIndex) throws -> HTTPRequest
    public let decode: @Sendable (HTTPResponseBytes) throws -> Value
    /// Ids learned on the way — written to the crosswalk by the store, not by callers.
    public let harvest: (@Sendable (Value) -> [Crosswalk])?
}

/// A batch resource: N ids in, one request out, indexed result. Declared by the service
/// when the source really has a batch endpoint (criterion 17).
public struct BatchResource<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    public let chunkSize: Int                    // Radarr /moviefile: 40 ids per URL
    public let resource: @Sendable ([Key]) -> Resource<[Key: Value]>
}

public struct Command: Sendable {
    public let id: OperationID
    public let instance: InstanceID
    public let request: @Sendable (CapabilityIndex) throws -> HTTPRequest
    /// Declared up front; the store invalidates exactly these after a 2xx.
    public let invalidates: Set<InvalidationTag>
    /// Optional optimistic projection — applied ONLY to a live stream, never written to the store.
    public let optimistic: OptimisticEffect?
    /// Long-running arr commands: the /command id to poll until completed/failed.
    public let tracks: CommandTracking?
    public let requiredCapability: Capability?
}
```

```swift
public actor Store {
    public struct Options: Sendable {
        public var location: DatabaseLocation
        public var memoryBudget: Int = 8 * 1024 * 1024
        public var diskBudget: Int = 64 * 1024 * 1024
        public var sweepInterval: Duration = .seconds(900)
    }

    public init(options: Options, transport: any Transport, governor: Governor,
                capabilities: CapabilityIndex, credentials: any CredentialProvider,
                clock: any Clock, telemetry: Telemetry) throws

    /// The read. `maxAge` may only TIGHTEN the freshness class's TTL.
    /// - fresh hit      → returns, zero requests (criterion 1)
    /// - stale hit      → returns immediately and revalidates in the background (SWR),
    ///                    unless `policy == .mustRevalidate`
    /// - miss           → coalesces with any in-flight request for the same key (criterion 2)
    /// - breaker open   → returns the stale row if there is one, else throws `.breakerOpen`
    public func read<V>(_ resource: Resource<V>, maxAge: Duration? = nil,
                        policy: ReadPolicy = .staleWhileRevalidate,
                        priority: RequestPriority = .interactive) async throws -> Cached<V>

    public func readBatch<K, V>(_ batch: BatchResource<K, V>, keys: [K],
                                maxAge: Duration? = nil,
                                priority: RequestPriority = .background) async throws -> [K: V]

    /// Synchronous, no I/O: the memory tier only. For "do I already have this?" decisions.
    public nonisolated func peek<V>(_ key: ResourceKey, as: V.Type) -> Cached<V>?

    @discardableResult
    public func run(_ command: Command) async throws -> CommandOutcome

    public func invalidate(tags: Set<InvalidationTag>, reason: InvalidationReason) async
    public func sweep() async            // retention + budget, oldest last_used first
    public func purge(_ class: FreshnessClass) async
    public func purgeAll() async         // AppCaches hook

    /// Bridge to views: a value stream that re-emits when any of `tags` is invalidated.
    public nonisolated func changes(matching tags: Set<InvalidationTag>) -> AsyncStream<Set<InvalidationTag>>
}

public enum ReadPolicy: Sendable { case staleWhileRevalidate, cacheOnly, mustRevalidate }

public struct Cached<V: Sendable>: Sendable {
    public let value: V
    public let fetchedAt: Date
    public let origin: Origin                 // .memory, .disk, .network
    public let isStale: Bool
    public let instance: InstanceID
    public enum Origin: String, Sendable { case memory, disk, network }
}
```

**Coalescing and cancellation (criterion 2, 10).** Each in-flight key holds a `Task` plus a waiter
count. `read` increments on entry and decrements in a `defer`. Cancelling one waiter throws
`CancellationError` out of *that* `await` only; the shared `Task` is cancelled exactly when the
count reaches zero, and the cancelled task writes nothing (the store commits only after a complete
decode). This is the behaviour that makes pull-to-refresh and overlapping refreshes safe.

**Live streams and optimistic pending.**

```swift
public struct Pending<Element: Sendable>: Sendable {
    public let token: UUID
    public let expiresAt: Date
    public let effect: OptimisticEffect
}

public actor LiveStream<Element: Sendable & Equatable> {
    public init(id: LiveStreamID, instance: InstanceID, freshness: FreshnessClass = .volatile,
                store: Store, clock: any Clock)

    /// Values with pending effects already applied, newest-wins.
    public nonisolated func values() -> AsyncStream<[Element]>
    /// The last value, synchronously — what a cold launch renders before any request.
    public nonisolated func last() -> [Element]

    public func ingest(_ elements: [Element], from origin: Cached<[Element]>.Origin) async
    public func apply(_ effect: OptimisticEffect, expiry: Duration = .seconds(30)) async -> Pending<Element>
    public func confirm(_ token: UUID) async
    /// Called on every ingest: drops effects the source now agrees with, and expired ones.
    public func reconcile() async
    /// One "last known" row per (instance, stream) in SQLite, for the cold start.
    public func checkpoint() async
}
```

The ghost-row rule that lives in `QueueViewModel.applyOverrides` today (a force-started item
vanishes from `/queue` for 10–15 s) moves here as `OptimisticEffect.keepAlive`, so it is tested
without a view model.

**Synchronous snapshot** — two consumers today (`MediaServerIndex.posterURL(for:)`,
`.isWatched(_:)`), both in view bodies:

```swift
/// Lock-guarded, not an actor: a SwiftUI body may not await. Rebuilt off the caller's
/// thread on invalidation; readers see (value, version) atomically.
public final class Snapshot<Projection: Sendable>: @unchecked Sendable {
    public init(tags: Set<InvalidationTag>, store: Store,
                build: @escaping @Sendable (Store) async -> Projection)
    public var current: (value: Projection, version: UInt64) { get }
    public func refreshIfNeeded()          // cheap: a version compare
}

public struct MediaServerProjection: Sendable {
    public func artwork(for identity: MediaIdentity) -> ArtworkReference?
    public func seasonArtwork(for identity: MediaIdentity, season: Int) -> ArtworkReference?
    public func isWatched(_ identity: MediaIdentity) -> Bool
    public var titleCount: Int { get }
}
```

### C.7 Events

```swift
public enum DataEvent: Sendable, Equatable {
    case queueChanged(InstanceID)
    case queueStatus(InstanceID, QueueStatusFacts)
    case fileImported(InstanceID, entity: Int?)
    case libraryChanged(InstanceID, kind: MediaKindID, entity: Int?)
    case commandFinished(InstanceID, name: String, succeeded: Bool)
    case progressTick(InstanceID)
    case connectivity(HostID, Governor.Health)
    case systemWoke(Date)
    case unknown(InstanceID, name: String, action: String)
}

public protocol EventSource: Sendable {
    var id: String { get }
    func events() -> AsyncStream<DataEvent>
    func start() async
    func stop() async
}

/// Servarr SignalR, ported off ArrCore types. Negotiate is POST /signalr/messages/negotiate
/// ?negotiateVersion=1 with X-Api-Key; the socket carries access_token in the query, which is
/// the one URL that must never be logged whole.
public actor SignalREventSource: EventSource { … }
public actor PollingEventSource: EventSource { … }   // download clients, 2 s floor
public struct WakeEventSource: EventSource { … }     // NSWorkspace/UIApplication signal injected by ArrCore

/// The single place an event becomes tags (criterion 4).
public enum EventTagMap {
    public static func tags(for event: DataEvent) -> Set<InvalidationTag>
}
```

Typed data-layer messages (verified to compile; `Subject` must be a **class**, see §G):

```swift
public final class MediaKitCenter: Sendable { public static let shared = MediaKitCenter() }

public struct DataDidInvalidate: NotificationCenter.AsyncMessage {
    public typealias Subject = MediaKitCenter
    public let instance: InstanceID
    public let tags: Set<InvalidationTag>
    public let reason: InvalidationReason
}
public struct InstanceConfigurationDidChange: NotificationCenter.AsyncMessage {
    public typealias Subject = MediaKitCenter
    public let instances: Set<InstanceID>
}
public struct ConnectivityDidChange: NotificationCenter.AsyncMessage {
    public typealias Subject = MediaKitCenter
    public let host: HostID
    public let health: Governor.Health
}
```

### C.8 Composition

```swift
/// Not Sendable, not an actor: one context serves one composition on one task. It records
/// what it read so the result carries provenance, the minimum freshness and the tag union.
public final class CompositionContext {
    public init(store: Store, crosswalk: IdentityCrosswalk, resolver: IdentityResolver,
                priority: RequestPriority)

    public func read<V>(_ r: Resource<V>, maxAge: Duration? = nil) async throws -> V
    public func readOptional<V>(_ r: Resource<V>, maxAge: Duration? = nil) async -> V?   // partials are normal
    public func readBatch<K, V>(_ b: BatchResource<K, V>, keys: [K]) async throws -> [K: V]
    public func live<E>(_ stream: LiveStream<E>) -> [E]      // never reads a volatile resource

    public private(set) var provenance: Provenance
}

public struct Provenance: Sendable, Equatable {
    public var tags: Set<InvalidationTag>
    public var oldestFetch: Date?
    public var usedNetwork: Bool
    public var degraded: [InstanceID: MediaKitError]   // which parts are missing and why
}

public struct Composed<Value: Sendable>: Sendable {
    public let value: Value
    public let provenance: Provenance
}

/// Memoised by the composition's own `Hashable` input value, in memory only, invalidated
/// by the recorded tag union, and re-emitting through `changes(matching:)`.
public actor Composer {
    public init(store: Store, crosswalk: IdentityCrosswalk, resolver: IdentityResolver)

    public func compose<Input: Hashable & Sendable, Value: Sendable>(
        _ input: Input,
        priority: RequestPriority = .interactive,
        _ body: @Sendable @escaping (Input, CompositionContext) async throws -> Value
    ) async throws -> Composed<Value>

    public nonisolated func stream<Input: Hashable & Sendable, Value: Sendable>(
        _ input: Input,
        _ body: @Sendable @escaping (Input, CompositionContext) async throws -> Value
    ) -> AsyncStream<Composed<Value>>
}
```

### C.9 Artwork and discovery

```swift
/// Replaces PosterStore's (url, tier, apiKey) entry points, MediaServerPosterAccess,
/// PosterTier.cdnVariant and TMDBClient.imageURL. The cache key never carries the token.
public struct ArtworkReference: Hashable, Sendable, Codable {
    public let url: URL                       // token-free, query-free where the source allows
    public let headers: [String: String]      // resolved per request by the caller, not stored
    public let cacheKey: String               // sha256(url + sizing), no credential material
    public let sizing: Sizing
    public enum Sizing: Hashable, Sendable, Codable { case asStored, longestEdge(Int) }

    /// Server-side resize: Plex /photo/:/transcode?width=&height=&url=, Jellyfin/Emby maxWidth=,
    /// TMDB path variant (w185/w780/original). Pure, testable, no singleton.
    public func sized(to sizing: Sizing) -> ArtworkReference
}

public struct DiscoveredServer: Hashable, Sendable {
    public let kind: ServiceKindID            // .plex, .jellyfin, .emby
    public let name: String
    public let endpoints: [URL]
    public let identifier: String?            // machineIdentifier / Id — never a token
}

public actor Discovery {
    public init(telemetry: Telemetry)
    /// Plex: NWBrowser bonjour(type: "_plexmediasvr._tcp", domain: nil).
    /// Jellyfin/Emby: UDP 7359 broadcast "who is JellyfinServer?" and parse the JSON reply.
    /// Results are suggestions for Settings; nothing is ever written to config by this type.
    public func scan(for kinds: Set<ServiceKindID>, timeout: Duration = .seconds(4)) async -> [DiscoveredServer]

    /// Pure parsers — what the offline tests exercise (criterion 25).
    public nonisolated static func parseBonjour(name: String, txt: [String: String],
                                                endpoint: NWEndpoint) -> DiscoveredServer?
    public nonisolated static func parseUDPReply(_ data: Data, from host: String) -> DiscoveredServer?
}
```

### C.10 The connection — one object ArrCore holds

```swift
/// Everything above, assembled. One per process role; the widget builds its own.
public final class MediaKitConnection: Sendable {
    public struct Configuration: Sendable {
        public var role: Role                    // .app, .widget, .tests
        public var databaseLocation: DatabaseLocation
        public var transport: any Transport
        public var credentials: any CredentialProvider
        public var clock: any Clock
        public var log: any LogSink
        public var limits: Governor.Limits
    }
    public init(_ configuration: Configuration) throws

    public let registry: InstanceRegistry
    public let store: Store
    public let composer: Composer
    public let crosswalk: IdentityCrosswalk
    public let capabilities: CapabilityIndex
    public let governor: Governor
    public let telemetry: Telemetry
    public let discovery: Discovery

    public func radarr(_ id: InstanceID) -> RadarrService
    public func sonarr(_ id: InstanceID) -> SonarrService
    public func lidarr(_ id: InstanceID) -> LidarrService
    public func whisparr(_ id: InstanceID) -> WhisparrService
    public func downloadClient(_ id: InstanceID) -> any DownloadService
    public func mediaServer(_ id: InstanceID) -> any MediaServerService
    public func tmdb(_ id: InstanceID) -> TMDBService

    public func queue(_ id: InstanceID) -> LiveStream<ArrQueueRow>
    public func progress(_ id: InstanceID) -> LiveStream<DownloadProgressRow>
    public func sessions(_ id: InstanceID) -> LiveStream<MediaServerSessionRow>

    public func start() async      // restore capabilities, checkpoints; start event sources
    public func stop() async
}
```

---

## D. SQLite

**Locations** (`DatabaseLocation` is injected; MediaKit never asks the OS which app it is in):

| Platform / role | Path |
|---|---|
| macOS app | `~/Library/Containers/pl.incred.ArrBarr/Data/Library/Application Support/MediaKit/mediakit.sqlite` (no app group on macOS, phase-0 H4) |
| iOS app + widget | `<group.pl.incred.ArrBarr>/Library/Application Support/MediaKit/mediakit.sqlite` |
| tests | a temp directory, or `:memory:` |

Application Support, never Caches: `cache_delete` takes a termination assertion to reclaim Caches
and that is what used to kill this app (`PosterStore` comment). The store is the offline render
path; it may not be reclaimable.

**Open flags and pragmas**

```sql
-- sqlite3_open_v2: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
--   | SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION   (iOS only; the constant
--     exists in the iOS SDK's sqlite3.h — verified — and applies to db, -wal and -shm together)
PRAGMA journal_mode = WAL;         -- app and widget open the same file
PRAGMA synchronous  = NORMAL;      -- WAL + NORMAL is crash-safe for a cache
PRAGMA foreign_keys = ON;
PRAGMA temp_store   = MEMORY;
PRAGMA busy_timeout = 5000;        -- also sqlite3_busy_timeout(db, 5000)
PRAGMA wal_autocheckpoint = 256;   -- ~1 MB, keeps the -wal small for the extension
```

**Schema (`user_version = 1`)**

```sql
CREATE TABLE entries (
    key          TEXT PRIMARY KEY NOT NULL,   -- ResourceKey.description, never a secret
    instance     TEXT NOT NULL,               -- "radarr#1"
    fingerprint  TEXT NOT NULL,               -- base|digest8
    class        TEXT NOT NULL,               -- FreshnessClass.rawValue, never 'volatile'
    payload      BLOB NOT NULL,               -- the decoded value, re-encoded as JSON
    fetched_at   REAL NOT NULL,
    stale_at     REAL NOT NULL,               -- invalidation SETS this to now; rows are not deleted
    last_used    REAL NOT NULL,
    bytes        INTEGER NOT NULL
) STRICT;
CREATE INDEX entries_instance     ON entries(instance);
CREATE INDEX entries_sweep        ON entries(class, last_used);
CREATE INDEX entries_fingerprint  ON entries(fingerprint);

CREATE TABLE entry_tags (
    tag       TEXT NOT NULL,
    entry_key TEXT NOT NULL REFERENCES entries(key) ON DELETE CASCADE,
    PRIMARY KEY (tag, entry_key)
) STRICT, WITHOUT ROWID;
CREATE INDEX entry_tags_entry ON entry_tags(entry_key);

-- Survives every cache wipe. "Delete and rebuild" is only ever allowed on entries/entry_tags.
CREATE TABLE capabilities (
    instance     TEXT PRIMARY KEY NOT NULL,
    fingerprint  TEXT NOT NULL,
    version      TEXT,
    capabilities TEXT NOT NULL,     -- sorted, space-separated Capability.rawValues
    probed_at    REAL NOT NULL,
    origin       TEXT NOT NULL
) STRICT;

CREATE TABLE crosswalk (
    from_ns    TEXT NOT NULL, from_value TEXT NOT NULL,
    to_ns      TEXT NOT NULL, to_value   TEXT NOT NULL,
    kind       TEXT NOT NULL,
    confidence INTEGER NOT NULL,
    source     TEXT NOT NULL,
    fetched_at REAL NOT NULL,
    PRIMARY KEY (from_ns, from_value, to_ns, kind)
) STRICT, WITHOUT ROWID;
CREATE INDEX crosswalk_reverse ON crosswalk(to_ns, to_value, kind);

-- One row per (instance, stream): the cold-start render (criterion 15).
CREATE TABLE last_known (
    instance   TEXT NOT NULL,
    stream     TEXT NOT NULL,          -- "queue" | "progress" | "sessions"
    payload    BLOB NOT NULL,
    captured_at REAL NOT NULL,
    PRIMARY KEY (instance, stream)
) STRICT, WITHOUT ROWID;

CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL) STRICT;
```

**Migrations.** `PRAGMA user_version` read at open. `0 → 1` creates everything. A future `n → n+1`
may `DROP`/recreate `entries` and `entry_tags` freely (they are a cache); `capabilities`,
`crosswalk` and `last_known` must be migrated, never dropped — they are what makes a cold,
offline launch and a probe-free start possible. An unknown (higher) `user_version` is not an error:
the store opens read-only for `capabilities`/`last_known` and skips the cache, so an older build
started by accident degrades instead of corrupting.

**Size cap.** `sweep()` runs at launch+15 min intervals and on `didEnterBackground`: delete rows
past `retention`, then, while `SUM(bytes) > diskBudget`, delete in `ORDER BY class DESC, last_used
ASC` batches of 200 (coldest class last — `frozen` crosswalk-feeding rows are the last to go),
then `PRAGMA incremental_vacuum` if `freelist_count` is large. `volatile` never reaches this code:
the memory tier is a separate dictionary and `Store.commit` refuses to bind a `volatile` payload
(criterion 6 is a `SELECT COUNT(*) FROM entries WHERE class='volatile'` after a read burst).

**Concurrency.** One `Store` actor owns one connection per process (`SQLITE_OPEN_NOMUTEX`, so
SQLite itself does no locking). The widget is a *different process* with its *own* connection —
that is what WAL and `busy_timeout` are for. All SQL runs in `@concurrent` functions off the
actor's executor; the actor serialises them.

---

## E. Service vocabularies

Notation: `tags produced` are attached to the cached value; `invalidates` is what a command
declares. Paths are taken from the golden corpus verbatim. `{apiBase}` is `/api/v3` (Radarr,
Sonarr, Whisparr v3) or `/api/v1` (Lidarr).

### E.1 Radarr (`RadarrService`) — instance `radarr#1`

| Resource / Command | Method + path | Query | Tags | Freshness |
|---|---|---|---|---|
| `systemStatus` | GET `{apiBase}/system/status` | — | `capability(i)` | live |
| `health` | GET `{apiBase}/health` | — | `collection(i,.health)` | live |
| `diskSpace` | GET `{apiBase}/diskspace` | — | `collection(i,.health)` | live |
| `queue` | GET `{apiBase}/queue` | `pageSize`, `includeUnknownMovieItems` | `collection(i,.queue)` | volatile |
| `movieFiles(ids:)` **batch** | GET `{apiBase}/moviefile` | `movieId` ×N (corpus shows 4 in one URL) | `entity(i,.movie,id)` ∀id | cold |
| `movie(id:)` | GET `{apiBase}/movie/{id}` | — | `entity(i,.movie,id)`, `identity(tmdb/imdb)` | cold |
| `allMovies` | GET `{apiBase}/movie` | — | `collection(i,.library)` | warm |
| `calendar(start:end:)` | GET `{apiBase}/calendar` | `start,end,unmonitored` | `collection(i,.calendar)` | warm |
| `history(page:)` | GET `{apiBase}/history` | `page,pageSize,sortKey,sortDirection,includeMovie` | `collection(i,.history)` | warm |
| `historyFor(movieIds:)` | GET `{apiBase}/history` | `+movieIds` | `entity(i,.movie,id)` | warm |
| `credits(movieId:)` | GET `{apiBase}/credit` | `movieId` | `entity(i,.movie,id)` | cold |
| `alternateTitles` | GET `{apiBase}/alttitle` | — | `collection(i,.library)` | frozen |
| `qualityProfiles` / `rootFolders` / `metadataProfiles` / `customFormats` / `downloadClients` | GET `{apiBase}/qualityprofile` \| `/rootfolder` \| `/metadataprofile` \| `/customformat` \| `/downloadclient` | — | `collection(i,.profiles)` | cold |
| `lookup(term:)` | GET `{apiBase}/movie/lookup` | `term` | `identity(…)` harvest only | live |
| `isSearchRunning` | GET `{apiBase}/command` | — | `collection(i,.commands)` | live |
| `releases(movieId:)` | GET `{apiBase}/release` | `movieId` | none (never cached) | volatile, 120 s timeout |
| **cmd** `searchMovie(ids:)` | POST `{apiBase}/command` `{name:"MoviesSearch",movieIds:[…]}` | | inv: `collection(i,.queue)`, `entity(i,.movie,id)` | tracks command id |
| **cmd** `setMonitored(id:_:)` | GET then PUT `{apiBase}/movie/{id}` | | inv: `entity(i,.movie,id)`, `collection(i,.library)` | typed RMW, see below |
| **cmd** `updateRecord(id:moveFiles:)` | GET + PUT `{apiBase}/movie/{id}?moveFiles=` | | same | typed RMW |
| **cmd** `addMovie(_:)` | POST `{apiBase}/movie` | | inv: `collection(i,.library)` | |
| **cmd** `deleteRecord(id:…)` | DELETE `{apiBase}/movie/{id}?deleteFiles&addImportExclusion&addImportListExclusion` | | inv: `collection(i,.library)`, `entity(…)` | |
| **cmd** `deleteQueueItem(id:…)` | DELETE `{apiBase}/queue/{id}?removeFromClient&blocklist` | | inv: `collection(i,.queue)` | |
| **cmd** `grabQueueItem(id:)` | POST `{apiBase}/queue/grab/{id}` `{}` | | inv: `collection(i,.queue)` | cap `arrQueueGrab` |
| **cmd** `grabRelease(guid:indexerId:)` | POST `{apiBase}/release` | | inv: `collection(i,.queue)` | |

**Typed read-modify-write.** The two `[String: Any]` paths (phase-0 fact 2) become
`ArrRecordEnvelope`: a `struct` holding the record's decoded *known* fields plus
`extra: [String: JSONValue]` for everything else, `Codable` both ways with key order preserved on
re-encode. `setMonitored` decodes, flips `monitored`, re-encodes — no `JSONSerialization`, no silent
rename escape (memory: "untyped JSON bodies escape renames").

### E.2 Sonarr — everything in E.1 with `series`/`episode` in place of `movie`, plus

| Resource / Command | Method + path | Tags | Notes |
|---|---|---|---|
| `episodes(seriesId:)` | GET `{apiBase}/episode?seriesId=` | `entity(i,.series,id)` | cold |
| `episodeFiles(seriesId:)` | GET `{apiBase}/episodefile?seriesId=` | `entity(i,.series,id)` | cold; per-series, not batchable |
| `queue` | GET `{apiBase}/queue?pageSize&includeEpisode` | `collection(i,.queue)` | volatile |
| `calendar` | GET `{apiBase}/calendar?start,end,unmonitored,includeSeries` | `collection(i,.calendar)` | warm |
| **cmd** `setSeasonMonitored` | **capability-gated**: `.sonarrSeasonEndpointV5` → PUT `/api/v5/series/{id}/season` `{seasonNumber,monitored}`; else the v3 path | inv: `entity(i,.series,id)` | see below |
| **cmd** `setEpisodesMonitored` | PUT `{apiBase}/episode/monitor` `{episodeIds,monitored}` | inv: `entity(i,.series,id)` | |
| **cmd** `searchSeason` / `searchEpisodes` / `searchSeries` | POST `{apiBase}/command` | inv: `collection(i,.queue)` | tracked |
| `realtime.negotiate` | POST `/signalr/messages/negotiate?negotiateVersion=1` | — | event source, not a resource |

**The v3 season fallback stays a double PUT, and is declared as such.** `SonarrService`
exposes `setSeasonMonitored` as one `Command` whose `request` builder asks
`CapabilityIndex.has(.sonarrSeasonEndpointV5, i)`. When the capability is absent, the command
becomes a three-step `CompositeCommand` (GET record → PUT with the *opposite* value → PUT with the
target value), because Sonarr only cascades `SetEpisodeMonitoredBySeason` on an actual transition.
The capability is probed once per fingerprint and cached; a 404/405 from v5 at *runtime* removes the
capability and re-runs the command on the v3 path, so an upgrade or downgrade of Sonarr costs one
wasted request, not one per toggle (criterion 11). `SonarrMonitorMode.apiValue` semantics
(`firstSeason`/`latestSeason`, memory rule) are preserved in `ArrAddOptions`.

### E.3 Lidarr

`artist` / `album` / `track` vocabulary on `/api/v1`. Resources: `allArtists`, `artist(id:)`,
`artistAlbums(artistId:)`, `album(id:)`, `tracks(albumId:)`, `trackFiles(albumId:)`,
`queue?includeUnknownArtistItems`, `calendar`, `history[?albumIds]`, `metadataProfiles`.
Commands: `setAlbumMonitored`, `setArtistMonitored` (typed RMW), `searchAlbum` (`AlbumSearch`),
`addArtist` (POST `/artist`), `addAlbum` (**GET `/api/v1/search?term=` then POST `/api/v1/album`**
— two steps, capability `.lidarrSearchLookup`, the one add flow with a lookup leg).
`trackFiles` has **no batch endpoint**: the batch resource declares `chunkSize: 1` and the
`Governor` caps it at 4 concurrent (today's `maxConcurrentSideLoads`), so criterion 17 is satisfied
by the limiter, not by a fake batch.

### E.4 Whisparr

v3 = Radarr's vocabulary with `InstanceID(kind: .whisparr)`, `movieCategory`, capability
`.whisparrMovieVocabulary`. v2 detection: `system.status.version` major `2` → capability
`.whisparrSeriesVocabulary` and **only** the Servarr-generic resources (`system/status`, `health`,
`diskspace`, `queue`, `calendar`, `history`) are offered; every movie-specific resource throws
`.unsupportedCapability`. This is the documented gap from decision Q3 and it fails *loudly at one
boundary* instead of 400-ing per call site. Fixtures are synthetic (`synthetic: true`).

### E.5 Download clients — sessions inside the transport contract

| Client | Reads | Writes | Session handling |
|---|---|---|---|
| qBittorrent | GET `/api/v2/app/version`, `/app/preferences`, `/torrents/info` | POST `/torrents/stop`, `/start`, `/delete`, `/setForceStart`, `/torrents/add` (multipart) | `.login` → one `POST /api/v2/auth/login` per launch, SID cookie in a private cookie jar, generation counter; `.bearer` (cap `qbittorrentAPIKeyAuth`) → no login. `Referer` on every request. `paused`+`stopped` both sent (cap `qbittorrentStoppedSpelling` decides nothing — both are always sent, as today). 409 on add → `commandRejected`; body `"Fails."` (exact, case-insensitive) → `contains(hash:)` probe then `commandRejected` |
| Transmission | POST `/transmission/rpc` `session-get`, `torrent-get` | `torrent-start/stop/remove/add` | 409 handshake at the header level: `X-Transmission-Session-Id` from the response, retry once. This is the only place `SessionAuthenticator.recover` reads a response *header* |
| Deluge | POST `/json` `daemon.info`, `core.get_torrents_status`, `core.get_config_value` | `core.pause_torrent/resume_torrent/remove_torrent/add_torrent_magnet/add_torrent_file`, `label.set_torrent` | `auth.login` once, session cookie, generation counter, re-login once on a `not authenticated` error object |
| rTorrent | POST `/RPC2` XML-RPC `system.client_version`, `d.multicall2` | `d.start`, `d.stop`, `d.erase`, `load.normal/start/raw/raw_start` | Basic auth header; no session |
| SABnzbd | GET `/api?mode=version|queue|history&output=json&apikey=` | `mode=queue&name=pause|resume|delete`, `mode=addfile` (multipart) | **apikey in the query** — one of the two documented exceptions; the key is stripped from every log line, fixture and telemetry row by `RequestBuilder.loggablePath` |
| NZBGet | POST `/jsonrpc` `version`, `listgroups`, `history`, `status` | `editqueue` (GroupPause/GroupResume/GroupDelete), `append` | Basic auth header |

All six expose the same `DownloadService` surface:

```swift
public protocol DownloadService: Sendable {
    var instance: InstanceID { get }
    func version() -> Resource<String>
    func progress(ids: Set<String>) -> Resource<[String: DownloadProgressRow]>
    func contains(hash: String) -> Resource<Bool>
    func defaultAddPaused() -> Resource<Bool?>
    func pause(_ ids: [String]) -> Command
    func resume(_ ids: [String]) -> Command
    func remove(_ ids: [String], deleteFiles: Bool) -> Command
    func forceStart(_ ids: [String]) -> Command      // qBittorrent only; else .unsupportedCapability
    func add(_ payload: DownloadPayload, category: String?, paused: Bool) -> Command
}
```

Progress is `volatile` and only ever reaches the UI through `LiveStream<DownloadProgressRow>`, whose
`PollingEventSource` holds today's 2 s TTL / 60 s max-age rule and the "some clients failed ≠ all
failed" distinction (phase-0 fact 15) as `LiveStream.ingest(partial:)`.

### E.6 Plex

| Resource / Command | Method + path | Tags | Freshness |
|---|---|---|---|
| `identity` | GET `/identity` | `capability(i)` | live |
| `libraries` | GET `/library/sections` | `collection(i,.library)` | warm |
| `items(sectionKey:)` | GET `/library/sections/{key}/all?includeGuids=1` | `collection(i,.library)` | warm |
| `sessions` | GET `/status/sessions` | — | volatile |
| `watchHistory(limit:)` | GET `/status/sessions/history/all?sort&X-Plex-Container-Start&X-Plex-Container-Size` | `collection(i,.history)` | warm |
| `seasonImages(itemId:)` | GET `/library/metadata/{id}/children` | `entity(i,.series,…)` | cold |
| **cmd** `scan(sectionId:)` | GET `/library/sections/{id}/refresh` | inv: `collection(i,.library)` | |
| **cmd** `emptyTrash(sectionId:)` | PUT `/library/sections/{id}/emptyTrash` | inv: `collection(i,.library)` | Plex only |

Headers: `X-Plex-Token` + `Accept: application/json` (Plex answers XML otherwise). Guid parsing
harvests crosswalks at `.asserted` confidence — this is the single biggest source of identity in
the app and the reason `libraryIndex` is a `harvest`ing resource rather than a snapshot type.
Jellyfin/Emby share one service (`/System/Info`, `/Users`, `/Users/{id}/Items`, `/Sessions`,
`/Shows/{id}/Seasons`, `/Library/VirtualFolders`, `POST /Items/{id}/Refresh`) and differ only in
the auth header (`Authorization: MediaBrowser Token="…"` vs `X-Emby-Token`) — phase-0 H16 notes the
spike and ArrCore disagree here; the design follows **ArrCore** (bare `X-Emby-Token` for Emby) and
flags it in §J.

### E.7 TMDB

20 GET resources from the corpus (`/3/configuration`, `/3/search/person`, `/3/movie/{id}`,
`/3/movie/{id}/credits|videos|similar|recommendations`, `/3/tv/{id}`,
`/3/tv/{id}/aggregate_credits|videos|similar|recommendations|external_ids`, `/3/find/{id}
?external_source=tvdb_id`, `/3/person/{id}[/movie_credits|/tv_credits]`, `/3/discover/movie|tv`).
Auth: v4 read-access token → `Authorization: Bearer` (what the corpus shows); a 32-char v3 key →
`api_key` in the query, the second documented exception. Everything is `frozen` except `discover`
(`warm`) — TMDB facts do not move. `external_ids` and `find` carry `harvest` closures, so every
TMDB round trip pays for itself by filling the crosswalk.

---

## F. Six flows

### F1. Cold launch, off the LAN

1. `AppDelegate` builds `MediaKitConnection(.app)`. `Store.init` opens SQLite (WAL,
   `busy_timeout`), reads `user_version`, and loads `capabilities` + `last_known` **synchronously**
   — three small `SELECT`s, no network, no actor hop for the caller because they happen in `init`.
2. `connection.start()` → `CapabilityProbe.restore()` populates `CapabilityIndex` from the
   `capabilities` table (`origin == .restored`).
3. The popover's queue view reads `connection.queue(radarr).last()` — a **synchronous** array from
   the `last_known` row. Upcoming and library come from
   `store.read(radarr.calendar(…), policy: .cacheOnly)` / `allMovies` — hits on `entries`,
   `origin == .disk`, `isStale == true`. **Zero requests so far.**
4. Views render. In parallel `Composer.stream` kicks off the real refresh; the first request per
   host reaches `Governor.run`, the connection fails with `.unreachable(host, .offline)`, and after
   the 4th failure the breaker is `down(until:)`. Subsequent reads short-circuit to the stale rows
   and never produce a `MediaKitError` the UI shows: ArrCore's offline chip is driven by
   `governor.health(host)` (memory: "offline UX must be subtle").
5. `ConnectivityDidChange` is posted once per host, not per request.
   Telemetry records `skipped(breakerOpen)` — visible in the report, invisible in the UI.

### F2. DetailView for a movie, opened twice inside the freshness window

First open (`input = DetailInput(identity:, instance:)`):

```swift
let composed = try await composer.compose(input) { input, ctx in
    let movie   = try await ctx.read(radarr.movie(id))                    // network, cold
    let files   = try await ctx.readBatch(radarr.movieFiles, keys: [id])  // network
    let credits = await ctx.readOptional(radarr.credits(movieId: id))     // network
    let profiles = await ctx.readOptional(radarr.qualityProfiles)         // disk hit (cold, 6 h)
    let history = await ctx.readOptional(radarr.historyFor(movieIds: [id]))
    let tmdbID  = await ctx.crosswalk.known(.arr(i, id), in: .tmdbMovie)  // no request
    let videos  = tmdbID.flatMap { await ctx.readOptional(tmdb.movieVideos($0)) }
    return MovieDetailFacts(...)
}
```

Baseline says 7 requests; this issues **5** (profiles and the TMDB id come from disk/crosswalk).
Second open within 6 h: every `read` is a fresh hit in the memory tier, `Composer` returns the
memoised `Composed` value for the same `Hashable` input, and the request count is **0**
(criterion 1). A 20-card grid of the same screen batches `movieFiles` into ⌈20/40⌉ = 1 request
(criterion 17).

### F3. Pause a download

1. `queueVM.pause(item)` → `gateway.pause(item)` → `store.run(qbittorrent.pause([hash]))`.
2. Before the request, the command's `optimistic` effect is applied to
   `connection.queue(instance)` and `connection.progress(instance)`:
   `LiveStream.apply(.status(.paused), expiry: .seconds(30))` returns a `Pending` token. The stream
   re-emits immediately with the row marked paused. **Nothing is written to the store** — the
   optimistic value can never outlive the process or reach SQLite.
3. The request goes out (`priority: .interactive`, `idempotent: false`, so no retry).
4. On 2xx the command's `invalidates` (`collection(i,.queue)`) is applied: matching `entries` rows
   get `stale_at = now`, `DataDidInvalidate` is posted, the polling event source's next tick (≤ 2 s)
   re-reads the queue.
5. `LiveStream.reconcile()` drops the pending effect as soon as an ingested row agrees, or at the
   30 s expiry — whichever comes first. A rejection (`commandRejected`) drops it at once and the
   error goes to the caller; the breaker is **not** tripped, because a reachable client refusing one
   request is not a down client (the exact bug the current `actionFailureProvesClientDown` guards).

### F4. SignalR queue event → view

`SignalREventSource` parses the frame (`type 1`, `arguments[0].name` lowercased,
`action` inside `arguments[0].body`) → `DataEvent.queueChanged(sonarr#1)`.
`EventTagMap.tags(for:)` returns exactly `{collection(sonarr#1, .queue)}` — and for
`moviefile|episodefile|trackfile` exactly `{collection(i,.queue), collection(i,.library),
entity(i, kind, id?)}`. `Store.invalidate(tags:)` marks those rows stale, bumps the versions of any
`Snapshot` watching them and yields from `changes(matching:)`. ArrCore's view model wraps that in
`Observations { … }` so the SwiftUI body re-runs. The 0.25 s burst coalescing and the 1 s/30 s
floors stay in ArrCore (phase-0 fact 7) — MediaKit emits raw events; a data layer that decides how
often a popover may redraw is a data layer that has learned about popovers. Criterion 4's test
feeds recorded frames and asserts the tag set is exactly that, with nothing else invalidated.

### F5. Widget timeline

1. `TimelineProvider` builds `MediaKitConnection(.widget)`: same group-container DB path, its own
   connection, `Governor.Limits(maxConcurrent: [.background: 2])`, all reads `.background`.
2. `store.read(radarr.allMovies, policy: .cacheOnly)` and `queue(i).last()` render the entry
   **immediately** from the shared SQLite — the timeline is never blocked on the network.
3. If the row's `fetchedAt` is older than the widget's refresh budget (30 min), one
   `.staleWhileRevalidate` read per configured service goes out, writes back into the same tables,
   and a second timeline entry is emitted. WAL + `busy_timeout(5000)` is what makes the concurrent
   app write safe; the widget writes only `entries`/`entry_tags`/`last_known`.
4. `LibrarySummaryService` and `UpcomingService` disappear; the widget's `curate` logic moves into
   the widget target where it belongs. `WidgetDataStore.isDemoActive` selects `FixtureTransport`
   exactly as the app does — one demo mechanism, two processes (criteria 14 and 16).

### F6. Capability probe

- **Sonarr without v5.** `ensure(sonarr#1)` reads `GET /api/v3/system/status` once per fingerprint.
  Version major ≥ 5 ⇒ `.sonarrSeasonEndpointV5` present. Version below ⇒ absent, and
  `setSeasonMonitored` builds the v3 composite with no error and no wasted v5 attempt. If the probe
  said "v5" and the server answers 404/405 anyway (reverse proxy, beta), the command catches exactly
  those two statuses once, removes the capability, persists, and retries on v3 — the runtime
  fallback survives as a *correction to the probe*, not as the primary mechanism.
- **Whisparr v2 vs v3.** Same status read; `version` major 2 ⇒ `.whisparrSeriesVocabulary`,
  3 ⇒ `.whisparrMovieVocabulary`. Ambiguous or missing version ⇒ conservative default =
  the Servarr-generic set only.
- **Probe failure.** `ensure` returns, in order: the row in `capabilities` for this fingerprint
  (`origin: .restored`), else `conservativeDefault(for:)` (`origin: .conservativeDefault`).
  It never throws and never reaches the UI. The next successful `systemStatus` read (which is a
  normal `live` resource on the health path) re-arms the probe; a changed `version` string
  invalidates the row even when the fingerprint did not change.

---

## G. Concurrency and isolation

**Actors and why.** `Store` (one SQLite connection + the coalescing table — both are
single-writer state), `Governor` (per-host counters, breaker states, token buckets),
`InstanceRegistry` (fingerprints), `IdentityCrosswalk` (batched upserts), `CapabilityProbe`
(one probe per fingerprint), `LiveStream` (last value + pending effects), `Composer` (memo table),
`FixtureTransport` and `SessionAuth` (session cookies, generation counters), `Discovery`
(NWBrowser callbacks funnelled into one place), `SignalREventSource`/`PollingEventSource`.
Eleven actor types — against 55 actor declarations in today's ArrCore.

**Nonisolated.** Every value type: `MediaID`, `MediaIdentity`, `Resource`, `Command`,
`ResourceKey`, `InvalidationTag`, `HTTPRequest/Response`, every wire model, every parser
(`ExternalIDParsing`, `Discovery.parseBonjour/parseUDPReply`, `EventTagMap.tags(for:)`,
`RequestBuilder`), `URLSessionTransport`. Two classes are `@unchecked Sendable` with an `NSLock`
rather than actors, for one stated reason each: `CapabilityIndex` (an endpoint choice must not
await) and `Snapshot` (a SwiftUI body must not await) — the same justification `MediaServerIndex`
carries today, now applied to exactly two types instead of leaking into a dozen call sites.

**What `NonisolatedNonsendingByDefault` changes (SE-0461).** Without it, a `nonisolated async func`
hops to the generic executor; with it, it runs **on the caller's actor** and does not hop. That is
what makes `CompositionContext.read` cheap from ArrCore's `@MainActor` (it stays on the main actor
until it hits `Store`, which is a real actor and does hop) and it is why `@concurrent` is spelled
explicitly on the three places that genuinely want a different executor:

```swift
@concurrent func decode<V: Decodable>(_ bytes: HTTPResponseBytes, as: V.Type) throws -> V
@concurrent func commit(_ rows: [EntryRow]) throws        // SQLite writes
@concurrent func rebuild(_ projection: …) -> Projection    // Snapshot rebuild
```

JSON decoding a 7 MB Plex library and a 1.5 MB Lidarr queue are the two measured hot spots; both
are `@concurrent`.

**Codable models stay Sendable** because they are `struct`s of value types with no reference
members; `JSONValue` (the `extra` bag in `ArrRecordEnvelope`) is an `indirect enum` over
`String/Double/Bool/[JSONValue]/[String: JSONValue]/null`, which is `Sendable` by construction.
`InferIsolatedConformances` (SE-0470) is deliberately **not** relied on inside MediaKit — nothing
here is globally isolated, so there is nothing to infer; it matters in ArrCore once
`defaultIsolation(MainActor.self)` lands in phase 5 (it is what stops `ArrCredit`'s
`Decodable` conformance from erroring, which is the single error phase 0 measured).

**Verified by compilation** (scratch package, tools 6.2, `.macOS(.v26)`, `defaultIsolation(nil)`,
both upcoming features, SDK 27, zero warnings):

- `Observations.init(_ emit: @escaping @isolated(any) @Sendable () throws(Failure) -> Element)`
  — documented signature. Because the closure is `@Sendable`, **a plain non-Sendable `@Observable`
  class cannot be observed from a nonisolated package**: the probe failed with
  *"capture of 'box' with non-Sendable type 'Box' in a '@Sendable' closure"*. Two shapes do compile
  and both are used: (a) a `@MainActor @Observable` class observed from a `@MainActor` function —
  ArrCore's view models; (b) an `@Observable` class that is `@unchecked Sendable` with lock-guarded
  storage and hand-written `access`/`withMutation` accessors — MediaKit's one observable type,
  `ObservableVersionCounter`, which is what `Store.changes(matching:)` and `Snapshot` feed.
- Typed `NotificationCenter` messages compile, **but `Subject` must be a class**: with
  `typealias Subject = Never` the compiler rejects `messages(of:for:bufferSize:)` with
  *"requires that 'DataDidInvalidate.Subject' (aka 'Never') be a class type"*. Hence the
  `MediaKitCenter` singleton subject. `post(_:subject:)`, `addObserver(of:for:using:)` and
  `messages(of:for:bufferSize:)` all compile against it.
- `import SQLite3` with zero dependencies, `sqlite3_open_v2`, `sqlite3_busy_timeout`,
  `sqlite3_exec`, `sqlite3_prepare_v2`, `sqlite3_bind_text` with
  `unsafeBitCast(-1, to: sqlite3_destructor_type.self)` (the `SQLITE_TRANSIENT` macro is not
  exposed to Swift) — compiles. SDK SQLite is **3.54.0**, so `STRICT` tables (3.37+) and
  `WITHOUT ROWID` are available.
- `@concurrent func` on a nonisolated async function — compiles.
- `withTaskCancellationHandler { … } onCancel: { task.cancel() }` around a
  `withCheckedThrowingContinuation`-wrapped `URLSessionDataTask` — compiles, and is used instead of
  `session.data(for:)` precisely because the async method's behaviour under `Task` cancellation is
  not stated in the documentation (§J, open question 3). `URLSessionTask.cancel()` is documented to
  produce `NSURLErrorCancelled`, which the transport maps to `MediaKitError.cancelled`.

**Cancellation through coalescing.** `Store.read` registers a waiter, then
`await inflight.value`. Cancelling the outer `Task` throws `CancellationError` at that `await`; the
`defer` decrements the waiter count; when it reaches zero the shared `Task` is cancelled, which
cancels the `URLSessionDataTask` through the handler above. A cancelled fetch never calls
`commit`, so no partial row exists (criteria 2 and 10).

---

## H. Tests

Fixture transport matching, in order (first match wins, and a miss is
`MediaKitError.fixtureMissing(operation)` — never a silent empty result):

1. `request.operation` ⟷ the sidecar's `operation` field (`radarr.fetchQueue` ⟷ `fetchQueue`),
   scoped by the fixture directory = `instance.kind`.
2. `request.rpcMethod` ⟷ the recorded body's method name (`core.get_torrents_status`,
   `torrent-get`, `listgroups`, `d.multicall2`) — this is how six calls sharing `/json` are told apart.
3. `method` + `pathTemplate` ⟷ the sidecar's `request_path` (`{id}` matches one segment).
4. Query discriminator for SABnzbd (`mode=`) and TMDB `find` (`external_source=`).
5. Demo overlays: the `DemoWorld` applies recorded mutations (monitor flags, queue statuses, added
   titles) to the decoded fixture before returning it, so demo pause/resume/add behave. Overlays are
   JSON rules plus a ~60-line interpreter; **`grep DemoMode Packages/MediaKit` returns zero**
   (criterion 14).

`RecordingTransport` (test-support target) holds `AllowList.section5` as a `[AllowedOperation]`
table of `(ServiceKindID, HTTPMethod, pathTemplate, rpcMethod?)` built literally from prompt
section 5, plus a `deny` list for `GET /release` and every write. `send` checks the table **before**
delegating and throws `AllowListViolation` otherwise; the scrubber strips credential headers,
`apikey`/`api_key`/`access_token` query values and hostnames before writing the fixture. Its own
test asserts that `GET /release`, every `POST/PUT/DELETE`, and an unlisted RPC method are all
rejected without a socket.

| # | Criterion | Test file · test | Fixture / transport |
|---|---|---|---|
| 1 | Second read inside freshness = 0 requests | `StoreFreshnessTests.readTwiceInsideTTLIssuesOneRequest` | counting `FixtureTransport` |
| 2 | Two parallel reads = 1 request; one cancel doesn't kill the other | `StoreCoalescingTests.parallelReadsShareOneRequest`, `.cancellingOneWaiterKeepsTheOther` | delaying fixture |
| 3 | Command's tags force the next read to the network | `StoreCommandTests.commandInvalidatesDeclaredTags` + `RadarrCommandTests.setMonitoredInvalidatesEntity` | radarr fixtures |
| 4 | SignalR event invalidates only its tags | `EventTagMapTests.queueFrameInvalidatesOnlyQueue`, `.fileImportedFrameInvalidatesQueueAndLibrary` | recorded frames (ported from the existing frame tests) |
| 5 | URL change or key rotation invalidates instantly | `InstanceRegistryTests.sameURLRotatedKeyChangesFingerprint`, `.reconcileInvalidatesChangedInstance` | none (pure) |
| 6 | Volatile never on disk | `StorePersistenceTests.volatileClassNeverReachesSQLite` | temp DB + read burst |
| 7 | 429 blocks one host until Retry-After | `GovernorTests.rateLimitedHostIsBlockedOthersRun` | fake clock |
| 8 | Per-host concurrency under 100 reads | `GovernorTests.concurrencyLimitRespected(limit:)` (parameterised) | fixture with a barrier |
| 9 | Breaker opens / serves stale / half-opens | `GovernorTests.breakerOpensAfterFailures`, `StoreOfflineTests.openBreakerServesStaleWithoutRequest` | failing fixture |
| 10 | Cancel cancels the last waiter, stores nothing | `TransportCancellationTests.cancelPropagatesAndStoresNothing` | delaying fixture |
| 11 | Probe once per fingerprint; v5→v3; Whisparr v2/v3; failure → last/default | `CapabilityProbeTests` ×5 (`probesOncePerFingerprint`, `restoresFromDiskAfterRelaunch`, `sonarrWithoutV5UsesV3Path`, `whisparrVersionSelectsVocabulary`, `probeFailureFallsBackConservatively`) | `*/testconnection.json` + synthetic whisparr |
| 12 | No secret in key/log/telemetry/fixture | `SecretHygieneTests.scanFourSources` | repo scan + in-process capture |
| 13 | Every error case has a catalog key | `ArrCoreTests/MediaKitErrorPresenterTests.everyCaseHasAKey` (exhaustive switch, no `default`) + `Tools/loc/lint_missing_keys.py` | none |
| 14 | Demo only through FixtureTransport | `DemoWorldTests.pauseResumeAddRoundTrip` + `grep -r DemoMode Packages/MediaKit` = 0 | fixtures |
| 15 | Cold start renders from SQLite before the first request | `ColdStartTests.rendersLastKnownBeforeAnyRequest` | seeded temp DB + counting/delaying fixture |
| 16 | Widget builds, links MediaKit, shares SQLite | `xcodebuild -scheme ArrBarrWidgets` + `WidgetSnapshotTests.readsGroupContainerSnapshot` + grep for ArrCore clients = 0 | group-container temp DB |
| 17 | 20 cards don't scale requests | `CompositionBatchTests.twentyCardsIssueOneBatchRequest` | radarr `fetchQueue-api-v3-moviefile` fixture |
| 18 | No client construction in Views/ViewModels | `Tools/grep` gate in the phase-5 report | — |
| 19 | 28 tools on fixtures, list unchanged | `ArrCoreTests/LocalToolBackendFixtureTests` (one case per tool) + `ChatToolCatalogTests.catalogIsUnchanged` | full fixture bundle |
| 20 | Three green `swift test`, three green schemes, zero MediaKit warnings | verifier: `swift test` ×3, `BuildProject` + `GetBuildLog` severity filter | — |
| 21 | Telemetry report per host | `TelemetryReportTests.reportCountsEveryEventKind` | in-memory sink |
| 22 | No `#available(macOS 26…)` outside TonightCore | grep gate, phase 3 | — |
| 23 | Data-layer events are typed messages | `MessagesTests.invalidationPostsTypedMessage` + grep gate | — |
| 24 | ArrCore `defaultIsolation(MainActor)`, MediaKit `nil` | build of both packages, end of phase 5 | — |
| 25 | Discovery from Bonjour/UDP fixtures, no network | `DiscoveryParserTests.parsesPlexBonjourRecord`, `.parsesJellyfinUDPReply`, `.rejectsGarbage` | captured payloads in `Fixtures/discovery/` |
| 26 | Golden-corpus parity | `GoldenParityTests.everyOperationMatchesTheCorpus` — builds each declared `Resource`/`Command` request and diffs method, path template, sorted query keys, header names and body against the 181 entries | corpus JSON |
| 27 | Counters/timings not worse than baseline | phase-6 report from `Telemetry.report()` + `GetConsoleOutput` | — |
| 28 | Phase-7 Spotlight/FM work | phase-7 tests | — |

Criterion 26 deserves its own note: `GoldenParityTests` is the reason `HTTPRequest` carries
`pathTemplate` and `operation` as first-class fields. The test is a pure function over declared
resources — no transport, no fixtures — so it runs in milliseconds and catches a renamed query key
the day it is written. Documented exceptions (`fetchQueue`'s repeated `movieId`, which the corpus
records as `movieId,movieId,movieId,movieId`) are a small allow-list in the test.

---

## I. Migration seam

One gateway in ArrCore, built once, owned by nobody else:

```swift
// ArrCore/Services/ServiceGateway.swift  (phase 5, ~260 lines)
@MainActor
public final class ServiceGateway {
    public static let shared = ServiceGateway()

    public private(set) var connection: MediaKitConnection

    /// The ONLY place a MediaKit instance is constructed. Called once from AppDelegate /
    /// iOSAppRoot / the widget's provider with the role it needs.
    public static func make(role: MediaKitConnection.Role, configStore: ConfigStore) -> ServiceGateway

    /// ConfigStore → InstanceRegistry. One subscription replaces the five 1.5 s Combine
    /// debounce pipelines in QueueViewModel; the debounce moves here.
    public func bind(_ configStore: ConfigStore)

    // Domain compositions — the only API Views and ViewModels see.
    public func queueRows() -> AsyncStream<[QueueItem]>
    public func upcoming() async -> Composed<[UpcomingItem]>
    public func history(source:page:entityId:) async -> Composed<HistoryPage>
    public func detail(_ identity: MediaIdentity) async -> Composed<DetailFacts>
    public func library(_ kind: MediaKindID) async -> Composed<LibrarySnapshot>
    public func pause(_ item: QueueItem) async throws
    // …
}
```

- **ConfigStore → InstanceRegistry.** `ServiceConfig` (46 `@Published`) is translated once into
  `[InstanceDescriptor]` + a `CredentialProvider` that reads the keychain/group suite on demand.
  MediaKit never sees `ServiceConfig`, `ServiceKind` or `DemoMode`.
- **Demo becomes a transport choice.** `ServiceGateway.make` picks `FixtureTransport` when
  `DemoMode.isActive`, `URLSessionTransport` otherwise. The 46 demo branches in six clients, plus
  `DemoMocks`/`DemoMonitorState`/`DemoQueueState`, are deleted; the 22 branches in Views/ViewModels
  shrink to the one badge check `DemoMode.isActive` the prompt allows.
- **PosterStore consumes `ArtworkReference`.** `image(for:tier:apiKey:)` becomes
  `image(_ reference: ArtworkReference, tier:)`; `PosterTier` maps to `ArtworkReference.Sizing`,
  and `MediaServerPosterAccess` + `TMDBClient.imageURL` + `PosterTier.cdnVariant` are deleted.
  The byte cache, the three tiers, the Application-Support-vs-Caches rule and the SHA-256 key all
  stay exactly as they are — `PosterStore` keeps owning bytes, MediaKit owns *which* bytes.
- **The 28 tools.** `LocalToolBackend` (8 files, 3,041 lines) keeps its shape and swaps its
  dependencies: every `XClient(config:)` becomes a `ServiceGateway` call. The five duplicated
  `ServiceKind → client` switches collapse into `gateway.service(for: source)`. `ArrMCPServer` needs
  no change at all — it reaches the tools through `ToolCatalogBridge`/`MCPCallRouter` (123 lines,
  zero client construction).
- **DetailView's 17 sites** become one `@State var facts: Composed<DetailFacts>?` fed by
  `gateway.detail(identity)`; `UpcomingRowView`, `LibraryTabContent` and `SettingsView` lose their
  in-body client construction to the same compositions. `MediaServerIndex` is replaced by
  `Snapshot<MediaServerProjection>`, keeping both synchronous view-body reads.
- **The widget** builds its own `ServiceGateway(role: .widget)` against the group-container DB; it
  no longer links `LibrarySummaryService`/`UpcomingService` (both deleted).
- **Errors.** One `MediaKitErrorPresenter` in ArrCore with an exhaustive `switch` over the 16 cases
  → catalog keys, plus `ServiceMessage.text` appended verbatim (the *arr's* own reason, which is
  where the useful message lives).

---

## J. Risks, open questions, dropped ideas

### Risks

1. **The 8,590-line budget has 60 lines of slack.** The three cuts in §B are load-bearing; if the
   fixture-overlay interpreter grows into a demo engine, the budget goes. Mitigation: a
   `Tools/mediakit/loc_gate.py` in CI-less form, run by each phase's integrator.
2. **SQLite from two processes.** WAL + `busy_timeout` is the right answer, but an iOS extension
   killed mid-write leaves a `-wal` the app must recover. Mitigation: `wal_autocheckpoint = 256`,
   and the widget only ever writes in one short transaction per timeline.
3. **Plex's 7 MB library payload** decoded on every warm refresh. Mitigation: `@concurrent` decode,
   `warm` class, and a `harvest`-only decode path that extracts guids without materialising the
   full metadata objects.
4. **Whisparr is test-proven only** (decision Q3). A v2 instance would likely reveal that the
   generic Servarr resources differ more than assumed.
5. **Optimistic effects live only in `LiveStream`.** If a future screen expects an optimistic value
   from `Store.read`, it will not find one. That is intentional and must be said out loud in the spec.

### Open questions (each with a recommendation)

1. **CryptoKit.** Section 1.2's allow-list does not name it, so the design ships a 60-line SHA-256.
   *Recommendation: allow CryptoKit* (it is a system framework with no package dependency) and
   delete those 60 lines; otherwise keep the local implementation and cover it with NIST vectors.
2. **Emby's auth header.** ArrCore sends bare `X-Emby-Token`; the MediaKit spike sends Jellyfin's
   `Authorization: MediaBrowser Token="…"` (phase-0 H16). No Emby instance exists to test.
   *Recommendation: send `X-Emby-Token` (today's behaviour, the one that has shipped) and add
   `Authorization` as a fallback on 401.*
3. **`URLSession.data(for:)` under `Task` cancellation.** The documentation for the async method
   does not state that it cancels the underlying task. *Recommendation (already in the design):
   don't rely on it — wrap `URLSessionDataTask` in `withTaskCancellationHandler`, whose
   `URLSessionTask.cancel()` → `NSURLErrorCancelled` behaviour **is** documented.*
4. **UDP 7359 discovery on iOS.** Broadcast/multicast may require
   `com.apple.developer.networking.multicast`, which needs an Apple-granted entitlement, and the
   OSS macOS build is ad-hoc signed. Not confirmable from documentation.
   *Recommendation: ship Bonjour (`_plexmediasvr._tcp`, plus `_jellyfin._tcp` where advertised) on
   both platforms, make the UDP probe macOS-only, and keep the parsers platform-independent so
   criterion 25's tests pass either way.*
5. **`NSBonjourServices` / `NSLocalNetworkUsageDescription`.** Both are required Info.plist keys for
   `NWBrowser` (documented under NWBrowser's Essentials). They are a project-file change in phase 3.
   *Recommendation: add them in the same commit as the floor raise, via `AddInfoPlist`.*
6. **Whisparr v2/v3 discriminator.** Version major is the only signal available without a library
   request. *Recommendation: version major, with `appName`/`instanceName` as a tiebreak, and a
   documented "unknown ⇒ generic-only" branch.*
7. **`RecordingTransport` in a test-support target.** Section 5 says the allow-list lives in
   `RecordingTransport`'s code; it does — just not in the shipping library.
   *Recommendation: accept; it strictly reduces what a release binary can do.*
8. **Second instance per kind.** The schema is keyed by `InstanceID` from day one (Q5), but the UI,
   `ConfigStore` and the gateway expose one. *Recommendation: keep `ordinal` fixed at 1 in phase 5
   and do not build UI for it.*

### Prompt-section-3 ideas dropped, one line each

- **`ConnectionHealthMonitor` / `ServerStatusModel` as separate types** — the breaker is the single
  source of truth; both become reads of `Governor.health(_:)`.
- **A separate `Retry` and `Breaker` type** — merged into `Governor`, because all three decisions
  are keyed by host and splitting them means three types disagreeing about one host's state.
- **A separate `StoreSchema` file** — the DDL is 40 lines and belongs next to the code that runs it.
- **`ProviderHealth`, `BatchMediaProvider`, `MediaGraph`, `MediaFieldSet`, per-field provider cost
  and precedence (spike)** — dropped. Per-field precedence is what produced the spike's `.title`
  field that "glues five facts together"; resources in the service's own vocabulary plus a
  composition that picks fields explicitly is smaller and legible.
- **`FragmentCache` (spike)** — replaced by `Store`, which has the same coalescing and adds
  persistence, tags and a size cap.
- **`MediaTelemetry` (spike)** — kept as an idea, rewritten: events are an enum, counters are per
  host **and** per resource, and the report is text without secrets.
- **Catalog intents (spike)** — out of scope; `DiscoverViewModel`'s TMDB/library sources have no
  call site today (phase-0 §3.3) and should not be resurrected by this rewrite.
- **A generic `MediaProvider` protocol across services** — dropped; the four families have
  genuinely different vocabularies, and a protocol wide enough for all of them is a protocol that
  says nothing.
- **Optimistic writes into the store** — dropped explicitly (prompt section 3 already forbids it);
  optimism lives in `LiveStream` and expires.
