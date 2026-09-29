import Foundation

/// Demo mode and every fixture-driven test: answers from `Fixtures/<kind>.json` and echoes writes.
public actor FixtureTransport: Transport, SocketTransport {
    private struct Entry: Decodable {
        let status: Int
        let headers: [String: String]
        let body: JSONValue
        let synthetic: Bool?
        /// The recording day: dates in the body move by whole days so it reads as today (calendars stay upcoming).
        let anchor: Date?
        /// A query key (`movieId`): rows carrying it answer only the request with the same value (credits per title).
        let scope: String?
    }

    private let root: URL
    private let clock: any MediaClock
    private var files: [InstanceKind: [String: Entry]] = [:]
    /// PUT bodies keyed by path: a demo monitor toggle survives the next GET of the same record.
    private var putBodies: [String: JSONValue] = [:]
    /// Demo pause/resume by download id: the arr queue rows tracking those downloads report it.
    private var downloadStatus: [String: String] = [:]
    private var removedQueueItems: Set<String> = []
    private var log: [(OperationID, Date)] = []
    private var commands: [Int: Date] = [:]
    private var nextCommandID = 1000

    public static var bundledFixtures: URL { Bundle.module.resourceURL!.appendingPathComponent("Fixtures") }

    public init(bundleRoot: URL? = nil, clock: any MediaClock = SystemClock()) {
        root = bundleRoot ?? Self.bundledFixtures; self.clock = clock
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
        // SABnzbd's API writes are GETs; a download action is a write whatever the verb.
        let isWrite = request.method != "GET" || (kind.family == .download && DownloadAction(rawValue: request.operation.name) != nil)
        if isWrite { noteWrite(request) }
        if request.method == "PUT", case let .bytes(data, contentType) = request.body, contentType.contains("json"),
           let json = try? JSONDecoder().decode(JSONValue.self, from: data) {
            putBodies[pathKey] = json
        }
        if request.method == "GET", let remembered = putBodies[pathKey] {
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: try encode(remembered))
        }
        if request.method == "GET", let hit = record(in: table, template: request.pathTemplate, id: request.url.lastPathComponent) {
            let body = hit.anchor.map { Self.shift(hit.body, byDays: Self.days(from: $0, to: clock.now)) } ?? hit.body
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: try encode(body))
        }
        if let entry = table["\(name)-\(slug)"] ?? table[name] {
            var body = applyState(entry.body, name: name)
            if let scope = entry.scope { body = Self.scoped(body, by: scope, to: request.url) }
            if let anchor = entry.anchor { body = Self.shift(body, byDays: Self.days(from: anchor, to: clock.now)) }
            return HTTPResponse(status: entry.status, headers: HTTPHeaders(entry.headers), body: try encode(body))
        }
        guard isWrite else { throw MediaKitError.fixtureMissing(request.operation) }
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
        return FixtureSocket(frames: [#"{}"#])
    }

    // periphery:ignore
    public func requestLog() -> [(OperationID, Date)] { log }

    // MARK: - Internals

    private func load(_ kind: InstanceKind) throws -> [String: Entry] {
        if let cached = files[kind] { return cached }
        let url = root.appendingPathComponent("\(kind.rawValue).json")
        guard let data = try? Data(contentsOf: url) else { files[kind] = [:]; return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let table = try decoder.decode([String: Entry].self, from: data)
        files[kind] = table
        return table
    }

    /// One recorded detail answers every id; a list that holds the requested id answers with that entry
    /// instead, dated like the list. The calendar goes first: its rows are the upcoming state of the title.
    private func record(in table: [String: Entry], template: String, id: String) -> (body: JSONValue, anchor: Date?)? {
        let sources = ["movie": ["fetchcalendar", "fetchallmovies"], "series": ["fetchallseries"],
                       "artist": ["fetchallartists"], "album": ["fetchcalendar", "fetchartistalbums"]]
        guard let noun = template.split(separator: "/").dropLast().last.map(String.init), template.hasSuffix("/{id}"),
              let ops = sources[noun], let wanted = Double(id) else { return nil }
        for op in ops {
            guard case let .array(items)? = table[op]?.body else { continue }
            if let hit = items.first(where: { $0["id"]?.intValue.map(Double.init) == wanted }) { return (hit, table[op]?.anchor) }
        }
        return nil
    }

    private static func scoped(_ body: JSONValue, by key: String, to url: URL) -> JSONValue {
        guard case let .array(items) = body,
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == key })?.value.flatMap(Int.init)
        else { return body }
        return .array(items.filter { $0[key]?.intValue == id })
    }

    /// The recording's day against the viewer's local day, so "today" rows read as today east of UTC too.
    static func days(from anchor: Date, to now: Date, calendar: Calendar = .current) -> Int {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let today = utc.date(from: calendar.dateComponents([.year, .month, .day], from: now)) else { return 0 }
        return utc.dateComponents([.day], from: utc.startOfDay(for: anchor), to: today).day ?? 0
    }

    private static func shift(_ value: JSONValue, byDays days: Int) -> JSONValue {
        switch value {
        case let .object(o): return .object(o.mapValues { shift($0, byDays: days) })
        case let .array(a): return .array(a.map { shift($0, byDays: days) })
        case let .string(s):
            let full = ISO8601DateFormatter(), day = ISO8601DateFormatter()
            day.formatOptions = [.withFullDate]
            if s.count == 20, let d = full.date(from: s) { return .string(full.string(from: d.addingTimeInterval(Double(days) * 86_400))) }
            if s.count == 10, let d = day.date(from: s) { return .string(day.string(from: d.addingTimeInterval(Double(days) * 86_400))) }
            return value
        default: return value
        }
    }

    private func encode(_ value: JSONValue) throws -> Data {
        if case let .string(s) = value, s.first != "{", s.first != "[" { return Data(s.utf8) }
        return try JSONEncoder().encode(value)
    }

    private func noteWrite(_ request: HTTPRequest) {
        if request.pathTemplate.contains("/queue/{id}"), request.method == "DELETE" { removedQueueItems.insert(request.url.lastPathComponent) }
        guard request.operation.kind.family == .download else { return }
        let status: String? = switch DownloadAction(rawValue: request.operation.name) {
        case .pause: "paused"
        case .resume, .forceStart: "downloading"
        default: nil
        }
        guard let status else { return }
        var ids: [String] = []
        if case let .form(fields) = request.body, let hashes = fields["hashes"] { ids += hashes.split(separator: "|").map(String.init) }
        if let value = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "value" })?.value {
            ids += value.split(separator: ",").map(String.init)
        }
        for id in ids { downloadStatus[id.lowercased()] = status }
    }

    /// Queue rows reflect pause/resume/delete for the process lifetime; commands complete after 3 s of clock time.
    private func applyState(_ body: JSONValue, name: String) -> JSONValue {
        if name.hasPrefix("fetchqueue"), case var .object(o) = body, case let .array(records)? = o["records"] {
            o["records"] = .array(records.compactMap { record in
                guard let id = record["id"]?.intValue.map(String.init) else { return record }
                if removedQueueItems.contains(id) { return nil }
                if let download = record["downloadId"]?.stringValue?.lowercased(), let status = downloadStatus[download], case var .object(r) = record {
                    r["status"] = .string(status); return .object(r)
                }
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
