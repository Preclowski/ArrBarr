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
        let cs = configStore
        let triggers: [AnyPublisher<Void, Never>] = [
            cs.$mcpEnabled.map { _ in () }.eraseToAnyPublisher(),
            cs.$mcpHostPort.map { _ in () }.eraseToAnyPublisher(),
            cs.$mcpRequireAuth.map { _ in () }.eraseToAnyPublisher(),
            cs.$mcpAuthToken.map { _ in () }.eraseToAnyPublisher(),
            cs.$mcpDisabledTools.map { _ in () }.eraseToAnyPublisher(),
            cs.$sonarr.map { _ in () }.eraseToAnyPublisher(),
            cs.$radarr.map { _ in () }.eraseToAnyPublisher(),
            cs.$lidarr.map { _ in () }.eraseToAnyPublisher(),
            cs.$whisparr.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] in self?.applyMCPConfig() }
            .store(in: &cancellables)
        applyMCPConfig()
    }

    private func applyMCPConfig() {
        let cs = configStore
        guard cs.mcpEnabled else { Task { await mcpController.stop() }; return }
        if cs.mcpRequireAuth && cs.mcpAuthToken.isEmpty {
            // Mint a token rather than start a server whose auth can never pass (the validator fails closed on empty).
            cs.mcpAuthToken = MCPTokenStore.generate()
            return
        }
        let inputs = MCPServerController.BackendInputs(
            sonarr: cs.sonarr, radarr: cs.radarr, lidarr: cs.lidarr, whisparr: cs.whisparr,
            aiKnowsAboutWhisparr: cs.aiKnowsAboutWhisparr, tmdbApiKey: cs.tmdbApiKey,
            downloadClients: DownloadClientConfigs(
                qbittorrent: cs.qbittorrent, transmission: cs.transmission, nzbget: cs.nzbget,
                sabnzbd: cs.sabnzbd, rtorrent: cs.rtorrent, deluge: cs.deluge),
            mediaServer: cs.mediaServer)
        let config = MCPServerController.Config(
            hostPort: cs.mcpHostPort, requireAuth: cs.mcpRequireAuth, token: cs.mcpAuthToken,
            disabledTools: cs.mcpDisabledTools, backendInputs: inputs)
        Task { await mcpController.restart(with: config) }
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
