import ArrCore
import MCP
import Logging
import Foundation

/// Owns the lifecycle of the MCP HTTP server: starts/stops the NIO host from a
/// config snapshot and publishes status back to the app via a callback.
public actor MCPServerController {
    public struct Config: Sendable {
        public let hostPort: String
        public let requireAuth: Bool
        public let token: String
        public let disabledTools: Set<String>
        public let backendInputs: BackendInputs
        public init(hostPort: String, requireAuth: Bool, token: String,
                    disabledTools: Set<String>, backendInputs: BackendInputs) {
            self.hostPort = hostPort; self.requireAuth = requireAuth; self.token = token
            self.disabledTools = disabledTools; self.backendInputs = backendInputs
        }
    }

    /// Snapshot of the arr/tmdb config needed to build `LocalToolBackend` + catalog.
    public struct BackendInputs: Sendable {
        public let sonarr, radarr, lidarr, whisparr: ServiceConfig
        public let aiKnowsAboutWhisparr: Bool
        public let tmdbApiKey: String
        public let downloadClients: DownloadClientConfigs
        public init(sonarr: ServiceConfig, radarr: ServiceConfig, lidarr: ServiceConfig,
                    whisparr: ServiceConfig, aiKnowsAboutWhisparr: Bool, tmdbApiKey: String,
                    downloadClients: DownloadClientConfigs) {
            self.sonarr = sonarr; self.radarr = radarr; self.lidarr = lidarr; self.whisparr = whisparr
            self.aiKnowsAboutWhisparr = aiKnowsAboutWhisparr; self.tmdbApiKey = tmdbApiKey
            self.downloadClients = downloadClients
        }
    }

    public enum Status: Sendable, Equatable {
        case stopped, running(url: String), failed(message: String)
    }

    private let logger = Logger(label: "arrbarr.mcp")
    private var host: NIOHTTPHost?
    private var onStatus: (@Sendable (Status) -> Void)?

    public init() {}

    public func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) { onStatus = handler }

    /// (Re)start the server with a fresh config. Stops any running instance first.
    public func restart(with config: Config) async {
        await stop()

        let parts = config.hostPort.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]) else {
            emit(.failed(message: "Invalid bind address: \(config.hostPort)")); return
        }
        let bindHost = String(parts[0])
        let i = config.backendInputs

        let backend = LocalToolBackend(
            sonarr: i.sonarr, radarr: i.radarr, lidarr: i.lidarr, whisparr: i.whisparr,
            aiKnowsAboutWhisparr: i.aiKnowsAboutWhisparr, tmdbApiKey: i.tmdbApiKey,
            downloadClients: i.downloadClients)
        let tmdbEnabled = !i.tmdbApiKey.isEmpty
        let catalog = ChatToolCatalog.tools(
            includeSonarr: i.sonarr.isConfigured, includeRadarr: i.radarr.isConfigured,
            includeLidarr: i.lidarr.isConfigured,
            includeWhisparr: i.whisparr.isConfigured && i.aiKnowsAboutWhisparr,
            includeTMDBMovies: tmdbEnabled && i.radarr.isConfigured,
            includeTMDBSeries: tmdbEnabled && i.sonarr.isConfigured)
        let router = MCPCallRouter(backend: backend, catalog: catalog,
                                   disabled: config.disabledTools, logger: logger)
        let exposed = catalog.filter { !config.disabledTools.contains($0.name) }.count
        if exposed == 0 {
            logger.notice("0 tools to expose — no Sonarr/Radarr/etc. is configured in this profile")
        } else {
            logger.notice("exposing \(exposed) tools", metadata: ["count": .stringConvertible(exposed)])
        }

        var validators: [any HTTPRequestValidator] = [
            OriginValidator.localhost(port: port),
            AcceptHeaderValidator(mode: .sseRequired),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
            SessionValidator(),
        ]
        if config.requireAuth {
            validators.insert(StaticBearerValidator(token: config.token), at: 1)
        }
        let pipeline = StandardValidationPipeline(validators: validators)

        let host = NIOHTTPHost(host: bindHost, port: port, validationPipeline: pipeline,
                               logger: logger) { _, _ in await router.makeServer() }
        do {
            try await host.start()
            self.host = host
            let url = "http://\(bindHost):\(port)/mcp"
            emit(.running(url: url))
            logger.notice("MCP server started", metadata: ["url": .string(url)])
        } catch {
            emit(.failed(message: "\(error)"))
            logger.error("MCP server failed to start", metadata: ["error": .string("\(error)")])
        }
    }

    public func stop() async {
        await host?.stop()
        host = nil
        emit(.stopped)
    }

    private func emit(_ s: Status) { onStatus?(s) }
}
