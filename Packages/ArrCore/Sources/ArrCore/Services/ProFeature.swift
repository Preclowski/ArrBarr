import Foundation

/// A capability that requires ArrBarr Control — the paid tier, which is always
/// called "Control" in anything the user reads (the `Pro` in these type and
/// property names is internal only). Each case carries the localized copy shown
/// as the contextual line in the paywall ("what you just tried").
public enum ProFeature: String, CaseIterable, Sendable {
    case chat
    case downloadClients
    case addTitle
    case queueAction
    case mediaServer

    /// Big contextual headline at the top of the paywall.
    public var paywallHeadlineKey: String {
        switch self {
        case .chat:            return "Ask your library anything"
        case .queueAction:     return "Manage your downloads"
        case .addTitle:        return "Add new titles"
        case .downloadClients: return "Connect download clients"
        case .mediaServer:     return "Connect your media server"
        }
    }

    /// One-line contextual subtitle under the headline.
    public var paywallSubtitleKey: String {
        switch self {
        case .chat:            return "Chat drives your whole stack in plain language."
        case .queueAction:     return "Pause, resume and remove downloads right from ArrBarr."
        case .addTitle:        return "Find a movie or show and add it in one tap."
        case .downloadClients: return "Add and manage SABnzbd, qBittorrent and the rest."
        case .mediaServer:     return "Pull artwork and watch history from Plex, Jellyfin or Emby."
        }
    }
}
