import Foundation

/// Actively probes the services the queue refresh never touches (download
/// clients + OpenAI + TMDB) by calling each client's existing
/// `testConnection()`. Throttled so the probe runs at most once per
/// `minInterval`, since connection health changes rarely and probing every 5s
/// queue tick would hammer the clients.
///
/// Isolated as an `actor` that only ever sees a `Sendable` `ProbeInputs`
/// snapshot — it never touches the `@MainActor ConfigStore`. Results come back
/// as `Sendable` `ProbeOutcome`s for the caller to apply on the main actor.
actor ConnectionHealthMonitor {
    /// A Sendable snapshot of just what the probes need, built on the main actor
    /// and handed across the isolation boundary.
    struct ProbeInputs: Sendable {
        /// Configured download clients only (keyed by kind).
        var clients: [ServiceKind: ServiceConfig]
        var openai: OpenAIConfig?
        var tmdbKey: String?
        /// Non-nil only when a media server is configured.
        var mediaServer: MediaServerConfig?

        init(clients: [ServiceKind: ServiceConfig] = [:], openai: OpenAIConfig? = nil,
             tmdbKey: String? = nil, mediaServer: MediaServerConfig? = nil) {
            self.clients = clients
            self.openai = openai
            self.tmdbKey = tmdbKey
            self.mediaServer = mediaServer
        }
    }

    struct ProbeOutcome: Sendable {
        let service: MonitoredService
        let success: Bool
        let detail: String?
        let message: String?
    }

    private var lastProbe: Date?
    /// Minimum gap between full probe sweeps.
    static let minInterval: TimeInterval = 60

    /// Probe every configured target, but skip the sweep entirely if the last
    /// one ran less than `minInterval` ago (unless `force`). Returns one outcome
    /// per probed target; an empty array means "throttled, nothing to apply".
    func probeIfDue(_ inputs: ProbeInputs, force: Bool) async -> [ProbeOutcome] {
        let now = Date()
        if !force, let last = lastProbe, now.timeIntervalSince(last) < Self.minInterval {
            return []
        }
        lastProbe = now
        return await Self.probeAll(inputs)
    }

    /// Probe one service immediately (e.g. right after a key was saved).
    func probe(_ service: MonitoredService, _ inputs: ProbeInputs) async -> ProbeOutcome {
        await Self.probeOne(service, inputs)
    }

    // MARK: - Probing (nonisolated: runs concurrently, touches no actor state)

    private static func probeAll(_ inputs: ProbeInputs) async -> [ProbeOutcome] {
        var targets: [MonitoredService] = inputs.clients.keys.map { .arr($0) }
        if inputs.openai != nil { targets.append(.openai) }
        if inputs.tmdbKey != nil { targets.append(.tmdb) }
        if inputs.mediaServer != nil { targets.append(.mediaServer) }

        return await withTaskGroup(of: ProbeOutcome.self) { group in
            for target in targets {
                group.addTask { await probeOne(target, inputs) }
            }
            var results: [ProbeOutcome] = []
            for await outcome in group { results.append(outcome) }
            return results
        }
    }

    private static func probeOne(_ service: MonitoredService, _ inputs: ProbeInputs) async -> ProbeOutcome {
        do {
            switch service {
            case .arr(let kind):
                guard let cfg = inputs.clients[kind] else {
                    return ProbeOutcome(service: service, success: false, detail: nil, message: nil)
                }
                let detail = try await ConnectionTester.test(kind: kind, config: cfg)
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
            case .mediaServer:
                guard let cfg = inputs.mediaServer,
                      let client = MediaServerClientFactory.make(config: cfg) else {
                    return ProbeOutcome(service: service, success: false, detail: nil, message: nil)
                }
                // The handshake's version line doubles as the row's detail
                // ("Plex 1.40.2"), which is what names the server in Status.
                let handshake = try await client.testConnection()
                return ProbeOutcome(service: service, success: true,
                                    detail: handshake.versionLine, message: nil)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return ProbeOutcome(service: service, success: false, detail: nil, message: message)
        }
    }
}
