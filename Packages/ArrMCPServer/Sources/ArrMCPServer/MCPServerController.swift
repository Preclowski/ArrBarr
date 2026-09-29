import ArrCore
import MCP
import Logging
import Foundation

public actor MCPServerController {
    public struct Config: Sendable, Equatable {
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

    public struct BackendInputs: Sendable, Equatable {
        public let sonarr, radarr, lidarr, whisparr: ServiceConfig
        public let aiKnowsAboutWhisparr: Bool
        public let tmdbApiKey: String
        public let downloadClients: DownloadClientConfigs
        /// Drives the `media_server_*` tools.
        public let mediaServer: MediaServerConfig
        public init(sonarr: ServiceConfig, radarr: ServiceConfig, lidarr: ServiceConfig,
                    whisparr: ServiceConfig, aiKnowsAboutWhisparr: Bool, tmdbApiKey: String,
                    downloadClients: DownloadClientConfigs,
                    mediaServer: MediaServerConfig = .empty) {
            self.sonarr = sonarr; self.radarr = radarr; self.lidarr = lidarr; self.whisparr = whisparr
            self.aiKnowsAboutWhisparr = aiKnowsAboutWhisparr; self.tmdbApiKey = tmdbApiKey
            self.downloadClients = downloadClients
            self.mediaServer = mediaServer
        }
    }

    public enum Status: Sendable, Equatable {
        case stopped, running(url: String), failed(message: String)
    }

    /// `restart`/`stop` come fire-and-forget from a debounced Settings sink; they collapse here so the newest wins.
    private enum DesiredState: Sendable {
        case stopped
        case running(Config)
    }

    private let logger = Logger(label: "arrbarr.mcp")
    private var host: NIOHTTPHost?
    private var onStatus: (@Sendable (Status) -> Void)?
    private var pendingState: DesiredState?
    private var isApplying = false

    public init() {}

    public func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) { onStatus = handler }

    public func restart(with config: Config) async { await apply(.running(config)) }

    public func stop() async { await apply(.stopped) }

    /// Actor isolation is not enough: `performRestart` suspends at the bind, so two restarts would both
    /// bind the port (EADDRINUSE) and the loser could publish `.failed` while the winner serves.
    private func apply(_ desired: DesiredState) async {
        pendingState = desired
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        while let next = pendingState {
            pendingState = nil
            switch next {
            case .stopped: await performStop()
            case .running(let config): await performRestart(with: config)
            }
        }
    }

    private func performRestart(with config: Config) async {
        await performStop()

        // The last colon: an IPv6 host ("[::1]:8080") has colons of its own.
        guard let colon = config.hostPort.lastIndex(of: ":"),
              let port = Int(config.hostPort[config.hostPort.index(after: colon)...]) else {
            emit(.failed(message: "Invalid bind address: \(config.hostPort)")); return
        }
        let bindHost = config.hostPort[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        // Never expose the tool surface beyond loopback without a bearer token. The Origin check below only
        // stops browser-based DNS rebinding — a direct client just omits the header.
        let loopback = ["127.0.0.1", "localhost", "::1"].contains(bindHost.lowercased())
        if !loopback && !config.requireAuth {
            emit(.failed(message: "Refusing to bind \(config.hostPort) without authentication — enable the bearer token or bind to 127.0.0.1."))
            logger.error("refused non-loopback bind without auth", metadata: ["bind": .string(config.hostPort)])
            return
        }

        let i = config.backendInputs

        let backend = LocalToolBackend(
            sonarr: i.sonarr, radarr: i.radarr, lidarr: i.lidarr, whisparr: i.whisparr,
            aiKnowsAboutWhisparr: i.aiKnowsAboutWhisparr, tmdbApiKey: i.tmdbApiKey,
            downloadClients: i.downloadClients, mediaServer: i.mediaServer,
            // Remote MCP clients have no popover: UI-driving tools must
            // answer in text, not open windows on the Mac's menu bar.
            headlessSurface: true)
        let tmdbEnabled = !i.tmdbApiKey.isEmpty
        let catalog = ChatToolCatalog.tools(
            includeSonarr: i.sonarr.isConfigured, includeRadarr: i.radarr.isConfigured,
            includeLidarr: i.lidarr.isConfigured,
            includeWhisparr: i.whisparr.isConfigured && i.aiKnowsAboutWhisparr,
            includeTMDBMovies: tmdbEnabled && i.radarr.isConfigured,
            includeTMDBSeries: tmdbEnabled && i.sonarr.isConfigured,
            includeMediaServer: i.mediaServer.isConfigured)
        let router = MCPCallRouter(backend: backend, catalog: catalog,
                                   disabled: config.disabledTools, logger: logger)
        let exposed = catalog.filter { !config.disabledTools.contains($0.name) }.count
        if exposed == 0 {
            logger.notice("0 tools to expose — no Sonarr/Radarr/etc. is configured in this profile")
        } else {
            logger.notice("exposing \(exposed) tools", metadata: ["count": .stringConvertible(exposed)])
        }

        var validators: [any HTTPRequestValidator] = [
            loopback ? OriginValidator.localhost(port: port) : BrowserOriginValidator(),
            AcceptHeaderValidator(mode: .sseRequired),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
            SessionValidator(),
        ]
        if config.requireAuth {
            validators.insert(StaticBearerValidator(token: config.token, logger: logger), at: 1)
        }
        let pipeline = StandardValidationPipeline(validators: validators)

        let host = NIOHTTPHost(host: bindHost, port: port, validationPipeline: pipeline,
                               logger: logger) { _, _ in await router.makeServer() }
        // Take ownership before the awaited bind, so the host is never a live
        // object that nothing references while `start()` is suspended.
        self.host = host
        do {
            try await host.start()
            let url = "http://\(config.hostPort)/mcp"
            emit(.running(url: url))
            logger.notice("MCP server started", metadata: ["url": .string(url)])
        } catch {
            // Belt-and-braces: `start()` already reaped its event-loop group; a no-op after a failed bind.
            await host.stop()
            self.host = nil
            emit(.failed(message: "\(error)"))
            logger.error("MCP server failed to start", metadata: ["error": .string("\(error)")])
        }
    }

    private func performStop() async {
        await host?.stop()
        host = nil
        emit(.stopped)
    }

    private func emit(_ s: Status) { onStatus?(s) }
}
