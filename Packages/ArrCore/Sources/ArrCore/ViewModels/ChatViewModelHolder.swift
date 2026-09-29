import Foundation
import Observation

/// Holds the chat VM above the tab bar so the conversation survives tab switches,
/// rebuilding it only when the AI configuration changes.
@Observable
final class ChatViewModelHolder {
    private(set) var vm: ChatViewModel
    @ObservationIgnored private var lastSignature: String = ""

    init() {
        self.vm = ChatViewModelFactory.makePlaceholder()
    }

    /// No-op when the signature matches, which preserves message history.
    func reconfigure(store: ConfigStore) {
        let next = Self.signature(store: store)
        guard next != lastSignature else { return }
        lastSignature = next
        // The old VM may hold an unanswered confirm continuation; dropping it
        // unresumed hangs the tool call forever, so cancel first.
        vm.cancelPending()
        vm.cancelTurn()
        vm = ChatViewModelFactory.make(
            sonarr: store.sonarr,
            radarr: store.radarr,
            lidarr: store.lidarr,
            whisparr: store.whisparr,
            aiKnowsAboutWhisparr: store.aiKnowsAboutWhisparr,
            tmdbApiKey: store.tmdbApiKey,
            downloadClients: DownloadClientConfigs(
                qbittorrent: store.qbittorrent,
                transmission: store.transmission,
                nzbget: store.nzbget,
                sabnzbd: store.sabnzbd,
                rtorrent: store.rtorrent,
                deluge: store.deluge
            ),
            mediaServer: store.mediaServer,
            chatProvider: store.chatProvider,
            openai: store.openai,
            appLanguage: store.appLanguage
        )
    }

    static func signature(store: ConfigStore) -> String {
        [
            store.sonarr.baseURL, store.sonarr.apiKey, "\(store.sonarr.enabled)",
            store.radarr.baseURL, store.radarr.apiKey, "\(store.radarr.enabled)",
            store.lidarr.baseURL, store.lidarr.apiKey, "\(store.lidarr.enabled)",
            store.whisparr.baseURL, store.whisparr.apiKey, "\(store.whisparr.enabled)",
            "\(store.aiKnowsAboutWhisparr)",
            store.tmdbApiKey,
            store.qbittorrent.baseURL, store.qbittorrent.apiKey, "\(store.qbittorrent.enabled)",
            store.transmission.baseURL, store.transmission.apiKey, "\(store.transmission.enabled)",
            store.nzbget.baseURL, store.nzbget.apiKey, "\(store.nzbget.enabled)",
            store.sabnzbd.baseURL, store.sabnzbd.apiKey, "\(store.sabnzbd.enabled)",
            store.rtorrent.baseURL, store.rtorrent.apiKey, "\(store.rtorrent.enabled)",
            store.deluge.baseURL, store.deluge.apiKey, "\(store.deluge.enabled)",
            store.mediaServer.kind.rawValue, store.mediaServer.baseURL,
            store.mediaServer.token, "\(store.mediaServer.enabled)",
            store.chatProvider.rawValue,
            store.openai.baseURL, store.openai.apiKey, store.openai.model,
            // Branch inputs of `ChatViewModelFactory.make`. `DemoMode.isActive` isn't observable;
            // it's re-read only because `useDemoStore` → `applyValues` always publishes.
            "\(DemoMode.isActive)",
            "\(store.aiEnabled)",
            // The OpenAI prompt's fallback reply language; the UI switches live, so the chat must too.
            store.appLanguage,
        ].joined(separator: "|")
    }
}
