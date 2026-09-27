import Foundation

public struct QBittorrentService: DownloadService {
    public let instance: InstanceID
    private let capabilities: CapabilityIndex
    public init(instance: InstanceID, capabilities: CapabilityIndex) { self.instance = instance; self.capabilities = capabilities }

    private func plan(_ op: String, method: String = "GET", path: String, query: [(String, String)] = [], body: HTTPRequest.Body = .none, priority: RequestPriority = .interactive) -> RequestPlan {
        RequestPlan(instance: instance, operation: op, method: method, pathTemplate: "/api/v2" + path, query: query.map { .init($0.0, $0.1) }, body: body, auth: .session, priority: priority)
    }

    struct Torrent: Codable { let hash: String; let name: String; let state: String; let progress: Double; let dlspeed: Int64?; let eta: Int64?; let size: Int64?; let category: String? }

    public func version() -> Resource<String> {
        Resource(plan: plan("testConnection", path: "/app/version"), tags: [.capabilities(instance)], freshness: .reference, decode: { String(decoding: $0, as: UTF8.self) })
    }

    public func tasks(ids: Set<String>) -> RequestPlan {
        plan("fetchProgress", path: "/torrents/info", query: ids.isEmpty ? [] : [("hashes", ids.map { $0.lowercased() }.sorted().joined(separator: "|"))], priority: .background)
    }

    public func decodeTasks(_ response: HTTPResponse, ids: Set<String>) throws -> [DownloadTask] {
        try Self.decodeJSON([Torrent].self, response, operation: OperationID(instance.kind, "fetchProgress")).map { t in
            DownloadTask(id: t.hash, name: t.name, state: Self.state(t.state), progress: t.progress, downloadSpeed: t.dlspeed, sizeBytes: t.size,
                         etaSeconds: t.eta.map { $0 >= 8_640_000 ? nil : Int($0) } ?? nil, category: t.category, instance: instance)
        }
    }

    static func state(_ raw: String) -> DownloadTask.State {
        switch raw {
        case "downloading", "forcedDL", "metaDL", "forcedMetaDL": .downloading
        case "pausedDL", "stoppedDL": .paused
        case "queuedDL", "allocating": .queued
        case "uploading", "forcedUP", "stalledUP", "queuedUP", "pausedUP", "stoppedUP": .seeding
        case "checkingDL", "checkingUP", "checkingResumeData", "moving": .checking
        case "stalledDL": .stalled
        case "error", "missingFiles": .error
        default: .queued
        }
    }

    public func defaultAddPaused() -> Resource<Bool?> {
        Resource(plan: plan("defaultAddPaused", path: "/app/preferences"), tags: [.capabilities(instance)], freshness: .reference) { data in
            (try? JSONDecoder().decode(JSONValue.self, from: data))?["start_paused_enabled"]?.boolValue
        }
    }

    public func action(_ action: DownloadAction, ids: [String], deleteFiles: Bool) -> Command {
        let hashes = ids.map { $0.lowercased() }.joined(separator: "|")
        let newVerbs = capabilities.has(.qbittorrentStopStartVerbs, instance)
        let (op, path, fields): (String, String, [String: String]) = switch action {
        case .pause: ("pause", newVerbs ? "/torrents/stop" : "/torrents/pause", ["hashes": hashes])
        case .resume: ("resume", newVerbs ? "/torrents/start" : "/torrents/resume", ["hashes": hashes])
        case .delete: ("delete", "/torrents/delete", ["hashes": hashes, "deleteFiles": String(deleteFiles)])
        case .forceStart: ("forceStart", "/torrents/setForceStart", ["hashes": hashes, "value": "true"])
        }
        let p = plan(op, method: "POST", path: path, body: .form(fields))
        let service = self
        return command(op, effects: effects(action, ids: ids)) { ctx in
            do { _ = try await ctx.send(p) } catch let error as MediaKitError {
                // 404 on the 5.x verb from a 4.x server (or the reverse): flip the capability and retry once.
                guard case let .rejected(_, status, _) = error, status == 404, action == .pause || action == .resume else { throw error }
                if newVerbs { await ctx.demote(.qbittorrentStopStartVerbs, for: service.instance) } else { await ctx.promote(.qbittorrentStopStartVerbs, for: service.instance) }
                let alt = newVerbs ? (action == .pause ? "/torrents/pause" : "/torrents/resume") : (action == .pause ? "/torrents/stop" : "/torrents/start")
                _ = try await ctx.send(service.plan(op, method: "POST", path: alt, body: .form(fields)))
            }
            return CommandReceipt(acceptedAt: ctx.clock.now)
        }
    }

    public func add(_ payload: DownloadPayload, category: String?, paused: Bool) -> Command {
        var fields: [String: String] = ["paused": String(paused), "stopped": String(paused)]
        if let category { fields["category"] = category }
        let p: RequestPlan
        switch payload.content {
        case let .magnet(link):
            fields["urls"] = link
            p = plan("addMagnet", method: "POST", path: "/torrents/add", body: .multipart(fields: fields, file: nil))
        case let .file(data, filename):
            p = plan("addFile", method: "POST", path: "/torrents/add", body: .multipart(fields: fields, file: .init(name: "torrents", filename: filename, data: data, contentType: "application/x-bittorrent")))
        }
        let service = self
        return command(p.operation.name) { ctx in
            let r = try await ctx.send(p)
            if String(decoding: r.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "Fails." {
                throw MediaKitError.rejected(service.instance, status: r.status, serverMessage: "Fails.")
            }
            return CommandReceipt(acceptedAt: ctx.clock.now)
        }
    }
}
