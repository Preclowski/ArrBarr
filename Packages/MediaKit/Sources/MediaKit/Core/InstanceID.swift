import Foundation

public enum InstanceKind: String, Sendable, Codable, CaseIterable, Hashable {
    case radarr, sonarr, lidarr, whisparr
    case qbittorrent, transmission, deluge, rtorrent, sabnzbd, nzbget
    case plex, jellyfin, emby
    case tmdb

    public enum Family: Sendable, Hashable { case servarr, download, mediaServer, metadata }

    public var family: Family {
        switch self {
        case .radarr, .sonarr, .lidarr, .whisparr: .servarr
        case .qbittorrent, .transmission, .deluge, .rtorrent, .sabnzbd, .nzbget: .download
        case .plex, .jellyfin, .emby: .mediaServer
        case .tmdb: .metadata
        }
    }
}

public struct InstanceID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let kind: InstanceKind
    public let ordinal: Int

    public init(_ kind: InstanceKind, ordinal: Int = 0) {
        self.kind = kind
        self.ordinal = ordinal
    }

    public var description: String { "\(kind.rawValue)#\(ordinal)" }
}

public struct Host: Hashable, Sendable, Codable, CustomStringConvertible {
    public let scheme: String
    public let name: String
    public let port: Int

    public init(_ url: URL) {
        scheme = url.scheme?.lowercased() ?? "http"
        name = url.host?.lowercased() ?? ""
        port = url.port ?? (scheme == "https" ? 443 : 80)
    }

    public var description: String { "\(name):\(port)" }
}

public struct OperationID: Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(_ kind: InstanceKind, _ name: String) { rawValue = "\(kind.rawValue).\(name)" }
    public init(stringLiteral value: String) { rawValue = value }

    public var kind: InstanceKind {
        InstanceKind(rawValue: String(rawValue.prefix { $0 != "." })) ?? .radarr
    }
    public var name: String { String(rawValue.drop { $0 != "." }.dropFirst()) }
    public var description: String { rawValue }
}
