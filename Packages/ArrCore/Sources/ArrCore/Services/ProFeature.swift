import Foundation

/// A capability of the paid tier, always called "Control" to the user; `Pro` is internal only.
public enum ProFeature: String, CaseIterable, Sendable {
    case chat
    case downloadClients
    case addTitle
    case queueAction
    case mediaServer

    public var paywallHeadlineKey: String {
        switch self {
        case .chat:            return "Ask your library anything"
        case .queueAction:     return "Manage your downloads"
        case .addTitle:        return "Add new titles"
        case .downloadClients: return "Connect download clients"
        case .mediaServer:     return "Connect your media server"
        }
    }

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
