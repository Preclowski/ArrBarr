import Foundation

/// Servarr SignalR hub over the injected socket transport.
public actor SignalRSource {
    public enum FrameOutcome: Equatable, Sendable { case events([DataEvent]), close, ignored }

    private static let recordSeparator = "\u{1E}"
    private static let minimumHealthyLifetime: Duration = .seconds(30)
    private static let coldCadence: Duration = .seconds(300)
    private static let deadCyclesBeforeCold = 10

    public let instance: InstanceID
    private let pipeline: RequestPipeline
    private let clock: any MediaClock
    private let log: any LogSink
    private var continuations: [UUID: AsyncStream<DataEvent>.Continuation] = [:]
    private var loop: Task<Void, Never>?
    private var socket: (any WireSocket)?
    private var backoffWait: Task<Void, any Error>?
    private var deadCycles = 0

    public init(instance: InstanceID, pipeline: RequestPipeline, clock: any MediaClock, log: any LogSink) {
        self.instance = instance; self.pipeline = pipeline; self.clock = clock; self.log = log
    }

    public func events() -> AsyncStream<DataEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<DataEvent>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { _ in Task { await self.drop(id) } }
        return stream
    }

    private func drop(_ id: UUID) { continuations.removeValue(forKey: id) }

    public func start() {
        guard loop == nil else { return }
        loop = Task { await self.run() }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        socket?.cancel()
        socket = nil
    }

    /// Tears the socket down and cuts any backoff short: a fixed URL shouldn't sit out a cold-cadence wait.
    public func forceReconnect() {
        deadCycles = 0
        socket?.cancel()
        backoffWait?.cancel()
    }

    private func emit(_ event: DataEvent) {
        for c in continuations.values { c.yield(event) }
    }

    private func run() async {
        var backoff: Duration = .seconds(1)
        while !Task.isCancelled {
            let started = clock.now
            var lived = false
            do {
                try await cycle(receivedFrame: &lived)
            } catch is CancellationError {
                return
            } catch {
                log.log(.debug, category: "Events", "\(instance) realtime cycle ended: \((error as? MediaKitError)?.caseName ?? "socket")")
            }
            if Task.isCancelled { return }
            let healthy = lived || clock.now.timeIntervalSince(started) >= Self.minimumHealthyLifetime.seconds
            if healthy {
                backoff = .seconds(1)
                deadCycles = 0
            } else {
                backoff = min(backoff * 2, .seconds(30))
                deadCycles += 1
            }
            // Jittered, so several arrs behind one host that went down together don't reconnect in lockstep.
            let delay = (deadCycles >= Self.deadCyclesBeforeCold ? Self.coldCadence : backoff) * Double.random(in: 0.8...1.2)
            let wait = Task { [clock] in try await clock.sleep(for: delay) }
            backoffWait = wait
            await withTaskCancellationHandler { _ = try? await wait.value } onCancel: { wait.cancel() }
            backoffWait = nil
        }
    }

    private func cycle(receivedFrame: inout Bool) async throws {
        let token = try await negotiate()
        let ws = try await pipeline.socket(RequestPlan(
            instance: instance, operation: "realtime.connect", pathTemplate: "/signalr/messages",
            query: [.init("id", token)], auth: .querySecret("access_token"), priority: .background, timeout: .seconds(30)))
        socket = ws
        defer { socket = nil; ws.cancel() }
        try await ws.send(#"{"protocol":"json","version":1}"# + Self.recordSeparator)
        var pending: [String] = []
        let first = try await ws.receive()
        guard case let .text(text) = first else { throw MediaKitError.serviceError(instance, code: "handshake", message: "socket closed") }
        var frames = text.components(separatedBy: Self.recordSeparator).filter { !$0.isEmpty }
        guard let handshake = frames.first else { throw MediaKitError.serviceError(instance, code: "handshake", message: "empty") }
        frames.removeFirst()
        if let json = try? JSONSerialization.jsonObject(with: Data(handshake.utf8)) as? [String: Any], let error = json["error"] {
            throw MediaKitError.serviceError(instance, code: "handshake", message: String(describing: error))
        }
        pending = frames
        log.log(.debug, category: "Events", "\(instance) handshake ok")
        emit(.queueChanged(instance))
        let ping = Task { [clock] in
            while !Task.isCancelled {
                try? await clock.sleep(for: .seconds(15))
                guard !Task.isCancelled else { break }
                try? await ws.send(#"{"type":6}"# + Self.recordSeparator)
            }
        }
        defer { ping.cancel() }
        for frame in pending { if try handle(frame) { receivedFrame = true } }
        while !Task.isCancelled {
            switch try await ws.receive() {
            case let .text(text):
                for frame in text.components(separatedBy: Self.recordSeparator) where !frame.isEmpty {
                    if try handle(frame) { receivedFrame = true }
                }
            case .binary:
                receivedFrame = true
            case .closed:
                return
            }
        }
    }

    /// Returns true when the frame counted as proof of life; throws on Close so the loop reconnects.
    private func handle(_ frame: String) throws -> Bool {
        switch Self.parse(frame: frame, instance: instance) {
        case .close: throw MediaKitError.serviceError(instance, code: "close", message: nil)
        case .ignored: return true
        case let .events(events):
            for event in events { emit(event) }
            return true
        }
    }

    private func negotiate() async throws -> String {
        let response = try await pipeline.send(RequestPlan(
            instance: instance, operation: "realtime.negotiate", method: "POST", pathTemplate: "/signalr/messages/negotiate",
            query: [.init("negotiateVersion", "1")], auth: .header("X-Api-Key"), priority: .background, retry: .never))
        let json = try await pipeline.decode(JSONValue.self, from: response, operation: OperationID(instance.kind, "realtime.negotiate"))
        // `connectionToken` when present (SignalR spec, multiplexed hosts), else `connectionId`.
        if let token = json["connectionToken"]?.stringValue, !token.isEmpty { return token }
        if let id = json["connectionId"]?.stringValue, !id.isEmpty { return id }
        throw MediaKitError.decoding(OperationID(instance.kind, "realtime.negotiate"), detail: "no connectionToken")
    }

    /// Pure. Servarr nests `action` inside `arguments[0].body`.
    public nonisolated static func parse(frame: String, instance: InstanceID) -> FrameOutcome {
        let trimmed = frame.hasSuffix(recordSeparator) ? String(frame.dropLast()) : frame
        guard let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
              let type = json["type"] as? Int else { return .ignored }
        switch type {
        case 1:
            guard let args = json["arguments"] as? [[String: Any]], let payload = args.first, let name = payload["name"] as? String else {
                if let target = json["target"] as? String, !target.isEmpty { return .events([.other(instance, resource: target, action: "raw")]) }
                return .ignored
            }
            let body = payload["body"] as? [String: Any]
            let action = body?["action"] as? String ?? ""
            return .events(events(name: name, action: action, body: body, instance: instance))
        case 7:
            return .close
        default:
            return .ignored
        }
    }

    static func events(name: String, action: String, body: [String: Any]?, instance i: InstanceID) -> [DataEvent] {
        let resource = body?["resource"] as? [String: Any]
        let id = resource?["id"] as? Int
        switch name.lowercased() {
        case "queue":
            return [.queueChanged(i)]
        case "queue/status":
            guard let resource, let total = resource["totalCount"] as? Int else { return [.other(i, resource: name, action: action)] }
            return [.queueStatus(i, QueueCounts(total: total, count: resource["count"] as? Int ?? 0, unknown: resource["unknownCount"] as? Int ?? 0,
                                                errors: resource["errors"] as? Bool ?? false, warnings: resource["warnings"] as? Bool ?? false))]
        case "moviefile": return [.fileImported(i, kind: .movie, entityID: resource?["movieId"] as? Int)]
        case "episodefile": return [.fileImported(i, kind: .series, entityID: resource?["seriesId"] as? Int)]
        case "trackfile": return [.fileImported(i, kind: .album, entityID: resource?["albumId"] as? Int)]
        case "movie": return [.entityChanged(i, kind: .movie, entityID: id)]
        case "series": return [.entityChanged(i, kind: .series, entityID: id)]
        case "artist": return [.entityChanged(i, kind: .artist, entityID: id)]
        case "album": return [.entityChanged(i, kind: .album, entityID: id)]
        case "health": return [.healthChanged(i)]
        case "calendar": return [.calendarChanged(i)]
        case "command":
            let status = (resource?["status"] as? String ?? "").lowercased()
            guard status == "completed" || status == "failed" else { return [.other(i, resource: name, action: action)] }
            return [.commandFinished(i, name: resource?["name"] as? String ?? "")]
        default:
            return [.other(i, resource: name, action: action)]
        }
    }
}
