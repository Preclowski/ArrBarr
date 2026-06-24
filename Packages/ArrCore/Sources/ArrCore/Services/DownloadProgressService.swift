import Foundation

/// Caches and batch-fetches live download progress from the configured download
/// clients, so the queue can overlay the client's fresher value on top of the
/// arr's polled `/queue` progress (arr stays the fallback).
///
/// Self-contained: it builds and reuses its own source clients from the configs
/// it's handed — rebuilding one only when its config changes — so callers just
/// pass `[ServiceKind: ServiceConfig]` and never branch per client. Conformers
/// are actors, so a refresh fans the per-client fetches out in parallel. A short
/// `ttl` collapses the bursty queue refreshes (poll + realtime) into one client
/// round-trip; a total fetch wipe keeps the last-known map so bars don't snap
/// back to the arr value on a transient blip.
public actor DownloadProgressService {
    /// Process-wide cache — one progress snapshot shared by every queue refresh.
    public static let shared = DownloadProgressService()

    private var sources: [ServiceKind: DownloadProgressSource] = [:]
    private var sourceConfigs: [ServiceKind: ServiceConfig] = [:]
    private var cache: [String: DownloadProgress] = [:]
    private var lastRefresh: Date?
    private var inFlight: Task<[String: DownloadProgress], Never>?
    private let ttl: TimeInterval

    public init(ttl: TimeInterval = 2) { self.ttl = ttl }

    /// Cached live progress keyed by lowercased download id. Refreshes from all
    /// configured, progress-capable clients when the cache is older than `ttl`;
    /// otherwise serves the cache; coalesces concurrent callers into one fetch.
    /// Returns `[:]` when no client is configured (→ the queue keeps arr values).
    public func snapshot(configs: [ServiceKind: ServiceConfig]) async -> [String: DownloadProgress] {
        let active = resolveSources(configs)
        guard !active.isEmpty else { return [:] }
        if let last = lastRefresh, Date().timeIntervalSince(last) < ttl { return cache }
        if let inFlight { return await inFlight.value }
        let task = Task { await self.refresh(active) }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    private func refresh(_ sources: [DownloadProgressSource]) async -> [String: DownloadProgress] {
        let merged = await withTaskGroup(of: [String: DownloadProgress].self) { group in
            for source in sources {
                // Per-source failure is best-effort: it contributes nothing, so
                // its downloads fall back to the arr progress for this cycle.
                group.addTask { (try? await source.fetchProgress()) ?? [:] }
            }
            var all: [String: DownloadProgress] = [:]
            for await map in group { all.merge(map) { _, new in new } }
            return all
        }
        lastRefresh = Date()
        if !merged.isEmpty { cache = merged }  // keep last-known on a total wipe
        return cache
    }

    /// Build/reuse one source client per configured, progress-capable kind.
    private func resolveSources(_ configs: [ServiceKind: ServiceConfig]) -> [DownloadProgressSource] {
        var result: [DownloadProgressSource] = []
        for (kind, cfg) in configs where cfg.isConfigured {
            if sourceConfigs[kind] != cfg {
                sources[kind] = Self.makeSource(kind, cfg)  // first seen / config changed
                sourceConfigs[kind] = cfg
            }
            if let source = sources[kind] { result.append(source) }
        }
        return result
    }

    /// The one place that maps a client kind to its progress source. A kind that
    /// doesn't (yet) conform returns nil → its downloads keep the arr fallback.
    private static func makeSource(_ kind: ServiceKind, _ cfg: ServiceConfig) -> DownloadProgressSource? {
        switch kind {
        case .qbittorrent:  return QbittorrentClient(config: cfg)
        case .sabnzbd:      return SabnzbdClient(config: cfg)
        case .transmission: return TransmissionClient(config: cfg)
        case .deluge:       return DelugeClient(config: cfg)
        case .rtorrent:     return RtorrentClient(config: cfg)
        case .nzbget:       return NzbgetClient(config: cfg)
        // arr kinds (radarr / sonarr / …) aren't download clients.
        default:            return nil
        }
    }
}
