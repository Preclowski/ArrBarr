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
        /// The one media server, when connected — drives the `media_server_*`
        /// tools. Defaulted so existing call sites (and tests) compile unchanged.
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

    /// What the caller last asked for. `restart`/`stop` are fire-and-forget from
    /// a debounced Settings sink, so several can be in flight at once; they
    /// collapse into this single slot so the newest request wins.
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

    /// (Re)start the server with a fresh config. Stops any running instance first.
    public func restart(with config: Config) async { await apply(.running(config)) }

    /// Stop the server, superseding any queued restart.
    public func stop() async { await apply(.stopped) }

    /// Serialises every state change. Actor isolation alone is not enough: each
    /// `performRestart` suspends at the awaited bind, so without this two
    /// restarts would interleave — both see `host == nil`, both bind the same
    /// port, one gets EADDRINUSE — and whichever finished last would decide the
    /// published status, potentially showing `.failed` while the winner serves.
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

        let parts = config.hostPort.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]) else {
            emit(.failed(message: "Invalid bind address: \(config.hostPort)")); return
        }
        let bindHost = String(parts[0])

        // Never expose the tool surface (queue deletes, library writes) beyond
        // loopback without a bearer token. The Origin check below only stops
        // browser-based DNS rebinding — a direct client just omits the header.
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
            downloadClients: i.downloadClients, mediaServer: i.mediaServer)
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
        // Take ownership before the awaited bind, so the host is never a live
        // object that nothing references while `start()` is suspended.
        self.host = host
        do {
            try await host.start()
            let url = "http://\(bindHost):\(port)/mcp"
            emit(.running(url: url))
            logger.notice("MCP server started", metadata: ["url": .string(url)])
        } catch {
            // `start()` already reaped its own event-loop group; this is the
            // belt-and-braces teardown (a no-op after a failed bind) so no
            // half-built host is ever dropped on the floor.
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
