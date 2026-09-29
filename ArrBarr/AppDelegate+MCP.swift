import AppKit
import ArrCore
import ArrMCPServer
import Combine

extension AppDelegate {
    // MARK: - MCP server

    func wireMCPServer() {
        Task {
            await mcpController.setStatusHandler { status in
                Task { @MainActor in MCPServerStatusModel.shared.status = MCPServerStatus(status) }
            }
        }
        // Every setting the tools read (arrs, download clients, TMDB, media server) restarts the server;
        // anything else collapses in `removeDuplicates`.
        configStore.objectWillChange
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .prepend(())
            .map { [weak self] _ in self?.mcpConfig() }
            .removeDuplicates()
            .sink { [weak self] config in
                guard let controller = self?.mcpController else { return }
                Task { if let config { await controller.restart(with: config) } else { await controller.stop() } }
            }
            .store(in: &cancellables)
    }

    /// nil = the server should be stopped.
    private func mcpConfig() -> MCPServerController.Config? {
        let cs = configStore
        guard cs.mcpEnabled else { return nil }
        // Mint a token rather than start a server whose auth can never pass (the validator fails closed on empty).
        if cs.mcpRequireAuth && cs.mcpAuthToken.isEmpty { cs.mcpAuthToken = MCPTokenStore.generate() }
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
