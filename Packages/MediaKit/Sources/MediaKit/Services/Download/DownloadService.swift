import Foundation

public struct DownloadTask: Sendable, Hashable, Codable, LivePatchable {
    public enum State: String, Sendable, Codable { case downloading, paused, queued, seeding, checking, stalled, error, completed }
    public let id: String
    public let name: String
    public var state: State
    public let progress: Double
    public let downloadSpeed: Int64?
    public let sizeBytes: Int64?
    public let etaSeconds: Int?
    public let category: String?
    public let instance: InstanceID

    public init(id: String, name: String, state: State, progress: Double, downloadSpeed: Int64? = nil, sizeBytes: Int64? = nil,
                etaSeconds: Int? = nil, category: String? = nil, instance: InstanceID) {
        self.id = id.lowercased(); self.name = name; self.state = state; self.progress = progress; self.downloadSpeed = downloadSpeed
        self.sizeBytes = sizeBytes; self.etaSeconds = etaSeconds; self.category = category; self.instance = instance
    }

    public func applying(_ change: PendingEffect.Change) -> DownloadTask? {
        guard case let .status(raw) = change, let state = State(rawValue: raw) else { return nil }
        var copy = self
        copy.state = state
        return copy
    }
}

public struct DownloadPayload: Sendable {
    public enum Content: Sendable { case file(Data, filename: String), magnet(String) }
    public let content: Content
    public init(_ content: Content) { self.content = content }
}

public enum DownloadAction: String, Sendable { case pause, resume, delete, forceStart }

public protocol DownloadService: Sendable {
    var instance: InstanceID { get }
    func version() -> Resource<String>
    /// The live pump for `LiveStream<DownloadTask>`; volatile, never a store row. `ids` narrows where the API can.
    func tasks(ids: Set<String>) -> RequestPlan
    func decodeTasks(_ response: HTTPResponse, ids: Set<String>) throws -> [DownloadTask]
    func defaultAddPaused() -> Resource<Bool?>
    func action(_ action: DownloadAction, ids: [String], deleteFiles: Bool) -> Command
    func add(_ payload: DownloadPayload, category: String?, paused: Bool) -> Command
}

extension Capability {
    public static let downloadForceStart = Capability(rawValue: "downloadForceStart")
}

extension DownloadService {
    var downloadsTag: InvalidationTag { .collection(.downloads, instance) }

    func command(_ name: String, effects: [PendingEffect] = [], run: @escaping @Sendable (CommandContext) async throws -> CommandReceipt) -> Command {
        Command(name: OperationID(instance.kind, name), instance: instance, invalidates: [downloadsTag], effects: effects, run: run)
    }

    /// Keyed by the download id, with no instance: it names the client's task and every arr queue row tracking it.
    func effects(_ action: DownloadAction, ids: [String]) -> [PendingEffect] {
        let change: PendingEffect.Change = switch action {
        case .pause: .status(DownloadTask.State.paused.rawValue)
        case .resume, .forceStart: .status(DownloadTask.State.downloading.rawValue)
        case .delete: .removed
        }
        return ids.map { PendingEffect(elementID: $0.lowercased(), change: change) }
    }

    public func fetchTasks(ids: Set<String>, pipeline: RequestPipeline) async throws -> [DownloadTask] {
        try decodeTasks(try await pipeline.send(tasks(ids: ids)), ids: ids)
    }

    static func unsupportedForceStart(_ instance: InstanceID) -> Command {
        Command(name: OperationID(instance.kind, "forceStart"), instance: instance, invalidates: []) { _ in
            throw MediaKitError.unsupported(instance, .downloadForceStart)
        }
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, _ response: HTTPResponse, operation: OperationID, decoder: JSONDecoder = WireCodec.decoder) throws -> T {
        do { return try decoder.decode(T.self, from: response.body) } catch { throw MediaKitError.decoding(operation, detail: WireCodec.describe(error)) }
    }

    /// JSON-RPC result or `.serviceError` when the envelope carries an error on HTTP 200.
    static func rpcResult(_ response: HTTPResponse, instance: InstanceID, operation: OperationID) throws -> JSONValue {
        let envelope = try decodeJSON(JSONValue.self, response, operation: operation)
        if case let .object(err)? = envelope["error"], !err.isEmpty {
            throw MediaKitError.serviceError(instance, code: err["code"]?.intValue.map(String.init), message: err["message"]?.stringValue)
        }
        return envelope["result"] ?? .null
    }
}
