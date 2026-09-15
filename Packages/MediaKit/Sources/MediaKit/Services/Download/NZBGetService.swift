import Foundation

public struct NZBGetService: DownloadService {
    public let instance: InstanceID
    public init(instance: InstanceID) { self.instance = instance }

    private func rpc(_ op: String, method: String, params: [JSONValue] = [], priority: RequestPriority = .interactive) -> RequestPlan {
        RequestPlan(instance: instance, operation: op, method: "POST", pathTemplate: "/jsonrpc", body: try! RequestBuilder.jsonRPC(method: method, params: .array(params)),
                    auth: .basic, priority: priority, retry: ["version", "listgroups", "history", "status"].contains(method) ? .idempotent : .never, rpcMethod: method)
    }

    public func version() -> Resource<String> {
        Resource(plan: rpc("testConnection", method: "version"), tags: [.capabilities(instance)], freshness: .reference) { data in
            (try? JSONDecoder().decode(JSONValue.self, from: data))?["result"]?.stringValue ?? ""
        }
    }

    public func tasks(ids: Set<String>) -> RequestPlan { rpc("fetchProgress", method: "listgroups", params: [.number(0)], priority: .background) }

    public func decodeTasks(_ response: HTTPResponse, ids: Set<String>) throws -> [DownloadTask] {
        let result = try Self.rpcResult(response, instance: instance, operation: OperationID(instance.kind, "fetchProgress"))
        return (result.arrayValue ?? []).compactMap { g in
            guard let id = g["NZBID"]?.intValue else { return nil }
            let total = Double(g["FileSizeMB"]?.intValue ?? 0), remaining = Double(g["RemainingSizeMB"]?.intValue ?? 0)
            let state: DownloadTask.State = switch g["Status"]?.stringValue ?? "" {
            case "DOWNLOADING": .downloading
            case "PAUSED": .paused
            case "QUEUED": .queued
            case "FETCHING", "PP_QUEUED", "LOADING_PARS", "VERIFYING_SOURCES", "REPAIRING", "VERIFYING_REPAIRED", "RENAMING", "UNPACKING", "MOVING", "POST_UNPACK_RENAMING", "EXECUTING_SCRIPT", "PP_FINISHED": .checking
            default: .queued
            }
            return DownloadTask(id: String(id), name: g["NZBName"]?.stringValue ?? String(id), state: state, progress: total > 0 ? (total - remaining) / total : 0,
                                sizeBytes: Int64(total * 1_048_576), category: g["Category"]?.stringValue, instance: instance)
        }
    }

    public func defaultAddPaused() -> Resource<Bool?> {
        Resource(plan: rpc("defaultAddPaused", method: "version"), tags: [.capabilities(instance)], freshness: .reference) { _ in nil }
    }

    public func action(_ action: DownloadAction, ids: [String], deleteFiles: Bool) -> Command {
        guard action != .forceStart else { return Self.unsupportedForceStart(instance) }
        let verb = switch action { case .pause: "GroupPause"; case .resume: "GroupResume"; default: deleteFiles ? "GroupDelete" : "GroupFinalDelete" }
        let p = rpc(action.rawValue, method: "editqueue", params: [.string(verb), .string(""), .array(ids.compactMap { Int($0) }.map { .number(Double($0)) })])
        return command(action.rawValue) { ctx in _ = try await ctx.send(p); return CommandReceipt(acceptedAt: ctx.clock.now) }
    }

    public func add(_ payload: DownloadPayload, category: String?, paused: Bool) -> Command {
        guard case let .file(data, filename) = payload.content else {
            return Command(name: OperationID(instance.kind, "addFile"), instance: instance, invalidates: []) { _ in throw MediaKitError.unsupported(self.instance, Capability(rawValue: "magnet")) }
        }
        let p = rpc("addFile", method: "append", params: [.string(filename), .string(data.base64EncodedString()), .string(category ?? ""), .number(0), .bool(false), .bool(paused), .string(""), .number(0), .string("SCORE")])
        return command("addFile") { ctx in _ = try await ctx.send(p); return CommandReceipt(acceptedAt: ctx.clock.now) }
    }
}
