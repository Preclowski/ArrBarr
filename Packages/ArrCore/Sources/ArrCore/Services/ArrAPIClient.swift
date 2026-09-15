import Foundation
import MediaKit

/// ArrCore keeps its own `JSONValue` for the MCP surface; the wire one is MediaKit's.
typealias KitJSON = MediaKit.JSONValue

/// What the four arr clients share. Every request goes through MediaKit; a client is a value that names its arr
/// and carries the config it was built with (the saved one, a Settings draft, or a test's).
public protocol ArrAPIClient: Sendable {
    var config: ServiceConfig { get }
    var source: QueueItem.Source { get }
    var serviceName: String { get }
}

/// The gateway plus the service bound to this client's instance: the saved profile's, or the draft's own ordinal.
struct ArrContext {
    let gateway: ServiceGateway
    let service: ServarrService
    var store: ResourceStore { gateway.store }
    var instance: InstanceID { service.instance }
}

extension ArrAPIClient {
    func context() async throws -> ArrContext {
        let gateway = await ServiceGateway.resolve()
        let instance = await gateway.adopt(config, for: source.serviceKind)
        await gateway.ready()
        guard gateway.isConfigured(instance), let service = gateway.kit.servarr(instance) else { throw MediaKitError.notConfigured(instance) }
        return ArrContext(gateway: gateway, service: service)
    }

    /// Reads a MediaKit resource decoded into one of ArrCore's own record types (same plan, same tags, same freshness).
    func read<T: Codable & Sendable, V>(_ type: T.Type, policy: ReadPolicy = .cacheFirst, maxAge: Duration? = nil,
                                        priority: RequestPriority = .interactive, _ make: (ServarrService) -> Resource<V>) async throws -> T {
        let context = try await context()
        let template = make(context.service)
        let resource = Resource<T>.json(template.plan, tags: template.tags, freshness: template.freshness, ttl: template.ttl)
        return try await context.store.read(resource, policy: policy, maxAge: maxAge, priority: priority).value
    }

    @discardableResult
    func run(_ make: (ServarrService) -> Command) async throws -> CommandReceipt {
        let context = try await context()
        return try await context.store.run(make(context.service))
    }

    /// A one-request write with a JSON body; answers the new record id when the arr echoes one.
    @discardableResult
    func post(_ operation: String, path: String, body: [String: KitJSON], invalidates: (InstanceID) -> Set<InvalidationTag>, timeout: Duration = .seconds(15)) async throws -> Int? {
        let context = try await context()
        let plan = RequestPlan(instance: context.instance, operation: operation, method: "POST", pathTemplate: context.service.profile.apiBase + path,
                               body: try RequestBuilder.json(KitJSON.object(body)), auth: .header("X-Api-Key"), timeout: timeout)
        let command = Command(name: plan.operation, instance: context.instance, invalidates: invalidates(context.instance)) { ctx in
            let response = try await ctx.send(plan)
            let id = (try? await ctx.decode(KitJSON.self, from: response, operation: plan.operation))?["id"]?.intValue
            return CommandReceipt(acceptedAt: ctx.clock.now, serverMessage: RequestBuilder.serverMessage(from: response.body), trackingID: id)
        }
        return try await context.store.run(command).trackingID
    }

    // MARK: - Shared reads

    /// The record as the arr sent it, for forms that read fields MediaKit does not model.
    func getRawObject(_ path: String) async throws -> [String: Any] {
        let context = try await context()
        let plan = RequestPlan(instance: context.instance, operation: "fetchRawRecord", pathTemplate: context.service.profile.apiBase + path, auth: .header("X-Api-Key"))
        let value = try await context.store.read(Resource<KitJSON>.json(plan, tags: [], freshness: .volatile), policy: .mustRevalidate).value
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        guard let dictionary = object as? [String: Any] else { throw MediaKitError.decoding(plan.operation, detail: "expected a JSON object") }
        return dictionary
    }

    func fetchCustomFormats() async throws -> [ArrCore.ArrCustomFormatDetail] { try await read([ArrCore.ArrCustomFormatDetail].self) { $0.customFormats() } }
    func fetchQualityProfiles() async throws -> [ArrCore.ArrQualityProfile] { try await read([ArrCore.ArrQualityProfile].self) { $0.qualityProfiles() } }
    func fetchHealth() async throws -> [ArrHealthRecord] { try await read([ArrHealthRecord].self, policy: .mustRevalidate) { $0.health() } }
    func fetchDiskSpace() async throws -> [DiskSpace] { try await read([DiskSpace].self) { $0.diskSpace() } }

    func fetchReleases(query: [URLQueryItem]) async throws -> [Release] {
        let context = try await context()
        var plan = context.service.releases(entityID: 0).plan
        plan.query = query.map { RequestPlan.QueryItem($0.name, $0.value ?? "") }
        return try await context.store.read(Resource<[Release]>.json(plan, tags: [], freshness: .volatile, ttl: .seconds(60))).value
    }

    func testConnection() async throws -> String {
        let status = try await read(MediaKit.ArrSystemStatus.self, policy: .mustRevalidate) { $0.status() }
        return status.version.map { "\(serviceName) \($0)" } ?? "OK"
    }

    func isSearchRunning(entityId: Int) async -> Bool {
        let commands = (try? await read([ArrCore.ArrCommand].self, policy: .mustRevalidate) { $0.commands() }) ?? []
        return commands.contains { $0.isSearch(for: entityId) }
    }

    // MARK: - Shared writes

    func setMovieMonitored(movieId: Int, monitored: Bool) async throws {
        try await run { $0.setMonitored(entityID: movieId, monitored) }
    }

    /// Merges `fields` over the current record; a changed root folder moves the files along.
    func updateLibraryRecord(path recordPath: String, fields: [String: Any]) async throws {
        let context = try await context()
        let operation = OperationID(context.instance.kind, "updateLibraryRecord")
        guard let id = Int(recordPath.split(separator: "/").last ?? "") else { throw MediaKitError.decoding(operation, detail: "no id in \(recordPath)") }
        let edits = try JSONDecoder().decode([String: KitJSON].self, from: JSONSerialization.data(withJSONObject: fields))
        let plan = RequestPlan(instance: context.instance, operation: "updateLibraryRecord", pathTemplate: context.service.profile.apiBase + recordPath, auth: .header("X-Api-Key"))
        let current = try await context.store.read(Resource<KitJSON>.json(plan, tags: [], freshness: .volatile), policy: .mustRevalidate).value
        var movedPath: String?
        if let newRoot = fields["rootFolderPath"] as? String, let oldRoot = current["rootFolderPath"]?.stringValue,
           newRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != oldRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
           let folder = current["path"]?.stringValue?.split(separator: "/").last.map(String.init) {
            movedPath = (newRoot.hasSuffix("/") ? String(newRoot.dropLast()) : newRoot) + "/" + folder
        }
        let path = movedPath
        _ = try await context.store.run(context.service.update(entityID: id, moveFiles: path != nil) { envelope in
            for (key, value) in edits { envelope.set(key, value) }
            if let path { envelope.set("path", .string(path)) }
        })
    }

    func deleteLibraryRecord(path: String, deleteFiles: Bool, addImportExclusion: Bool) async throws {
        guard let id = Int(path.split(separator: "/").last ?? "") else { return }
        try await run { $0.delete(entityID: id, deleteFiles: deleteFiles, addImportExclusion: addImportExclusion) }
    }

    func grabRelease(guid: String, indexerId: Int) async throws { try await run { $0.grabRelease(guid: guid, indexerID: indexerId) } }

    func deleteQueueItem(id: Int, removeFromClient: Bool = true, blocklist: Bool = false) async throws {
        try await run { $0.deleteQueueItem(id: id, removeFromClient: removeFromClient, blocklist: blocklist, now: Date()) }
    }

    func grabQueueItem(id: Int) async throws { try await run { $0.grabQueueItem(id: id) } }

    func postCommand(_ body: [String: Any]) async throws {
        guard let name = body["name"] as? String else { return }
        var extra = try JSONDecoder().decode([String: KitJSON].self, from: JSONSerialization.data(withJSONObject: body))
        extra.removeValue(forKey: "name")
        let entityID = (body["movieId"] as? Int) ?? (body["seriesId"] as? Int) ?? (body["artistId"] as? Int) ?? (body["movieIds"] as? [Int])?.first
        try await run { $0.command(named: name, body: extra, entityID: entityID) }
    }
}
