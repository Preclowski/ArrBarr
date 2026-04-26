import Foundation

/// Konfiguracja jednej z czterech usług. URL i credentials trzymane w UserDefaults.
struct ServiceConfig: Codable, Equatable {
    var baseURL: String      // np. "http://192.168.1.10:7878"
    var apiKey: String       // używane przez Radarr/Sonarr/SABnzbd
    var username: String     // qBittorrent
    var password: String     // qBittorrent

    var isConfigured: Bool {
        guard let url = URL(string: baseURL), url.scheme != nil, url.host != nil else { return false }
        return true
    }

    static let empty = ServiceConfig(baseURL: "", apiKey: "", username: "", password: "")
}

enum ServiceKind: String, CaseIterable, Identifiable {
    case radarr, sonarr, sabnzbd, qbittorrent
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .radarr: return "Radarr"
        case .sonarr: return "Sonarr"
        case .sabnzbd: return "SABnzbd"
        case .qbittorrent: return "qBittorrent"
        }
    }

    var requiresApiKey: Bool {
        switch self {
        case .radarr, .sonarr, .sabnzbd: return true
        case .qbittorrent: return false
        }
    }

    var requiresLogin: Bool {
        self == .qbittorrent
    }
}
