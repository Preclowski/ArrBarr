import Foundation

struct TransmissionService: DownloadService {
    let instance: InstanceID
    init(instance: InstanceID) { self.instance = instance }

    private func rpc(_ op: String, method: String, arguments: [String: JSONValue] = [:], priority: RequestPriority = .interactive) -> RequestPlan {
        let body = try! RequestBuilder.json(JSONValue.object(["method": .string(method), "arguments": .object(arguments)]))
        return RequestPlan(instance: instance, operation: op, method: "POST", pathTemplate: "/transmission/rpc", body: body, auth: .session,
                           priority: priority, retry: method.hasSuffix("-get") ? .idempotent : .never, rpcMethod: method)
    }

    func version() -> Resource<String> {
        Resource(plan: rpc("testConnection", method: "session-get"), tags: [.capabilities(instance)], freshness: .reference) { data in
            (try? JSONDecoder().decode(JSONValue.self, from: data))?["arguments"]?["version"]?.stringValue ?? ""
        }
    }

    func tasks(ids: Set<String>) -> RequestPlan {
        var arguments: [String: JSONValue] = ["fields": .array(["hashString", "percentDone", "rateDownload", "status", "name", "totalSize", "eta"].map { .string($0) })]
        if !ids.isEmpty { arguments["ids"] = .array(ids.sorted().map { .string($0) }) }
        return rpc("fetchProgress", method: "torrent-get", arguments: arguments, priority: .background)
    }

    func decodeTasks(_ response: HTTPResponse, ids: Set<String>) throws -> [DownloadTask] {
        let json = try Self.decodeJSON(JSONValue.self, response, operation: OperationID(instance.kind, "fetchProgress"))
        guard json["result"]?.stringValue == "success" else {
            throw MediaKitError.serviceError(instance, code: nil, message: json["result"]?.stringValue)
        }
        return (json["arguments"]?["torrents"]?.arrayValue ?? []).compactMap { t in
            guard let hash = t["hashString"]?.stringValue else { return nil }
            let status = t["status"]?.intValue ?? 0
            let state: DownloadTask.State = switch status {
            case 0: .paused
            case 1, 2: .checking
            case 3: .queued
            case 4: .downloading
            case 5, 6: .seeding
            default: .queued
            }
            let eta = t["eta"]?.intValue ?? -1
            return DownloadTask(id: hash, name: t["name"]?.stringValue ?? hash, state: state, progress: t["percentDone"]?.doubleValue ?? 0,
                                downloadSpeed: t["rateDownload"]?.intValue.map(Int64.init), sizeBytes: t["totalSize"]?.intValue.map(Int64.init),
                                etaSeconds: eta >= 0 ? eta : nil, instance: instance)
        }
    }

    func defaultAddPaused() -> Resource<Bool?> {
        Resource(plan: rpc("defaultAddPaused", method: "session-get"), tags: [.capabilities(instance)], freshness: .reference) { data in
            (try? JSONDecoder().decode(JSONValue.self, from: data))?["arguments"]?["start-added-torrents"]?.boolValue.map { !$0 }
        }
    }

    func action(_ action: DownloadAction, ids: [String], deleteFiles: Bool) -> Command {
        guard action != .forceStart else { return Self.unsupportedForceStart(instance) }
        let method = switch action { case .pause: "torrent-stop"; case .resume: "torrent-start"; default: "torrent-remove" }
        var arguments: [String: JSONValue] = ["ids": .array(ids.map { .string($0) })]
        if action == .delete { arguments["delete-local-data"] = .bool(deleteFiles) }
        let p = rpc(action.rawValue, method: method, arguments: arguments)
        return command(action.rawValue, effects: effects(action, ids: ids)) { ctx in _ = try await ctx.send(p); return CommandReceipt(acceptedAt: ctx.clock.now) }
    }

    /// `download-dir` comes from `session-get`, then the category is a sub-folder: two requests in one run.
    func add(_ payload: DownloadPayload, category: String?, paused: Bool) -> Command {
        let service = self
        return command("addMagnet") { ctx in
            var arguments: [String: JSONValue] = ["paused": .bool(paused)]
            switch payload.content {
            case let .magnet(link): arguments["filename"] = .string(link)
            case let .file(data, _): arguments["metainfo"] = .string(data.base64EncodedString())
            }
            if let category {
                let session = try await ctx.decode(JSONValue.self, from: try await ctx.send(service.rpc("addMagnet", method: "session-get")), operation: OperationID(service.instance.kind, "addMagnet"))
                if let dir = session["arguments"]?["download-dir"]?.stringValue { arguments["download-dir"] = .string(dir + "/" + category) }
            }
            _ = try await ctx.send(service.rpc("addMagnet", method: "torrent-add", arguments: arguments))
            return CommandReceipt(acceptedAt: ctx.clock.now)
        }
    }
}

extension JSONValue {
    public var doubleValue: Double? { if case let .number(n) = self { n } else { nil } }
}
