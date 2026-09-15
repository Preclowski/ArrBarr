# MediaKit foundation design

Phase 1 synthesis. Branch `feat/mediakit-foundation`. Inputs: the three architect designs
(cache-first = CF, transport-first = TF, model-first = MF), the two critiques (call sites; lean
Swift 6.2), the rewrite prompt (sections 0–6a), the phase-0 report, the golden corpus
(`docs/superpowers/baseline/2026-09-15-golden-requests.json`, 181 rows) and the fixture bundle
(`Packages/MediaKit/Fixtures`, 218 files). Phase 2 plans from this document; phases 3–5 implement
it. Every type below is a real declaration; prose only says why.

**Winner.** Transport-first is the base. The call-site critic showed that the two designs it beat
cannot carry consumers that exist today: multi-request writes (`SonarrClient.setSeasonMonitored`,
`SearchViewModel.addAlbum`, the typed read-modify-write PUTs) and SignalR inside the injected
transport (`RealtimeUpdates`, the demo, telemetry of negotiate). Those are structural — CF's single
`RequestPlan` command and CF/MF's `send`-only `Transport` need a different shape, not a patch. The
lean critic preferred CF because TF's declared code does not compile in two places (`borrowing`
`~Copyable` context, nonisolated `@Observable` revision) and carries four actors and five policy
structs; every one of those objections is local and is fixed below by taking the lean critic's own
grafts (lock-guarded context, `ObservableVersionCounter`, one governor actor, one session actor,
merged policies). CF's store ideas — `ReadPolicy`, `BatchResource`, `Command.tracking`, the
serial-executor database, `HeaderRef.credential` — and MF's verified isolation facts,
synchronous `CapabilityIndex`, crosswalk `harvest`, `Governor.note(wake:)`, `last()` and
`Role`-based assembly are grafted onto the TF spine. Where the critics contradicted each other
(bytes-on-disk vs re-encoded payloads) the decision and its reason are in §4.3.

---

## 1. Goals and measures

From prompt section 0, with the phase-0 baseline (report §3).

| # | Goal | Measure | Baseline (phase 0) | Proof |
|---|---|---|---|---|
| 1 | Offline-first | after a relaunch with the network blocked, the popover and the library render from SQLite before the first request; an unreachable host produces no error UI | not measurable today (no instrumentation, H19) | `ColdStartTests.popoverDataAvailableBeforeFirstRequest`; phase-6 `GetConsoleOutput` time-to-first-render |
| 2 | No request storms | per-screen telemetry counters not worse than baseline; second detail open inside the freshness window = 0 requests; a 20-card grid does not scale requests with card count where a batch resource or index exists | popover cold 25 / reopen 11–14; library 7 / 0; detail movie 7 / 3; detail series 9(+1) / 3; search 8 / 5; add 2 (Lidarr 3) / 0; history 3 / 3; status 3 / 3 | `TelemetryRecorder.report()` per screen in phase 6; `StoreFreshnessTests`, `CompositionBatchTests` |
| 3 | Testable without a network | MediaKit and ArrCore tests never touch `URLSession.shared`; the test transport throws on every real host | 14 ArrCore test files rely on `URLProtocol.registerClass` against `URLSession.shared` | `HostileTransport` in every suite; grep gate `URLSession.shared` in `Tests/` = 0 |
| 4 | Light | MediaKit production code ≤ 60 % of the 14,317 lines it replaces = **≤ 8,590**; zero external dependencies; the iOS widget links and builds | replaced groups A 4,512 + B 3,113 + C 1,853 + D 2,889 + E 1,950 | §3 budget table (8,560); `swift package show-dependencies` = none; `xcodebuild ArrBarrWidgets` |

Timing baselines to hold: `swift test` ArrCore 8.0 s (956 tests), ArrMCPServer 27.1 s, MediaKit
spike 5.6 s; incremental `xcodebuild ArrBarr` 26.6 s. Cold start and list frame time have no
baseline; phase 3 adds the telemetry that measures them and phase 6 compares the old path (before
removal) against the new one.

---

## 2. Non-negotiables and owner decisions

Prompt section 1, restated as the constraints this design was checked against:

1. MediaKit is its own SwiftPM package and never imports ArrCore. Configuration, secrets, clock, transport, log sink and subsystem are injected.
2. Zero external dependencies. Allowed: Foundation, os, Observation, Network, system `SQLite3`, Swift Concurrency. (CryptoKit is *not* on the list; §4.5 avoids needing it.)
3. Swift 6 in MediaKit, strict concurrency, zero warnings; `swift-tools-version: 6.2`; `.defaultIsolation(nil)`, upcoming `NonisolatedNonsendingByDefault` and `InferIsolatedConformances`; `@concurrent` for background work. ArrCore gets `.defaultIsolation(MainActor.self)` in its manifest (phase 5, decision Q1) and stays in language mode v5.
4. Facts and indexes persist in system SQLite; macOS in the sandbox container's Application Support, iOS in the `group.pl.incred.ArrBarr` container with WAL, `busy_timeout` and `completeUntilFirstUserAuthentication` on db, wal and shm. `PosterStore` stays a byte layer and consumes one artwork reference type.
5. Domain types (`QueueItem`, `UpcomingItem`, `HistoryItem`) stay in ArrCore as compositions; MediaKit clients return resources in the service's own vocabulary.
6. In scope: Radarr, Sonarr, Lidarr, Whisparr (v3 shape; probe distinguishes v2/v3), qBittorrent, Transmission, Deluge, rTorrent, SABnzbd, NZBGet, Plex, Jellyfin, Emby, TMDB, SignalR as an event source, demo as a fixture transport, LAN media-server discovery.
7. Out of scope: LLM providers, MCP hosting, notifications, Spotlight index, StoreKit, KVSync, views. `TonightBarr`/`TonightCore` untouched.
8. Floor macOS 26 / iOS 26 in `project.pbxproj` and the ArrCore, MediaKit, ArrMCPServer manifests; the 14 availability lines in 6 ArrCore files go in phase 3.
9. Branch `feat/mediakit-foundation`, `phase(N):` commits, no merge, no push, no tags.
10. English code and comments; comments only for a non-obvious why, two lines at most.
11. No dead code: old clients, caches and `RealtimeUpdates` go in the last migration wave (§10.6).
12. Tests before code where behaviour is deterministic: transport, limiter, breaker, store, identity, capabilities, decoders, write request shapes.
13. 26 APIs in the data layer from day one: `Observations` as the invalidation→view bridge, typed `NotificationCenter` messages for configuration change, invalidation and connectivity, `@concurrent`, the Swift `Network` API (`NetworkBrowser`, `NetworkConnection`) for discovery.
14. Secrets in headers wherever the protocol allows; in the query only where there is no other way (SABnzbd `apikey`, TMDB v3 `api_key`, and — documented here as the third, pre-existing case — the Servarr WebSocket upgrade `access_token`). Never in a cache key, log line, telemetry row or fixture. Logged URLs never carry a query.
15. Live tests against the owner's services are reads only, enforced in `RecordingTransport` code (§3.3, §11).
16. UI adoption of 26 APIs is phase 7, macOS only.

Owner decisions from the phase-0 report §6, binding here:

- **Q1(a)** ArrCore keeps v5 mode; `.defaultIsolation(MainActor.self)` lands in phase 5 after the old clients are deleted; criterion 24 is checked at the end of phase 5.
- **Q2(a)** the widget reads the shared SQLite snapshot in the group container and refreshes through its own MediaKit connection when the snapshot is stale.
- **Q3(a)** Whisparr = a v3 client derived from Radarr on synthetic fixtures; the probe distinguishes v2 and v3; v2 is a documented gap.
- **Q4** repo fixtures and corpus bodies carry only open-source titles; Lidarr `GET /track` and `GET /search` are on the allow-list.
- **Q5** CI stays on Xcode 26.4.1 (tools 6.2, floor 26, no 27-only API); the schema is keyed by `InstanceID` from day one while the UI stays single-instance; Jellyfin/Emby fixtures are synthetic and marked `synthetic: true`.

---

## 3. Package layout and line budget

### 3.1 Manifest

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MediaKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "MediaKit", targets: ["MediaKit"]),
        .library(name: "MediaKitRecording", targets: ["MediaKitRecording"]),
    ],
    targets: [
        .target(
            name: "MediaKit",
            path: "Sources/MediaKit",
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
        .target(
            name: "MediaKitRecording",
            dependencies: ["MediaKit"],
            path: "Sources/MediaKitRecording",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
        .testTarget(
            name: "MediaKitTests",
            dependencies: ["MediaKit", "MediaKitRecording"],
            path: "Tests/MediaKitTests",
            swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(nil)]
        ),
    ]
)
```

Verified on a scratch package under Swift 6.4 / SDK 27 (phase 0, and the critic's
`scratchpad/sqlprobe`): tools 6.2 + `.v26` + `defaultIsolation(nil)` + both upcoming features +
`import SQLite3` with zero dependencies builds clean. `MediaKitRecording` holds
`RecordingTransport` and `AllowList`; it is linked by `MediaKitTests` and by the phase-6 parity
recorder only — never by an app target — and is outside the production budget (stated once, in the
phase-6 report). Fixtures move from `Packages/MediaKit/Fixtures/` to
`Packages/MediaKit/Sources/MediaKit/Fixtures/` (SwiftPM resources must live under the target
directory); `Tools/fixtures/anonymize_fixtures.py:38` (`FIXTURE_ROOT`) changes accordingly in
phase 3. The 1.8 MB of JSON ships in the app and the widget: it *is* demo mode.

The existing 3,459-line spike under `Sources/MediaKit` is deleted in phase 3 before the first
kernel file lands (its `TonightCore` consumer is out of scope and may stop compiling, prompt §1.7).

### 3.2 Production budget (≤ 8,590)

Lines of Swift at `CLAUDE.md` comment density. The wire-model rows carry the lean critic's honest
re-estimate (≈ 1 line per consumed property + 3 per type) after pruning to fields with a consumer
in the phase-0 reader inventories.

| File | LOC | Contents |
|---|---|---|
| **Core/** | | |
| `Core/InstanceID.swift` | 70 | `InstanceKind`, `InstanceID`, `Host` |
| `Core/Fingerprint.swift` | 30 | base URL + credential generation |
| `Core/Credentials.swift` | 70 | `Credentials`, `CredentialProvider`, redacted descriptions |
| `Core/MediaKitError.swift` | 90 | closed enum, classification helpers |
| `Core/Clock.swift` | 50 | `MediaClock`, `SystemClock`, `TestClock` |
| `Core/Logging.swift` | 60 | `LogSink`, `OSLogSink`, signposts |
| `Core/Telemetry.swift` | 110 | events, lock-guarded recorder, report |
| `Core/JSONValue.swift` | 70 | the `extra` bag for typed round-trips |
| `Core/MediaKit.swift` | 130 | assembly: `Configuration`, `Role`, `start/stop`, service factories, `artworkHeaders` |
| *subtotal* | **680** | |
| **Wire/** | | |
| `Wire/HTTPTypes.swift` | 100 | `HTTPHeaders`, `HTTPRequest`, `HTTPResponse`, `WireFrame`, `WireSocket` |
| `Wire/Transport.swift` | 40 | `Transport`, `SocketTransport` |
| `Wire/URLSessionTransport.swift` | 130 | data task + web socket, cancellation |
| `Wire/FixtureTransport.swift` | 280 | matcher, sidecars, write echo, demo rules interpreter, frames |
| `Wire/RequestBuilder.swift` | 190 | URL join, query encoding, form, multipart, JSON-RPC envelope |
| `Wire/Redaction.swift` | 80 | secret registry, `loggableURL`, body scrub |
| *subtotal* | **820** | |
| **Kernel/** | | |
| `Kernel/RequestPlan.swift` | 90 | `RequestPlan`, `OperationID`, `RequestPriority`, `RetryDisposition`, `AuthPlacement` |
| `Kernel/RequestPipeline.swift` | 250 | the single send path, retry loop |
| `Kernel/HostGovernor.swift` | 230 | one actor: per-host limiter, rate gate, breaker |
| `Kernel/SessionBroker.swift` | 140 | `SessionStrategy`, one actor keyed by instance |
| `Kernel/SessionStrategies.swift` | 200 | 13 strategies (§5.5) |
| *subtotal* | **910** | |
| **Store/** | | |
| `Store/FreshnessClass.swift` | 40 | |
| `Store/InvalidationTag.swift` | 80 | tag vocabulary, `CollectionName` |
| `Store/ResourceKey.swift` | 50 | |
| `Store/Resource.swift` | 120 | `Resource`, `BatchResource`, `Command`, `Fetched`, `CacheOrigin`, `CommandReceipt` |
| `Store/ResourceStore.swift` | 380 | read policies, coalescer, SWR, invalidate, sweep |
| `Store/MemoryTier.swift` | 90 | LRU by bytes, volatile TTL |
| `Store/SQLiteDatabase.swift` | 300 | actor on a serial executor, statement cache, transactions |
| `Store/StoreSchema.swift` | 110 | DDL, PRAGMAs, migrations, `DatabaseLocation` |
| `Store/StoreRevision.swift` | 110 | `@Observable` lock-guarded counter + typed messages + subject |
| `Store/Snapshot.swift` | 80 | synchronous projection |
| *subtotal* | **1,360** | |
| **Instances/** | | |
| `Instances/InstanceRegistry.swift` | 130 | descriptors, fingerprints, config-change invalidation |
| `Instances/Capabilities.swift` | 200 | `Capability`, `CapabilitySet`, `CapabilityIndex`, `CapabilityProbe`, `derive` |
| *subtotal* | **330** | |
| **Identity/** | | |
| `Identity/MediaID.swift` | 130 | `IDNamespace`, `MediaID`, `MediaIdentity`, `Crosswalk` |
| `Identity/ExternalIDParsing.swift` | 100 | Plex guids, Jellyfin `ProviderIds`, Servarr ids, TMDB `external_ids` |
| `Identity/IdentityStore.swift` | 100 | actor: known/record/forget; resolver routes |
| *subtotal* | **330** | |
| **Events/** | | |
| `Events/DataEvent.swift` | 60 | |
| `Events/EventTagMap.swift` | 90 | the one event→tags function |
| `Events/EventHub.swift` | 140 | attach/detach, burst window, `queueStatus` memory, `wakeAll`, `lastEventAt` |
| `Events/SignalRSource.swift` | 340 | negotiate, handshake, ping, backoff, `parse` |
| *subtotal* | **630** | |
| **Live/** | | |
| `Live/LiveStream.swift` | 300 | policy, scope, pump, push coverage, partial, checkpoint, pending overlay |
| *subtotal* | **300** | |
| **Compose/** | | |
| `Compose/CompositionContext.swift` | 130 | reads with provenance |
| `Compose/CompositionEngine.swift` | 140 | memo, `observe`, `values` |
| *subtotal* | **270** | |
| **Services/Servarr/** | | |
| `Services/Servarr/ServarrProfile.swift` | 90 | api base, nouns, query spellings, four flavours |
| `Services/Servarr/ServarrService.swift` | 340 | resources + commands (§5.1), RMW, season toggle |
| `Services/Servarr/ServarrWire.swift` | 480 | shared shapes, four entity families, `ArrRecordEnvelope` |
| *subtotal* | **910** | |
| **Services/Download/** | | |
| `Services/Download/DownloadService.swift` | 130 | protocol, `DownloadTask`, `DownloadPayload`, `DownloadAction`, RPC helpers |
| `Services/Download/QBittorrentService.swift` | 160 | |
| `Services/Download/TransmissionService.swift` | 120 | |
| `Services/Download/DelugeService.swift` | 120 | |
| `Services/Download/RTorrentService.swift` | 160 | incl. the XML-RPC codec for six calls |
| `Services/Download/SABnzbdService.swift` | 110 | |
| `Services/Download/NZBGetService.swift` | 110 | |
| *subtotal* | **910** | |
| **Services/MediaServer/** | | |
| `Services/MediaServer/MediaServerService.swift` | 270 | Plex + Jellyfin/Emby |
| `Services/MediaServer/MediaServerWire.swift` | 160 | slim index entry, sessions, history |
| *subtotal* | **430** | |
| **Services/TMDB/** | | |
| `Services/TMDB/TMDBService.swift` | 150 | |
| `Services/TMDB/TMDBWire.swift` | 130 | |
| *subtotal* | **280** | |
| **Artwork / Discovery** | | |
| `Artwork/ArtworkReference.swift` | 110 | |
| `Discovery/Discovery.swift` | 160 | `NetworkBrowser` Bonjour, `NetworkConnection<UDP>` beacon, parsers |
| *subtotal* | **270** | |
| **Total** | **8,560** | slack 30 |

680 + 820 + 910 + 1,360 + 330 + 330 + 630 + 300 + 270 + 910 + 910 + 430 + 280 + 270 = 8,560.
`Package.swift` (≈ 40 lines) is a manifest and is not counted, as CF counted it and TF did not;
the phase-6 report states the convention once.

**Cuts already taken to get here** (each a decision, each reversible only by removing something
else): four arr clients are one `ServarrService` over a flavour table; Jellyfin and Emby are one
service with a two-case auth switch; Whisparr v3 is the Radarr flavour plus one capability;
demo state is fixture data plus a rule interpreter, not 2,889 lines of mocks; one identity model
(`MediaID`, `MediaIdentity`, crosswalk table, parsers — no provider/precedence framework); no
`EventSource` protocol (two sources: SignalR and the wake call); `BatchResource` has two strategies
(`chunked`, `perKey`) and "index" is a composition over `library`; telemetry counts only, no
histograms; one governor actor and one session actor; TMDB `similar*` dropped (no consumer —
`LocalToolBackend+Discover` uses `recommendations` only); wire models pruned to consumed fields.

**Relief valves if a file overruns**, in order: (1) move the demo rule table from Swift to
`Fixtures/demo-rules.json` (−40 in `FixtureTransport`); (2) generate `ServarrWire.swift` and
`TMDBWire.swift` with `Tools/mediakit/gen_wire.py` from the fixture bodies pruned to the consumed
field list, which removes hand-written boilerplate (−60 to −100, still counted — see open question
§13.2); (3) drop `Discovery`'s UDP beacon to macOS only (−30). Nothing else is pre-approved; an
overrun beyond these is a question in the phase-3 decision pack, not a silent shave.

### 3.3 Test target layout

```
Packages/MediaKit/Tests/MediaKitTests/
  Support/
    TestClock.swift            // MediaClock with advance(by:)
    CountingTransport.swift    // records [RequestPlan]; answers from a closure
    BlockingTransport.swift    // holds requests until released; peak-concurrency recorder
    ScriptedTransport.swift    // status/body/headers script per operation, incl. 429 + Retry-After
    HostileTransport.swift     // throws on any host that is not "fixture.invalid"
    TempDatabase.swift         // per-suite temp directory; two-connection helper for WAL tests
    FixtureAccess.swift        // Bundle.module fixtures root
  Kernel/   HostGovernorTests, BreakerTests, RetryTests, SessionBrokerTests, PipelineTests, CancellationTests
  Store/    StoreFreshnessTests, StoreCoalescingTests, StoreInvalidationTests, StorePersistenceTests,
            StoreOfflineTests, SQLiteSchemaTests, SnapshotTests, RevisionTests, ColdStartTests
  Instances/ InstanceRegistryTests, CapabilityTests
  Identity/ ExternalIDParsingTests, IdentityStoreTests
  Events/   SignalRFrameTests (the 10 ported cases + reconnect/backoff), EventTagMapTests, EventHubTests
  Live/     LiveStreamTests, PendingEffectTests
  Compose/  CompositionTests, CompositionBatchTests
  Services/ ServarrResourceTests, ServarrCommandTests, DownloadClientTests, MediaServerTests, TMDBTests
  Parity/   GoldenParityTests, AllowListTests, WriteShapeTests
  Hygiene/  SecretLeakTests, TypedMessageTests, TelemetryReportTests, DiscoveryParserTests, WidgetStoreTests
Packages/MediaKit/Sources/MediaKitRecording/
  RecordingTransport.swift     // allow-list gate + scrub-before-write
  AllowList.swift              // prompt §5 table as code (+ Lidarr /track, /search)
```

ArrCore-side tests that this design requires: `MediaKitErrorMappingTests` (criterion 13),
`LocalToolBackendFixtureTests` (criterion 19), `ServiceGatewayTests` (reconcile, demo restart).
Every ArrCore suite that today registers a `URLProtocol` stub migrates to an injected
`ScriptedTransport`/`FixtureTransport`; the greedy `canInit { true }` stubs (memory note) go with
them.

---

## 4. Kernel

Isolation is stated on every declaration. Unannotated types are `nonisolated` (package default).
Names were checked against ArrCore's public namespace: `InstanceKind` (not `ServiceKind`),
`CacheOrigin` (not `Origin`), `*Service` (not `*Client`) exist because the ArrCore names collide
and both modules coexist in phase 5.

### 4.1 Transport

```swift
public struct HTTPHeaders: Sendable, Hashable, ExpressibleByDictionaryLiteral {
    public subscript(name: String) -> String? { get set }        // case-insensitive
    public init(dictionaryLiteral elements: (String, String)...)
    public var names: [String] { get }
}

public struct HTTPRequest: Sendable {
    public enum Body: Sendable {
        case none
        case bytes(Data, contentType: String)                     // JSON, XML-RPC
        case form([String: String])                               // sorted keys, RFC 3986 unreserved
        case multipart(fields: [String: String], file: FilePart?)
    }
    public struct FilePart: Sendable { public let name: String, filename: String, data: Data, contentType: String }
    public var method: String
    public var url: URL
    public var headers: HTTPHeaders
    public var body: Body
    public var timeout: Duration
    /// Set by the pipeline, read by transports for fixture matching and logging. Never a URL.
    public var operation: OperationID
    public var pathTemplate: String                               // "/api/v3/movie/{id}"
    public var rpcMethod: String?
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: HTTPHeaders
    public let body: Data
    public var isSuccess: Bool { (200..<300).contains(status) }
}

public enum WireFrame: Sendable { case text(String), binary(Data), closed(code: Int?) }

public protocol WireSocket: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> WireFrame
    func cancel()
}

/// One request in, one response out. No retries, no limits, no credentials, no logging.
public protocol Transport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// Separate from `Transport` (lean critic TF-7): a socket is not a request, and a transport that
/// cannot open one (the widget's, a scripted test double) says so by not conforming.
public protocol SocketTransport: Sendable {
    func open(_ request: HTTPRequest) async throws -> any WireSocket
}
```

Three implementations:

```swift
public struct URLSessionTransport: Transport, SocketTransport {          // nonisolated struct
    public init(session: URLSession)
    /// No URLCache, per-instance cookie jar when `cookies` is true (qBittorrent, Deluge).
    public static func makeSession(cookies: Bool, timeout: Duration) -> URLSession
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse
    public func open(_ request: HTTPRequest) async throws -> any WireSocket
}

public actor FixtureTransport: Transport, SocketTransport {              // §8
    public init(bundleRoot: URL, rules: [DemoRule], clock: any MediaClock)
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse
    public func open(_ request: HTTPRequest) async throws -> any WireSocket
    public func enqueueFrames(_ frames: [String], for instance: InstanceID)
    public func requestLog() -> [(OperationID, Date)]
    public func reset()
}

// Target MediaKitRecording — never linked by an app.
public struct RecordingTransport: Transport, SocketTransport {
    public init(wrapping: any Transport & SocketTransport, allowList: AllowList, output: URL, redaction: Redaction)
}
public struct AllowList: Sendable {
    public struct Rule: Sendable { public let kind: InstanceKind, method: String, pathTemplate: String, rpcMethod: String?, query: [String: String]? }
    public static let section5: AllowList
    public func permits(_ request: HTTPRequest, kind: InstanceKind) -> Bool
}
```

Rules that every implementation obeys:

- **Timeout** is `HTTPRequest.timeout` (default 15 s from the plan; `releases` and `grabRelease`
  120 s). `URLSessionTransport` sets it on the `URLRequest`; a fired timeout surfaces as
  `MediaKitError.unreachable(host, .timeout)` from the pipeline's classification.
- **Cancellation.** `URLSessionTransport.send` creates the data task explicitly and wraps its
  continuation in `withTaskCancellationHandler(operation:onCancel:isolation:)` (Swift,
  back-deployed; verified) whose handler calls `URLSessionTask.cancel()`. The resulting
  `URLError.cancelled` and any `CancellationError` are rethrown as **`CancellationError`**, the one
  and only spelling of cancellation in the package (TF-9). `MediaKitError` has no `cancelled` case;
  ArrCore tests `is CancellationError` (phase-0 fact 5: pull-to-refresh depends on a bare rethrow).
- **Status is data, not failure.** A non-2xx response is returned; the pipeline classifies it
  (409 and 401/403 are session policy, 429/503 are rate policy).
- **Allow-list enforcement** lives in `RecordingTransport.send/open`: `AllowList.section5.permits`
  runs *before* delegation and a miss throws `MediaKitError.notPermitted(operation)` without
  building a URLSession task. `section5` is the prompt §5 table verbatim plus the two phase-0
  additions (Lidarr `GET /api/v1/track`, `GET /api/v1/search`) and `POST /signalr/messages/negotiate`
  + the WebSocket upgrade. `AllowListTests` asserts every forbidden cell row by row.
- **Redaction** is one registry both the log sink and the recorder consult:

```swift
public struct Redaction: Sendable {
    public static let standard: Redaction
    public func loggableURL(_ url: URL) -> String          // scheme://host[:port]/path — never the query
    public func scrub(_ request: HTTPRequest) -> HTTPRequest
    public func scrub(_ body: Data, contentType: String) -> Data
}
```
`standard` strips: headers `X-Api-Key`, `X-Plex-Token`, `X-Emby-Token`, `Authorization`, `Cookie`,
`Set-Cookie`; query items `apikey`, `api_key`, `access_token`; form fields `username`, `password`
(qBittorrent login); JSON-RPC `auth.login` `params` (Deluge); `X-Transmission-Session-Id`; every
host name is replaced by `<host>` when writing fixtures. `SecretLeakTests` feeds the two login
bodies and the WebSocket query through it.

### 4.2 Limiter, retry, breaker

```swift
public enum RequestPriority: Int, Sendable, Comparable {
    case background = 0        // live-stream polls, prefetch, revalidation, the widget
    case interactive = 1       // anything a visible screen awaits
    case session = 2           // credential handshakes only; reserved lane, never queues behind the others
}

public enum RetryDisposition: Sendable {
    case idempotent            // GET and the explicitly safe RPC reads: retried up to 3 attempts
    case never                 // every state-changing write
    case handshakeOnly         // re-sent exactly once after a session rejection (401/403/409/in-band)
}

public enum HostHealth: Sendable, Equatable {
    case unknown                                  // never contacted this process
    case healthy
    case degraded(consecutiveFailures: Int)       // 1..<threshold
    case down(since: Date, retryAt: Date)         // breaker open
    case throttled(until: Date)                   // 429/503 Retry-After — not a failure
}

/// One actor for every host (lean critic TF-5): the limiter, rate gate and breaker of a host are one
/// mutable cell, and hosts are a dictionary inside.
public actor HostGovernor {
    public struct Limits: Sendable, Equatable {
        public var maxConcurrent: Int = 4                 // today's maxConcurrentSideLoads
        public var backgroundShare: Int = 2               // of maxConcurrent, at most this many background
        public var reservedSessionSlots: Int = 1
        public var minimumInterval: Duration? = nil       // TMDB: .milliseconds(250)
        public var failureThreshold: Int = 3
        public var openFor: Duration = .seconds(30)       // doubles per consecutive open, cap 5 min
    }
    public struct Slot: Sendable { let host: Host; let id: UInt64; let priority: RequestPriority }
    public enum Outcome: Sendable { case success, transportFailure(MediaKitError), retryAfter(Duration), cancelled }

    public init(defaults: Limits, overrides: [InstanceKind: Limits], clock: any MediaClock, telemetry: any TelemetrySink, log: any LogSink)
    /// Waits for a slot honouring the rate gate and the breaker. Throws `.breakerOpen` / `.rateLimited`
    /// *before* queueing when the host is shut; throws `CancellationError` if the task dies queued.
    public func enter(_ host: Host, kind: InstanceKind, priority: RequestPriority) async throws -> Slot
    public func leave(_ slot: Slot, outcome: Outcome)
    public nonisolated func health(of host: Host) -> HostHealth          // lock-guarded snapshot
    public func healthUpdates() -> AsyncStream<(Host, HostHealth)>
    public func noteWake(at: Date)                                      // half-opens every `down` host
}
```

Semantics, testable with `TestClock`:

- **Limiter.** Per host, a FIFO of continuations per priority band. `interactive` drains before
  `background`; `background` may hold at most `backgroundShare` of the slots so a burst of
  polls cannot starve a screen (TF-5 priority inversion). `session` uses `reservedSessionSlots`
  and never waits for the others — without the reservation, four 401s hold four slots and the
  re-login they all wait for deadlocks. `minimumInterval` is a token-bucket floor between sends.
- **Rate gate.** On 429 or 503 with `Retry-After` (seconds or HTTP-date; absent → 30 s) the host
  is `throttled(until:)`; `enter` throws `.rateLimited(host, retryAfter:)` until then. Other hosts
  are untouched (criterion 7).
- **Breaker.** Counts consecutive `transportFailure` outcomes (`unreachable` only — an HTTP 500 is
  a server that is *up*). At `failureThreshold` → `down(since:retryAt:)`, `TelemetryEvent.breakerOpened`,
  one `ConnectivityChanged` message. While down, `enter` throws `.breakerOpen` without queueing —
  and `ResourceStore.read` turns that into the stale row (§4.3). At `retryAt` exactly one slot is
  granted (half-open); success → `healthy` + `breakerClosed`; failure → `down` with `openFor`
  doubled (cap 5 min). `noteWake` moves every `down` host to half-open so the first post-wake
  request probes immediately (MF graft). `cancelled` is not a strike.
- **Health per instance.** `Host` is `scheme+host+port`; two services behind one reverse-proxy
  origin share a governor cell. That is accepted: a dead origin is dead for both, and a 429 from
  a proxy is per origin. `MediaKit.health(of: InstanceID)` maps instance → host.
- **Retry** lives in `RequestPipeline.send`, not in a policy type: `idempotent` reads get up to
  3 attempts with `250 ms × 2^attempt × jitter(0.8…1.2)` capped at 8 s, `Retry-After` overrides the
  delay, and only after `unreachable`, 429, 503 or 502/504; `never` gets one attempt;
  `handshakeOnly` is the session re-send.

```swift
public struct RequestPlan: Sendable, Hashable {
    public enum AuthPlacement: Sendable, Hashable {
        case header(String)                     // "X-Api-Key", "X-Plex-Token", "X-Emby-Token"
        case bearer                             // TMDB v4, qBittorrent API-key mode
        case basic                              // NZBGet, rTorrent, Transmission with a username
        case jellyfinMediaBrowser               // Authorization: MediaBrowser Token="…"
        case querySecret(String)                // ONLY "apikey" (SABnzbd), "api_key" (TMDB v3), "access_token" (WS upgrade)
        case session                            // qBittorrent SID / Deluge cookie / Transmission session id
        case none
    }
    public var instance: InstanceID
    public var operation: OperationID
    public var method: String
    public var pathTemplate: String             // "/api/v3/movie/{id}"
    public var pathValues: [String: String]     // {"id": "1525"}
    public var query: [(String, String)]        // never a secret
    public var headers: HTTPHeaders             // never a secret
    public var body: HTTPRequest.Body
    public var auth: AuthPlacement
    public var priority: RequestPriority
    public var retry: RetryDisposition
    public var timeout: Duration
    public var rpcMethod: String?
}

public struct OperationID: Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let rawValue: String                 // "radarr.fetchQueue": <kind>.<corpus operation>
    public var kind: InstanceKind { get }
    public var name: String { get }             // "fetchQueue"
}

/// A value over actors; a service holds one for free.
public struct RequestPipeline: Sendable {
    public init(transport: any Transport, sockets: (any SocketTransport)?, governor: HostGovernor,
                sessions: SessionBroker, credentials: any CredentialProvider, registry: InstanceRegistry,
                telemetry: any TelemetrySink, log: any LogSink, signposts: OSSignposter?, clock: any MediaClock)
    public func send(_ plan: RequestPlan) async throws -> HTTPResponse
    public func socket(_ plan: RequestPlan) async throws -> any WireSocket    // throws .unsupported when `sockets == nil`
}
```

`send`, in order — this sequence is the design:

1. `registry.descriptor(plan.instance)` → `nil` or disabled → `throw .notConfigured` before any host work.
2. `credentials.credentials(for:)` → `nil` → `.notConfigured`.
3. `governor.enter(host, kind:, priority:)` — may throw `.breakerOpen` / `.rateLimited`.
4. `sessions.authorize(plan, credentials:)` builds the `HTTPRequest`: URL from `baseURL` + `pathTemplate`/`pathValues` + `query`, then the secret is attached according to `auth`. **The secret exists only in this `HTTPRequest`** — never in `RequestPlan`, `ResourceKey`, telemetry or logs (criterion 12).
5. `OSSignposter.beginInterval("mediakit.request")` around `transport.send`.
6. Classify: 2xx → success. 401/403/409/in-band RPC error → `sessions.rejection(for:)`; if a rejection, `sessions.refresh(...)` at `.session` priority (one `establish` per generation, coalesced) then one re-send (`handshakeOnly`); a second rejection surfaces as `.unauthorized`. 429/503 → `leave(.retryAfter)`, then retry per disposition. Other 4xx → `.rejected`, 5xx → `.serverFault`, both carrying the parsed body reason (`RequestBuilder.serverMessage`: Servarr array, `{message}`, ASP.NET `ProblemDetails`). A JSON-RPC/XML-RPC error envelope on HTTP 200 → `.serviceError`.
7. Transport throw → `.unreachable(host, kind)`; `leave(.transportFailure)`; retry per disposition.
8. `CancellationError` → `leave(.cancelled)` and rethrow.
9. Telemetry `request`/`response`/`failure` on every path; `.debug` log for the request line (`Redaction.loggableURL`), `.notice` for breaker transitions and session establishment.

### 4.3 Store

```swift
public enum FreshnessClass: Int, Sendable, Codable, CaseIterable, Comparable {
    case volatile  = 0      // TTL 5 s;   memory only, never SQLite
    case live      = 1      // TTL 60 s;  disk retention 1 d
    case warm      = 2      // TTL 10 min; retention 7 d
    case reference = 3      // TTL 6 h;   retention 30 d
    case archival  = 4      // TTL 30 d;  retention 180 d
    public var defaultTTL: Duration { get }
    public var retention: Duration { get }
    public var persists: Bool { self != .volatile }
}

public enum CollectionName: String, Sendable, Codable, CaseIterable {
    case queue, calendar, history, library, health, profiles, commands, sessions, downloads, lookup
}

public struct InvalidationTag: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String                                        // printable, secret-free
    public static func instance(_ id: InstanceID) -> Self             // "i:radarr#0"
    public static func collection(_ c: CollectionName, _ id: InstanceID) -> Self   // "c:queue@radarr#0"
    public static func entity(_ id: InstanceID, _ kind: MediaKind, _ entityID: Int) -> Self // "e:movie/radarr#0/1525"
    public static func identity(_ id: MediaID) -> Self                // "x:tmdb-movie:603"
    public static func capabilities(_ id: InstanceID) -> Self         // "k:radarr#0"
}

public struct ResourceKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public let instance: InstanceID
    public let operation: OperationID
    public let discriminator: String     // sorted "k=v" pairs of non-secret path values + query; "" when none
    public var storageKey: String { "\(instance)|\(operation.rawValue)|\(discriminator)" }
}

public enum CacheOrigin: String, Sendable, Codable { case memory, disk, network, coalesced }

public struct Fetched<Value: Sendable>: Sendable {
    public let value: Value
    public let origin: CacheOrigin
    public let fetchedAt: Date
    public let isStale: Bool
    public let tags: Set<InvalidationTag>
    /// Set when a stale row was served because the fetch failed (breaker open, unreachable).
    public let degraded: MediaKitError?
}

public struct Resource<Value: Codable & Sendable>: Sendable {
    public let key: ResourceKey
    public let tags: Set<InvalidationTag>
    public let freshness: FreshnessClass
    public let ttl: Duration?                      // overrides the class TTL (releases: 60 s)
    public let plan: RequestPlan                   // built by the service from CapabilityIndex, synchronously
    public let decode: @Sendable (Data) throws -> Value      // pure over bytes
    public let harvest: (@Sendable (Value) -> [Crosswalk])?  // ids learned on the way (§4.6)
}

public struct BatchResource<Key: Hashable & Sendable, Value: Codable & Sendable>: Sendable {
    public enum Strategy: Sendable {
        case chunked(max: Int, make: @Sendable ([Key]) -> Resource<[Value]>, identify: @Sendable (Value) -> Key?)
        case perKey(make: @Sendable (Key) -> Resource<[Value]>)     // no batch endpoint; the limiter bounds it
    }
    public let strategy: Strategy
}

public struct CommandReceipt: Sendable {
    public let acceptedAt: Date
    public let serverMessage: String?
    public let trackingID: Int?              // arr /command id
}

public struct CommandContext: Sendable {                     // what a command's `run` may do
    public func send(_ plan: RequestPlan) async throws -> HTTPResponse
    public func decode<T: Decodable & Sendable>(_ type: T.Type, from response: HTTPResponse, operation: OperationID) async throws -> T
    public var capabilities: CapabilityIndex { get }
    public func demote(_ capability: Capability, for instance: InstanceID) async   // persists; re-probe on next status
    public func promote(_ capability: Capability, for instance: InstanceID) async
}

public struct Command: Sendable {
    public let name: OperationID
    public let instance: InstanceID
    public let invalidates: Set<InvalidationTag>
    public let optimistic: PendingEffect?                 // applied to a live stream only (§6.2)
    public let tracking: Tracking?
    public enum Tracking: Sendable { case arrCommand(timeout: Duration) }   // polls {api}/command/{id} at .background
    /// Multi-request writes are ordinary code here (TF graft): GET→PUT, GET→PUT→GET→PUT, GET /search→POST.
    public let run: @Sendable (CommandContext) async throws -> CommandReceipt
}

public enum ReadPolicy: Sendable, Equatable {
    case cacheFirst              // fresh → return; stale/absent → fetch and await; failure with a stale row → stale + degraded
    case staleWhileRevalidate    // stale → return now, revalidate at .background; commit bumps the revision
    case cacheOnly               // never touches the network; cold start, Spotlight, the widget's first entry
    case mustRevalidate          // always fetch (coalesced, limited); a stale row is never substituted
}

public actor ResourceStore {
    public init(database: SQLiteDatabase?, pipeline: RequestPipeline, identity: IdentityStore?,
                clock: any MediaClock, telemetry: any TelemetrySink, log: any LogSink, memoryBudget: Int = 8 << 20)
    public func start() async                       // loads nothing for entries (lazy); warms nothing
    public func read<V>(_ resource: Resource<V>, policy: ReadPolicy = .cacheFirst, maxAge: Duration? = nil,
                        priority: RequestPriority = .interactive) async throws -> Fetched<V>
    /// cached → revalidated → one element per matching invalidation *or commit*.
    public func observe<V>(_ resource: Resource<V>, maxAge: Duration? = nil,
                           priority: RequestPriority = .interactive) -> AsyncStream<Fetched<V>>
    public func batch<K, V>(_ batch: BatchResource<K, V>, keys: [K], policy: ReadPolicy = .cacheFirst,
                            maxAge: Duration? = nil, priority: RequestPriority = .interactive) async -> [K: Result<V, MediaKitError>]
    public func run(_ command: Command, priority: RequestPriority = .interactive) async throws -> CommandReceipt
    public func invalidate(_ tags: Set<InvalidationTag>, reason: InvalidationReason) async
    public func invalidate(instance: InstanceID, reason: InvalidationReason) async
    public func sweep() async                       // retention + size cap; app role only
    public func purge(_ class: FreshnessClass) async
    public func purgeAll() async
    public func statistics() async -> StoreStatistics
    public nonisolated let revision: StoreRevision
}

public enum InvalidationReason: String, Sendable, Codable { case command, event, configuration, manual, wake }
```

**Read algorithm.** `effectiveTTL = min(resource.ttl ?? class.defaultTTL, maxAge ?? ∞)`; a row is
fresh when `now < min(fetchedAt + effectiveTTL, stale_at)`. Lookup order: memory tier →
`entries` (filtered by the instance's current fingerprint) → network. `cacheFirst` awaits the
fetch on a miss; if the fetch throws and a stale row exists, the row is returned with
`isStale = true, degraded = error` and `TelemetryEvent.staleServed`; with no row the error
propagates. `.breakerOpen` and `.rateLimited` are thrown by `enter` before a socket, so the offline
path costs one actor hop. `staleWhileRevalidate` returns the stale row immediately and starts one
`.background` revalidation (coalesced like any fetch); the commit bumps `revision`, so `observe`,
`Snapshot` and `CompositionEngine.observe` re-emit the fresh value (CF-9/MF-6 fixed: the tick
bumps on **invalidate and on commit of a fresher row**). `mustRevalidate` is what tools and
manual refresh use.

**Coalescing (criteria 2, 10).** `inFlight: [ResourceKey: InFlight]` where
`InFlight { task: Task<Data, Error>; waiters: Set<UInt64> }`. A reader registers a waiter id, then
awaits `task.value` inside `withTaskCancellationHandler`; the `onCancel` handler enqueues
`removeWaiter(key, id)`. Removal is **by id and idempotent** (CF-4's double-decrement cannot
happen); the normal path removes the same id after the value returns. When the set becomes empty
the task is cancelled. A cancelled task never reaches `commit`: the memory/SQLite write happens
after decode, inside the actor, guarded by a final `Task.isCancelled` check, so a cancelled read
leaves no row and no `entry_tags` edge.

**Commit.** `decode` runs in `@concurrent static func WireCodec.decode(_:as:) async throws`
(nonisolated, off the store actor), the value is re-encoded with `JSONEncoder` (`@concurrent`,
same file) and written as the row payload; `harvest` output goes to `IdentityStore.record`.
**Payload = re-encoded value, not response bytes.** Reason: the Plex library index is 7 MB on the
wire and ~500 KB as the slim `MediaServerIndexEntry` array (§5.3); the widget's 16 MB cap, the
cold-start decode time (criteria 15, 27) and the snapshot rebuild (CF-10, lean finding 14) all
depend on the row being the *decoded* shape. Cost: `Value: Codable` (synthesised; wire models are
`let` structs), one encode per network read, and a `user_version` bump whenever a persisted model
changes — cache tables may be dropped, so that bump is free. Fixture bodies remain the decoder's
input in tests; they are not cache payloads.

**Batch.** `chunked`: keys are sorted, de-duplicated and cut into chunks of `max`; each chunk is
one `Resource<[Value]>` (its `ResourceKey.discriminator` is the sorted id list, so identical chunks
coalesce across concurrent compositions) read through the store; results are split by `identify`.
`perKey`: one resource per key, issued through the limiter (`maxConcurrent` bounds fan-out). A key
whose chunk fails maps to `.failure`; partial results are the norm.

**Volatile.** Lives only in `MemoryTier` (5 s TTL by default). `SQLiteDatabase.put` refuses
`class == .volatile` before binding, and the DDL's `CHECK (class > 0)` makes a bug a constraint
violation (criterion 6 is `SELECT COUNT(*) FROM entries WHERE class = 0` = 0). Live-stream values
are not resources and never enter `entries`; their last value goes to `live_snapshots` (§4.4).

**Sweep and purge.** `sweep()` runs in the app role only (the widget never deletes the app's
rows): on `start()`, every 6 h, on memory pressure and on `applicationDidEnterBackground`:
(1) `DELETE FROM entries WHERE stale_at < now − retention(class)` per class in batches of 200 rows
per transaction; (2) while `SUM(bytes) > cap` (64 MB app) delete by `(class ASC, last_used ASC)`
until under 90 %; (3) `PRAGMA incremental_vacuum(64)` when `freelist_count` exceeds 25 % of
`page_count`. `purge(class)` deletes one class; `purgeAll()` deletes `entries`/`entry_tags` only.
ArrCore's `AppCaches.purgeExpired()` calls `sweep()`; `AppCaches.clearArtwork()` is unchanged
(artwork bytes stay in `PosterStore`); Developer options' "clear caches" calls `purgeAll()`.
`memoryBudget` is an LRU by bytes over `MemoryTier` (8 MB app, 2 MB widget).

```swift
/// Synchronous, lock-guarded projection for view bodies. Two consumers today (poster override,
/// watched state); a third needs a reason.
public final class Snapshot<Value: Sendable>: Sendable {
    public init(tags: Set<InvalidationTag>, initial: Value, store: ResourceStore,
                rebuild: @escaping @Sendable (ResourceStore) async -> Value)
    public var current: (value: Value, version: UInt64) { get }     // OSAllocatedUnfairLock, no await
    public func start() async                                        // first rebuild + subscribe to `revision`
    public func stop()
}

/// The one `@Observable` type in MediaKit. `@unchecked Sendable` with lock-guarded storage and
/// hand-written `access`/`withMutation` (verified: scratchpad/sqlprobe `AtomicBox`; probe p9 runs it).
@Observable public final class StoreRevision: @unchecked Sendable {
    public func tick(for tag: InvalidationTag) -> UInt64
    public var all: UInt64 { get }
    internal func bump(_ tags: Set<InvalidationTag>)
}
```

`Observations({ revision.tick(for: tag) })` (Observation, macOS 26; `init(_ emit: @escaping
@isolated(any) @Sendable () throws(Failure) -> Element)` verified) is how ArrCore view models and
`Snapshot` subscribe. Probe p9 established two facts the consumers must respect: a burst of
mutations in one actor job is *not* atomic to an observer on another executor (emissions
`[0, 28, 100]`), and a slow consumer coalesces (10 jobs → 2 emissions). Every emission therefore
means "re-read now", never "here is the delta"; `Observations.untilFinished(_:)` (verified) ends a
stream whose composition was dropped.

### 4.4 SQLite

```swift
/// An actor pinned to its own serial queue (SE-0392) so `sqlite3_step` never blocks the cooperative
/// pool and the connection is single-threaded by construction (`SQLITE_OPEN_NOMUTEX` is then safe).
public actor SQLiteDatabase {
    public nonisolated let queue: DispatchSerialQueue          // init(label:qos:attributes:autoreleaseFrequency:target:) verified
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    public init(location: DatabaseLocation, log: any LogSink) throws   // opens, PRAGMAs, migrates; call off the main thread
    public func entry(_ key: ResourceKey, fingerprint: Fingerprint) throws -> StoredEntry?
    public func entries(_ keys: [ResourceKey], fingerprint: Fingerprint) throws -> [ResourceKey: StoredEntry]
    public func put(_ entries: [StoredEntry]) throws                      // one BEGIN IMMEDIATE … COMMIT; rejects .volatile
    public func markStale(tags: Set<InvalidationTag>, at: Date) throws -> Int
    public func markStale(instance: InstanceID, at: Date) throws -> Int
    public func touch(_ keys: [ResourceKey], at: Date) throws
    public func lastKnown(instance: InstanceID, stream: String) throws -> (Data, Date)?
    public func putLastKnown(instance: InstanceID, stream: String, payload: Data, at: Date) throws
    public func capabilities(_ instance: InstanceID) throws -> StoredCapabilities?
    public func putCapabilities(_ value: StoredCapabilities) throws
    public func crosswalk(from: MediaID, kind: MediaKind) throws -> [Crosswalk]
    public func putCrosswalk(_ edges: [Crosswalk]) throws
    public func forgetCrosswalk(instance: InstanceID) throws
    public func sweep(now: Date, cap: Int, retention: (FreshnessClass) -> Duration) throws -> SweepReport
    public func statistics() throws -> StoreStatistics
}

public struct DatabaseLocation: Sendable {
    public enum Kind: Sendable { case file(directory: URL), memory }
    public let kind: Kind
    public let fileName: String                      // "mediakit.sqlite"
    public let protectFiles: Bool                    // iOS: SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION
    public let diskCap: Int                          // 64 MB app, 16 MB widget
    public let readOnlyCache: Bool                   // widget never writes `entries` (see below)
}
```

Ten hot statements are prepared once and reused (`sqlite3_reset` + `sqlite3_clear_bindings`;
lean finding 13). `SQLITE_TRANSIENT` is `unsafeBitCast(-1, to: sqlite3_destructor_type.self)`
(verified in `scratchpad/sqlprobe/Probe.swift`). SDK SQLite is 3.54.0 (`sqlite3.h:155`), so
`STRICT` and `WITHOUT ROWID` are available.

**Paths** (injected; MediaKit never asks which app it is in):

| Role | Path |
|---|---|
| macOS app | `FileManager.urls(for: .applicationSupportDirectory)` inside the sandbox → `~/Library/Containers/pl.incred.ArrBarr/Data/Library/Application Support/MediaKit/mediakit.sqlite` |
| iOS app and widget | `containerURL(forSecurityApplicationGroupIdentifier: "group.pl.incred.ArrBarr")/Library/Application Support/MediaKit/mediakit.sqlite` |
| demo (any role) | `.memory` |
| tests | a temp directory per suite, or `.memory` |

Application Support, never Caches: `cache_delete` may reclaim Caches and the store is the offline
render path.

**Open flags and PRAGMAs.** `sqlite3_open_v2` with
`SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX`, plus
`SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION` (`0x00300000`, present in both
the macOS and iOS SDK `sqlite3.h:636`) when `protectFiles` — SQLite applies it to the db, `-wal`
and `-shm` it creates, which `FileManager.setAttributes` after the fact cannot guarantee (lean
finding 12). Then, on the create path only and before any DDL, `PRAGMA auto_vacuum = INCREMENTAL`
(a no-op after the first table; finding 11). Every open:

```sql
PRAGMA journal_mode = WAL;          -- app + widget on one file (iOS)
PRAGMA synchronous  = NORMAL;       -- WAL + NORMAL is crash-safe for a cache
PRAGMA busy_timeout = 5000;         -- also sqlite3_busy_timeout(db, 5000)
PRAGMA foreign_keys = ON;
PRAGMA temp_store   = MEMORY;
PRAGMA wal_autocheckpoint = 256;    -- ~1 MB: keeps the -wal small for the extension
```

**DDL (`user_version = 1`).**

```sql
CREATE TABLE entries (
    key          TEXT    PRIMARY KEY NOT NULL,   -- ResourceKey.storageKey; never a secret
    instance     TEXT    NOT NULL,               -- "radarr#0"
    fingerprint  TEXT    NOT NULL,               -- Fingerprint.rawValue
    operation    TEXT    NOT NULL,               -- OperationID.rawValue, for the telemetry report
    class        INTEGER NOT NULL CHECK (class > 0),   -- volatile == 0 is refused by the DB itself
    payload      BLOB    NOT NULL,               -- re-encoded value (JSON)
    bytes        INTEGER NOT NULL,
    fetched_at   REAL    NOT NULL,
    stale_at     REAL    NOT NULL,               -- invalidation SETS this; rows are never deleted by it
    last_used    REAL    NOT NULL
) STRICT;                                        -- rowid table: payloads can be megabytes (lean TF-4)
CREATE INDEX entries_sweep    ON entries(class, last_used);
CREATE INDEX entries_instance ON entries(instance, fingerprint);

CREATE TABLE entry_tags (
    tag        TEXT NOT NULL,
    entry_key  TEXT NOT NULL REFERENCES entries(key) ON DELETE CASCADE,
    PRIMARY KEY (tag, entry_key)
) STRICT, WITHOUT ROWID;
CREATE INDEX entry_tags_key ON entry_tags(entry_key);

-- The three tables below survive every cache wipe and every migration.
CREATE TABLE capabilities (
    instance     TEXT PRIMARY KEY NOT NULL,
    fingerprint  TEXT NOT NULL,
    version      TEXT,
    capabilities TEXT NOT NULL,                  -- sorted, space-separated Capability.rawValue
    probed_at    REAL NOT NULL,
    origin       TEXT NOT NULL                   -- probe | persisted | conservativeDefault
) STRICT;

CREATE TABLE crosswalk (
    from_ns    TEXT NOT NULL, from_value TEXT NOT NULL,
    to_ns      TEXT NOT NULL, to_value   TEXT NOT NULL,
    kind       TEXT NOT NULL,                    -- MediaKind.rawValue
    confidence INTEGER NOT NULL,
    source     TEXT NOT NULL,
    fetched_at REAL NOT NULL,
    PRIMARY KEY (from_ns, from_value, to_ns, kind)
) STRICT, WITHOUT ROWID;
CREATE INDEX crosswalk_reverse ON crosswalk(to_ns, to_value, kind);

CREATE TABLE live_snapshots (
    instance    TEXT NOT NULL,
    stream      TEXT NOT NULL,                   -- "queue" | "progress" | "sessions"
    payload     BLOB NOT NULL,
    captured_at REAL NOT NULL,
    PRIMARY KEY (instance, stream)
) STRICT, WITHOUT ROWID;

CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL) STRICT;
```

`live_snapshots` is not a cache entry and is never read by `ResourceStore.read`; it is the
last-known row the cold start renders (`LiveStream.last()`), written once per successful live
cycle debounced to 5 s, and it has no `stale_at` — the UI shows it with `captured_at` and replaces
it on the first live value.

**Invalidation** is one statement per call:
`UPDATE entries SET stale_at = ?now WHERE key IN (SELECT entry_key FROM entry_tags WHERE tag IN (…))`.
Nothing is deleted, so the breaker and the first render can serve it. `invalidate(instance:)` is
`UPDATE entries SET stale_at = ?now WHERE instance = ?` plus the fingerprint filter on every read,
which makes a row from a previous server unreachable even before the sweep removes it
(`StorePersistenceTests.readIgnoresRowsFromAnotherFingerprint`).

**Migrations.** `StoreSchema.migrate` reads `PRAGMA user_version` and applies steps in order. A
step may `DROP` and recreate `entries` and `entry_tags` (they are a cache; the cost is one
refresh). `capabilities`, `crosswalk` and `live_snapshots` are migrated in place (`ALTER TABLE` or
copy-and-rename) and never dropped: losing them means a probe storm and an empty cold start. An
unknown *higher* `user_version` (an older build opened a newer file) is not an error: the store
opens with `readOnlyCache = true` for that session — it reads `capabilities`, `crosswalk` and
`live_snapshots`, treats `entries` as empty and writes nothing.

**Two processes on one file (iOS).** The app and the widget each hold one read-write connection;
WAL plus `busy_timeout` serialise them. The widget's role sets `readOnlyCache = false` (it writes
the rows it fetched, so the next app launch starts warm) but `diskCap` is advisory for it: only
the app role runs `sweep()`. A long app-side sweep is bounded by the 200-row transaction batches.

### 4.5 Instances, credentials, fingerprints

```swift
public enum InstanceKind: String, Sendable, Codable, CaseIterable, Hashable {
    case radarr, sonarr, lidarr, whisparr
    case qbittorrent, transmission, deluge, rtorrent, sabnzbd, nzbget
    case plex, jellyfin, emby
    case tmdb
    public enum Family: Sendable { case servarr, download, mediaServer, metadata }
    public var family: Family { get }
}

public struct InstanceID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let kind: InstanceKind
    public let ordinal: Int                        // 0 today; a second instance changes no schema
    public var description: String { "\(kind.rawValue)#\(ordinal)" }
}

public struct Host: Hashable, Sendable, Codable, CustomStringConvertible {
    public let scheme: String, name: String, port: Int
    public init(_ url: URL)                        // path and query are dropped by construction
    public var description: String { "\(name):\(port)" }
}

/// base URL + credential generation. Never the secret, never a hash of it.
public struct Fingerprint: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String                    // "<normalised base URL without query>|<generation>"
    public init(baseURL: URL, generation: String)
}

public struct Credentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public enum Material: Sendable {
        case apiKey(String)
        case bearer(String)
        case userPassword(user: String, password: String)
        case token(String)
        case none
    }
    public let baseURL: URL
    public let material: Material
    /// Opaque, rotated by the provider whenever the secret is written. Drives the fingerprint.
    public let generation: String
    public var description: String { "Credentials(•••)" }        // probe p6: without these the key prints
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// Asked per request. MediaKit never stores a secret and never receives one at configuration time.
public protocol CredentialProvider: Sendable {
    func credentials(for instance: InstanceID) async -> Credentials?
}

public struct InstanceDescriptor: Sendable, Equatable {
    public let id: InstanceID
    public let baseURL: URL
    public let enabled: Bool
    public let generation: String                  // same value the provider returns; lets the registry fingerprint without a secret
    public let limits: HostGovernor.Limits?
}

public actor InstanceRegistry {
    public init(store: ResourceStore, capabilities: CapabilityProbe, sessions: SessionBroker,
                identity: IdentityStore, messages: MessageSubject, telemetry: any TelemetrySink, log: any LogSink)
    /// The ONE place configuration enters MediaKit. For every instance whose fingerprint moved:
    /// `store.invalidate(instance:)`, `capabilities.invalidate`, `sessions.invalidate`,
    /// `identity.forget(instance:)`, then one `ConfigurationChanged` message. Returns the changed set.
    @discardableResult public func apply(_ descriptors: [InstanceDescriptor]) async -> Set<InstanceID>
    public func descriptor(_ id: InstanceID) -> InstanceDescriptor?
    public func fingerprint(_ id: InstanceID) -> Fingerprint?
    public func configured(_ family: InstanceKind.Family) -> [InstanceID]
    public func host(_ id: InstanceID) -> Host?
}
```

**Why a generation, not SHA-256(secret)** (lean finding 6, decision — confirmed in §13.1):
ArrCore's `SecretStore` already owns every write of a secret; stamping a UUID next to the value on
each write (`SecretStore.generation(for:)`, persisted in the same store — the group suite on iOS
so the widget reads it too) makes rotation of a same-length key detectable (phase-0 H9/fact 14)
without hashing a possibly weak download-client password into a plaintext file, and removes the
CryptoKit question from §1.2. Re-entering an identical key bumps the generation and costs one
spurious invalidation; acceptable. Existing installs get a generation lazily on first read.

### 4.6 Identity

```swift
public enum MediaKind: String, Sendable, Codable, CaseIterable, Hashable {
    case movie, series, season, episode, artist, album, track, person
}

public enum IDNamespace: Hashable, Sendable, Codable {
    case tmdbMovie, tmdbSeries, tmdbPerson
    case tvdb, imdb
    case musicBrainzArtist, musicBrainzAlbum, musicBrainzTrack
    case arr(InstanceID)                           // a library row id, meaningful only next to its instance
    case mediaServer(InstanceID)                   // Plex ratingKey / Jellyfin item id
    public var impliedKind: MediaKind? { get }     // nil where the namespace spans kinds (imdb, arr, mediaServer)
}

public struct MediaID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let namespace: IDNamespace
    public let value: String                       // "603", "tt0068646"; never a secret
    public var description: String { get }         // "tmdb-movie:603", "arr:radarr#0:1525" — round-trips
    public init?(_ token: String)
    public static func tmdbMovie(_ id: Int) -> MediaID
    public static func tmdbSeries(_ id: Int) -> MediaID
    public static func tvdb(_ id: Int) -> MediaID
    public static func imdb(_ id: String) -> MediaID          // lowercased "tt…"
    public static func arr(_ instance: InstanceID, _ id: Int) -> MediaID
    public static func server(_ instance: InstanceID, _ id: String) -> MediaID
}

/// One model for movie, series, season, episode, artist, album, track, person. Flat lineage
/// (nearest ancestor first) keeps it Hashable and Codable with no indirection.
public struct MediaIdentity: Hashable, Sendable, Codable {
    public struct Ancestor: Hashable, Sendable, Codable { public let kind: MediaKind; public let ids: Set<MediaID>; public let ordinal: Int? }
    public let kind: MediaKind
    public let ids: Set<MediaID>
    public let ordinal: Int?                       // season / episode / track number
    public let lineage: [Ancestor]                 // episode → [season, series]
    public func id(in namespace: IDNamespace) -> MediaID?
    public func merging(_ other: MediaIdentity) -> MediaIdentity
    public func matches(_ other: MediaIdentity) -> Bool      // shared id, same kind, same ordinal — never title/year
}

public struct Crosswalk: Hashable, Sendable, Codable {
    public enum Confidence: Int, Sendable, Codable, Comparable { case inferred = 40, verified = 80, asserted = 100 }
    public enum Source: String, Sendable, Codable { case arrRecord, arrLookup, mediaServerGuid, tmdbExternalIDs, tmdbFind, libraryIndex }
    public let from: MediaID
    public let to: MediaID
    public let kind: MediaKind
    public let confidence: Confidence
    public let source: Source
    public let fetchedAt: Date
}

public actor IdentityStore {
    public init(database: SQLiteDatabase?, clock: any MediaClock)
    /// Pure lookup, no network; the only identity call allowed on a cold offline launch.
    public func known(_ id: MediaID, in namespace: IDNamespace, minimum: Crosswalk.Confidence = .inferred) -> MediaID?
    public func identity(for id: MediaID, kind: MediaKind) -> MediaIdentity
    public func record(_ edges: [Crosswalk])                  // upsert; higher confidence wins; both directions
    public func forget(instance: InstanceID)                  // fingerprint change
}

/// Replaces SeriesIdentityResolver. Routes, cheapest first; each names the confidence it yields:
///  1. crosswalk (any)  2. TMDB /tv/{id}/external_ids or /find/{id}?external_source=tvdb_id (asserted)
///  3. Sonarr /series/lookup?term=tmdb:N whose record echoes the id (verified)  4. nil.
public struct IdentityResolver: Sendable {
    public init(store: ResourceStore, identity: IdentityStore, tmdb: TMDBService?, sonarr: ServarrService?)
    public func resolve(_ id: MediaID, into namespace: IDNamespace, minimum: Crosswalk.Confidence = .verified) async -> MediaID?
}

// ExternalIDParsing.swift — nonisolated pure functions over String / [String: String].
public enum ExternalIDParsing {
    public static func plexGuids(_ guids: [String], kind: MediaKind) -> Set<MediaID>          // tmdb://, tvdb://, imdb://, plex://, legacy agents
    public static func jellyfinProviderIDs(_ ids: [String: String], kind: MediaKind) -> Set<MediaID>
    public static func servarrIDs(tmdbId: Int?, imdbId: String?, tvdbId: Int?, foreignId: String?, kind: MediaKind) -> Set<MediaID>
    public static func tmdbExternalIDs(imdb: String?, tvdb: Int?) -> Set<MediaID>
}
```

**Cross-walk table** is `crosswalk` in §4.4 (`from_ns, from_value, to_ns, to_value, kind,
confidence, source, fetched_at`). Edges are written by `ResourceStore.commit` from
`Resource.harvest` (MF graft): `library`, `details`, `lookup` harvest arr↔tmdb/imdb/tvdb/mbid at
`.asserted`; the media-server index harvests server↔external ids at `.asserted`; TMDB
`external_ids`/`find` at `.asserted`. Consequence: "do I own this title?" on the search screen is
`identity.known(.tmdbMovie(id), in: .arr(radarr0))`, no library payload; after the first visit the
series detail needs no `/find` hop.

### 4.7 Capabilities

```swift
public struct Capability: Hashable, Sendable, Codable, RawRepresentable { public let rawValue: String }
public extension Capability {
    static let servarrSeasonEndpointV5: Capability    // PUT /api/v5/series/{id}/season (Sonarr major ≥ 5)
    static let whisparrV3: Capability                 // Radarr fork: movie vocabulary, movieCategory
    static let whisparrV2: Capability                 // Sonarr fork: series vocabulary, tvCategory — documented gap
    static let qbittorrentStopStartVerbs: Capability  // 5.x /torrents/stop|start; 4.x pause|resume
}

public struct CapabilitySet: Sendable, Equatable, Codable {
    public enum Origin: String, Sendable, Codable { case probe, persisted, conservativeDefault }
    public let instance: InstanceID
    public let fingerprint: Fingerprint?
    public let version: String?
    public let capabilities: Set<Capability>
    public let probedAt: Date?
    public let origin: Origin
    public func has(_ c: Capability) -> Bool
}

/// Synchronous, lock-guarded: a service picking an endpoint must not await (MF graft).
public final class CapabilityIndex: Sendable {
    public func current(_ instance: InstanceID) -> CapabilitySet      // never nil: conservative default when unknown
    public func has(_ c: Capability, _ instance: InstanceID) -> Bool
}

public actor CapabilityProbe {
    public init(store: ResourceStore, index: CapabilityIndex, database: SQLiteDatabase?, clock: any MediaClock, log: any LogSink)
    public func restore() async                                       // capabilities table → index, at start()
    /// Once per fingerprint: reads the kind's status resource (`reference`, so cached on disk) and derives.
    /// Never throws: probe → persisted row for this fingerprint → conservative default.
    @discardableResult public func ensure(_ instance: InstanceID) async -> CapabilitySet
    public func invalidate(_ instance: InstanceID) async               // fingerprint change or version change
    public func demote(_ c: Capability, for instance: InstanceID) async
    public func promote(_ c: Capability, for instance: InstanceID) async
    public nonisolated static func derive(kind: InstanceKind, statusBody: Data) -> (version: String?, capabilities: Set<Capability>)
    public nonisolated static func conservativeDefault(for kind: InstanceKind) -> Set<Capability>
}
```

| Kind | Probe resource | `derive` rule | Conservative default |
|---|---|---|---|
| radarr, sonarr, lidarr | `status` (`GET {api}/system/status`) | sonarr: `version` major ≥ 5 → `servarrSeasonEndpointV5` (owner's Sonarr is 4.0.19 → absent, v3 double-PUT with no wasted v5 request) | ∅ |
| whisparr | `status` (`GET /api/v3/system/status`) | `version` major 3 → `whisparrV3`; major 2 → `whisparrV2`; other → ∅ | `whisparrV3` (the shipped behaviour) |
| qbittorrent | `version` (`GET /api/v2/app/version`) | major ≥ 5 → `qbittorrentStopStartVerbs` (owner's is v5.2.3) | ∅ (4.x verbs) |
| transmission, deluge, rtorrent, sabnzbd, nzbget | `version` (`session-get`, `daemon.info`, `system.client_version`, `mode=version`, `version`) | version only | ∅ |
| plex, jellyfin, emby | `identity` (`GET /identity`, `GET /System/Info`) | version only | ∅ |
| tmdb | `configuration` (`GET /3/configuration`) | none | ∅ |

Runtime correction is symmetric and one-shot: a command that answers 404/405 on a
capability-gated path calls `demote`/`promote` and re-runs once on the other form (F.6). A
`status` read whose `version` differs from the stored one re-probes. `MediaKit.start()` calls
`ensure` for every configured instance at `.background` — so a v5 Sonarr is promoted before the
first write (MF-9) and every host has a health state within seconds of launch (call-sites shared
defect (c)). Whisparr v2: only the Servarr-generic resources (`status`, `health`, `diskSpace`,
`queue`, `calendar`, `history`) are offered; every movie-vocabulary resource and command throws
`.unsupported(instance, .whisparrV3)` from the service method that builds it.

### 4.8 Events

```swift
public struct QueueCounts: Sendable, Equatable, Codable { public let total, errors, warnings: Int }

public enum DataEvent: Sendable, Equatable {
    case queueChanged(InstanceID)
    case queueStatus(InstanceID, QueueCounts)
    case fileImported(InstanceID, kind: MediaKind, entityID: Int?)       // moviefile | episodefile | trackfile
    case entityChanged(InstanceID, kind: MediaKind, entityID: Int?)      // movie | series | artist | album updated/deleted
    case healthChanged(InstanceID)
    case calendarChanged(InstanceID)
    case commandFinished(InstanceID, name: String)
    case other(InstanceID, resource: String, action: String)
    case woke(Date)
    case connectivity(Host, HostHealth)
}

public actor SignalRSource {
    public init(instance: InstanceID, pipeline: RequestPipeline, clock: any MediaClock, telemetry: any TelemetrySink, log: any LogSink)
    public func events() -> AsyncStream<DataEvent>
    public func start() async
    public func stop() async
    public func forceReconnect() async
    public enum FrameOutcome: Equatable { case events([DataEvent]), close, ignored }
    /// Pure. Servarr nests `action` inside `arguments[0].body`. The 10 RealtimeFrameParsingTests cases port verbatim.
    public nonisolated static func parse(frame: String, instance: InstanceID) -> FrameOutcome
}

public actor EventHub {
    public init(store: ResourceStore, tagMap: EventTagMap, clock: any MediaClock, telemetry: any TelemetrySink, log: any LogSink)
    public func attach(_ source: SignalRSource, for instance: InstanceID) async
    public func detach(_ instance: InstanceID) async
    public func register(_ stream: any LiveStreamPushTarget)             // streams told about pushes
    public func wakeAll() async                                          // forceReconnect every source, emit .woke
    public func events() -> AsyncStream<DataEvent>                       // raw, for ArrCore's notification UX
    public nonisolated func lastEventAt(_ instance: InstanceID) -> Date? // the 300 s silence gate
}

public struct EventTagMap: Sendable {
    public func tags(for event: DataEvent, lastCounts: QueueCounts?) -> Set<InvalidationTag>
}
```

`SignalRSource` ports `RealtimeUpdates.SignalRConnection` off ArrCore types: negotiate is
`pipeline.send(RequestPlan(operation: "sonarr.realtime.negotiate", POST /signalr/messages/negotiate?negotiateVersion=1,
auth: .header("X-Api-Key")))`; the socket is `pipeline.socket(plan)` with
`auth: .querySecret("access_token")` on `wss://…/signalr/messages?id=…` (the one URL that must
never be logged whole; `Redaction` strips it). Handshake consume, 15 s ping pump,
`receive` with timeout, backoff 1 s → 30 s doubling, reset only when a cycle lived (a frame, or
`minimumHealthyLifetime` 30 s), 300 s cold-start cadence after 10 dead cycles, `queueChanged`
emitted on every (re)connect — unchanged from today. Because the socket comes from the injected
`SocketTransport`, `FixtureTransport.enqueueFrames` drives criterion 4 end to end and the
negotiate request is counted, limited and breakered like any other.

**Sources → tags** (`EventTagMap`, the only place an event becomes tags; criterion 4):

| Source | Event | Tags |
|---|---|---|
| SignalR `queue` (`sync`/`updated`/`deleted`) | `queueChanged(i)` | `c:queue@i` |
| SignalR `queue/status` | `queueStatus(i, counts)` | ∅ if `counts == lastCounts[i]`, else `c:queue@i` (keeps `noteQueueStatus`'s skip, CF-8) |
| SignalR `moviefile`/`episodefile`/`trackfile` | `fileImported(i, kind, id)` | `c:queue@i`, `c:library@i`, `c:history@i`, `c:calendar@i`, `e:kind/i/id` when carried |
| SignalR `movie`/`series`/`artist`/`album` `updated`/`deleted` | `entityChanged(i, kind, id)` | `c:library@i`, `c:calendar@i`, `e:kind/i/id` when carried (the 10-min `warm` TTL on `library` stays as the backstop, TF-4) |
| SignalR `health` | `healthChanged(i)` | `c:health@i` |
| SignalR `calendar` | `calendarChanged(i)` | `c:calendar@i` |
| SignalR `command` (`completed`/`failed`) | `commandFinished(i, name)` | `c:commands@i`; plus `c:queue@i` when `name` is a search or grab |
| SignalR anything else (`system/task`, `version`, `queue/details`) | `other` | ∅ |
| Wake (`EventHub.wakeAll`, called by `AppDelegate`) | `woke` | ∅ — `HostGovernor.noteWake` + `LiveStream.refreshNow` on every stream; no store row is marked stale |
| Governor | `connectivity(host, health)` | ∅ — a `ConnectivityChanged` message only |
| Download-client polling | — | not an event: polling is `LiveStream`'s cadence (§6.2) |

`EventHub` coalesces per instance in a 250 ms burst window with a 1 s floor while a stream is
`.foreground` and 30 s while `.background` (today's `QueueViewModel` constants), then calls
`store.invalidate(tags, reason: .event)` and `stream.notePush(instance, at:)` on every registered
stream. `wakeAll` also posts nothing itself — `noteWake` and the streams do the work.

**Observations bridge.** `store.invalidate` and every commit call `revision.bump(tags)`.
ArrCore: `for await _ in Observations({ kit.store.revision.tick(for: .collection(.queue, sonarr0)) })`
in a view model; `Snapshot` and `CompositionEngine.observe` subscribe the same way. Nothing in
MediaKit is `@MainActor`.

**Typed messages** (Foundation, macOS 26 — `NotificationCenter.AsyncMessage: Sendable`, subject
overloads require `Subject: AnyObject`; `post(_:subject:)`, `messages(of:for:)`,
`addObserver(of:for:using:)` compile against a final-class subject — verified in
`scratchpad/sqlprobe/Msg.swift` and probe p7; `typealias Subject = Never` is rejected). The
center is injected and the subject is the kit instance, not a singleton (lean finding 10), so two
kits in two test suites cannot cross-talk:

```swift
public final class MessageSubject: Sendable { public init() {} }        // one per MediaKit; `kit.subject`

public struct ConfigurationChanged: NotificationCenter.AsyncMessage {
    public typealias Subject = MessageSubject
    public let instances: Set<InstanceID>          // whose fingerprint moved
}
public struct Invalidated: NotificationCenter.AsyncMessage {
    public typealias Subject = MessageSubject
    public let tags: Set<InvalidationTag>
    public let reason: InvalidationReason
}
public struct ConnectivityChanged: NotificationCenter.AsyncMessage {
    public typealias Subject = MessageSubject
    public let host: Host
    public let instances: Set<InstanceID>
    public let health: HostHealth
}
// ArrCore: for await m in center.messages(of: kit.subject, for: ConnectivityChanged.self) { … }
```

`AsyncMessage` delivery is asynchronous on arbitrary isolation; ArrCore hops to the main actor
itself. The twelve navigation posts stay `Notification.Name` until phase 7 (criterion 23).

### 4.9 Telemetry and logging

```swift
public enum TelemetryEvent: Sendable {
    case request(OperationID, Host, RequestPriority)
    case response(OperationID, Host, status: Int, bytes: Int, duration: Duration)
    case cacheHit(ResourceKey, CacheOrigin)
    case cacheMiss(ResourceKey)
    case staleServed(ResourceKey, MediaKitError)
    case coalesced(ResourceKey, waiters: Int)
    case skipped(OperationID, Host, SkipReason)                // .breakerOpen, .rateLimited, .notConfigured
    case failure(OperationID, Host, MediaKitError)
    case invalidated(Set<InvalidationTag>, InvalidationReason)
    case breakerOpened(Host, until: Date)
    case breakerClosed(Host)
    case rateLimited(Host, retryAfter: Duration?)
    case sessionEstablished(InstanceID, generation: Int)
}
public enum SkipReason: String, Sendable { case breakerOpen, rateLimited, notConfigured }

public protocol TelemetrySink: Sendable { func record(_ event: TelemetryEvent) }

/// Lock-guarded (OSAllocatedUnfairLock), not an actor: `record` runs on the governor's critical path.
public final class TelemetryRecorder: TelemetrySink, Sendable {
    public struct HostCounters: Sendable, Equatable {
        public var requests, hits, misses, staleServed, coalesced, skipped, failures, invalidations, breakerOpens, rateLimits, bytes: Int
    }
    public init(clock: any MediaClock)
    public func record(_ event: TelemetryEvent)
    public func counters(for host: Host) -> HostCounters
    public func counters(for operation: OperationID) -> Int      // request count per operation
    public func report() -> String                               // criterion 21; one block per host, top-10 operations; no URL, no query
    public func reset()
}
public struct NoTelemetry: TelemetrySink { public func record(_ event: TelemetryEvent) {} }

public enum LogLevel: Sendable { case debug, notice, error, fault }
public protocol LogSink: Sendable {
    func log(_ level: LogLevel, category: String, _ message: @autoclosure () -> String, privateFields: [String: String])
}
public struct OSLogSink: LogSink {
    public init(subsystem: String)                               // ArrCore passes "pl.incred.ArrBarr"
}
public struct NoLog: LogSink {}
```

Categories are `MediaKit.<Area>` (`Transport`, `Store`, `Governor`, `Session`, `Events`,
`Live`, `Capabilities`, `Discovery`). Levels follow `CLAUDE.md`: `.debug` for repeating work
(requests, hits, polls), `.notice` for one-shot events with a user-visible consequence (breaker
open/close, session established, invalidation by command, a capability demoted), `.error` for
failures the user may feel, `.fault` only for a broken invariant (a volatile row reaching
`put`). `privateFields` carry titles, hosts and anything from the user's infrastructure and are
logged `.private`; counts, ids and enum cases go in the message as `.public`. Timings go to
`OSSignposter` (`init(subsystem:category:)` verified) intervals `mediakit.request`,
`mediakit.decode`, `mediakit.sql`, `mediakit.compose`, `mediakit.coldstart` — never to log lines.

### 4.10 Discovery

```swift
public struct DiscoveredServer: Sendable, Hashable {
    public enum Source: String, Sendable { case bonjour, udpBeacon }
    public let kind: InstanceKind                  // .plex, .jellyfin, .emby
    public let name: String
    public let endpoint: URL
    public let identifier: String?                 // machineIdentifier / Id — never a token
    public let source: Source
}

public actor Discovery {
    public init(log: any LogSink)
    /// Plex via NetworkBrowser(for: .bonjour("_plexmediasvr._tcp", domain: nil, includeTxtRecord: true))
    /// and `run(_:)`; Jellyfin/Emby via a NetworkConnection<UDP> datagram "who is JellyfinServer?" to
    /// 255.255.255.255:7359 (macOS only, see §13.3). Nothing is written; results are Settings hints.
    public func scan(for kinds: Set<InstanceKind>, timeout: Duration = .seconds(4)) async -> [DiscoveredServer]
    public nonisolated static func parseBonjour(name: String, txt: [String: String], host: String, port: Int) -> DiscoveredServer?
    public nonisolated static func parseBeacon(_ payload: Data, from host: String) -> DiscoveredServer?
}
```

Verified (appledoc): `NetworkBrowser<Provider: BrowserProvider>` (Network, macOS 26),
`init(for:using:)`, `run(_ handler: @escaping @isolated(any) @Sendable ([Provider.Endpoint]) async throws -> Void)`,
`BrowserProvider.bonjour(_:domain:includeTxtRecord:) -> Bonjour`, `NetworkConnection<ApplicationProtocol>`
with `init(to:using: NWParametersBuilder)`, `UDP` (Network, macOS 26). The datagram send/receive
call names on `NetworkConnection` were not reachable through the documentation JSON and are a
phase-3 documentation check before the beacon is written (§9.5). Criterion 25 tests the two
parsers only. iOS needs `NSBonjourServices` (`_plexmediasvr._tcp`) and
`NSLocalNetworkUsageDescription` in `ArrBarriOS`'s Info.plist — added in phase 3 through
`AddInfoPlist` in the floor-raise commit.

---

## 5. Service vocabularies

Conventions. `OperationID.rawValue` = `<kind>.<corpus operation>` — the corpus `operation`
column is the operation vocabulary, so criterion 26 is a pure join and fixture files keep their
phase-0 names (`radarr/fetchqueue.json`, `radarr/fetchqueue-api-v3-moviefile.json`). Where one
new resource replaces several corpus rows, the table names every row it covers; §5.7 proves all
181 rows are covered. `{api}` is `/api/v3` (radarr, sonarr, whisparr) or `/api/v1` (lidarr).
Tags use §4.3's vocabulary; `i` is the instance. "Gate" is the capability that must be present.
Every service method is synchronous and builds its `RequestPlan` from `CapabilityIndex` at call
time; a service is a value:

```swift
public struct ServarrService: Sendable {
    public init(instance: InstanceID, profile: ServarrProfile, capabilities: CapabilityIndex)
    public let instance: InstanceID
    public let profile: ServarrProfile
}
```

### 5.1 Servarr — one service, four flavours

```swift
public struct ServarrProfile: Sendable, Hashable {
    public let kind: InstanceKind
    public let apiBase: String                    // "/api/v3" | "/api/v1"
    public let entityNoun: String                 // "movie" | "series" | "artist"
    public let entityKind: MediaKind              // .movie | .series | .artist
    public let childNoun: String?                 // nil | "episode" | "album"
    public let fileNoun: String                   // "moviefile" | "episodefile" | "trackfile"
    public let fileParentKey: String              // "movieId" | "seriesId" | "albumId"
    public let queueIncludeFlag: String           // "includeUnknownMovieItems" | "includeEpisode" | "includeUnknownArtistItems"
    public let historyIncludeKeys: [String]       // ["includeMovie"] | ["includeSeries","includeEpisode"] | ["includeArtist","includeAlbum"]
    public let historyIDsKey: String              // "movieIds" | "seriesIds" | "albumIds"
    public let calendarIncludeKey: String?        // nil | "includeSeries" | nil
    public let searchCommand: String              // "MoviesSearch" | "SeriesSearch" | "ArtistSearch"
    public let downloadCategoryKey: String        // "movieCategory" | "tvCategory" | "musicCategory"
    public static let radarr, sonarr, lidarr, whisparr: ServarrProfile   // whisparr = radarr with kind .whisparr
}
```

Resources (`ServarrService` methods). Class column = `FreshnessClass`; "harvest" = writes crosswalk edges.

| Method | OperationID (corpus rows covered) | Request | Tags | Class | Gate |
|---|---|---|---|---|---|
| `status()` | `<k>.testConnection` | `GET {api}/system/status` | `k:i` | reference | — |
| `health()` | `<k>.fetchHealth` | `GET {api}/health` | `c:health@i` | live | — |
| `diskSpace()` | `<k>.fetchDiskSpace` | `GET {api}/diskspace` | `c:health@i` | live | — |
| `queue()` | `<k>.fetchQueue` (`/queue` row) | `GET {api}/queue?pageSize=1000&<queueIncludeFlag>=true` | `c:queue@i` | volatile | — |
| `calendar(start:end:)` | `<k>.fetchCalendar` | `GET {api}/calendar?start&end&unmonitored=true[&includeSeries=true]` | `c:calendar@i` | warm | — |
| `history(page:pageSize:)` | `<k>.fetchHistory` | `GET {api}/history?page&pageSize&sortKey=date&sortDirection=descending&<historyIncludeKeys>` | `c:history@i` | warm | — |
| `historyFor(entityID:)` | `radarr.fetchHistoryForMovie`, `sonarr.fetchHistoryForSeries`, `lidarr.fetchHistoryForAlbum` | history query + `<historyIDsKey>=<id>` | `c:history@i`, `e:<entityKind>/i/id` | warm | — |
| `library()` | `radarr.fetchAllMovies`, `sonarr.fetchAllSeries`, `lidarr.fetchAllArtists` (+ `<k>.search.fetchLibraryOwnership`, same request) | `GET {api}/<entityNoun>` | `c:library@i` | warm | whisparr: `whisparrV3` |
| `details(id:)` | `radarr.fetchMovieDetails`, `sonarr.fetchSeriesDetails`, `lidarr.fetchArtistDetails` | `GET {api}/<entityNoun>/{id}` | `e:<entityKind>/i/id`, `c:library@i` | reference | whisparr: `whisparrV3` |
| `albumDetails(id:)` (lidarr) | `lidarr.fetchAlbumDetails` | `GET /api/v1/album/{id}` | `e:album/i/id` | reference | — |
| `movieFiles` (radarr, whisparr) — `BatchResource<Int, ArrMovieFile>` `.chunked(max: 25)` | `radarr.fetchMovieFile` (+ `radarr.fetchQueue` `/moviefile` side-load row) | `GET /api/v3/moviefile?movieId=a&movieId=b…` | `e:movie/i/id` per id | reference | — |
| `episodeFiles` (sonarr) — `BatchResource<Int, ArrEpisodeFile>` `.perKey` | `sonarr.fetchEpisodeFileMap` (+ `sonarr.fetchQueue` `/episodefile` row) | `GET /api/v3/episodefile?seriesId=` | `e:series/i/id` | reference | — |
| `trackFiles` (lidarr) — `BatchResource<Int, ArrTrackFile>` `.perKey` | `lidarr.fetchTrackFiles` (+ `lidarr.fetchQueue` `/trackfile` row) | `GET /api/v1/trackfile?albumId=` | `e:album/i/id` | reference | — |
| `episodes(seriesID:)` (sonarr) | `sonarr.fetchEpisodes` | `GET /api/v3/episode?seriesId=` | `e:series/i/id` | reference | — |
| `albums(artistID:)` (lidarr) | `lidarr.fetchArtistAlbums` | `GET /api/v1/album?artistId=` | `e:artist/i/id` | reference | — |
| `tracks(albumID:)` (lidarr) | `lidarr.fetchTracks` | `GET /api/v1/track?albumId=` | `e:album/i/id` | reference | — |
| `credits(movieID:)` (radarr) | `radarr.fetchCredits` | `GET /api/v3/credit?movieId=` | `e:movie/i/id` | archival | — |
| `alternateTitles()` (radarr) | `radarr.alternateTitleMap` | `GET /api/v3/alttitle` | `c:library@i` | archival | — |
| `qualityProfiles()` | `<k>.fetchQualityProfiles` (+ `<k>.search.fetchQualityProfiles`) | `GET {api}/qualityprofile` | `c:profiles@i` | reference | — |
| `metadataProfiles()` | `<k>.search.fetchMetadataProfiles` | `GET {api}/metadataprofile` | `c:profiles@i` | reference | — |
| `rootFolders()` | `<k>.search.fetchRootFolders` | `GET {api}/rootfolder` | `c:profiles@i` | reference | — |
| `customFormats()` | `<k>.fetchCustomFormats` | `GET {api}/customformat` | `c:profiles@i` | reference | — |
| `downloadClients()` | `<k>.fetchDownloadClients` | `GET {api}/downloadclient` | `c:profiles@i` | reference | — |
| `commands()` | `<k>.isSearchRunning` | `GET {api}/command` | `c:commands@i` | live | — |
| `lookup(term:)` | `<k>.search.lookup` (`/<entityNoun>/lookup` row) | `GET {api}/<entityNoun>/lookup?term=` | `c:lookup@i` | live | whisparr: `whisparrV3` |
| `lidarrSearch(term:)` (lidarr) | `lidarr.search.lookup` (`/search` row) + `lidarr.search.addAlbum` GET leg | `GET /api/v1/search?term=` | `c:lookup@i` | live | — |
| `releases(entityID:)` | `<k>.fetchReleases` | `GET {api}/release?<movieId|episodeId|albumId>=` (timeout 120 s) | ∅ | volatile, `ttl: 60 s` | — |

`library`, `details`, `lookup` and `albumDetails` carry `harvest` closures
(`ExternalIDParsing.servarrIDs` → `Crosswalk(.arr(i, id) ↔ tmdb/imdb/tvdb/musicBrainz, .asserted)`).
Queue rows decode into `ArrQueueRecord` with an `ArrEntityRef` that takes whichever of
`movie`/`series`/`episode`/`album`/`artist` the flavour embeds; calendar and history likewise.

Commands. `INV` = tags invalidated after a 2xx. `track` = `Command.tracking = .arrCommand(timeout: 10 min)`
(the store polls `commands()` at `.background` every 3 s until `completed`/`failed`, then invalidates `INV` again — replaces `DetailView.watchSearchState`).

| Method | OperationID (corpus rows) | Requests inside `run` | INV | Gate / notes |
|---|---|---|---|---|
| `deleteQueueItem(id:removeFromClient:blocklist:)` | `<k>.deleteQueueItem` | `DELETE {api}/queue/{id}?removeFromClient&blocklist` | `c:queue@i`, `c:history@i` | optimistic `.removed` |
| `grabQueueItem(id:)` | `<k>.grabQueueItem` | `POST {api}/queue/grab/{id}` body `{}` | `c:queue@i` | — |
| `grabRelease(guid:indexerID:)` | `<k>.grabRelease` | `POST {api}/release` `{guid, indexerId}` (timeout 120 s) | `c:queue@i` | — |
| `search(_ target:)` where target ∈ movie(ids) / series(id) / season(id, n) / episodes(ids) / album(ids) | `radarr.searchMovie`, `sonarr.searchSeries`, `sonarr.searchSeason`, `sonarr.searchEpisodes`, `lidarr.searchAlbum` | `POST {api}/command` `{name: "MoviesSearch"|"SeriesSearch"|"SeasonSearch"|"EpisodeSearch"|"AlbumSearch", …ids}` | `c:commands@i`, `e:…`; `c:queue@i` on completion | track |
| `command(named:body:)` | `radarr.postCommand` | `POST {api}/command` `{name, …}` (RefreshMovie today) | `c:commands@i`, `e:…` | track |
| `setMonitored(entityID:_:)` | `radarr.setMovieMonitored`, `sonarr.setSeriesMonitored`, `lidarr.setArtistMonitored` (GET + PUT rows) | `GET {api}/<entityNoun>/{id}` → decode `ArrRecordEnvelope` → flip `monitored` → `PUT {api}/<entityNoun>/{id}` | `e:…`, `c:library@i`, `c:calendar@i` | typed RMW; the GET is `pipeline.send`, never the cache |
| `setAlbumMonitored(albumID:_:)` (lidarr) | `lidarr.setAlbumMonitored` (GET + PUT) | `GET /api/v1/album/{id}` → flip → `PUT /api/v1/album/{id}` | `e:album/i/id`, `c:calendar@i` | typed RMW |
| `setEpisodesMonitored(ids:_:)` (sonarr) | `sonarr.setEpisodesMonitored` | `PUT /api/v3/episode/monitor` `{episodeIds, monitored}` | `e:series/i/id`, `c:calendar@i` | — |
| `setSeasonMonitored(seriesID:season:_:)` (sonarr) | `sonarr.setSeasonMonitored` (v5 PUT row; v3 GET ×2 + PUT ×2 rows) | if `servarrSeasonEndpointV5`: `PUT /api/v5/series/{id}/season` `{seasonNumber, monitored}`; else GET → PUT with the *opposite* value → GET → PUT with the target (Sonarr cascades only on a transition). A 404/405 on the v5 path → `ctx.demote` and the v3 form once. | `e:series/i/id`, `c:calendar@i` | gate `servarrSeasonEndpointV5` |
| `add(_ payload: ArrAddPayload)` | `radarr.search.addMovie`, `sonarr.search.addSeries`, `lidarr.search.addArtist` | `POST {api}/<entityNoun>` | `c:library@i`, `c:calendar@i`, `c:lookup@i` | `SonarrMonitorMode.apiValue` spellings (`firstSeason`, `latestSeason`) preserved in `ArrAddOptions` |
| `addAlbum(_ payload:)` (lidarr) | `lidarr.search.addAlbum` (GET `/search` + POST `/album` rows) | `GET /api/v1/search?term=` → pick the row whose `foreignAlbumId` matches → `POST /api/v1/album` | `c:library@i`, `c:calendar@i`, `c:lookup@i` | two requests in one `run` |
| `update(entityID:edit:moveFiles:)` | `<k>.updateLibraryRecord` (GET + PUT) | `GET {api}/<entityNoun>/{id}` → `edit(ArrRecordEnvelope)` → `PUT {api}/<entityNoun>/{id}?moveFiles=` | `e:…`, `c:library@i`, `c:calendar@i` | typed RMW |
| `delete(entityID:deleteFiles:addImportExclusion:)` | `<k>.deleteLibraryRecord` | `DELETE {api}/<entityNoun>/{id}?deleteFiles&addImportExclusion&addImportListExclusion` (both spellings, as today) | `c:library@i`, `e:…`, `c:calendar@i` | — |

**Typed read-modify-write.** `ArrRecordEnvelope<Known: Codable>` decodes the fields MediaKit
models into `known` and everything else into `extra: [String: JSONValue]`; re-encoding merges
`known` over `extra` so unmodelled fields are echoed back (memory note: untyped JSON bodies escape
renames). No `[String: Any]` crosses a function boundary; phase-0 fact 2 is retired.

**Whisparr** = `ServarrProfile.radarr` with `kind: .whisparr`; the probe sets `whisparrV3` or
`whisparrV2` (§4.7). Under `whisparrV2` only the rows without a gate above exist; the gated
methods throw `.unsupported(instance, .whisparrV3)` at construction. Fixtures under
`Fixtures/whisparr/` are synthesised from the Radarr bodies (`synthetic: true`).

### 5.2 Download clients

```swift
public struct DownloadTask: Sendable, Hashable, Codable {
    public let id: String                     // lowercased hash / nzo_id — the arr's downloadId
    public let name: String
    public let state: State                   // downloading, paused, queued, seeding, checking, stalled, error, completed
    public let progress: Double               // 0…1
    public let downloadSpeed: Int64?
    public let sizeBytes: Int64?
    public let etaSeconds: Int?
    public let category: String?
    public enum State: String, Sendable, Codable { case downloading, paused, queued, seeding, checking, stalled, error, completed }
}
public struct DownloadPayload: Sendable {
    public enum Content: Sendable { case file(Data, filename: String), magnet(String) }
    public let content: Content
}
public enum DownloadAction: String, Sendable { case pause, resume, delete, forceStart }

public protocol DownloadService: Sendable {
    var instance: InstanceID { get }
    func version() -> Resource<String>                                           // reference; the probe resource
    /// The live pump for LiveStream<DownloadTask>; volatile, never a store row. `ids` narrows where the API can.
    func tasks(ids: Set<String>) -> RequestPlan
    func decodeTasks(_ response: HTTPResponse, ids: Set<String>) throws -> [DownloadTask]
    func defaultAddPaused() -> Resource<Bool?>                                    // reference
    func action(_ action: DownloadAction, ids: [String], deleteFiles: Bool) -> Command
    func add(_ payload: DownloadPayload, category: String?, paused: Bool) -> Command
}
```

| Client | `version` (OperationID) | `tasks` (OperationID) | Actions (OperationID → request) | `add` (OperationID → request) | `defaultAddPaused` |
|---|---|---|---|---|---|
| qBittorrent | `qbittorrent.testConnection` `GET /api/v2/app/version` | `qbittorrent.fetchProgress` `GET /api/v2/torrents/info` (+ `qbittorrent.contains`, same request, used inside `add`) | `qbittorrent.pause` → `POST /torrents/stop` if `qbittorrentStopStartVerbs` else `/torrents/pause`; `qbittorrent.resume` → `/torrents/start` \| `/torrents/resume`; `qbittorrent.delete` → `POST /torrents/delete` form `hashes,deleteFiles`; `qbittorrent.forceStart` → `POST /torrents/setForceStart` | `qbittorrent.addMagnet` / `qbittorrent.addFile` → `POST /api/v2/torrents/add` multipart with `urls` or `torrents` file, `category`, **both** `paused` and `stopped` (phase-0 fact 4); HTTP 409 or body exactly `Fails.` → re-read `tasks` and, if the hash is present, succeed as duplicate, else `.rejected` | `qbittorrent.defaultAddPaused` `GET /api/v2/app/preferences` (`start_paused_enabled`) |
| Transmission | `transmission.testConnection` RPC `session-get` | `transmission.fetchProgress` RPC `torrent-get` fields `hashString,percentDone,rateDownload,status,name,totalSize,eta`, `ids` | `transmission.pause` → `torrent-stop`; `.resume` → `torrent-start`; `.delete` → `torrent-remove` `delete-local-data` | `transmission.addMagnet` → `torrent-add` with `download-dir` = `session-get`'s `download-dir` + `/<category>` (two requests in `run`) | `session-get` `start-added-torrents` (same request as version) |
| Deluge | `deluge.testConnection` RPC `daemon.info` (`auth.login` is the session strategy, §5.5) | `deluge.fetchProgress` RPC `core.get_torrents_status` `[{}, [fields]]` | `deluge.pause` → `core.pause_torrent`; `.resume` → `core.resume_torrent`; `.delete` → `core.remove_torrent` | `deluge.addMagnet` → `core.add_torrent_magnet`; file → `core.add_torrent_file`; `label.set_torrent` after add is non-fatal | `core.get_config` `add_paused` |
| rTorrent | `rtorrent.testConnection` XML-RPC `system.client_version` | `rtorrent.fetchProgress` XML-RPC `d.multicall2("", "main", d.hash=, d.name=, d.completed_bytes=, d.size_bytes=, d.down.rate=, d.state=, d.is_active=)` with the positional alignment check | `rtorrent.pause` → `d.stop`; `.resume` → `d.start`; `.delete` → `d.erase` | `rtorrent.addMagnet` → `load.start`; file → `load.raw_start` | none (`nil`) |
| SABnzbd | `sabnzbd.testConnection` `GET /api?mode=version&output=json` | `sabnzbd.fetchProgress` `GET /api?mode=queue&output=json` (+ `sabnzbd.contains`, same request) | `sabnzbd.pause` → `mode=queue&name=pause&value=<nzo_id>`; `.resume` → `name=resume`; `.delete` → `name=delete` (all GET, as recorded) | `sabnzbd.addFile` → `POST /api?mode=addfile&output=json` multipart `name` file, `cat` | none |
| NZBGet | `nzbget.testConnection` RPC `version` | `nzbget.fetchProgress` RPC `listgroups [0]` | `nzbget.pause` → `editqueue ["GroupPause", "", [ids]]`; `.resume` → `"GroupResume"`; `.delete` → `"GroupDelete"` | `nzbget.addFile` → `append [name, base64, category, 0, false, false, "", 0, "SCORE"]` | none |

`apikey` for SABnzbd is `AuthPlacement.querySecret("apikey")` on every plan — one of the two
sanctioned query secrets; `Redaction` strips it. SABnzbd `history` (`sabnzbd.history`,
`GET /api?mode=history&output=json&limit=`) is a `Resource<[SABHistorySlot]>`, `warm`, tag
`c:downloads@i`, read by the History feed composition. `forceStart` on anything but qBittorrent
throws `.unsupported(instance, Capability("forceStart"))` — the one non-probe capability, declared
as a static constant `Capability.downloadForceStart` set by construction for qBittorrent only.

### 5.3 Plex, Jellyfin, Emby

```swift
public struct MediaServerIndexEntry: Sendable, Hashable, Codable {       // the slim projection row (§4.3)
    public let itemID: String                 // ratingKey / Id
    public let kind: MediaKind                // movie | series
    public let ids: Set<MediaID>              // from guids / ProviderIds
    public let title: String
    public let year: Int?
    public let artworkPath: String?           // thumb / ImageTags.Primary
    public let viewCount: Int
    public let lastViewedAt: Date?
}
public struct MediaServerSession: Sendable, Hashable, Codable { public let itemID: String, title: String, user: String?, progress: Double?, state: String }
public struct MediaServerHistoryRow: Sendable, Hashable, Codable { public let itemID: String, ids: Set<MediaID>, kind: MediaKind, title: String, viewedAt: Date }

public struct MediaServerService: Sendable {
    public init(instance: InstanceID, capabilities: CapabilityIndex, userID: String?)   // userID: Jellyfin/Emby only
}
```

| Method | OperationID (corpus rows) | Plex request | Jellyfin / Emby request | Tags | Class |
|---|---|---|---|---|---|
| `identity()` | `plex.testConnection` / `jellyfin.testConnection` / `emby.testConnection` | `GET /identity` | `GET /System/Info` | `k:i` | reference |
| `libraries()` | `plex.libraries` (+ `plex.libraryIndex` `/library/sections` row) | `GET /library/sections` | `GET /Library/VirtualFolders` | `c:library@i` | reference |
| `libraryIndex(section:)` → `[MediaServerIndexEntry]` | `plex.libraryIndex` (`/library/sections/{id}/all` row) | `GET /library/sections/{key}/all?includeGuids=1` | `GET /Users/{userId}/Items?ParentId=&Recursive=true&Fields=ProviderIds,UserData` | `c:library@i` | warm |
| `sessions()` | `plex.nowPlaying` | `GET /status/sessions` | `GET /Sessions` | `c:sessions@i` | volatile (live pump only) |
| `watchHistory(limit:)` | `plex.recentlyWatched` | `GET /status/sessions/history/all?sort=viewedAt:desc&X-Plex-Container-Start=0&X-Plex-Container-Size=` | `GET /Users/{userId}/Items?IsPlayed=true&SortBy=DatePlayed&SortOrder=Descending&Limit=` | `c:history@i` | warm |
| `seasonArtwork(item:)` | `plex.seasonPosters` | `GET /library/metadata/{id}/children` | `GET /Shows/{id}/Seasons?userId=` | `e:series/i/…` | reference |
| **cmd** `scanLibrary(section:)` | `plex.scanLibrary` | `GET /library/sections/{id}/refresh` | `POST /Library/Refresh` | INV `c:library@i` | fixture-only (not on the allow-list) |
| **cmd** `emptyTrash(section:)` | `plex.emptyTrash` | `PUT /library/sections/{id}/emptyTrash` | — (`.unsupported`) | INV `c:library@i` | fixture-only |

`libraryIndex` and `watchHistory` carry `harvest` (`ExternalIDParsing.plexGuids` /
`jellyfinProviderIDs` → `Crosswalk(.server(i, itemID) ↔ external ids, .asserted, .mediaServerGuid)`).
Plex sends `Accept: application/json` on every request. Jellyfin/Emby fixtures are synthetic
(`synthetic: true`); their `userId` comes from `MediaServerConfig.userId` (resolved today by
`testConnection` from `/Users`; that resolution becomes `MediaServerService.resolveUser()` →
`GET /Users` — OperationID `jellyfin.users`, on the allow-list).

### 5.4 TMDB

```swift
public struct TMDBService: Sendable {
    public init(instance: InstanceID = InstanceID(kind: .tmdb, ordinal: 0), capabilities: CapabilityIndex)
}
```

Auth is chosen from `Credentials.Material`: `.bearer` (v4 read token) → `Authorization: Bearer`;
`.apiKey` (32-hex v3 key) → `querySecret("api_key")`, the second sanctioned query secret.
TMDB's governor gets `minimumInterval: .milliseconds(250)`.

| Method | OperationID (corpus rows) | Request | Tags | Class |
|---|---|---|---|---|
| `configuration()` | `tmdb.testConnection` | `GET /3/configuration` | `k:i` | reference |
| `searchPerson(query:)` | `tmdb.searchPerson` | `GET /3/search/person?query=` | `c:lookup@i` | live |
| `movie(id:)` | `tmdb.movieCountries` | `GET /3/movie/{id}` | `x:tmdb-movie:id` | archival |
| `movieCredits(id:)` | `tmdb.movieCredits` | `GET /3/movie/{id}/credits` | `x:tmdb-movie:id` | archival |
| `movieVideos(id:)` | `tmdb.movieVideos` | `GET /3/movie/{id}/videos` | `x:tmdb-movie:id` | archival |
| `movieRecommendations(id:page:)` | `tmdb.recommendedMovies` | `GET /3/movie/{id}/recommendations?page=` | `x:tmdb-movie:id` | warm |
| `tv(id:)` | `tmdb.tvCountries` (+ `tmdb.tvCreators`, same request) | `GET /3/tv/{id}` | `x:tmdb-series:id` | archival |
| `tvCredits(id:)` | `tmdb.tvCredits` | `GET /3/tv/{id}/aggregate_credits` | `x:tmdb-series:id` | archival |
| `tvVideos(id:)` | `tmdb.tvVideos` | `GET /3/tv/{id}/videos` | `x:tmdb-series:id` | archival |
| `tvRecommendations(id:page:)` | `tmdb.recommendedTV` | `GET /3/tv/{id}/recommendations?page=` | `x:tmdb-series:id` | warm |
| `tvExternalIDs(id:)` | `tmdb.tvdbIdFromTVId` | `GET /3/tv/{id}/external_ids` | `x:tmdb-series:id` | archival (harvest `.tmdbExternalIDs`) |
| `find(tvdbID:)` | `tmdb.tvIdFromTVDB` | `GET /3/find/{id}?external_source=tvdb_id` | `x:tvdb:id` | archival (harvest `.tmdbFind`) |
| `person(id:)` | `tmdb.personDetails` | `GET /3/person/{id}` | `x:tmdb-person:id` | archival |
| `personMovieCredits(id:)` | `tmdb.personMovieCredits` | `GET /3/person/{id}/movie_credits` | `x:tmdb-person:id` | archival |
| `personTVCredits(id:)` | `tmdb.personTVCredits` | `GET /3/person/{id}/tv_credits` | `x:tmdb-person:id` | archival |
| `discoverMovies(sort:minVotes:)` | `tmdb.discoverMovies` | `GET /3/discover/movie?include_adult=false&sort_by=&vote_count.gte=` | `c:lookup@i` | warm |
| `discoverTV(sort:minVotes:)` | `tmdb.discoverTV` | `GET /3/discover/tv?include_adult=false&sort_by=&vote_count.gte=` | `c:lookup@i` | warm |

`tmdb.similarMovies` and `tmdb.similarTV` are **not** implemented: no ArrCore consumer calls
them (`LocalToolBackend+Discover.swift:400,427` uses recommendations only). `image.tmdb.org`
URLs never carry a credential.

### 5.5 Auth and session handling per service

```swift
public struct SessionToken: Sendable { public var headers: HTTPHeaders; public var query: [(String, String)]; public var generation: Int }
public enum SessionRejection: Sendable, Equatable { case unauthenticated; case handshake(header: String, value: String) }
public typealias SessionSend = @Sendable (HTTPRequest) async throws -> HTTPResponse

public protocol SessionStrategy: Sendable {
    func authorize(_ request: HTTPRequest, plan: RequestPlan, credentials: Credentials, session: SessionToken?) throws -> HTTPRequest
    func rejection(for response: HTTPResponse) -> SessionRejection?
    /// Runs at `.session` priority through the pipeline. `nil` = this service has no session.
    func establish(after rejection: SessionRejection?, credentials: Credentials, send: SessionSend) async throws -> SessionToken?
}

/// One actor keyed by instance (lean critic TF-5). One `establish` per generation; a burst of 403s awaits the same login.
public actor SessionBroker {
    public init(strategies: [InstanceKind: any SessionStrategy], telemetry: any TelemetrySink, clock: any MediaClock, log: any LogSink)
    public func authorize(_ plan: RequestPlan, credentials: Credentials, baseURL: URL) async throws -> HTTPRequest
    public func rejection(for response: HTTPResponse, kind: InstanceKind) -> SessionRejection?
    public func refresh(_ instance: InstanceID, after: SessionRejection?, credentials: Credentials, send: SessionSend) async throws
    public func invalidate(_ instance: InstanceID)             // fingerprint change
}
```

| Kind | `authorize` | `rejection` | `establish` |
|---|---|---|---|
| radarr, sonarr, lidarr, whisparr | header `X-Api-Key` | 401/403 → `.unauthenticated` | nil → surfaces as `.unauthorized` |
| Servarr SignalR (same strategy, `plan.auth == .querySecret("access_token")`) | `X-Api-Key` on negotiate; `access_token` query on the upgrade | — | nil |
| qBittorrent, `.userPassword` | cookie jar of the instance's `URLSession`; `Referer: <baseURL>` always (CSRF) | 401/403 → `.unauthenticated` | `POST /api/v2/auth/login` form `username`,`password`; body must equal `Ok.`; **one login per generation per process** (prompt §5: qBittorrent bans an IP after failed logins) |
| qBittorrent, `.apiKey` | `Referer` + `Authorization: Bearer <key>` | 401/403 | nil — a 403 means the key is wrong |
| Transmission | `X-Transmission-Session-Id` when held; `Authorization: Basic` when a username is set | 409 → `.handshake("X-Transmission-Session-Id", value)` | no request: the token is the rejection's header value (the one place a response header is load-bearing) |
| Deluge | cookie jar | HTTP 200 whose `error.message` contains "not authenticated" or `result == false` on a non-login call → `.unauthenticated` | `POST /json {"method":"auth.login","params":[password]}`; once per generation |
| rTorrent, NZBGet | `Authorization: Basic` | 401 | nil |
| SABnzbd | `apikey` query item | body `{"status":false,"error":"API Key Incorrect"}` → `.unauthenticated` | nil |
| Plex | `X-Plex-Token`, `Accept: application/json` | 401 | nil |
| Jellyfin | `Authorization: MediaBrowser Token="…"` | 401 | nil |
| Emby | `X-Emby-Token` (bare — ArrCore's shipped behaviour; the spike's wrapping was the H16 discrepancy) | 401 | nil |
| TMDB | `.bearer` → `Authorization: Bearer`; `.apiKey` → `api_key` query | 401 | nil |

Cookie jars are a transport concern: `URLSessionTransport.makeSession(cookies: true)` is used
for the qBittorrent and Deluge instances only; the pipeline never sees a cookie. A second
rejection at the same generation surfaces instead of looping.

### 5.6 Artwork reference

```swift
public enum ArtworkTier: String, Sendable, Codable, CaseIterable { case icon, card, full }   // PosterTier's three tiers

/// The single thing PosterStore consumes. Hashable + Codable and structurally unable to carry a token.
public struct ArtworkReference: Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable { case poster, fanart, banner, thumbnail, still, profile }
    public enum HeaderRef: Hashable, Sendable, Codable { case literal(String), credential(InstanceID) }   // CF graft
    public enum Sizing: Hashable, Sendable, Codable {
        case native
        case tmdbCDN(path: String)                       // /t/p/<w185|w342|original>/<path> per tier
        case plexTranscode(photoPath: String)            // /photo/:/transcode?width=&height=&minSize=1&upscale=1&url=
        case jellyfinFill(itemID: String, tag: String?)  // /Items/{id}/Images/Primary?maxWidth=&tag=
    }
    public let url: URL                                  // token-free, always
    public let headers: [String: HeaderRef]              // resolved at download time, never stored as values
    public let sizing: Sizing
    public let kind: Kind
    public func sized(_ tier: ArtworkTier) -> ArtworkReference
    public var cacheKey: String { get }                  // stable, secret-free: "<kind>|<sizing>|<url>"
}

// Producers (services): pure over the wire value + the instance's base URL.
extension ServarrService     { public func artwork(for record: ArrImages, kind: ArtworkReference.Kind) -> ArtworkReference? }
extension MediaServerService { public func artwork(for entry: MediaServerIndexEntry) -> ArtworkReference? }
extension TMDBService        { public func artwork(path: String, kind: ArtworkReference.Kind) -> ArtworkReference }

// Consumer side, one call (call-sites TF-10):
extension MediaKit { public func artworkHeaders(for reference: ArtworkReference) async -> HTTPHeaders }
```

`artworkHeaders` resolves each `.credential(instance)` through `CredentialProvider` and the
instance's `SessionStrategy.authorize`; `.literal` copies. It folds `MediaServerArtworkSizing`,
`MediaServerPosterAccess.sizedURL`, `PosterTier.cdnVariant` and `TMDBClient.imageURL`.
Tier sizes: icon 256 px, card 780 px, full native (today's `PosterTier` semantics).

### 5.7 Golden-corpus coverage

All 181 rows map to exactly one resource, command or event source above:

| Client | Rows | Mapped to | Deliberate exceptions |
|---|---|---|---|
| radarr | 34 | 20 resources, 12 commands (§5.1) | `fetchQueue` `/moviefile` row + `fetchMovieFile` → one `movieFiles` batch (query compared as a key *set*); `search.fetchLibraryOwnership` = `library`; `search.fetchQualityProfiles` = `qualityProfiles`; `postCommand` → `command(named:)` |
| sonarr | 39 | 22 resources, 13 commands | as radarr; `setSeasonMonitored` three shapes = one capability-gated command (the v5 row appears only with the capability set, the v3 rows only without); `realtime.negotiate` → `SignalRSource`, not a resource |
| lidarr | 37 | 24 resources, 11 commands | `search.lookup` two rows → `lookup` (`/artist/lookup`) and `lidarrSearch` (`/search`); `search.addAlbum` GET leg = `lidarrSearch`, POST leg inside `addAlbum` |
| tmdb | 20 | 17 resources | `movieCountries` → `movie(id:)`; `tvCountries` + `tvCreators` → `tv(id:)`; `similarMovies`, `similarTV` dropped (no consumer) |
| qbittorrent | 10 | 3 resources, 6 commands | `contains` = the `tasks` request, used inside `add` |
| sabnzbd | 8 | 4 resources, 4 commands | `contains` = `tasks`; every action is a GET as recorded |
| plex | 9 | 7 resources, 2 commands | `libraryIndex` `/library/sections` row = `libraries`; `seasonPosters` (n=6) = `seasonArtwork` |
| deluge, transmission, rtorrent, nzbget | 6 each | 2 resources + 4 commands each | `testConnection` for Deluge is `auth.login` in the corpus (the old client's probe) → here the probe is `daemon.info` and `auth.login` is `SessionStrategy.establish`; documented deviation in `GoldenParityTests.knownDeviations` |

`GoldenParityTests` builds every resource's `RequestPlan` (pure) and runs every command's `run`
against a `CountingTransport` (writes answered with the echo rule, §8), then diffs
`(method, pathTemplate, sorted query-key set, sorted header names, scrubbed body keys)` per
OperationID against the corpus row with the `knownDeviations` table above. The corpus's `allowed`
column doubles as the allow-list test oracle.

---

## 6. Composition engine, live streams, synchronous snapshot

### 6.1 Composition

```swift
public struct Provenance: Sendable, Equatable {
    public var tags: Set<InvalidationTag>
    public var oldestFetch: Date?
    public var origins: [CacheOrigin: Int]
    public var failures: [ResourceKey: MediaKitError]
    public var isComplete: Bool { failures.isEmpty }
    public var isOffline: Bool { get }             // every failure is unreachable / breakerOpen
}
public struct Composed<Value: Sendable>: Sendable { public let value: Value; public let provenance: Provenance }

/// One per build. Sendable: `async let` fan-out inside a body is the point (TF-1, CF-5, MF-7).
/// Accumulators live behind OSAllocatedUnfairLock<Provenance>; no `@unchecked`.
public final class CompositionContext: Sendable {
    public let priority: RequestPriority
    public let policy: ReadPolicy
    public func read<V>(_ r: Resource<V>, maxAge: Duration? = nil) async throws -> V
    public func optional<V>(_ r: Resource<V>, maxAge: Duration? = nil) async -> V?        // failure recorded, not thrown
    public func batch<K, V>(_ b: BatchResource<K, V>, keys: [K], maxAge: Duration? = nil) async -> [K: V]
    public func known(_ id: MediaID, in namespace: IDNamespace) async -> MediaID?         // crosswalk, no network
    public func has(_ c: Capability, _ instance: InstanceID) -> Bool
    public var provenance: Provenance { get }
}

/// Lock-guarded, not an actor: bodies run on the caller, never serialised on an engine actor (lean finding 4).
public final class CompositionEngine: Sendable {
    public init(store: ResourceStore, identity: IdentityStore, capabilities: CapabilityIndex, clock: any MediaClock, telemetry: any TelemetrySink)
    /// Memoised on `input` in memory only; dropped when any tag in its provenance is invalidated.
    public func compose<Input: Hashable & Sendable, Value: Sendable>(
        _ input: Input, priority: RequestPriority = .interactive, policy: ReadPolicy = .cacheFirst,
        _ body: @Sendable @escaping (CompositionContext) async throws -> Value) async throws -> Composed<Value>
    /// Many inputs under one limiter budget; bodies run concurrently in a task group.
    public func values<Input: Hashable & Sendable, Value: Sendable>(
        _ inputs: [Input], priority: RequestPriority = .interactive,
        _ body: @Sendable @escaping (Input, CompositionContext) async throws -> Value) async -> [Input: Result<Composed<Value>, MediaKitError>]
    /// cached/first build → revalidated → one element per invalidation or commit touching the provenance.
    public func observe<Input: Hashable & Sendable, Value: Sendable>(
        _ input: Input, priority: RequestPriority = .interactive,
        _ body: @Sendable @escaping (CompositionContext) async throws -> Value) -> AsyncStream<Composed<Value>>
    public func forget<Input: Hashable & Sendable>(_ input: Input)
}
```

Rules. A body reads only through its context; `read` records origin, tags and `fetchedAt`, so
the result carries provenance, minimum freshness and the tag union. Partial results are the norm
(`optional`, `batch`). A composition never reads a `volatile` resource: queue rows, progress and
sessions come from live streams (§6.2). Memo: key = `input`, value = `Composed` + tag union;
`store.revision` bumps on any tag in the union drop the memo; a partial result (`!isComplete`) is
memoised only until the next read of the same input (prompt §3.4). Grids are one composition over
the id list, not N per-card compositions: `ctx.batch(radarr.movieFiles, keys: twentyIDs)` is
one request (criterion 17); where the source has neither batch endpoint nor index
(Sonarr `episodefile?seriesId`, Lidarr `trackfile?albumId`) the `perKey` strategy runs through the
limiter (4 concurrent) and criterion 17 does not apply, as the prompt allows.

### 6.2 Live streams

```swift
public struct LiveStreamID: Hashable, Sendable, Codable, RawRepresentable { public let rawValue: String }   // "queue" | "progress" | "sessions"
public enum LiveScope: Sendable, Equatable { case all, ids(Set<String>) }
public enum LiveActivity: Sendable { case foreground, background, paused }

public struct LivePolicy: Sendable, Equatable {
    public var foregroundInterval: Duration = .seconds(30)
    public var backgroundInterval: Duration = .seconds(120)
    public var pushSilence: Duration = .seconds(300)        // no push for this long → poll again
    public var staleGrace: Duration = .seconds(60)          // full failure keeps the last value this long
    public var checkpointDebounce: Duration = .seconds(5)
    public static let queue: LivePolicy                     // 30 s / 120 s
    public static let progress: LivePolicy                  // 2 s / paused; staleGrace 60 s (DownloadProgressService.maxCacheAge)
    public static let sessions: LivePolicy                  // 30 s / 120 s
}

public struct PendingEffect: Sendable, Equatable, Codable {
    public enum Change: Sendable, Equatable, Codable { case status(String), removed, keepAlive }
    public let elementID: String
    public let change: Change
    public let expiresAt: Date
}

public struct LiveValue<Element: Codable & Sendable>: Sendable {
    public let elements: [Element]                          // pending effects already applied
    public let measuredAt: Date
    public let partial: Set<InstanceID>                     // instances that failed this cycle
    public let isStale: Bool                                // every instance failed and staleGrace has not passed
    public let pending: [PendingEffect]
}

public protocol LiveStreamPushTarget: Sendable { func notePush(_ instance: InstanceID, at: Date) async }

public actor LiveStream<Element: Codable & Sendable & Equatable>: LiveStreamPushTarget {
    public init(id: LiveStreamID, instances: [InstanceID], policy: LivePolicy, store: ResourceStore,
                pipeline: RequestPipeline, database: SQLiteDatabase?, clock: any MediaClock,
                telemetry: any TelemetrySink, log: any LogSink,
                elementID: @escaping @Sendable (Element) -> String,
                fetch: @escaping @Sendable (InstanceID, LiveScope, RequestPipeline) async throws -> [Element],
                isActive: @escaping @Sendable ([Element]) -> Bool = { _ in false })
    public func values() -> AsyncStream<LiveValue<Element>>
    public nonisolated func last() -> LiveValue<Element>?     // lock-guarded; live_snapshots after start()
    public func start() async                                  // loads live_snapshots, starts the pump
    public func refreshNow(priority: RequestPriority) async
    public func setActivity(_ activity: LiveActivity)
    public func setScope(_ scope: LiveScope)                   // progress: the queue's download ids
    public func setInstances(_ instances: [InstanceID])        // configuration change
    public func notePush(_ instance: InstanceID, at: Date) async   // EventHub: refresh (coalesced) + covers `instance` for pushSilence
    public func apply(_ effect: PendingEffect)                 // optimistic; store untouched
    public func clear(elementID: String)
}
```

Pump rules, all in one place instead of `QueueViewModel` (CF/TF graft, MF-1 fixed):

- Every poll is `.background` and goes through `fetch(instance, scope, pipeline)` per instance
  concurrently; the value is the concatenation, `partial` the failed set.
- A tick is skipped when every instance is covered by push (`lastPush + pushSilence > now`) **and**
  `isActive(last.elements)` is false **and** no pending effect is live — today's
  `canSkipForegroundTick`. `notePush` refreshes (the hub already coalesced the burst).
- An empty successful cycle replaces the value; a fully failed cycle keeps the previous elements
  with `partial = all` for `staleGrace`, then emits `isStale = true` with the old elements — the
  bars never snap to arr values on a blip (phase-0 fact 15), and a dead client stops overlaying
  after 60 s.
- Pending effects apply on every emission; `.status` rewrites the element's status field through
  `Element`'s `LivePatchable` conformance (`func applying(_ change: PendingEffect.Change) -> Self?`,
  `nil` = removed); `.keepAlive` re-inserts the last seen element while the source omits it (the
  force-start ghost row). An effect is dropped when the source agrees or at `expiresAt` (30 s).
- The last successful value is written to `live_snapshots` debounced to 5 s; `start()` loads it so
  `last()` is non-nil before the first request (criterion 15).
- The store is never written by a live stream and a live stream never reads the store.

The kit exposes three: `MediaKit.liveQueue() -> LiveStream<ArrQueueRecord>`,
`liveProgress() -> LiveStream<DownloadTask>`, `liveSessions() -> LiveStream<MediaServerSession>`.
ArrCore's queue composition joins queue and progress by lowercased download id, computes the
trackable ids and calls `progress.setScope(.ids(...))` after every queue value — the join stays
in ArrCore because `QueueItem` does.

### 6.3 Synchronous snapshot

`Snapshot<Value>` (§4.3) is the only `await`-free read. ArrCore defines the two projections it
needs — `MediaServerProjection` (`artwork(for: MediaIdentity) -> ArtworkReference?`,
`isWatched(_:) -> Bool`) built from `libraryIndex` + `watchHistory` — as two separate snapshots
tagged `c:library@plex` and `c:history@plex`, so a now-playing tick (`c:sessions`) rebuilds
neither (CF-10). Rebuilds run on the subscriber task off the main actor; `current` is a lock, two
words, no await.

---

## 7. Errors

```swift
public enum UnreachableKind: String, Sendable, Codable { case dns, refused, timeout, tls, offline, other }

public enum MediaKitError: Error, Sendable, Hashable {
    case notConfigured(InstanceID)
    case unreachable(Host, UnreachableKind)
    case breakerOpen(Host, until: Date)
    case rateLimited(Host, retryAfter: Duration?)
    case unauthorized(InstanceID, status: Int, serverMessage: String?)
    case rejected(InstanceID, status: Int, serverMessage: String?)       // other 4xx
    case serverFault(InstanceID, status: Int, serverMessage: String?)    // 5xx
    case serviceError(InstanceID, code: String?, message: String?)       // RPC error envelope on HTTP 200
    case decoding(OperationID, detail: String)
    case unsupported(InstanceID, Capability)
    case persistence(detail: String)
    case notPermitted(OperationID)                                       // MediaKitRecording allow-list
    case fixtureMissing(OperationID)                                     // FixtureTransport only
    public var caseName: String { get }                                  // stable discriminator for the mapper test
    public var serverMessage: String? { get }
    public var host: Host? { get }
    public var instance: InstanceID? { get }
}
```

Thirteen cases, no user-facing literal. Cancellation is `CancellationError`, not a case.
`serverMessage` is the arr's own reason parsed from the body (Servarr array, `{message}`,
ASP.NET `ProblemDetails`) — memory note: arr errors live in the response body.

**ArrCore mapper contract.** One `enum MediaKitErrorPresenter` in ArrCore with
`static func key(for error: MediaKitError) -> String` — an exhaustive `switch` with no `default`
over the 13 cases (so a new case is a compile error), each returning a catalogue key from
`Localizable.xcstrings`, plus `static func message(for:) -> String` that appends
`serverMessage` verbatim when present. `notPermitted` and `fixtureMissing` share the key
`error.mediakit.internal`. `MediaKitErrorMappingTests.everyCaseHasAKey` iterates a
`static let allCases: [MediaKitError]` sample and `Tools/loc/lint_missing_keys.py` checks the
keys exist (criterion 13). `CancellationError` renders nothing.

---

## 8. Demo

`FixtureTransport` owns all demo state; ArrCore keeps one `DemoMode.isActive` flag for badges and
the transport choice (`grep DemoMode Packages/MediaKit` = 0, criterion 14). `DemoMocks*`,
`DemoQueueState`, `DemoMonitorState` and the 46 client branches are deleted in §10.6.

**Matching**, in order, first match wins, on `HTTPRequest.operation`/`pathTemplate`/`rpcMethod`
(set by the pipeline; the transport never parses a URL):

1. Directory = `operation.kind.rawValue` (`Fixtures/radarr/`).
2. Variant file `<operation.name lowercased>-<slug>.json` where `slug` = `rpcMethod` with `.`→`-`
   for RPC clients, else `pathTemplate` with `/`→`-`, `{id}` removed, leading `-` trimmed
   (`fetchqueue-api-v3-moviefile.json`); if absent, the plain `<operation.name lowercased>.json`.
3. The `.meta.json` sidecar supplies `status` and response headers; `original_array_count` is
   ignored at runtime.
4. Writes (`POST`/`PUT`/`DELETE`) without a file: apply the matching `DemoRule` (if any) and answer
   `200` with the request body echoed for `PUT`/`POST` JSON (Servarr returns the record) or `{}`
   otherwise. Commands (`POST {api}/command`) answer `{"id": <n>, "status": "queued"}` and the
   `commands()` fixture reports it `completed` after 3 s of `clock` time.
5. A `GET` without a file throws `MediaKitError.fixtureMissing(operation)` — a test failure, never
   a silent empty array.
6. `open(_:)` returns a socket that replays frames queued by `enqueueFrames(_:for:)` and then
   blocks; the demo queues one `queue`-`sync` frame per arr at start so the "live" badge is honest.

**Demo rules** (`DemoRule`, a Swift table in `FixtureTransport.swift`, ≤ 100 lines with its
interpreter; relief valve: move to JSON):

```swift
public struct DemoRule: Sendable {
    public enum Effect: Sendable {
        case setQueueStatus(kind: InstanceKind, status: String)      // pause/resume → subsequent fetchProgress/fetchQueue rows
        case removeQueueItem(kind: InstanceKind)                      // delete
        case setMonitored(kind: InstanceKind, value: KeyPath<Bool>)   // setMonitored / setSeasonMonitored / setEpisodesMonitored
        case appendLibrary(kind: InstanceKind)                         // add → the lookup row appears in library + calendar
        case commandRunning(kind: InstanceKind, seconds: Int)         // search → isSearchRunning
    }
    public let on: OperationID
    public let effect: Effect
}
```

The interpreter edits the fixture JSON tree with `JSONSerialization` (a `[String: Any]` tree is
acceptable in a test-support type; no wire model is imported into the transport). Effects live
in the actor for the process lifetime and `reset()` clears them. This replaces `DemoQueueState`
(pause/cancel across refreshes) and `DemoMonitorState` (monitor toggles). Demo uses
`DatabaseLocation.memory`, so a demo relaunch starts from the fixtures, as the isolated demo
suite does today.

---

## 9. ArrCore integration

One entry point in ArrCore: `ServiceGateway` (`@MainActor final class`, `Services/ServiceGateway.swift`),
owned by `ConfigStore` and exposed through `ConfigStore.gateway`. It builds one `MediaKit`
instance from `Configuration` (§4.5), re-`reconcile`s it on every `ConfigStore` change
(instances added, removed, re-keyed), swaps `URLSessionTransport` for `FixtureTransport` when
demo mode toggles, and stops it on quit. Consumers (view models, `LocalToolBackend`, intents,
widget) reach services only through `gateway.servarr(.radarr)`, `gateway.download(id)`,
`gateway.mediaServer`, `gateway.tmdb`, `gateway.store`, `gateway.engine` and `gateway.live`.
No view model constructs a client (criterion 5: `grep "Client(" Views ViewModels` = 0 after
phase 5).

9.1 Compositions stay in ArrCore: `QueueItem`, `QueueGroup`, `UpcomingItem`, `HistoryItem`,
`DiscoverItem` are built by `Compositions/*.swift` from MediaKit resources inside
`CompositionEngine.observe` closures; `QueueViewModel` subscribes to one `LiveStream<[QueueGroup]>`
and one `Observations` sequence for the store revision, replacing the 1.5 s debounce, the 30 s poll
timer and the 0.25 s burst loop (§6.2 owns cadence).

9.2 Errors: `MediaKitErrorPresenter` (§7). Health: `ConnectionHealthMonitor` is replaced by
`gateway.health` derived from `HostGovernor` breaker state + `EventHub.lastEventAt`.

9.3 Widget (`ArrBarrWidgets`): `MediaKit(role: .snapshotReader)` opens the group-container database
read-only, projects `Snapshot` synchronously for the timeline, and when the snapshot is older than
`FreshnessClass.interactive` starts a `.refresher` role instance that fetches only the
`widget` resource allow-list (queue, calendar, health) under a 4 MB budget (Plex index excluded).

9.4 Tools and MCP: `LocalToolBackend` reads through the store with `ReadPolicy.cachedOrFetch`;
`LocalToolBackendFixtureTests` runs all 28 tools against `FixtureTransport` (criterion 19).

9.5 Documentation check before phase-3 code: `Observations`, `NetworkBrowser`, `NetworkConnection`
and `NotificationCenter.MainActorMessage` are verified against Apple docs via
`appledoc.py` (the MCP `DocumentationSearch` tool is not exposed to this harness).

## 10. Migration waves (phase 5)

Each wave is one commit that builds all three schemes and passes all three test targets; the app
is relaunched after each. Old and new paths coexist inside a wave only through `ServiceGateway`.

1. **10.1 Gateway + queue**: `ServiceGateway`, `QueueViewModel` on `LiveStream`, aggregator and
   download-client polling removed; `RealtimeUpdates` consumer replaced by `EventHub`.
2. **10.2 Upcoming + history**: calendar and history compositions, `UpcomingItem` grouping.
3. **10.3 Details**: movie/series/artist/album detail reads via `BatchResource`, monitor toggles
   and searches via `Command`.
4. **10.4 Library, search, add, edit, delete**: `SearchViewModel`, add flows, root folders,
   profiles, tags, delete with `CommandReceipt` invalidation.
5. **10.5 Tools, MCP, settings, health, intents, widget**: `LocalToolBackend`, `ToolCatalogBridge`
   inputs, settings probes (`CapabilityProbe`), widget snapshot, Spotlight indexer as a store
   consumer.
6. **10.6 Removal**: delete `Services/{Sonarr,Radarr,Lidarr,Whisparr}Client*`, the six download
   clients, `RealtimeUpdates`, `ConnectionHealthMonitor`, `QueueAggregator`, `CoalescingCache`,
   `TMDBClient`, `MediaServerIndex` fetchers, `DemoMocks*`, `DemoQueueState`, `DemoMonitorState`,
   `HTTPClient`; migrate the 14 `URLProtocol` test files to injected transports; then set
   `.defaultIsolation(MainActor.self)` in `Packages/ArrCore/Package.swift` and fix what the
   compiler reports (criterion 24).

## 11. Recording and parity (phase 6)

`MediaKitRecording.RecordingTransport` wraps a `Transport`, refuses any request not matching
`AllowList` (prompt §5 table + Lidarr `GET /track`, `GET /search`; `GET /release` and every
non-GET except the SignalR negotiate are answered synthetically, never sent), scrubs headers,
query secrets, hosts and ids before writing a corpus row, and is compiled only into
`MediaKitTests` and the phase-6 parity run. Parity = the per-screen request shapes
(`method`, `pathTemplate`, sorted `query_keys`, `header_names`) recorded through the new stack
compared to `docs/superpowers/baseline/2026-09-15-golden-requests.json` per `operation`; every
difference is listed in the phase-6 report with a reason. Fixtures are re-anonymized with
`Tools/fixtures/anonymize_fixtures.py --check` before commit.

**Fixture packaging (phase 3 change).** The 218 per-operation files plus sidecars collapse into one
`Fixtures/<kind>.json` per service: `{ "<operation>": { "status", "headers", "body",
"synthetic" } }`. `FixtureTransport` loads one file per kind lazily. `anonymize_fixtures.py` gets
`--pack`/`--unpack` so recordings still land as single files in the scratchpad and are packed on
the way into the repo.

## 12. Phase 7 — API 26 UI (macOS)

Scope, in order, each its own commit, verified by relaunch: (1) Liquid Glass containers
(`glassEffect`, `GlassEffectContainer`) on the popover floating bar and the detached window
toolbar, replacing the hand-drawn sheen/rim from `GlassyFloatingBar`; (2) `Observations`-driven
lists replacing the remaining `@Published` fan-out in `ConfigStore` consumers of the popover;
(3) `.scrollEdgeEffectStyle` and `safeAreaBar` for the queue list header; (4) `Text` with
`AttributedString` markdown for chat via the 26 `Text(.init(markdown:))` path only where it
removes code. Anything that needs SDK 27 is excluded (CI stays on Xcode 26.4.1).

## 13. Open questions resolved by this spec

13.1 Fingerprint = host + credential generation counter (not a hash of the secret): no CryptoKit,
no secret material derived into a key.
13.2 `gen_wire.py` is a relief valve only; generated files count toward the budget.
13.3 Discovery UDP beacon is macOS-only; iOS uses Bonjour only.
