import Foundation
import os

/// One logger for the whole realtime subsystem. Errors in the connection loop
/// used to be swallowed silently ("polling is the safety net"), which made a
/// non-working SignalR impossible to diagnose. Boundary logs here turn that
/// into observable evidence: filter Console.app on subsystem
/// `pl.incred.ArrBarr`, category `Realtime`.
private let realtimeLog = Logger(category: "Realtime")

// MARK: - Realtime push updates over Sonarr/Radarr's SignalR endpoint
//
// Every Servarr app (Sonarr, Radarr, Lidarr, Whisparr) exposes the same
// SignalR-over-WebSocket hub at `/signalr/messages` that their own Web
// UI subscribes to for live updates. We connect there too so queue
// progress, file imports, and series changes push into ArrBarr instantly
// instead of waiting for the next polling tick.
//
// Polling stays in place as a fallback — if a SignalR connection
// genuinely can't be established (older Servarr, reverse-proxy
// stripping WebSocket upgrades, network hiccup), the user still gets
// the data, just on the old cadence.
//
// We deliberately do NOT use any external SignalR client library.
// ASP.NET Core's SignalR Hub Protocol over WebSocket is small enough
// to handshake by hand — `URLSessionWebSocketTask` gives us the
// transport, JSON serialization gives us the framing, and the rest
// is a couple of state-machine functions. The cost of avoiding a
// third-party dep is ~250 lines of careful but boring code.

/// Slim event surface — the view-model only needs to know "something
/// changed, refresh this arr" or "something changed across all arrs".
/// Body parsing is deliberately not exposed; the polling pipeline already
/// owns the canonical data fetch and the SignalR side is just a faster
/// trigger.
/// Servarr's own summary of a queue: how many rows, and whether any of them are
/// in trouble. Pushed inline on every queue change, so comparing two of them
/// answers "did anything material change" for the price of a socket frame.
///
/// Deliberately not a mirror of our own row set — `totalCount` includes pending
/// releases we never display. It is only ever compared against another instance
/// of itself, never against `queues[source].count`, so what it counts matters
/// less than that it counts the same things each time.
public struct QueueStatus: Sendable, Equatable {
    let totalCount: Int
    let count: Int
    let unknownCount: Int
    let errors: Bool
    let warnings: Bool

    init?(_ json: [String: Any]) {
        guard let totalCount = json["totalCount"] as? Int else { return nil }
        self.totalCount = totalCount
        self.count = json["count"] as? Int ?? 0
        self.unknownCount = json["unknownCount"] as? Int ?? 0
        self.errors = json["errors"] as? Bool ?? false
        self.warnings = json["warnings"] as? Bool ?? false
    }
}

public enum RealtimeEvent: Sendable, Equatable {
    /// Which arr this came from. Every case carries it; this just saves the
    /// callers a `switch` when all they want is the origin.
    public var source: QueueItem.Source {
        switch self {
        case .queueChanged(let s), .fileImported(let s), .other(let s, _, _),
             .queueStatus(let s, _):
            return s
        }
    }

    /// The arr's queue summary changed (or was re-announced unchanged).
    case queueStatus(source: QueueItem.Source, status: QueueStatus)

    /// Queue item added/updated/removed/etc. — caller should refresh
    /// the queue snapshot for the named source.
    case queueChanged(source: QueueItem.Source)
    /// File imported (movieFile/episodeFile/trackFile). Useful for
    /// "download complete" notifications; the queue refresh that
    /// follows will pick up the new state.
    case fileImported(source: QueueItem.Source)
    /// Anything else that suggests state has moved — series/movie/album
    /// updated, etc. Caller can ignore or coalesce as needed.
    case other(source: QueueItem.Source, name: String, action: String)
}

/// Owns one SignalR connection per configured arr. Reconfiguring
/// (called when ConfigStore changes) tears down stale connections and
/// brings up new ones for the current config. Connections live for the
/// lifetime of the app — Servarr's hub is designed for long-lived
/// browser tabs and handles the reconnect dance gracefully.
public actor RealtimeManager {
    private var connections: [QueueItem.Source: SignalRConnection] = [:]
    /// Monotonic token identifying the newest connection-mutating run
    /// (`reconfigure` / `forceReconnect` / `shutdown`). An actor is not a
    /// mutex: every `await` in those methods is a suspension point at which
    /// another call can start *and finish*. Each run captures the generation
    /// it started with and bails as soon as a newer one has taken over,
    /// rather than resuming and writing its stale connections back.
    private var generation: UInt64 = 0
    private var onEvent: @Sendable (RealtimeEvent) async -> Void
    /// Cached configs from the last `reconfigure` call. Lets
    /// `forceReconnect` rebuild every connection with the current
    /// auth/URL state without the caller having to re-pass it.
    private var lastConfigs: (sonarr: ServiceConfig, radarr: ServiceConfig, lidarr: ServiceConfig, whisparr: ServiceConfig)?
    /// Wall-clock of the most recent push event (any arr, any kind).
    /// Surfaced via `lastEventAt` so callers can detect "SignalR
    /// connected but hub gone silent" and tune polling accordingly.
    private var lastPushedAt: Date?
    public func lastEventAt() -> Date? { lastPushedAt }
    /// Same signal, split per arr — see `lastEventAt(_:)`.
    private var lastPushedBySource: [QueueItem.Source: Date] = [:]

    /// Transport for every connection's negotiate + WebSocket. Injectable so
    /// tests can drive negotiate against a `URLProtocol` stub instead of the
    /// network; production uses `.shared`.
    private let urlSession: URLSession

    public init(
        urlSession: URLSession = .shared,
        onEvent: @escaping @Sendable (RealtimeEvent) async -> Void = { _ in }
    ) {
        self.urlSession = urlSession
        self.onEvent = onEvent
    }

    /// Swap the event handler after construction. The view-model
    /// captures `self` weakly inside the handler closure, which
    /// requires `self` to exist before the closure can be built —
    /// so it's set after init rather than passed in.
    public func setHandler(_ handler: @escaping @Sendable (RealtimeEvent) async -> Void) {
        self.onEvent = handler
    }

    /// Bring connections in line with the current configuration. Idempotent
    /// — call any time configs change. Connections for arrs that disappear
    /// (e.g. user cleared a baseURL) are torn down; new ones come up for
    /// arrs that just got configured.
    public func reconfigure(
        sonarr: ServiceConfig,
        radarr: ServiceConfig,
        lidarr: ServiceConfig,
        whisparr: ServiceConfig
    ) async {
        lastConfigs = (sonarr, radarr, lidarr, whisparr)
        let desired: [(QueueItem.Source, ServiceConfig)] = [
            (.sonarr, sonarr),
            (.radarr, radarr),
            (.lidarr, lidarr),
            (.whisparr, whisparr),
        ]
        generation &+= 1
        let myGeneration = generation
        // Actor isolation does NOT make this method atomic: `await stop()`
        // suspends, and a second `reconfigure` (Settings publishes its config
        // as the user types) then runs to completion on top of us. Two rules
        // keep that safe:
        //   1. Take the old connection OUT of `connections` *before* awaiting
        //      its stop, so a reentrant call sees "nothing here" and builds
        //      its own instead of stopping the same object a second time.
        //   2. Bail after every suspension once `generation` has moved on,
        //      instead of overwriting the newer run's connection with ours.
        // Skipping (2) leaks a *live* socket: an overwritten connection is
        // unreachable but not deallocated, because `start()`'s
        // `Task { await self?.runLoop() }` holds a strong `self` until the
        // loop exits — and only `stop()` can end it. Each interleaving would
        // strand one WebSocket with its 15 s ping pump and reconnect loop for
        // the life of the process.
        // Starts stay fire-and-forget: `runLoop` is the long-lived part and
        // its setup races are absorbed by the actor.
        for (source, cfg) in desired {
            let want = cfg.isConfigured && !cfg.apiKey.isEmpty && !DemoMode.isActive
            let have = connections[source] != nil
            realtimeLog.debug("reconfigure \(source.rawValue, privacy: .public): want=\(want, privacy: .public) have=\(have, privacy: .public)")
            switch (want, have) {
            case (true, false):
                let conn = makeConnection(source: source, config: cfg)
                connections[source] = conn
                Task { await conn.start() }
            case (false, true):
                let existing = connections.removeValue(forKey: source)
                await existing?.stop()
                guard myGeneration == generation else { return }
            case (true, true):
                // Same URL + key → keep the live socket; only a real change
                // is worth a teardown.
                if connections[source]?.matches(cfg) == true { continue }
                let existing = connections.removeValue(forKey: source)
                await existing?.stop()
                guard myGeneration == generation else { return }
                let conn = makeConnection(source: source, config: cfg)
                connections[source] = conn
                Task { await conn.start() }
            case (false, false):
                break
            }
        }
    }

    /// Helper — builds a Connection whose event closure dispatches back
    /// through `self` rather than capturing a snapshot of `onEvent`.
    /// Lets `setHandler` updates apply to live connections without
    /// tearing them down.
    private func makeConnection(source: QueueItem.Source, config: ServiceConfig) -> SignalRConnection {
        SignalRConnection(source: source, config: config, session: urlSession) { [weak self] event in
            await self?.dispatch(event)
        }
    }

    /// Routes a Connection-side event to the current handler. Defined
    /// on the actor so reads of `onEvent` are isolated. Bumps
    /// `lastPushedAt` so `lastEventAt()` callers can detect a hub
    /// that connected but went silent.
    fileprivate func dispatch(_ event: RealtimeEvent) async {
        lastPushedAt = Date()
        lastPushedBySource[event.source] = lastPushedAt
        await onEvent(event)
    }

    /// Per-source liveness, which is what makes suppressing the poll safe.
    ///
    /// A global timestamp can't answer "is *this* arr's hub alive" — one busy
    /// Lidarr would vouch for three silent Sonarrs. And the reason a per-source
    /// timestamp is decisive at all is Servarr's own scheduler: the
    /// `RefreshMonitoredDownloads` task runs on a fixed interval (1 minute by
    /// default), `DownloadMonitoringService.Refresh()` publishes
    /// `TrackedDownloadRefreshedEvent` unconditionally at the end of it, and
    /// `QueueService` republishes that as `QueueUpdatedEvent` with no diff
    /// check. So a healthy hub emits a `queue` push on a timer **even when
    /// nothing is happening** — which is exactly what separates "quiet because
    /// idle" from "quiet because dead".
    public func lastEventAt(_ source: QueueItem.Source) -> Date? {
        lastPushedBySource[source]
    }


    public func shutdown() async {
        generation &+= 1
        // Drain the dictionary before awaiting the stops — same reentrancy
        // rule as `reconfigure`. Otherwise a call that resumes mid-shutdown
        // could install a connection that the trailing `removeAll()` would
        // then drop unstopped; the bumped generation sends it home instead.
        let stopping = connections
        connections.removeAll()
        for (_, conn) in stopping {
            await conn.stop()
        }
    }

    /// Tear down every connection and immediately reopen with the
    /// cached configs. Used after wake-from-sleep, when the OS may
    /// have killed the WebSocket but our reconnect loop won't notice
    /// for 30-90 s (it needs a failed `receive` to fire). No-op when
    /// we have nothing cached yet (`reconfigure` was never called).
    public func forceReconnect() async {
        guard let cfg = lastConfigs else { return }
        generation &+= 1
        let myGeneration = generation
        // Drain first, then stop — see `reconfigure`. And if a `reconfigure`
        // overtook us while we were awaiting the stops it has already brought
        // the world up to date; rebuilding on top of it would orphan its
        // sockets.
        let stopping = connections
        connections.removeAll()
        for (_, conn) in stopping {
            await conn.stop()
        }
        guard myGeneration == generation else { return }
        await reconfigure(
            sonarr: cfg.sonarr, radarr: cfg.radarr,
            lidarr: cfg.lidarr, whisparr: cfg.whisparr
        )
    }
}

// MARK: - Single SignalR connection (one arr)

/// One persistent SignalR connection. Owns its WebSocket, runs an
/// internal reconnect loop, parses incoming frames, and dispatches
/// `RealtimeEvent` to the manager's handler.
actor SignalRConnection {
    private let source: QueueItem.Source
    private let baseURL: String
    private let apiKey: String
    private let session: URLSession
    private let onEvent: @Sendable (RealtimeEvent) async -> Void

    private var task: Task<Void, Never>?
    private var ws: URLSessionWebSocketTask?
    private var pingTask: Task<Void, Never>?
    /// Set once a cycle reaches the listen phase. Purely diagnostic — it
    /// tells the failure log whether we died before or after the handshake.
    /// It is deliberately NOT what resets the backoff; see `listenStartedAt`.
    private var lastReachedListen = false
    /// When the current cycle started listening, on a monotonic clock.
    /// Reaching the handshake proves nothing about a connection's health: a
    /// reverse proxy (or an *arr behind Cloudflare, or a ~1 s idle timeout)
    /// can accept the upgrade, answer `{}` and hang up — every single time.
    /// Treating that as success reset the backoff and the failure counter on
    /// every cycle, which pinned us at one negotiate POST + one WebSocket
    /// upgrade *per second, per arr*, forever, with the 30 s ceiling and the
    /// 5-minute cold start unreachable. So a cycle now only counts once the
    /// connection has actually LIVED — `minimumHealthyLifetime` on the wire,
    /// or at least one frame received.
    private var listenStartedAt: ContinuousClock.Instant?
    /// Whether the current cycle received a frame that wasn't a Close. The
    /// cheapest possible proof that the hub is genuinely talking to us —
    /// Servarr's own keepalive ping alone is enough.
    private var receivedFrameThisCycle = false
    /// How long a connection must survive before the cycle counts as healthy
    /// without having received anything. Comfortably past the "accepted the
    /// upgrade, then closed" pathologies (sub-second to a couple of seconds),
    /// and a healthy hub pings well inside it anyway.
    private static let minimumHealthyLifetime: Duration = .seconds(30)
    /// Counts cycles that never produced a living connection, in a row. After
    /// a threshold we throttle further so a bad reverse-proxy can't pin us at
    /// the 30s ceiling forever — we drop to once-every-5-minutes and let
    /// polling stay primary.
    private var consecutiveFailures = 0

    init(
        source: QueueItem.Source,
        config: ServiceConfig,
        session: URLSession = .shared,
        onEvent: @escaping @Sendable (RealtimeEvent) async -> Void
    ) {
        self.source = source
        self.baseURL = config.baseURL
        self.apiKey = config.apiKey
        self.session = session
        self.onEvent = onEvent
    }

    nonisolated func matches(_ config: ServiceConfig) -> Bool {
        // baseURL + apiKey are immutable on this actor — comparing them
        // without crossing the actor is safe and avoids unnecessary
        // serialization for the common "config didn't really change" case.
        config.baseURL == baseURL && config.apiKey == apiKey
    }

    func start() async {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() async {
        task?.cancel()
        task = nil
        pingTask?.cancel()
        pingTask = nil
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
    }

    /// Reconnect loop with exponential backoff. Backoff is reset on a cycle
    /// whose connection actually lived (so a flaky network that recovers fast
    /// goes back to 1 s), not on `runOnce` returning, which only happens on
    /// cancellation. Beyond `failureCeilingBeforeColdStart` consecutive dead
    /// cycles we drop to a 5-minute retry cadence — there's no point pounding
    /// a misconfigured reverse proxy when polling is doing the real work
    /// anyway.
    private func runLoop() async {
        var backoffNs: UInt64 = 1_000_000_000  // 1 s
        let maxBackoffNs: UInt64 = 30_000_000_000  // 30 s
        let coldStartNs: UInt64 = 5 * 60 * 1_000_000_000  // 5 min
        let failureCeilingBeforeColdStart = 10
        while !Task.isCancelled {
            lastReachedListen = false
            listenStartedAt = nil
            receivedFrameThisCycle = false
            do {
                try await runOnce()
            } catch is CancellationError {
                return
            } catch {
                // Network blip / negotiate failed / proxy refused upgrade.
                // Polling is the safety net, but log so a genuinely-broken
                // SignalR (auth, proxy stripping WS upgrade, wrong endpoint)
                // is diagnosable instead of failing invisibly. `reachedListen`
                // tells us whether we died before or after the handshake.
                realtimeLog.error("[\(self.source.rawValue, privacy: .public)] cycle failed (reachedHandshake=\(self.lastReachedListen, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            }
            // "Did real work" means the connection LIVED, not that it
            // handshook: a hub that greets us and immediately hangs up is a
            // failure, however polite. Either evidence counts — a frame we
            // received, or `minimumHealthyLifetime` spent on the wire.
            let lived = receivedFrameThisCycle
                || (listenStartedAt.map { ContinuousClock.now - $0 >= Self.minimumHealthyLifetime } ?? false)
            if lived {
                backoffNs = 1_000_000_000
                consecutiveFailures = 0
            } else {
                consecutiveFailures += 1
                backoffNs = min(backoffNs * 2, maxBackoffNs)
            }
            let sleepFor: UInt64 = (consecutiveFailures > failureCeilingBeforeColdStart)
                ? coldStartNs
                : backoffNs
            do {
                try await Task.sleep(nanoseconds: sleepFor)
            } catch {
                return
            }
        }
    }

    private func runOnce() async throws {
        let connectionToken = try await negotiate()
        let ws = try connectWebSocket(token: connectionToken)
        self.ws = ws
        defer {
            // External cancellation of our parent Task won't necessarily
            // unblock `receive()`; make sure the WS gets closed so the
            // next attempt isn't stuck on a half-open socket.
            ws.cancel(with: .goingAway, reason: nil)
            pingTask?.cancel()
            pingTask = nil
        }
        // Consume the handshake response; preserve any frames that
        // arrived in the same WebSocket message so `listen` can replay
        // them (under load Servarr happily batches `{}<RS>{type:1...}<RS>`
        // into one receive).
        let pending = try await consumeHandshake(ws: ws)
        // We're past the protocol handshake — which the failure log cares
        // about, but which on its own earns no backoff reset. Start the
        // lifetime clock instead and let `runLoop` judge the cycle when it
        // ends.
        lastReachedListen = true
        listenStartedAt = .now
        realtimeLog.debug("[\(self.source.rawValue, privacy: .public)] handshake ok — listening (pending=\(pending.count, privacy: .public))")
        // Announce the (re)connection as a queue change.
        //
        // Two jobs. It closes the reconnect window: anything that happened
        // while the socket was down produced a push we were not there to hear,
        // and nothing else would ever tell us. And it marks the source live, so
        // a freshly connected hub isn't treated as stale by the health gate
        // until its first real push arrives.
        await onEvent(.queueChanged(source: source))
        startPingPump(ws: ws)
        try await listen(ws: ws, pending: pending)
    }

    /// Step 1 — `POST /signalr/messages/negotiate?negotiateVersion=1`.
    /// Returns the token we'll thread into the WebSocket URL.
    ///
    /// ASP.NET Core SignalR with `negotiateVersion=1` returns BOTH
    /// `connectionId` and `connectionToken` — the spec says the client
    /// MUST use `connectionToken` when present (it differs from
    /// connectionId behind Azure SignalR Service and other multiplexed
    /// deployments). Fall back to `connectionId` for older / simpler
    /// hosts where `connectionToken` isn't emitted.
    private func negotiate() async throws -> String {
        guard var components = URLComponents(string: baseURL) else {
            throw URLError(.badURL)
        }
        components.path = (components.path.hasSuffix("/") ? components.path : components.path + "/")
            + "signalr/messages/negotiate"
        // Preserve any existing query items (some users paste URLs with
        // legacy `?apikey=` baked in); append rather than overwrite.
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "negotiateVersion", value: "1"))
        components.queryItems = items
        guard let url = components.url else { throw URLError(.badURL) }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)

        // Scheme/host/path only — never the query. The preserved user query
        // can carry a legacy `?apikey=`, and `.public` on the full URL would
        // write that key into the unified log. Same redaction as the WS log.
        realtimeLog.debug("[\(self.source.rawValue, privacy: .public)] negotiate POST \(components.scheme ?? "?", privacy: .public)://\(components.host ?? "?", privacy: .public)\(components.path, privacy: .public)")
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            realtimeLog.error("[\(self.source.rawValue, privacy: .public)] negotiate failed, HTTP \(status, privacy: .public)")
            throw URLError(.badServerResponse)
        }
        realtimeLog.debug("[\(self.source.rawValue, privacy: .public)] negotiate ok (HTTP \(status, privacy: .public))")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        if let token = json["connectionToken"] as? String, !token.isEmpty {
            return token
        }
        if let id = json["connectionId"] as? String, !id.isEmpty {
            return id
        }
        throw URLError(.cannotParseResponse)
    }

    /// Step 2 — open the WebSocket to `/signalr/messages?id=<token>`,
    /// authenticated via the `access_token` query param (Servarr accepts
    /// that as an alternative to the `X-Api-Key` header for WebSocket
    /// connections — header-only doesn't work because URLSession won't
    /// add it on upgrade).
    private func connectWebSocket(token: String) throws -> URLSessionWebSocketTask {
        guard var components = URLComponents(string: baseURL) else {
            throw URLError(.badURL)
        }
        components.scheme = (components.scheme == "https") ? "wss" : "ws"
        components.path = (components.path.hasSuffix("/") ? components.path : components.path + "/")
            + "signalr/messages"
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "id", value: token))
        items.append(URLQueryItem(name: "access_token", value: apiKey))
        components.queryItems = items
        guard let url = components.url else { throw URLError(.badURL) }

        // Log the host/scheme/path but not the query — it carries the API key.
        realtimeLog.debug("[\(self.source.rawValue, privacy: .public)] WS connect \(components.scheme ?? "?", privacy: .public)://\(components.host ?? "?", privacy: .public)\(components.path, privacy: .public)")
        let task = session.webSocketTask(with: url)
        task.resume()
        return task
    }

    /// Step 3 — send the JSON Hub Protocol handshake, then read until
    /// we've found the `{}` response frame. Returns any frames that
    /// arrived in the same WebSocket message AFTER the handshake reply
    /// so they can be processed by `listen` instead of getting dropped
    /// on the floor — Servarr happily batches `{}<RS>{"type":1...}<RS>`
    /// into one receive under load, and discarding the tail would mean
    /// missing the first real event.
    private func consumeHandshake(ws: URLSessionWebSocketTask) async throws -> [String] {
        let handshake = #"{"protocol":"json","version":1}"# + "\u{1E}"
        try await ws.send(.string(handshake))

        // Read frames until we've consumed the `{}` response. Anything
        // after it is queued for `listen` to handle.
        var buffer = ""
        while true {
            // Handshake reply should arrive promptly — a shorter watchdog here.
            let msg = try await receiveWithTimeout(ws, seconds: 30)
            switch msg {
            case .string(let s): buffer += s
            case .data(let d):   buffer += String(data: d, encoding: .utf8) ?? ""
            @unknown default:    continue
            }
            // Need at least one complete frame (terminated by 0x1E).
            guard buffer.contains("\u{1E}") else { continue }

            let frames = buffer.split(separator: "\u{1E}", omittingEmptySubsequences: false)
            // First frame must be the handshake response. If it's empty
            // or carries an `error` field, fail loudly so reconnect
            // doesn't paper over auth issues.
            let first = String(frames[0])
            guard !first.isEmpty,
                  let firstData = first.data(using: .utf8),
                  let firstJson = try? JSONSerialization.jsonObject(with: firstData) as? [String: Any] else {
                throw URLError(.badServerResponse)
            }
            if let handshakeErr = firstJson["error"] {
                realtimeLog.error("[\(self.source.rawValue, privacy: .public)] handshake rejected: \(String(describing: handshakeErr), privacy: .public)")
                throw URLError(.userAuthenticationRequired)
            }

            // The remaining frames may be empty (no batched events) or
            // contain real invocations. Drop the trailing empty
            // (split with omittingEmptySubsequences=false gives one
            // empty string at the end when the buffer ended at <RS>).
            var pending: [String] = []
            for frame in frames.dropFirst() {
                let str = String(frame)
                if !str.isEmpty { pending.append(str) }
            }
            return pending
        }
    }

    /// Push a `{type:6}` heartbeat every 15 s. SignalR's contract is
    /// that *both* sides ping to keep their respective idle timers
    /// fresh — if we only echo the server's pings, an idle period
    /// where the server doesn't send one (e.g. it's busy) will let
    /// the server's read-timer fire and close us out. Cheap insurance.
    private func startPingPump(ws: URLSessionWebSocketTask) {
        pingTask?.cancel()
        pingTask = Task { [weak ws] in
            let interval: UInt64 = 15_000_000_000
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: interval) } catch { return }
                guard let ws else { return }
                try? await ws.send(.string(#"{"type":6}"# + "\u{1E}"))
            }
        }
    }

    /// `URLSessionWebSocketTask.receive()` has no deadline. If a proxy accepts
    /// the WebSocket upgrade but the hub then goes silent (or the socket
    /// half-opens without a TCP RST), the read blocks forever and that arr
    /// silently stops receiving pushes until the next forced reconnect/wake.
    /// Race the read against a watchdog so a stalled socket throws and the
    /// reconnect loop recovers. Any received frame resets the window, so this
    /// behaves as an idle timeout (Servarr's SignalR keepalive pings well
    /// inside 60 s on a healthy connection).
    private func receiveWithTimeout(
        _ ws: URLSessionWebSocketTask, seconds: UInt64
    ) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await ws.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw URLError(.timedOut) }
            return result
        }
    }

    /// Step 4 — read frames forever, dispatch `RealtimeEvent`s. Each
    /// receive can carry multiple frames concatenated with 0x1E
    /// separators, so we split before parsing. `pending` carries any
    /// frames that arrived during the handshake read but after the
    /// `{}` response — they must be processed first, in order, so the
    /// first real invocation isn't lost when Servarr batches the
    /// handshake reply with the initial state push.
    private func listen(ws: URLSessionWebSocketTask, pending: [String]) async throws {
        for frame in pending {
            try await handleFrame(frame, ws: ws)
        }
        while !Task.isCancelled {
            let msg = try await receiveWithTimeout(ws, seconds: 60)
            let text: String
            switch msg {
            case .string(let s):
                text = s
            case .data(let d):
                text = String(data: d, encoding: .utf8) ?? ""
            @unknown default:
                continue
            }
            for frame in text.split(separator: "\u{1E}", omittingEmptySubsequences: true) {
                try await handleFrame(String(frame), ws: ws)
            }
        }
    }

    /// Parse one Hub Protocol message. We care about three message types:
    ///   - 1 (Invocation) — server-pushed event, our main event source
    ///   - 6 (Ping) — keepalive, echo back to keep the socket alive
    ///   - 7 (Close) — server is shutting us down, break out so the
    ///     reconnect loop can retry
    /// Anything else (StreamItem, Completion, …) is irrelevant for
    /// Servarr's one-way push model.
    private func handleFrame(_ frame: String, ws: URLSessionWebSocketTask) async throws {
        switch Self.parse(frame: frame, source: source) {
        case .close:
            // Server sent a Close (type 7) — break out so reconnect retries.
            // Deliberately does NOT count as a received frame: a hub that
            // greets us and hangs up must not buy the cycle a backoff reset.
            throw URLError(.cancelled)
        case .ignored:
            // Keepalive ping (or anything we don't act on) — still proof the
            // hub is alive and talking, which is what the backoff cares about.
            receivedFrameThisCycle = true
        case .events(let events):
            receivedFrameThisCycle = true
            for event in events {
                realtimeLog.debug("[\(self.source.rawValue, privacy: .public)] event \(String(describing: event), privacy: .public)")
                await onEvent(event)
            }
        }
    }

    /// Outcome of parsing one Hub Protocol frame. Pure + synchronous so the
    /// Servarr envelope parsing — the part that had the bug — is unit-testable
    /// against captured frames, independent of the live WebSocket.
    enum FrameOutcome: Equatable {
        case events([RealtimeEvent])
        case close       // server sent Close (type 7) — caller breaks the loop
        case ignored     // ping / unparseable / nothing actionable
    }

    /// Parse one frame into the events it implies. Servarr's Invocation
    /// envelope is `{type:1, target:"receiveMessage",
    /// arguments:[{name:"queue", body:{action:"sync"}}]}` — the resource
    /// `name` sits at `arguments[0].name` and `action` is nested inside
    /// `body`. The original parser required `action` at the *top level* of
    /// the argument, so its guard failed on every real frame and each event
    /// fell through to a `target`-tagged `.other` that the view-model ignored
    /// — i.e. SignalR connected and received, but nothing ever refreshed.
    static func parse(frame: String, source: QueueItem.Source) -> FrameOutcome {
        guard let data = frame.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? Int else {
            return .ignored
        }
        switch type {
        case 1:  // Invocation
            guard let args = json["arguments"] as? [[String: Any]],
                  let payload = args.first,
                  let name = payload["name"] as? String else {
                // No standard envelope — tag with the hub method so a change
                // still surfaces rather than being dropped on the floor.
                if let target = json["target"] as? String, !target.isEmpty {
                    return .events([.other(source: source, name: target, action: "raw")])
                }
                return .ignored
            }
            let body = payload["body"] as? [String: Any]
            let action = body?["action"] as? String ?? ""
            return .events(events(forName: name, action: action, source: source, body: body))
        case 7:  // Close
            return .close
        default:  // 6 = ping (our pump keeps the socket alive); rest irrelevant
            return .ignored
        }
    }

    /// Map a Servarr resource name to our event surface. Queue + file-import
    /// changes drive refresh/notifications; everything else surfaces as
    /// `.other` for any future listener.
    /// `name` is matched case-INSENSITIVELY. Servarr broadcasts the resource
    /// name lowercased — the wire says `moviefile` / `trackfile` /
    /// `episodefile`, not the camelCase spelling the API documentation uses.
    /// Matching the camelCase literals meant every file-import broadcast fell
    /// through to `.other` and `.fileImported` was never emitted by anything,
    /// on any source: an import was noticed only via the separate `queue`
    /// broadcast, and only if that one wasn't skipped.
    static func events(
        forName name: String, action: String, source: QueueItem.Source,
        body: [String: Any]? = nil
    ) -> [RealtimeEvent] {
        switch name.lowercased() {
        case "queue":
            return [.queueChanged(source: source)]
        case "episodefile", "moviefile", "trackfile":
            return [.fileImported(source: source), .queueChanged(source: source)]
        case "queue/status":
            // The one Servarr broadcast that ships its resource inline
            // (`QueueStatusController` sends `ModelAction.Updated` *with* the
            // body, unlike the queue's payload-free `Sync`). Free evidence of
            // whether anything actually changed — see `QueueStatus`.
            guard let resource = body?["resource"] as? [String: Any],
                  let status = QueueStatus(resource) else {
                return [.other(source: source, name: name, action: action)]
            }
            return [.queueStatus(source: source, status: status)]
        default:
            return [.other(source: source, name: name, action: action)]
        }
    }
}
