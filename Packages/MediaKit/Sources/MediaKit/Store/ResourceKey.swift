public struct ResourceKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public let instance: InstanceID
    public let operation: OperationID
    public let discriminator: String

    public init(instance: InstanceID, operation: OperationID, discriminator: String = "") {
        self.instance = instance; self.operation = operation; self.discriminator = discriminator
    }
    public init(_ plan: RequestPlan) {
        self.init(instance: plan.instance, operation: plan.operation, discriminator: plan.discriminator)
    }

    public var storageKey: String { "\(instance)|\(operation.rawValue)|\(discriminator)" }
    public var description: String { storageKey }
}

public enum CacheOrigin: String, Sendable, Codable { case memory, disk, network, coalesced }
