import Foundation

public struct SABnzbdService: DownloadService {
    public let instance: InstanceID
    public init(instance: InstanceID) { self.instance = instance }

    private func api(_ op: String, method: String = "GET", query: [(String, String)], body: HTTPRequest.Body = .none, priority: RequestPriority = .interactive) -> RequestPlan {
        RequestPlan(instance: instance, operation: op, method: method, pathTemplate: "/api", query: (query + [("output", "json")]).map { .init($0.0, $0.1) },
                    body: body, auth: .querySecret("apikey"), priority: priority, retry: method == "GET" && query.first?.1 != "pause" && query.first?.1 != "resume" ? .idempotent : .never)
    }

    struct Slot: Codable { let nzo_id: String; let filename: String; let status: String; let mb: String?; let mbleft: String?; let percentage: String?; let timeleft: String?; let cat: String? }
    struct QueueBody: Codable { let paused: Bool?; let slots: [Slot]; let kbpersec: String? }
    struct QueueResponse: Codable { let queue: QueueBody }

    public struct HistorySlot: Codable, Sendable, Hashable {
        public let nzo_id: String
        public let name: String
        public let status: String
        public let category: String?
        public let completed: Int?
        public let bytes: Int64?
        public let fail_message: String?
        public let storage: String?
    }
    struct HistoryResponse: Codable { struct Body: Codable { let slots: [HistorySlot] }; let history: Body }

    public func version() -> Resource<String> {
        Resource(plan: api("testConnection", query: [("mode", "version")]), tags: [.capabilities(instance)], freshness: .reference) { data in
            (try? JSONDecoder().decode(JSONValue.self, from: data))?["version"]?.stringValue ?? ""
        }
    }

    public func tasks(ids: Set<String>) -> RequestPlan { api("fetchProgress", query: [("mode", "queue")], priority: .background) }

    public func decodeTasks(_ response: HTTPResponse, ids: Set<String>) throws -> [DownloadTask] {
        let queue = try Self.decodeJSON(QueueResponse.self, response, operation: OperationID(instance.kind, "fetchProgress")).queue
        let speed = queue.kbpersec.flatMap(Double.init).map { Int64($0 * 1024) }
        return queue.slots.map { s in
            let state: DownloadTask.State = switch s.status.lowercased() {
            case "downloading": .downloading
            case "paused": .paused
            case "checking", "verifying", "repairing", "extracting", "moving": .checking
            default: .queued
            }
            let mb = Double(s.mb ?? "") ?? 0, left = Double(s.mbleft ?? "") ?? 0
            return DownloadTask(id: s.nzo_id, name: s.filename, state: state, progress: mb > 0 ? max(0, (mb - left) / mb) : 0,
                                downloadSpeed: state == .downloading ? speed : nil, sizeBytes: Int64(mb * 1_048_576),
                                etaSeconds: Self.seconds(s.timeleft), category: s.cat, instance: instance)
        }
    }

    public func history(limit: Int = 50) -> Resource<[HistorySlot]> {
        Resource(plan: api("history", query: [("mode", "history"), ("limit", String(limit))]), tags: [.collection(.downloads, instance)], freshness: .warm) { data in
            try WireCodec.decoder.decode(HistoryResponse.self, from: data).history.slots
        }
    }

    public func defaultAddPaused() -> Resource<Bool?> {
        Resource(plan: api("defaultAddPaused", query: [("mode", "version")]), tags: [.capabilities(instance)], freshness: .reference) { _ in nil }
    }

    public func action(_ action: DownloadAction, ids: [String], deleteFiles: Bool) -> Command {
        guard action != .forceStart else { return Self.unsupportedForceStart(instance) }
        let name = switch action { case .pause: "pause"; case .resume: "resume"; default: "delete" }
        var query = [("mode", "queue"), ("name", name), ("value", ids.joined(separator: ","))]
        if action == .delete { query.append(("del_files", deleteFiles ? "1" : "0")) }
        let p = api(action.rawValue, query: query)
        return command(action.rawValue, effects: effects(action, ids: ids)) { ctx in _ = try await ctx.send(p); return CommandReceipt(acceptedAt: ctx.clock.now) }
    }

    public func add(_ payload: DownloadPayload, category: String?, paused: Bool) -> Command {
        var query = [("mode", "addfile")]
        if let category { query.append(("cat", category)) }
        if paused { query.append(("priority", "-2")) }
        guard case let .file(data, filename) = payload.content else {
            return Command(name: OperationID(instance.kind, "addFile"), instance: instance, invalidates: []) { _ in throw MediaKitError.unsupported(self.instance, Capability(rawValue: "magnet")) }
        }
        let p = api("addFile", method: "POST", query: query, body: .multipart(fields: [:], file: .init(name: "name", filename: filename, data: data, contentType: "application/x-nzb")))
        let service = self
        return command("addFile") { ctx in
            let r = try await ctx.send(p)
            let json = try? await ctx.decode(JSONValue.self, from: r, operation: p.operation)
            if json?["status"]?.boolValue == false { throw MediaKitError.rejected(service.instance, status: r.status, serverMessage: json?["error"]?.stringValue) }
            return CommandReceipt(acceptedAt: ctx.clock.now)
        }
    }

    static func seconds(_ timeleft: String?) -> Int? {
        guard let parts = timeleft?.split(separator: ":").compactMap({ Int($0) }), parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
}
