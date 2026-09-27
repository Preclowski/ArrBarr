import Foundation
import Combine

extension ConfigStore {
    /// Pause/resume go straight to the download client; only a confirmed `.down` gates,
    /// `.unknown` (not yet probed) stays allowed.
    public func canControlDownload(_ proto: QueueItem.DownloadProtocol) -> Bool {
        guard let kind = selectedDownloadClient(for: proto) else { return false }
        if case .down = ConnectionHealth.shared.state(for: .arr(kind)) { return false }
        return true
    }

    public var tmdbEnabled: Bool { !tmdbApiKey.isEmpty }

    public func testProwlarr() async throws {
        _ = try await ProwlarrClient().testConnection()
    }

    public func config(for source: QueueItem.Source) -> ServiceConfig { config(for: source.serviceKind) }

    public func shouldBlurPoster(for source: QueueItem.Source) -> Bool {
        source == .whisparr && blurWhisparrPosters
    }

    func publisher(for kind: ServiceKind) -> Published<ServiceConfig>.Publisher {
        switch kind {
        case .radarr: $radarr
        case .sonarr: $sonarr
        case .lidarr: $lidarr
        case .whisparr: $whisparr
        case .sabnzbd: $sabnzbd
        case .qbittorrent: $qbittorrent
        case .nzbget: $nzbget
        case .transmission: $transmission
        case .rtorrent: $rtorrent
        case .deluge: $deluge
        }
    }

    public func config(for kind: ServiceKind) -> ServiceConfig {
        switch kind {
        case .radarr: return radarr
        case .sonarr: return sonarr
        case .lidarr: return lidarr
        case .whisparr: return whisparr
        case .sabnzbd: return sabnzbd
        case .qbittorrent: return qbittorrent
        case .nzbget: return nzbget
        case .transmission: return transmission
        case .rtorrent: return rtorrent
        case .deluge: return deluge
        }
    }

    /// The drop flow needs arrs and download clients together: the arr names the client,
    /// the client's config carries its credentials.
    public var downloadDropConfigs: [ServiceKind: ServiceConfig] {
        Dictionary(uniqueKeysWithValues: ServiceKind.allCases.map { ($0, config(for: $0)) })
    }

    /// Same priority order as `QueueAggregator.performUsenet` / `performTorrent`; this
    /// client's reachability gates pause/resume, unlike delete, which the arr performs.
    public func selectedDownloadClient(for proto: QueueItem.DownloadProtocol) -> ServiceKind? {
        switch proto {
        case .usenet:
            if sabnzbd.isConfigured, !sabnzbd.apiKey.isEmpty { return .sabnzbd }
            if nzbget.isConfigured { return .nzbget }
            return nil
        case .torrent:
            if qbittorrent.isConfigured { return .qbittorrent }
            if transmission.isConfigured { return .transmission }
            if rtorrent.isConfigured { return .rtorrent }
            if deluge.isConfigured { return .deluge }
            return nil
        case .unknown:
            return nil
        }
    }


    public func update(_ kind: ServiceKind, with config: ServiceConfig) {
        switch kind {
        case .radarr: radarr = config
        case .sonarr: sonarr = config
        case .lidarr: lidarr = config
        case .whisparr: whisparr = config
        case .sabnzbd: sabnzbd = config
        case .qbittorrent: qbittorrent = config
        case .nzbget: nzbget = config
        case .transmission: transmission = config
        case .rtorrent: rtorrent = config
        case .deluge: deluge = config
        }
    }

    public static func normalizeArrOrder(_ stored: [String]?) -> [String] {
        let known = Set(defaultArrOrder)
        var seen = Set<String>()
        var result = (stored ?? []).filter { known.contains($0) && seen.insert($0).inserted }
        // Users from <0.7.x: put "tonight" and "needsyou" on top; other missing keys append.
        if !seen.contains(needsYouOrderKey) {
            result.insert(needsYouOrderKey, at: 0)
            seen.insert(needsYouOrderKey)
        }
        if !seen.contains(tonightOrderKey) {
            result.insert(tonightOrderKey, at: 0)
            seen.insert(tonightOrderKey)
        }
        for k in defaultArrOrder where !seen.contains(k) { result.append(k) }
        return result
    }
}
