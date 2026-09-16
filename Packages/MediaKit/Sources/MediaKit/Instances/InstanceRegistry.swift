import Foundation
import os

public struct InstanceDescriptor: Sendable, Equatable {
    public let id: InstanceID
    public let baseURL: URL
    public let enabled: Bool
    public let generation: String
    public let limits: HostGovernor.Limits?

    public init(id: InstanceID, baseURL: URL, enabled: Bool = true, generation: String, limits: HostGovernor.Limits? = nil) {
        self.id = id; self.baseURL = baseURL; self.enabled = enabled; self.generation = generation; self.limits = limits
    }

    public var fingerprint: Fingerprint { Fingerprint(baseURL: baseURL, generation: generation) }
}

/// The one place configuration enters MediaKit.
public actor InstanceRegistry {
    private var descriptors: [InstanceID: InstanceDescriptor] = [:]
    private let snapshot = OSAllocatedUnfairLock<[InstanceID: InstanceDescriptor]>(initialState: [:])
    private var dependents: Dependents?
    private let center: NotificationCenter
    private let telemetry: any TelemetrySink
    private let log: any LogSink

    struct Dependents {
        let store: ResourceStore
        let capabilities: CapabilityProbe
        let sessions: SessionBroker
        let identity: IdentityStore
        let subject: MessageSubject
    }

    public init(center: NotificationCenter = .default, telemetry: any TelemetrySink, log: any LogSink) {
        self.center = center; self.telemetry = telemetry; self.log = log
    }

    func attach(_ dependents: Dependents) { self.dependents = dependents }

    /// For every instance whose fingerprint moved: invalidate store, capabilities, sessions, identity; one message.
    @discardableResult
    public func apply(_ new: [InstanceDescriptor]) async -> Set<InstanceID> {
        var changed = Set<InstanceID>()
        let incoming = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
        for (id, descriptor) in incoming where descriptors[id]?.fingerprint != descriptor.fingerprint || descriptors[id]?.enabled != descriptor.enabled {
            changed.insert(id)
        }
        for id in descriptors.keys where incoming[id] == nil { changed.insert(id) }
        descriptors = incoming
        snapshot.withLock { $0 = incoming }
        guard !changed.isEmpty else { return changed }
        if let d = dependents {
            for id in changed {
                await d.store.invalidate(instance: id, reason: .configuration)
                await d.capabilities.invalidate(id)
                await d.sessions.invalidate(id)
                await d.identity.forget(instance: id)
            }
            center.post(ConfigurationChanged(instances: changed), subject: d.subject)
        }
        log.log(.notice, category: "Store", "configuration changed for \(changed.count) instance(s)")
        return changed
    }

    public nonisolated func descriptor(_ id: InstanceID) -> InstanceDescriptor? { snapshot.withLock { $0[id] } }
    public nonisolated func fingerprint(_ id: InstanceID) -> Fingerprint? { descriptor(id)?.fingerprint }
    public nonisolated func host(_ id: InstanceID) -> Host? { descriptor(id).map { Host($0.baseURL) } }
    public nonisolated func configured(_ family: InstanceKind.Family) -> [InstanceID] {
        snapshot.withLock { $0.values.filter { $0.enabled && $0.id.kind.family == family }.map(\.id).sorted { $0.description < $1.description } }
    }
    public nonisolated var all: [InstanceDescriptor] { snapshot.withLock { Array($0.values) } }
}
