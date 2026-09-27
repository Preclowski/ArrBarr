import Foundation

struct DelugeService: DownloadService {
    let instance: InstanceID
    init(instance: InstanceID) { self.instance = instance }

    private func rpc(_ op: String, method: String, params: [JSONValue] = [], priority: RequestPriority = .interactive) -> RequestPlan {
        RequestPlan(instance: instance, operation: op, method: "POST", pathTemplate: "/json", body: try! RequestBuilder.jsonRPC(method: method, params: .array(params)),
                    auth: .session, priority: priority, retry: method.hasPrefix("core.get") || method == "daemon.info" ? .idempotent : .never, rpcMethod: method)
    }

    func version() -> Resource<String> {
        Resource(plan: rpc("testConnection", method: "daemon.info"), tags: [.capabilities(instance)], freshness: .reference) { data in
            (try? JSONDecoder().decode(JSONValue.self, from: data))?["result"]?.stringValue ?? ""
        }
    }

    func tasks(ids: Set<String>) -> RequestPlan {
        let fields: JSONValue = .array(["name", "state", "progress", "download_payload_rate", "total_size", "eta", "hash", "label"].map { .string($0) })
        let filter: JSONValue = ids.isEmpty ? .object([:]) : .object(["id": .array(ids.sorted().map { .string($0) })])
        return rpc("fetchProgress", method: "core.get_torrents_status", params: [filter, fields], priority: .background)
    }

    func decodeTasks(_ response: HTTPResponse, ids: Set<String>) throws -> [DownloadTask] {
        let result = try Self.rpcResult(response, instance: instance, operation: OperationID(instance.kind, "fetchProgress"))
        guard case let .object(table) = result else { return [] }
        return table.map { hash, t in
            let state: DownloadTask.State = switch t["state"]?.stringValue ?? "" {
            case "Downloading": .downloading
            case "Paused": .paused
            case "Queued": .queued
            case "Seeding": .seeding
            case "Checking", "Allocating", "Moving": .checking
            case "Error": .error
            default: .queued
            }
            return DownloadTask(id: hash, name: t["name"]?.stringValue ?? hash, state: state, progress: (t["progress"]?.doubleValue ?? 0) / 100,
                                downloadSpeed: t["download_payload_rate"]?.intValue.map(Int64.init), sizeBytes: t["total_size"]?.intValue.map(Int64.init),
                                etaSeconds: t["eta"]?.intValue, category: t["label"]?.stringValue, instance: instance)
        }
    }

    func defaultAddPaused() -> Resource<Bool?> {
        Resource(plan: rpc("defaultAddPaused", method: "core.get_config"), tags: [.capabilities(instance)], freshness: .reference) { data in
            (try? JSONDecoder().decode(JSONValue.self, from: data))?["result"]?["add_paused"]?.boolValue
        }
    }

    func action(_ action: DownloadAction, ids: [String], deleteFiles: Bool) -> Command {
        guard action != .forceStart else { return Self.unsupportedForceStart(instance) }
        let service = self
        return command(action.rawValue, effects: effects(action, ids: ids)) { ctx in
            for id in ids {
                let p = switch action {
                case .pause: service.rpc("pause", method: "core.pause_torrent", params: [.array([.string(id)])])
                case .resume: service.rpc("resume", method: "core.resume_torrent", params: [.array([.string(id)])])
                default: service.rpc("delete", method: "core.remove_torrent", params: [.string(id), .bool(deleteFiles)])
                }
                _ = try Self.rpcResult(try await ctx.send(p), instance: service.instance, operation: p.operation)
            }
            return CommandReceipt(acceptedAt: ctx.clock.now)
        }
    }

    func add(_ payload: DownloadPayload, category: String?, paused: Bool) -> Command {
        let service = self
        return command("addMagnet") { ctx in
            let options: JSONValue = .object(["add_paused": .bool(paused)])
            let p = switch payload.content {
            case let .magnet(link): service.rpc("addMagnet", method: "core.add_torrent_magnet", params: [.string(link), options])
            case let .file(data, filename): service.rpc("addFile", method: "core.add_torrent_file", params: [.string(filename), .string(data.base64EncodedString()), options])
            }
            let result = try Self.rpcResult(try await ctx.send(p), instance: service.instance, operation: p.operation)
            if let category, let hash = result.stringValue {
                _ = try? await ctx.send(service.rpc("addMagnet", method: "label.set_torrent", params: [.string(hash), .string(category)]))
            }
            return CommandReceipt(acceptedAt: ctx.clock.now)
        }
    }
}
