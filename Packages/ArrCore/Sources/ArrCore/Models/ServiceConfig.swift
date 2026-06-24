import Foundation

public struct ServiceConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var baseURL: String
    public var apiKey: String
    public var username: String
    public var password: String

    public init(enabled: Bool, baseURL: String, apiKey: String, username: String, password: String) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.username = username
        self.password = password
    }

    public var isConfigured: Bool {
        guard enabled else { return false }
        guard let url = URL(string: baseURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return false }
        return true
    }

    /// Arr visibility gate (Radarr/Sonarr/Lidarr/Whisparr — every caller of
    /// this is an arr, and they all need an API key). An arr that's enabled
    /// with a URL but no key is treated as NOT visible: it would only emit a
    /// "missing API key" error in the queue. Settings surfaces that error
    /// instead. Demo mode runs on mocks, so the URL/key fields stay blank and
    /// we render as long as `enabled`.
    public var isVisible: Bool {
        DemoMode.isActive ? enabled : (isConfigured && !apiKey.isEmpty)
    }

    public static let empty = ServiceConfig(enabled: false, baseURL: "", apiKey: "", username: "", password: "")
}

public enum ServiceKind: String, CaseIterable, Identifiable, Sendable {
    case radarr, sonarr, lidarr, whisparr, sabnzbd, qbittorrent, nzbget, transmission, rtorrent, deluge
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .radarr: return "Radarr"
        case .sonarr: return "Sonarr"
        case .lidarr: return "Lidarr"
        case .whisparr: return "Whisparr"
        case .sabnzbd: return "SABnzbd"
        case .qbittorrent: return "qBittorrent"
        case .nzbget: return "NZBGet"
        case .transmission: return "Transmission"
        case .rtorrent: return "rTorrent"
        case .deluge: return "Deluge"
        }
    }

    public var requiresApiKey: Bool {
        switch self {
        case .radarr, .sonarr, .lidarr, .whisparr, .sabnzbd: return true
        default: return false
        }
    }

    public var requiresLogin: Bool {
        switch self {
        // qBittorrent's WebUI API authenticates with username/password via
        // `/api/v2/auth/login` (returns a SID session cookie) — it has no
        // API key. Same login shape as the other download clients.
        case .qbittorrent, .nzbget, .transmission, .rtorrent, .deluge: return true
        default: return false
        }
    }

    public var urlPlaceholder: String {
        switch self {
        case .radarr: return "http://192.168.1.10:7878"
        case .sonarr: return "http://192.168.1.10:8989"
        case .lidarr: return "http://192.168.1.10:8686"
        case .whisparr: return "http://192.168.1.10:6969"
        case .sabnzbd: return "http://192.168.1.10:8080"
        case .qbittorrent: return "http://192.168.1.10:8080"
        case .nzbget: return "http://192.168.1.10:6789"
        case .transmission: return "http://192.168.1.10:9091"
        case .rtorrent: return "http://192.168.1.10/RPC2"
        case .deluge: return "http://192.168.1.10:8112"
        }
    }
}
