import Foundation

public struct Fetched<Value: Sendable>: Sendable {
    public let value: Value
    public let origin: CacheOrigin
    public let fetchedAt: Date
    public let isStale: Bool
    public let tags: Set<InvalidationTag>
    /// Set when a stale row was served because the fetch failed.
    public let degraded: MediaKitError?

    public func map<T: Sendable>(_ f: (Value) throws -> T) rethrows -> Fetched<T> {
        Fetched<T>(value: try f(value), origin: origin, fetchedAt: fetchedAt, isStale: isStale, tags: tags, degraded: degraded)
    }
}

public struct Resource<Value: Codable & Sendable>: Sendable {
    public let key: ResourceKey
    public let tags: Set<InvalidationTag>
    public let freshness: FreshnessClass
    public let ttl: Duration?
    public let plan: RequestPlan
    public let decode: @Sendable (Data) throws -> Value
    public let harvest: (@Sendable (Value) -> [Crosswalk])?

    public init(plan: RequestPlan, tags: Set<InvalidationTag>, freshness: FreshnessClass, ttl: Duration? = nil,
                decode: @escaping @Sendable (Data) throws -> Value, harvest: (@Sendable (Value) -> [Crosswalk])? = nil) {
        self.key = ResourceKey(plan)
        self.tags = tags.union([.instance(plan.instance)])
        self.freshness = freshness; self.ttl = ttl; self.plan = plan; self.decode = decode; self.harvest = harvest
    }

    public var effectiveTTL: Duration { ttl ?? freshness.defaultTTL }
}

extension Resource {
    /// JSON body decoded as `Value` with the shared wire decoder.
    public static func json(_ plan: RequestPlan, tags: Set<InvalidationTag>, freshness: FreshnessClass, ttl: Duration? = nil,
                            decoder: JSONDecoder = WireCodec.decoder, harvest: (@Sendable (Value) -> [Crosswalk])? = nil) -> Resource<Value> where Value: Decodable {
        Resource(plan: plan, tags: tags, freshness: freshness, ttl: ttl,
                 decode: { data in try decoder.decode(Value.self, from: data) }, harvest: harvest)
    }
}

public struct BatchResource<Key: Hashable & Sendable, Value: Codable & Sendable>: Sendable {
    public enum Strategy: Sendable {
        case chunked(max: Int, make: @Sendable ([Key]) -> Resource<[Value]>, identify: @Sendable (Value) -> Key?)
        case perKey(make: @Sendable (Key) -> Resource<[Value]>)
    }
    public let strategy: Strategy
    public init(_ strategy: Strategy) { self.strategy = strategy }
}

public struct CommandReceipt: Sendable, Equatable {
    public let acceptedAt: Date
    public let serverMessage: String?
    public let trackingID: Int?
    public init(acceptedAt: Date, serverMessage: String? = nil, trackingID: Int? = nil) {
        self.acceptedAt = acceptedAt; self.serverMessage = serverMessage; self.trackingID = trackingID
    }
}

public struct CommandContext: Sendable {
    let pipeline: RequestPipeline
    let probe: CapabilityProbe?
    public let capabilities: CapabilityIndex
    public let clock: any MediaClock

    public func send(_ plan: RequestPlan) async throws -> HTTPResponse { try await pipeline.send(plan) }

    public func decode<T: Decodable & Sendable>(_ type: T.Type, from response: HTTPResponse, operation: OperationID) async throws -> T {
        try await pipeline.decode(type, from: response, operation: operation)
    }

    public func demote(_ capability: Capability, for instance: InstanceID) async { await probe?.demote(capability, for: instance) }
    public func promote(_ capability: Capability, for instance: InstanceID) async { await probe?.promote(capability, for: instance) }
}

public struct PendingEffect: Sendable, Equatable, Codable {
    public enum Change: Sendable, Equatable, Codable { case status(String), removed, keepAlive }
    public let elementID: String
    public let change: Change
    public let expiresAt: Date
    public init(elementID: String, change: Change, expiresAt: Date) { self.elementID = elementID; self.change = change; self.expiresAt = expiresAt }
}

public struct Command: Sendable {
    public enum Tracking: Sendable { case arrCommand(timeout: Duration) }

    public let name: OperationID
    public let instance: InstanceID
    public let invalidates: Set<InvalidationTag>
    public let optimistic: PendingEffect?
    public let tracking: Tracking?
    /// Multi-request writes are ordinary code here: GET→PUT, GET→PUT→GET→PUT, GET /search→POST.
    public let run: @Sendable (CommandContext) async throws -> CommandReceipt

    public init(name: OperationID, instance: InstanceID, invalidates: Set<InvalidationTag>, optimistic: PendingEffect? = nil,
                tracking: Tracking? = nil, run: @escaping @Sendable (CommandContext) async throws -> CommandReceipt) {
        self.name = name; self.instance = instance; self.invalidates = invalidates; self.optimistic = optimistic; self.tracking = tracking; self.run = run
    }
}

public enum ReadPolicy: Sendable, Equatable {
    case cacheFirst
    case staleWhileRevalidate
    case cacheOnly
    case mustRevalidate
}
