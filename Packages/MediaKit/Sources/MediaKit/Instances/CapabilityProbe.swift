import Foundation

public actor CapabilityProbe {
    private let store: ResourceStore
    private let index: CapabilityIndex
    private let database: SQLiteDatabase?
    private let clock: any MediaClock
    private let log: any LogSink
    private var ensured: [InstanceID: Fingerprint] = [:]
    private var inFlight: [InstanceID: Task<CapabilitySet, Never>] = [:]

    public init(store: ResourceStore, index: CapabilityIndex, database: SQLiteDatabase?, clock: any MediaClock, log: any LogSink) {
        self.store = store; self.index = index; self.database = database; self.clock = clock; self.log = log
    }

    /// capabilities table → index, at start(), so a cold offline launch picks the right endpoints.
    public func restore() async {
        guard let database else { return }
        for kind in InstanceKind.allCases {
            let id = InstanceID(kind)
            guard let row = try? await database.capabilities(id) else { continue }
            index.set(CapabilitySet(instance: id, fingerprint: row.fingerprint, version: row.version, capabilities: row.capabilities, probedAt: row.probedAt, origin: .persisted))
        }
    }

    /// Once per fingerprint; never throws: probe → persisted row for this fingerprint → conservative default.
    @discardableResult
    public func ensure(_ instance: InstanceID) async -> CapabilitySet {
        guard let fingerprint = store.pipeline.registry.fingerprint(instance) else { return index.current(instance) }
        if ensured[instance] == fingerprint { return index.current(instance) }
        if let task = inFlight[instance] { return await task.value }
        let task = Task { await self.probe(instance, fingerprint: fingerprint) }
        inFlight[instance] = task
        let result = await task.value
        inFlight[instance] = nil
        return result
    }

    private func probe(_ instance: InstanceID, fingerprint: Fingerprint) async -> CapabilitySet {
        let persisted = try? await database?.capabilities(instance)
        if let persisted, persisted.fingerprint == fingerprint {
            let set = CapabilitySet(instance: instance, fingerprint: fingerprint, version: persisted.version, capabilities: persisted.capabilities, probedAt: persisted.probedAt, origin: .persisted)
            index.set(set)
        }
        guard let plan = Self.probePlan(for: instance) else {
            ensured[instance] = fingerprint
            return index.current(instance)
        }
        do {
            let resource = Resource<JSONValue>.json(plan, tags: [.capabilities(instance), .collection(.status, instance)], freshness: .reference)
            let fetched = try await store.read(resource, policy: .cacheFirst, priority: .background)
            let body = try WireCodec.encoder.encode(fetched.value)
            let derived = Self.derive(kind: instance.kind, statusBody: body)
            let set = CapabilitySet(instance: instance, fingerprint: fingerprint, version: derived.version, capabilities: derived.capabilities, probedAt: clock.now, origin: .probe)
            index.set(set)
            try? await database?.putCapabilities(StoredCapabilities(instance: instance, fingerprint: fingerprint, version: derived.version, capabilities: derived.capabilities, probedAt: clock.now, origin: .probe))
            ensured[instance] = fingerprint
            log.log(.debug, category: "Capabilities", "probed \(instance) version \(derived.version ?? "?") caps \(derived.capabilities.count)")
            return set
        } catch {
            return index.current(instance)
        }
    }

    public func invalidate(_ instance: InstanceID) async {
        ensured.removeValue(forKey: instance)
        index.remove(instance)
    }

    public func demote(_ c: Capability, for instance: InstanceID) async { await adjust(instance) { $0.remove(c) } }
    public func promote(_ c: Capability, for instance: InstanceID) async { await adjust(instance) { $0.insert(c) } }

    private func adjust(_ instance: InstanceID, _ edit: (inout Set<Capability>) -> Void) async {
        let current = index.current(instance)
        var caps = current.capabilities
        edit(&caps)
        let set = CapabilitySet(instance: instance, fingerprint: current.fingerprint, version: current.version, capabilities: caps, probedAt: clock.now, origin: .probe)
        index.set(set)
        log.log(.notice, category: "Capabilities", "capabilities adjusted \(instance): \(caps.map(\.rawValue).sorted())")
        if let fingerprint = current.fingerprint {
            try? await database?.putCapabilities(StoredCapabilities(instance: instance, fingerprint: fingerprint, version: current.version, capabilities: caps, probedAt: clock.now, origin: .probe))
        }
    }

    static func probePlan(for instance: InstanceID) -> RequestPlan? {
        switch instance.kind {
        case .radarr, .sonarr, .whisparr:
            return RequestPlan(instance: instance, operation: "fetchStatus", pathTemplate: "/api/v3/system/status", auth: .header("X-Api-Key"), priority: .background)
        case .lidarr:
            return RequestPlan(instance: instance, operation: "fetchStatus", pathTemplate: "/api/v1/system/status", auth: .header("X-Api-Key"), priority: .background)
        case .qbittorrent:
            return RequestPlan(instance: instance, operation: "fetchVersion", pathTemplate: "/api/v2/app/version", auth: .session, priority: .background)
        case .plex:
            return RequestPlan(instance: instance, operation: "fetchIdentity", pathTemplate: "/identity", headers: ["Accept": "application/json"], auth: .header("X-Plex-Token"), priority: .background)
        case .jellyfin:
            return RequestPlan(instance: instance, operation: "fetchIdentity", pathTemplate: "/System/Info", auth: .jellyfinMediaBrowser, priority: .background)
        case .emby:
            return RequestPlan(instance: instance, operation: "fetchIdentity", pathTemplate: "/System/Info", auth: .header("X-Emby-Token"), priority: .background)
        case .tmdb, .transmission, .deluge, .rtorrent, .sabnzbd, .nzbget:
            return nil
        }
    }

    public nonisolated static func derive(kind: InstanceKind, statusBody: Data) -> (version: String?, capabilities: Set<Capability>) {
        let json = try? JSONDecoder().decode(JSONValue.self, from: statusBody)
        let version = json?["version"]?.stringValue ?? json?["Version"]?.stringValue ?? json?.stringValue
        let major = version.flatMap { Int($0.split(separator: ".").first ?? "") }
        var caps = Set<Capability>()
        switch kind {
        case .sonarr: if let major, major >= 5 { caps.insert(.servarrSeasonEndpointV5) }
        case .whisparr:
            if major == 3 { caps.insert(.whisparrV3) } else if major == 2 { caps.insert(.whisparrV2) }
        case .qbittorrent:
            let numeric = version?.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            if let m = numeric.flatMap({ Int($0.split(separator: ".").first ?? "") }), m >= 5 { caps.insert(.qbittorrentStopStartVerbs) }
        default: break
        }
        return (version, caps)
    }

    public nonisolated static func conservativeDefault(for kind: InstanceKind) -> Set<Capability> {
        kind == .whisparr ? [.whisparrV3] : []
    }
}
