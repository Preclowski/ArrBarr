import Foundation

/// One target of the unified connection-health system. Wraps every
/// `ServiceKind` (the 4 arrs + 6 download clients) and adds the two AI services
/// (OpenAI, TMDB) that have no `ServiceKind` of their own. Kept separate from
/// `ServiceKind` so the arr/download semantics there (and its many `.allCases`
/// iterations) stay untouched.
public enum MonitoredService: Hashable, Sendable, Identifiable {
    case arr(ServiceKind)
    case openai
    case tmdb

    /// The 6 download clients — the non-arr `ServiceKind` cases. These are not
    /// fetched on the normal queue cycle, so they need active probing.
    public static let downloadClientKinds: [ServiceKind] =
        [.sabnzbd, .nzbget, .qbittorrent, .transmission, .rtorrent, .deluge]

    /// Every monitored target, arrs first (declaration order) then download
    /// clients, then the AI services.
    public static var allCases: [MonitoredService] {
        ServiceKind.allCases.map { .arr($0) } + [.openai, .tmdb]
    }

    /// Targets that are NOT live-fetched by the queue refresh and therefore
    /// require their own probe: the download clients + the AI services.
    public static var probeTargets: [MonitoredService] {
        downloadClientKinds.map { .arr($0) } + [.openai, .tmdb]
    }

    public var id: String {
        switch self {
        case .arr(let kind): return "arr.\(kind.rawValue)"
        case .openai: return "openai"
        case .tmdb: return "tmdb"
        }
    }

    public var displayName: String {
        switch self {
        case .arr(let kind): return kind.displayName
        case .openai: return "OpenAI"
        case .tmdb: return "TMDB"
        }
    }

    /// True for the 4 real arrs (Radarr/Sonarr/Lidarr/Whisparr), whose health
    /// is driven by the live queue fetch rather than a dedicated probe.
    public var isArr: Bool {
        guard case .arr(let kind) = self else { return false }
        return [.radarr, .sonarr, .lidarr, .whisparr].contains(kind)
    }

    /// True for the 6 download clients.
    public var isDownloadClient: Bool {
        guard case .arr(let kind) = self else { return false }
        return Self.downloadClientKinds.contains(kind)
    }

    /// The backing `ServiceKind`, or `nil` for the AI services.
    public var serviceKind: ServiceKind? {
        if case .arr(let kind) = self { return kind }
        return nil
    }

    /// Whether this service is configured well enough to be worth probing.
    /// Unlike `ServiceConfig.isConfigured` (URL only), this also requires a
    /// non-empty key for the kinds that need one, so a keyless-but-URL'd arr /
    /// SABnzbd isn't probed and shown spuriously red.
    @MainActor
    public func isConfigured(in store: ConfigStore) -> Bool {
        switch self {
        case .arr(let kind):
            let cfg = store.config(for: kind)
            guard cfg.isConfigured else { return false }
            if kind.requiresApiKey { return !cfg.apiKey.isEmpty }
            return true
        case .openai:
            return store.openai.isConfigured
        case .tmdb:
            return !store.tmdbApiKey.isEmpty
        }
    }
}
