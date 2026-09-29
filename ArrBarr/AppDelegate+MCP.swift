import AppKit
import ArrCore
import ArrMCPServer

extension AppDelegate {
    // MARK: - MCP server

    func wireMCPServer() {
        Task {
            await mcpController.setStatusHandler { status in
                Task { @MainActor in MCPServerStatusModel.shared.status = MCPServerStatus(status) }
            }
        }
        // Every setting the tools read (arrs, download clients, TMDB, media server) restarts the server;
        // any other change leaves the config equal and is dropped.
        applyMCPConfig(mcpConfig())
        observers.append(observeChanges(of: { [weak self] in self?.mcpConfig() }, debounce: .milliseconds(400)) { [weak self] in
            self?.applyMCPConfig($0)
        })
    }

    private func applyMCPConfig(_ config: MCPServerController.Config?) {
        let cs = configStore
        // Mint a token rather than start a server whose auth can never pass (the validator fails closed on empty);
        // the new token comes back through the observation.
        if let config, config.requireAuth, config.token.isEmpty {
            cs.mcpAuthToken = MCPTokenStore.generate()
            return
        }
        let controller = mcpController
        Task { if let config { await controller.restart(with: config) } else { await controller.stop() } }
    }

    /// nil = the server should be stopped.
    private func mcpConfig() -> MCPServerController.Config? {
        let cs = configStore
        guard cs.mcpEnabled else { return nil }
        let inputs = MCPServerController.BackendInputs(
            sonarr: cs.sonarr, radarr: cs.radarr, lidarr: cs.lidarr, whisparr: cs.whisparr,
            aiKnowsAboutWhisparr: cs.aiKnowsAboutWhisparr, tmdbApiKey: cs.tmdbApiKey,
            downloadClients: DownloadClientConfigs(
                qbittorrent: cs.qbittorrent, transmission: cs.transmission, nzbget: cs.nzbget,
                sabnzbd: cs.sabnzbd, rtorrent: cs.rtorrent, deluge: cs.deluge),
            mediaServer: cs.mediaServer)
        return MCPServerController.Config(
            hostPort: cs.mcpHostPort, requireAuth: cs.mcpRequireAuth, token: cs.mcpAuthToken,
            disabledTools: cs.mcpDisabledTools, backendInputs: inputs)
    }
}

private extension MCPServerStatus {
    init(_ s: MCPServerController.Status) {
        switch s {
        case .stopped: self = .stopped
        case .running(let url): self = .running(url: url)
        case .failed(let message): self = .failed(message: message)
        }
    }
}
