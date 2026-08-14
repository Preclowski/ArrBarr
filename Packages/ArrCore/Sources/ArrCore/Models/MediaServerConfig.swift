import Foundation

/// Which media server ArrBarr talks to. One at a time — the integration is a
/// single connection, not a roster, so this is a picker value rather than a
/// per-server config like `ServiceKind`.
///
/// Deliberately NOT a `ServiceKind` case. That enum drives queue aggregation,
/// health reporting, the queue's section order, the brand-icon set and the
/// secrets roster; a media server takes part in none of those, and widening it
/// would touch every exhaustive switch in the app to buy nothing.
public enum MediaServerKind: String, Codable, CaseIterable, Identifiable, Sendable {
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

    /// Auth header this server expects for its REST API.
    ///
    /// Plex takes a bare `X-Plex-Token`; Emby a bare `X-Emby-Token`; Jellyfin
    /// wants the token wrapped in its `MediaBrowser` authorization scheme (a
    /// bare `X-Emby-Token` also works on most builds, but the documented header
    /// is the one that survives version bumps).
    func authHeaders(token: String) -> [String: String] {
        switch self {
        case .plex:
            return ["X-Plex-Token": token, "Accept": "application/json"]
        case .emby:
            return ["X-Emby-Token": token, "Accept": "application/json"]
        case .jellyfin:
            return [
                "Authorization": "MediaBrowser Token=\"\(token)\"",
                "Accept": "application/json",
            ]
        }
    }

    /// Query-parameter name that carries the token on image URLs.
    ///
    /// Poster URLs are handed to `PosterStore`, which fetches them with no
    /// per-host header knowledge, so the token has to ride in the query string.
    var imageTokenQueryName: String {
        switch self {
        case .plex: return "X-Plex-Token"
        case .jellyfin, .emby: return "api_key"
        }
    }

    /// Whether this server needs a user id to answer watch-state questions.
    /// Plex reports `viewCount` on the item itself for the token's own user;
    /// Jellyfin and Emby scope play state per user, so they need one.
    var requiresUserId: Bool {
        switch self {
        case .plex: return false
        case .jellyfin, .emby: return true
        }
    }
}

/// The single media-server connection. Mirrors `ServiceConfig`'s shape closely
/// enough to be familiar in Settings, but carries `kind` (which server) and
/// `userId` (resolved automatically, never typed) instead of a login pair.
public struct MediaServerConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var kind: MediaServerKind
    public var baseURL: String
    /// Plex: `X-Plex-Token`. Jellyfin / Emby: an API key from the dashboard.
    /// Persisted in `SecretStore`, blanked in the UserDefaults copy.
    public var token: String
    /// Jellyfin / Emby user whose play state we read. Resolved by
    /// `testConnection()` from the token itself, so the user never enters it.
    public var userId: String

    public init(enabled: Bool = false, kind: MediaServerKind = .plex,
                baseURL: String = "", token: String = "", userId: String = "") {
        self.enabled = enabled
        self.kind = kind
        self.baseURL = baseURL
        self.token = token
        self.userId = userId
    }

    /// Enabled, with a usable URL and a token. Unlike `ServiceConfig` there is
    /// no keyless mode — every one of the three servers authenticates, so a
    /// blank token means "not set up yet", not "open server".
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
