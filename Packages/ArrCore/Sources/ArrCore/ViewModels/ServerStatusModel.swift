import Foundation

/// Owns the disk-space fetch behind Settings → Status. Connection health and
/// queue activity are read straight from their shared singletons
/// (`ConnectionHealth`, `QueueViewModel`); only `/diskspace` needs its own
/// fetch, so that's all this model carries.
@MainActor
@Observable
public final class ServerStatusModel {
    public private(set) var disks: [DiskSpace] = []
    public private(set) var isRefreshing = false
    public private(set) var lastRefresh: Date?

    public init() {}

    /// Configured + keyed arrs — the only services that answer `/diskspace`.
    private var targets: [(ServiceKind, ServiceConfig)] {
        let store = ConfigStore.shared
        return [ServiceKind.radarr, .sonarr, .lidarr, .whisparr].compactMap { kind in
            let cfg = store.config(for: kind)
            guard cfg.isConfigured, !cfg.apiKey.isEmpty else { return nil }
            return (kind, cfg)
        }
    }

    public func refresh() async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if DemoMode.isActive {
            try? await Task.sleep(nanoseconds: 300_000_000)
            disks = Self.demoDisks
            lastRefresh = Date()
            return
        }

        let fetched = await Self.fetchAll(targets)
        disks = Self.dedupe(fetched)
        lastRefresh = Date()
    }

    /// Fetch `/diskspace` from every target concurrently; a failing arr
    /// contributes nothing rather than aborting the sweep.
    private static func fetchAll(_ targets: [(ServiceKind, ServiceConfig)]) async -> [DiskSpace] {
        await withTaskGroup(of: [DiskSpace].self) { group in
            for (kind, cfg) in targets {
                group.addTask { (try? await client(kind, cfg).fetchDiskSpace()) ?? [] }
            }
            var all: [DiskSpace] = []
            for await chunk in group { all += chunk }
            return all
        }
    }

    /// The four arrs share `ArrAPIClient`, so an existential is enough to call
    /// the protocol-extension `fetchDiskSpace()`.
    private static func client(_ kind: ServiceKind, _ cfg: ServiceConfig) -> any ArrAPIClient {
        switch kind {
        case .radarr:   return RadarrClient(config: cfg)
        case .sonarr:   return SonarrClient(config: cfg)
        case .lidarr:   return LidarrClient(config: cfg)
        default:        return WhisparrClient(config: cfg)
        }
    }

    /// Different arrs sharing a mount report it identically — collapse by path
    /// (keeping the largest-capacity read), drop capacity-less mounts, and sort
    /// fullest-first so the disks that need attention lead.
    private static func dedupe(_ disks: [DiskSpace]) -> [DiskSpace] {
        var byPath: [String: DiskSpace] = [:]
        for d in disks where d.isMeaningful {
            if let existing = byPath[d.path], existing.totalSpace >= d.totalSpace { continue }
            byPath[d.path] = d
        }
        return byPath.values.sorted { $0.usedFraction > $1.usedFraction }
    }

    private static let demoDisks: [DiskSpace] = [
        DiskSpace(path: "/data/media", label: "Media", freeSpace: 2_400_000_000_000, totalSpace: 16_000_000_000_000),
        DiskSpace(path: "/data/downloads", label: "Downloads", freeSpace: 180_000_000_000, totalSpace: 2_000_000_000_000),
    ]
}
