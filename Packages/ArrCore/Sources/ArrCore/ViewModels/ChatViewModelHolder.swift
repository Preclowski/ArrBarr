import Foundation
import Observation

/// Hosts the chat view-model at a scope above the tab bar so the conversation
/// survives Queue ↔ Upcoming ↔ Chat switches. SwiftUI's `@State` holder can't be
/// reassigned, so we wrap the VM in a holder that rebuilds it when the AI
/// configuration actually changes.
@MainActor
@Observable
public final class ChatViewModelHolder {
    public private(set) var vm: ChatViewModel
    /// Internal bookkeeping — not view state, so keep it out of observation.
    @ObservationIgnored private var lastSignature: String = ""

    public init() {
        self.vm = ChatViewModelFactory.makePlaceholder()
    }

    /// Rebuild the underlying VM if (and only if) the relevant config bits changed.
    /// No-op when the signature matches the last build — preserves message history.
    public func reconfigure(store: ConfigStore) {
        let next = Self.signature(store: store)
        guard next != lastSignature else { return }
        lastSignature = next
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
            chatProvider: store.chatProvider,
            openai: store.openai,
            appLanguage: store.appLanguage
        )
    }

    public static func signature(store: ConfigStore) -> String {
        [
            store.sonarr.baseURL, store.sonarr.apiKey, "\(store.sonarr.enabled)",
            store.radarr.baseURL, store.radarr.apiKey, "\(store.radarr.enabled)",
            store.lidarr.baseURL, store.lidarr.apiKey, "\(store.lidarr.enabled)",
            store.whisparr.baseURL, store.whisparr.apiKey, "\(store.whisparr.enabled)",
            "\(store.aiKnowsAboutWhisparr)",
            store.tmdbApiKey,
            // Download-client connection bits — changing any should rebuild
            // the backend so `health` probes the current endpoints.
            store.qbittorrent.baseURL, store.qbittorrent.apiKey, "\(store.qbittorrent.enabled)",
            store.transmission.baseURL, store.transmission.apiKey, "\(store.transmission.enabled)",
            store.nzbget.baseURL, store.nzbget.apiKey, "\(store.nzbget.enabled)",
            store.sabnzbd.baseURL, store.sabnzbd.apiKey, "\(store.sabnzbd.enabled)",
            store.rtorrent.baseURL, store.rtorrent.apiKey, "\(store.rtorrent.enabled)",
            store.deluge.baseURL, store.deluge.apiKey, "\(store.deluge.enabled)",
            store.chatProvider.rawValue,
            store.openai.baseURL, store.openai.apiKey, store.openai.model,
            // appLanguage is intentionally NOT part of the signature: changing
            // the app language already requires a restart to take effect, and
            // on restart the VM is rebuilt fresh with the new value anyway.
        ].joined(separator: "|")
    }
}
