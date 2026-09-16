import Foundation

/// A rule the demo applies to a write so later reads reflect it.
public struct DemoRule: Sendable {
    public enum Effect: Sendable {
        case setQueueStatus(status: String)
        case removeQueueItem
        case setMonitored
        case appendLibrary
        case commandRunning(seconds: Int)
    }
    public let on: OperationID
    public let effect: Effect
    public init(on: OperationID, effect: Effect) { self.on = on; self.effect = effect }
}

/// Demo mode and every fixture-driven test: answers from `Fixtures/<kind>.json`, echoes writes, replays queued frames.
public actor FixtureTransport: Transport, SocketTransport {
    private struct Entry: Decodable {
        let status: Int
        let headers: [String: String]
        let body: JSONValue
        let synthetic: Bool?
    }

    private let root: URL
    private let rules: [DemoRule]
    private let clock: any MediaClock
    private var files: [InstanceKind: [String: Entry]] = [:]
    private var overrides: [String: JSONValue] = [:]
    /// PUT bodies keyed by path: a demo monitor toggle survives the next GET of the same record.
    private var putBodies: [String: JSONValue] = [:]
    private var queueStatus: [String: String] = [:]
    private var removedQueueItems: Set<String> = []
    private var frames: [InstanceID: [String]] = [:]
    private var log: [(OperationID, Date)] = []
    private var commands: [Int: Date] = [:]
    private var nextCommandID = 1000

    public static var bundledFixtures: URL { Bundle.module.resourceURL!.appendingPathComponent("Fixtures") }

    public init(bundleRoot: URL? = nil, rules: [DemoRule] = [], clock: any MediaClock = SystemClock()) {
        root = bundleRoot ?? Self.bundledFixtures; self.rules = rules; self.clock = clock
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        log.append((request.operation, clock.now))
        let kind = request.operation.kind
        let name = request.operation.name.lowercased().replacingOccurrences(of: ".", with: "-")
        let table = try load(kind)
        let slug: String = {
            if let rpc = request.rpcMethod { return rpc.replacingOccurrences(of: ".", with: "-") }
            var s = request.pathTemplate.replacingOccurrences(of: "\\{[a-zA-Z]+\\}", with: "id", options: .regularExpression).replacingOccurrences(of: "/", with: "-")
            while s.hasPrefix("-") { s.removeFirst() }
            while s.hasSuffix("-") { s.removeLast() }
            return s.replacingOccurrences(of: "--", with: "-")
        }()
        let pathKey = "\(kind.rawValue)\(request.url.path)"
        if request.method == "PUT", case let .bytes(data, contentType) = request.body, contentType.contains("json"),
           let json = try? JSONDecoder().decode(JSONValue.self, from: data) {
            putBodies[pathKey] = json
        }
        if request.method == "GET", let remembered = putBodies[pathKey] {
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: try encode(remembered))
        }
        if let entry = table["\(name)-\(slug)"] ?? table[name] {
            var body = entry.body
            if let override = overrides[request.operation.rawValue] { body = override }
            body = applyState(body, kind: kind, name: name)
            return HTTPResponse(status: entry.status, headers: HTTPHeaders(entry.headers), body: try encode(body))
        }
        guard request.method != "GET" else { throw MediaKitError.fixtureMissing(request.operation) }
        apply(rulesFor: request.operation, request: request)
        if request.pathTemplate.hasSuffix("/command") {
            let id = nextCommandID
            nextCommandID += 1
            commands[id] = clock.now
            return HTTPResponse(status: 201, headers: ["Content-Type": "application/json"], body: Data(#"{"id":\#(id),"status":"queued"}"#.utf8))
        }
        if case let .bytes(data, contentType) = request.body, request.method != "DELETE", contentType.contains("json") {
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: data)
        }
        return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
    }

    public func open(_ request: HTTPRequest) async throws -> any WireSocket {
        log.append((request.operation, clock.now))
        let queued = frames.removeValue(forKey: InstanceID(request.operation.kind)) ?? []
        return FixtureSocket(frames: [#"{}"#] + queued)
    }

    public func enqueueFrames(_ newFrames: [String], for instance: InstanceID) { frames[instance, default: []].append(contentsOf: newFrames) }
    public func requestLog() -> [(OperationID, Date)] { log }
    public func reset() { overrides = [:]; putBodies = [:]; queueStatus = [:]; removedQueueItems = []; frames = [:]; log = []; commands = [:] }

    /// Tests and the demo seed variants without touching the bundle.
    public func override(_ operation: OperationID, body: JSONValue) { overrides[operation.rawValue] = body }

    // MARK: - Internals

    private func load(_ kind: InstanceKind) throws -> [String: Entry] {
        if let cached = files[kind] { return cached }
        let url = root.appendingPathComponent("\(kind.rawValue).json")
        guard let data = try? Data(contentsOf: url) else { files[kind] = [:]; return [:] }
        let table = try JSONDecoder().decode([String: Entry].self, from: data)
        files[kind] = table
        return table
    }

    private func encode(_ value: JSONValue) throws -> Data {
        if case let .string(s) = value, s.first != "{", s.first != "[" { return Data(s.utf8) }
        return try JSONEncoder().encode(value)
    }

    private func apply(rulesFor operation: OperationID, request: HTTPRequest) {
        let id = request.url.lastPathComponent
        for rule in rules where rule.on == operation {
            switch rule.effect {
            case let .setQueueStatus(status): queueStatus[id] = status
            case .removeQueueItem: removedQueueItems.insert(id)
            case .setMonitored, .appendLibrary, .commandRunning: break
            }
        }
        if request.method == "DELETE", request.pathTemplate.contains("/queue/") { removedQueueItems.insert(id) }
    }

    /// Queue rows reflect pause/resume/delete for the process lifetime; commands complete after 3 s of clock time.
    private func applyState(_ body: JSONValue, kind: InstanceKind, name: String) -> JSONValue {
        if name.hasPrefix("fetchqueue"), case var .object(o) = body, case let .array(records)? = o["records"] {
            o["records"] = .array(records.compactMap { record in
                guard let id = record["id"]?.intValue.map(String.init) else { return record }
                if removedQueueItems.contains(id) { return nil }
                if let status = queueStatus[id], case var .object(r) = record { r["status"] = .string(status); return .object(r) }
                return record
            })
            return .object(o)
        }
        if name == "commandstatus", case var .object(o) = body, let id = o["id"]?.intValue, let started = commands[id] {
            o["status"] = .string(clock.now.timeIntervalSince(started) >= 3 ? "completed" : "started")
            return .object(o)
        }
        return body
    }
}

private final class FixtureSocket: WireSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [String]
    private var cancelled = false
    init(frames: [String]) { self.frames = frames.map { $0 + "\u{1E}" } }

    func send(_ text: String) async throws {}

    func receive() async throws -> WireFrame {
        while true {
            if let next = lock.withLock({ frames.isEmpty ? nil : frames.removeFirst() }) { return .text(next) }
            if lock.withLock({ cancelled }) { return .closed(code: 1000) }
            try await Task.sleep(for: .seconds(1))
        }
    }

    func cancel() { lock.withLock { cancelled = true } }
}
