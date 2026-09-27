import Foundation

/// Not a `ServiceKind` case: that enum drives queue aggregation, health, section order and
/// the secrets roster, none of which a media server takes part in.
nonisolated public enum MediaServerKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case plex, jellyfin, emby

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .plex: return "Plex"
        case .jellyfin: return "Jellyfin"
        case .emby: return "Emby"
        }
    }

    public var urlPlaceholder: String {
        switch self {
        case .plex: return "http://192.168.1.10:32400"
        case .jellyfin: return "http://192.168.1.10:8096"
        case .emby: return "http://192.168.1.10:8096"
        }
    }
}

/// `userId` is resolved automatically, never typed.
nonisolated public struct MediaServerConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var kind: MediaServerKind
    public var baseURL: String
    /// Plex: `X-Plex-Token`; Jellyfin / Emby: a dashboard API key. Kept in `SecretStore`.
    public var token: String
    /// Resolved by `testConnection()` from the token itself.
    public var userId: String

    public init(enabled: Bool = false, kind: MediaServerKind = .plex,
                baseURL: String = "", token: String = "", userId: String = "") {
        self.enabled = enabled
        self.kind = kind
        self.baseURL = baseURL
        self.token = token
        self.userId = userId
    }

    /// No keyless mode: every one of the three servers authenticates.
    public var isConfigured: Bool {
        guard enabled, !token.isEmpty else { return false }
        guard let url = URL(string: baseURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return false }
        return true
    }

    public static let empty = MediaServerConfig()
}
