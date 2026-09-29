import Foundation

/// A connection-health target: every `ServiceKind` plus services that have none
/// (Prowlarr, the media server, OpenAI, TMDB).
nonisolated public enum MonitoredService: Hashable, Sendable, Identifiable {
    case arr(ServiceKind)
    case openai
    case tmdb
    /// Not fetched on the queue cycle, so it is probed like the download clients.
    case prowlarr
    /// Which server lives in `ConfigStore.mediaServer`: there is only ever one.
    case mediaServer

    /// Not fetched on the queue cycle, so they need active probing.
    public static let downloadClientKinds: [ServiceKind] =
        [.sabnzbd, .nzbget, .qbittorrent, .transmission, .rtorrent, .deluge]

    public static var allCases: [MonitoredService] {
        ServiceKind.allCases.map { .arr($0) } + [.prowlarr, .mediaServer, .openai, .tmdb]
    }

    public static var probeTargets: [MonitoredService] {
        downloadClientKinds.map { .arr($0) } + [.prowlarr, .mediaServer, .openai, .tmdb]
    }

    public var id: String {
        switch self {
        case .arr(let kind): return "arr.\(kind.rawValue)"
        case .openai: return "openai"
        case .tmdb: return "tmdb"
        case .prowlarr: return "prowlarr"
        case .mediaServer: return "mediaServer"
        }
    }

    public var displayName: String {
        switch self {
        case .arr(let kind): return kind.displayName
        case .openai: return "OpenAI"
        case .tmdb: return "TMDB"
        case .prowlarr: return "Prowlarr"
        // Generic name: the row's detail line carries the handshake version ("Plex 1.40.2").
        case .mediaServer: return String(localized: "settings.mediaServer.label", bundle: .module)
        }
    }

    public var serviceKind: ServiceKind? {
        if case .arr(let kind) = self { return kind }
        return nil
    }

    /// Unlike `ServiceConfig.isConfigured` (URL only), also requires a key where one is needed,
    /// so a keyless arr isn't probed and shown red.
    @MainActor
    public func isConfigured(in store: ConfigStore) -> Bool {
        switch self {
        case .arr(let kind):
            return store.config(for: kind).isUsable(as: kind)
        case .openai:
            return store.openai.isConfigured
        case .tmdb:
            return !store.tmdbApiKey.isEmpty
        case .prowlarr:
            return store.prowlarr.isConfigured && !store.prowlarr.apiKey.isEmpty
        case .mediaServer:
            return store.mediaServer.isConfigured
        }
    }
}
