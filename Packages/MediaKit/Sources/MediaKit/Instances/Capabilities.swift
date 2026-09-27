import Foundation
import os

public struct Capability: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let servarrSeasonEndpointV5 = Capability(rawValue: "servarrSeasonEndpointV5")
    public static let whisparrV3 = Capability(rawValue: "whisparrV3")
    public static let qbittorrentStopStartVerbs = Capability(rawValue: "qbittorrentStopStartVerbs")
}

public struct CapabilitySet: Sendable, Equatable, Codable {
    public enum Origin: String, Sendable, Codable { case probe, persisted, conservativeDefault }
    public let instance: InstanceID
    public let fingerprint: Fingerprint?
    public let version: String?
    public let capabilities: Set<Capability>
    public let probedAt: Date?
    public let origin: Origin

    public init(instance: InstanceID, fingerprint: Fingerprint?, version: String?, capabilities: Set<Capability>, probedAt: Date?, origin: Origin) {
        self.instance = instance; self.fingerprint = fingerprint; self.version = version
        self.capabilities = capabilities; self.probedAt = probedAt; self.origin = origin
    }

    public func has(_ c: Capability) -> Bool { capabilities.contains(c) }

    public static func conservative(_ instance: InstanceID) -> CapabilitySet {
        CapabilitySet(instance: instance, fingerprint: nil, version: nil,
                      capabilities: CapabilityProbe.conservativeDefault(for: instance.kind), probedAt: nil, origin: .conservativeDefault)
    }
}

/// Synchronous, lock-guarded: a service picking an endpoint must not await.
public final class CapabilityIndex: Sendable {
    private let table = OSAllocatedUnfairLock<[InstanceID: CapabilitySet]>(initialState: [:])
    public init() {}

    public func current(_ instance: InstanceID) -> CapabilitySet {
        table.withLock { $0[instance] } ?? .conservative(instance)
    }
    public func has(_ c: Capability, _ instance: InstanceID) -> Bool { current(instance).has(c) }

    func set(_ value: CapabilitySet) { table.withLock { $0[value.instance] = value } }
    func remove(_ instance: InstanceID) { table.withLock { _ = $0.removeValue(forKey: instance) } }
}
