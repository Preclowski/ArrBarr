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
public enum RealtimeEvent: Sendable, Equatable {
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
        // `await` stops inline (not detached) so a rapid second call to
        // `reconfigure` can't observe the new connection before the old
        // one has finished tearing down. Stops are cheap (cancellation
        // + WS close). Starts can fire-and-forget since runLoop is the
        // long-lived part — its setup races are absorbed by the actor.
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
                if let existing = connections[source] {
                    await existing.stop()
                }
                connections[source] = nil
            case (true, true):
                if connections[source]?.matches(cfg) == false {
                    if let existing = connections[source] {
                        await existing.stop()
                    }
                    let conn = makeConnection(source: source, config: cfg)
                    connections[source] = conn
                    Task { await conn.start() }
                }
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
        await onEvent(event)
    }

    public func shutdown() async {
        for (_, conn) in connections {
            await conn.stop()
        }
        connections.removeAll()
    }

    /// Tear down every connection and immediately reopen with the
    /// cached configs. Used after wake-from-sleep, when the OS may
    /// have killed the WebSocket but our reconnect loop won't notice
    /// for 30-90 s (it needs a failed `receive` to fire). No-op when
    /// we have nothing cached yet (`reconfigure` was never called).
    public func forceReconnect() async {
        guard let cfg = lastConfigs else { return }
        for (_, conn) in connections {
            await conn.stop()
        }
        connections.removeAll()
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
    /// Bumped each time a connection cycle reaches the listen phase
    /// successfully. Used by the reconnect loop to know whether the
    /// previous attempt actually got off the ground — proper exits
    /// from `listen` reset backoff, failures before handshake don't.
    private var lastReachedListen = false
    /// Counts failed-before-handshake attempts in a row. After a
    /// threshold we throttle further so a bad reverse-proxy can't
    /// pin us at the 30s ceiling forever — we drop to once-every-
    /// 5-minutes and let polling stay primary.
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

    /// Reconnect loop with exponential backoff. Backoff is reset on a
    /// reached-handshake cycle (so a flaky network that recovers fast
    /// goes back to 1 s), not on `runOnce` returning, which only
    /// happens on cancellation. Beyond `failureCeilingBeforeColdStart`
    /// consecutive *pre-handshake* failures we drop to a 5-minute
    /// retry cadence — there's no point pounding a misconfigured
    /// reverse proxy when polling is doing the real work anyway.
    private func runLoop() async {
        var backoffNs: UInt64 = 1_000_000_000  // 1 s
        let maxBackoffNs: UInt64 = 30_000_000_000  // 30 s
        let coldStartNs: UInt64 = 5 * 60 * 1_000_000_000  // 5 min
        let failureCeilingBeforeColdStart = 10
        while !Task.isCancelled {
            lastReachedListen = false
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
            if lastReachedListen {
                // We did real work — connection ran for a while. Reset.
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
        // We're past the protocol handshake. Mark the cycle as
        // "real" so backoff resets when listen eventually exits.
        lastReachedListen = true
        realtimeLog.debug("[\(self.source.rawValue, privacy: .public)] handshake ok — listening (pending=\(pending.count, privacy: .public))")
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

        realtimeLog.debug("[\(self.source.rawValue, privacy: .public)] negotiate POST \(url.absoluteString, privacy: .public)")
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
            let msg = try await ws.receive()
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
            let msg = try await ws.receive()
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
            throw URLError(.cancelled)
        case .ignored:
            break
        case .events(let events):
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
            let action = (payload["body"] as? [String: Any])?["action"] as? String ?? ""
            return .events(events(forName: name, action: action, source: source))
        case 7:  // Close
            return .close
        default:  // 6 = ping (our pump keeps the socket alive); rest irrelevant
            return .ignored
        }
    }

    /// Map a Servarr resource name to our event surface. Queue + file-import
    /// changes drive refresh/notifications; everything else surfaces as
    /// `.other` for any future listener.
    static func events(forName name: String, action: String, source: QueueItem.Source) -> [RealtimeEvent] {
        switch name {
        case "queue":
            return [.queueChanged(source: source)]
        case "episodeFile", "movieFile", "trackFile":
            return [.fileImported(source: source), .queueChanged(source: source)]
        default:
            return [.other(source: source, name: name, action: action)]
        }
    }
}
