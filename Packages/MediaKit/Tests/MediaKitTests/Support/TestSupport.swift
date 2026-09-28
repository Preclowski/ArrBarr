import Foundation
import Testing
@testable import MediaKit

/// Records every request; answers from a script keyed by operation name, or a closure.
final class ScriptedTransport: Transport, SocketTransport, @unchecked Sendable {
    struct Answer: Sendable {
        var status = 200
        var headers: HTTPHeaders = ["Content-Type": "application/json"]
        var body = Data("{}".utf8)
        var error: (any Error)?
    }

    private let lock = NSLock()
    private var script: [String: [Answer]] = [:]
    private(set) var requests: [HTTPRequest] = []
    var fallback: @Sendable (HTTPRequest) throws -> Answer = { _ in Answer() }
    var frames: [String] = []
    /// Real sleep before answering, for cancellation tests.
    var delay: Duration = .zero
    private var inFlight = 0, peakInFlight = 0, cancelled = 0

    init() {}

    func answer(_ operation: String, _ answers: Answer...) { lock.withLock { script[operation, default: []].append(contentsOf: answers) } }
    func answer(_ operation: String, json: String, status: Int = 200, instance: InstanceID? = nil) { answer(operation, Answer(status: status, body: Data(json.utf8))) }

    var operations: [String] { lock.withLock { requests.map(\.operation.name) } }
    var count: Int { lock.withLock { requests.count } }
    /// Most sends that were inside `send` at the same moment.
    var maxInFlight: Int { lock.withLock { peakInFlight } }
    /// Sends whose delay was cut short by cancellation.
    var cancelledSends: Int { lock.withLock { cancelled } }
    func count(_ operation: String) -> Int { lock.withLock { requests.filter { $0.operation.name == operation }.count } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let answer: Answer = try lock.withLock {
            requests.append(request)
            if var queue = script[request.operation.name], !queue.isEmpty {
                let first = queue.removeFirst()
                script[request.operation.name] = queue.isEmpty ? nil : queue
                return first
            }
            return try fallback(request)
        }
        lock.withLock { inFlight += 1; peakInFlight = max(peakInFlight, inFlight) }
        defer { lock.withLock { inFlight -= 1 } }
        if delay > .zero {
            do { try await Task.sleep(for: delay) } catch { lock.withLock { cancelled += 1 }; throw error }
        }
        if let error = answer.error { throw error }
        return HTTPResponse(status: answer.status, headers: answer.headers, body: answer.body)
    }

    func open(_ request: HTTPRequest) async throws -> any WireSocket {
        lock.withLock { requests.append(request) }
        return ScriptedSocket(frames: lock.withLock { frames })
    }
}

final class ScriptedSocket: WireSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [String]
    private(set) var sent: [String] = []
    private var cancelled = false
    init(frames: [String]) { self.frames = frames }

    func send(_ text: String) async throws { lock.withLock { sent.append(text) } }

    func receive() async throws -> WireFrame {
        while true {
            let next: String? = lock.withLock { frames.isEmpty ? nil : frames.removeFirst() }
            if let next { return .text(next) }
            if lock.withLock({ cancelled }) { return .closed(code: 1000) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func cancel() { lock.withLock { cancelled = true } }
}

/// Throws on any host that is not fixture.invalid: a test suite never reaches the network.
struct HostileTransport: Transport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        Issue.record("network request escaped the test double: \(request.method) \(request.pathTemplate)")
        throw URLError(.notConnectedToInternet)
    }
}

/// One kernel wired for tests: scripted transport, test clock, in-memory or temp database.
struct TestKit {
    let clock = TestClock()
    let transport = ScriptedTransport()
    let telemetry = TelemetryRecorder()
    let registry: InstanceRegistry
    let governor: HostGovernor
    let sessions: SessionBroker
    let pipeline: RequestPipeline
    let database: SQLiteDatabase?
    let store: ResourceStore
    let identity: IdentityStore
    let capabilities = CapabilityIndex()
    let probe: CapabilityProbe

    static let radarr = InstanceID(.radarr)
    static let sonarr = InstanceID(.sonarr)
    static let qbittorrent = InstanceID(.qbittorrent)

    let fixtures: FixtureTransport?

    init(instances: [InstanceID] = [TestKit.radarr, TestKit.sonarr], database location: DatabaseLocation? = .memory,
         limits: HostGovernor.Limits = HostGovernor.Limits(), credentials: [InstanceID: Credentials]? = nil, fixtures: Bool = false) async throws {
        let log = NoLog()
        clock.autoAdvance = true
        self.fixtures = fixtures ? FixtureTransport(clock: clock) : nil
        registry = InstanceRegistry(log: log)
        governor = HostGovernor(defaults: limits, clock: clock, telemetry: telemetry, log: log)
        sessions = SessionBroker(strategies: SessionStrategies.standard, telemetry: telemetry, log: log)
        var table = credentials ?? [:]
        var descriptors: [InstanceDescriptor] = []
        for id in instances {
            let url = URL(string: "http://\(id.kind.rawValue).fixture.invalid:8080")!
            if table[id] == nil { table[id] = Credentials(baseURL: url, material: .apiKey("secret-\(id.kind.rawValue)"), generation: "g1") }
            descriptors.append(InstanceDescriptor(id: id, baseURL: table[id]!.baseURL, generation: table[id]!.generation))
        }
        let wire: any Transport = self.fixtures ?? transport
        pipeline = RequestPipeline(transport: wire, sockets: transport, governor: governor, sessions: sessions,
                                   credentials: StaticCredentials(table), registry: registry, telemetry: telemetry, log: log, clock: clock)
        database = try location.map { try SQLiteDatabase(location: $0, log: log) }
        identity = IdentityStore(database: database)
        store = ResourceStore(database: database, pipeline: pipeline, identity: identity, clock: clock, telemetry: telemetry, log: log)
        probe = CapabilityProbe(store: store, index: capabilities, database: database, clock: clock, log: log)
        await store.attach(probe: probe, capabilities: capabilities)
        await registry.attach(.init(store: store, capabilities: probe, sessions: sessions, identity: identity))
        await registry.apply(descriptors)
    }

    func plan(_ operation: String, instance: InstanceID = TestKit.radarr, path: String = "/api/v3/queue", query: [RequestPlan.QueryItem] = [],
              priority: RequestPriority = .interactive) -> RequestPlan {
        RequestPlan(instance: instance, operation: operation, pathTemplate: path, query: query, auth: .header("X-Api-Key"), priority: priority)
    }

    func resource<V: Codable & Sendable>(_ operation: String, as type: V.Type = V.self, instance: InstanceID = TestKit.radarr, path: String = "/api/v3/queue",
                                         freshness: FreshnessClass = .live, ttl: Duration? = nil, tags: Set<InvalidationTag> = []) -> Resource<V> {
        Resource<V>.json(plan(operation, instance: instance, path: path), tags: tags.isEmpty ? [.collection(.queue, instance)] : tags, freshness: freshness, ttl: ttl)
    }
}

/// Polls a condition in real time; for state reached through unstructured tasks the test cannot await.
func eventually(within limit: Duration = .seconds(5), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + limit
    while !condition() {
        guard ContinuousClock.now < deadline else { Issue.record("condition not met within \(limit)"); return }
        try await Task.sleep(for: .milliseconds(2))
    }
}

enum Temp {
    static func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mediakit-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

extension ScriptedTransport.Answer {
    init(status: Int, body: Data) { self.init(); self.status = status; self.body = body }
}
