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
/// round-trip; a cycle in which *every* client failed keeps the last-known map
/// so bars don't snap back to the arr value on a transient blip — but only
/// until `maxCacheAge`, after which the arr takes over again (see `freshCache`).
public actor DownloadProgressService {
    /// Process-wide cache — one progress snapshot shared by every queue refresh.
    public static let shared = DownloadProgressService()

    private var sources: [ServiceKind: DownloadProgressSource] = [:]
    private var sourceConfigs: [ServiceKind: ServiceConfig] = [:]
    private var cache: [String: DownloadProgress] = [:]
    /// When `cache` was last filled by a fetch that actually *answered*. One
    /// stamp for the whole map is enough because the map is only ever replaced
    /// wholesale — a per-entry stamp would differ only if we merged surviving
    /// old entries into a new map, which we deliberately never do.
    private var cacheFilled: Date?
    /// Last *attempt*, successful or not — drives the `ttl` de-bounce, so a
    /// dead client isn't re-dialled once per queue refresh.
    private var lastRefresh: Date?
    private var inFlight: Task<[String: DownloadProgress], Never>?
    private let ttl: TimeInterval
    private let maxCacheAge: TimeInterval

    public init(ttl: TimeInterval = 2, maxCacheAge: TimeInterval = 60) {
        self.ttl = ttl
        self.maxCacheAge = maxCacheAge
    }

    /// Cached live progress keyed by lowercased download id. Refreshes from all
    /// configured, progress-capable clients when the cache is older than `ttl`;
    /// otherwise serves the cache; coalesces concurrent callers into one fetch.
    /// Returns `[:]` when no client is configured (→ the queue keeps arr values).
    ///
    /// `ids` are the download ids the arrs' queues actually reference. They
    /// narrow the request where the client's API allows it — see
    /// `DownloadProgressSource.fetchProgress(ids:)`.
    public func snapshot(
        configs: [ServiceKind: ServiceConfig], ids: Set<String> = []
    ) async -> [String: DownloadProgress] {
        let active = resolveSources(configs)
        guard !active.isEmpty else { return [:] }
        if let last = lastRefresh, Date().timeIntervalSince(last) < ttl { return freshCache }
        if let inFlight { return await inFlight.value }
        let task = Task { await self.refresh(active, ids: ids) }
        inFlight = task
        let result = await task.value
        // Only clear the slot if it still holds THIS task. The await above is an
        // actor hop, so a caller that arrived once the ttl had expired may have
        // installed its own refresh meanwhile; clearing unconditionally would
        // orphan that handle and let the next caller start a duplicate fetch.
        // Same guard as `PosterStore.image(for:)` — kept symmetric on purpose so
        // the difference can't quietly regress into a real bug here.
        if inFlight == task { inFlight = nil }
        return result
    }

    /// The cache, but only while it's recent enough to be worth overlaying.
    ///
    /// Past `maxCacheAge` we hand back nothing, so the queue falls back to the
    /// arr's own — still advancing — progress. Without the age limit, stopping a
    /// download client while the arr stays reachable froze every matching bar on
    /// the client's last reported value, indefinitely and with no visual cue.
    private var freshCache: [String: DownloadProgress] {
        guard let filled = cacheFilled,
              Date().timeIntervalSince(filled) < maxCacheAge else { return [:] }
        return cache
    }

    private func refresh(
        _ sources: [DownloadProgressSource], ids: Set<String>
    ) async -> [String: DownloadProgress] {
        let results = await withTaskGroup(of: [String: DownloadProgress]?.self) { group in
            for source in sources {
                // `nil` = this source failed; `[:]` = it answered and has nothing
                // running. Keeping those apart is the whole point: a per-source
                // failure stays best-effort (its downloads fall back to the arr
                // for this cycle), but a cycle where *all* of them failed must
                // not be mistaken for "every download finished".
                group.addTask { try? await source.fetchProgress(ids: ids) }
            }
            var all: [[String: DownloadProgress]?] = []
            for await map in group { all.append(map) }
            return all
        }
        lastRefresh = Date()

        let answered = results.compactMap { $0 }
        guard !answered.isEmpty else {
            // Total wipe — hold the last-known map so a blip doesn't snap the
            // bars back, but don't re-stamp it, so it still ages out.
            return freshCache
        }
        // What the answering clients report replaces the cache wholesale, empty
        // map included: a client reporting no downloads has genuinely finished
        // them, and keeping its old entries would pin those rows near 100%.
        var merged: [String: DownloadProgress] = [:]
        for map in answered { merged.merge(map) { _, new in new } }
        cache = merged
        cacheFilled = Date()
        return merged
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
