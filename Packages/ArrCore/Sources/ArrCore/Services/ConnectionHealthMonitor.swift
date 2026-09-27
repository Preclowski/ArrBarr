import Foundation

/// Probes services the queue refresh never touches, at most once per `minInterval`.
/// Sees only a `Sendable` `ProbeInputs` snapshot, never the main-actor ConfigStore.
actor ConnectionHealthMonitor {
    struct ProbeInputs: Sendable {
        var clients: [ServiceKind: ServiceConfig]
        var openai: OpenAIConfig?
        var tmdbKey: String?
        var mediaServer: MediaServerConfig?
        /// A flag, not a config: `ProwlarrClient` uses the gateway's saved instance.
        var prowlarr: Bool

        init(clients: [ServiceKind: ServiceConfig] = [:], openai: OpenAIConfig? = nil,
             tmdbKey: String? = nil, mediaServer: MediaServerConfig? = nil,
             prowlarr: Bool = false) {
            self.clients = clients
            self.openai = openai
            self.tmdbKey = tmdbKey
            self.mediaServer = mediaServer
            self.prowlarr = prowlarr
        }
    }

    struct ProbeOutcome: Sendable {
        let service: MonitoredService
        let success: Bool
        let detail: String?
        let message: String?
    }

    private var lastProbe: Date?
    nonisolated static let minInterval: TimeInterval = 60

    /// An empty result means "throttled, nothing to apply".
    func probeIfDue(_ inputs: ProbeInputs, force: Bool) async -> [ProbeOutcome] {
        let now = Date()
        if !force, let last = lastProbe, now.timeIntervalSince(last) < Self.minInterval {
            return []
        }
        lastProbe = now
        return await Self.probeAll(inputs)
    }

    func probe(_ service: MonitoredService, _ inputs: ProbeInputs) async -> ProbeOutcome {
        await Self.probeOne(service, inputs)
    }

    // MARK: - Probing (nonisolated: runs concurrently, touches no actor state)

    nonisolated private static func probeAll(_ inputs: ProbeInputs) async -> [ProbeOutcome] {
        var targets: [MonitoredService] = inputs.clients.keys.map { .arr($0) }
        if inputs.openai != nil { targets.append(.openai) }
        if inputs.tmdbKey != nil { targets.append(.tmdb) }
        if inputs.mediaServer != nil { targets.append(.mediaServer) }
        if inputs.prowlarr { targets.append(.prowlarr) }

        return await withTaskGroup(of: ProbeOutcome.self) { group in
            for target in targets {
                group.addTask { await probeOne(target, inputs) }
            }
            var results: [ProbeOutcome] = []
            for await outcome in group { results.append(outcome) }
            return results
        }
    }

    nonisolated private static func probeOne(_ service: MonitoredService, _ inputs: ProbeInputs) async -> ProbeOutcome {
        do {
            switch service {
            case .arr(let kind):
                guard let cfg = inputs.clients[kind] else {
                    return ProbeOutcome(service: service, success: false, detail: nil, message: nil)
                }
                let detail = try await ServiceHandles.testConnection(kind, config: cfg)
                return ProbeOutcome(service: service, success: true, detail: detail, message: nil)
            case .openai:
                guard let cfg = inputs.openai else {
                    return ProbeOutcome(service: service, success: false, detail: nil, message: nil)
                }
                try await OpenAIProvider(config: cfg).testConnection()
                return ProbeOutcome(service: service, success: true, detail: nil, message: nil)
            case .tmdb:
                guard let key = inputs.tmdbKey else {
                    return ProbeOutcome(service: service, success: false, detail: nil, message: nil)
                }
                try await TMDBClient(apiKey: key).testConnection()
                return ProbeOutcome(service: service, success: true, detail: nil, message: nil)
            case .prowlarr:
                guard inputs.prowlarr else {
                    return ProbeOutcome(service: service, success: false, detail: nil, message: nil)
                }
                let detail = try await ProwlarrClient().testConnection()
                return ProbeOutcome(service: service, success: true, detail: detail, message: nil)
            case .mediaServer:
                guard let cfg = inputs.mediaServer,
                      let client = MediaServerClientFactory.make(config: cfg) else {
                    return ProbeOutcome(service: service, success: false, detail: nil, message: nil)
                }
                // The version line ("Plex 1.40.2") names the server in Status.
                let handshake = try await client.testConnection()
                return ProbeOutcome(service: service, success: true,
                                    detail: handshake.versionLine, message: nil)
            }
        } catch {
            let message = error.userFacingMessage
            return ProbeOutcome(service: service, success: false, detail: nil, message: message)
        }
    }
}
