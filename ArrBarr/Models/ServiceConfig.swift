import Foundation

struct ServiceConfig: Codable, Equatable {
    var enabled: Bool
    var baseURL: String
    var apiKey: String
    var username: String
    var password: String

    var isConfigured: Bool {
        guard enabled else { return false }
        guard let url = URL(string: baseURL), url.scheme != nil, url.host != nil else { return false }
        return true
    }

    static let empty = ServiceConfig(enabled: true, baseURL: "", apiKey: "", username: "", password: "")
}

enum ServiceKind: String, CaseIterable, Identifiable {
    case radarr, sonarr, sabnzbd, qbittorrent, nzbget, transmission, rtorrent, deluge
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .radarr: return "Radarr"
        case .sonarr: return "Sonarr"
        case .sabnzbd: return "SABnzbd"
        case .qbittorrent: return "qBittorrent"
        case .nzbget: return "NZBGet"
        case .transmission: return "Transmission"
        case .rtorrent: return "rTorrent"
        case .deluge: return "Deluge"
        }
    }

    var requiresApiKey: Bool {
        switch self {
        case .radarr, .sonarr, .sabnzbd: return true
        default: return false
        }
    }

    var requiresLogin: Bool {
        switch self {
        case .qbittorrent, .nzbget, .transmission, .rtorrent, .deluge: return true
        default: return false
        }
    }
}
