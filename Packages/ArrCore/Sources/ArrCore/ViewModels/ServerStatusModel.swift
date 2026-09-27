import Foundation
import MediaKit

/// Owns the disk-space fetch behind Settings → Status. Connection health and
/// queue activity are read straight from their shared singletons
/// (`ConnectionHealth`, `QueueViewModel`); only `/diskspace` needs its own
/// fetch, so that's all this model carries.
@Observable
public final class ServerStatusModel {
    public private(set) var disks: [ArrDiskSpace] = []
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

        let fetched = await Self.fetchAll(targets)
        disks = Self.dedupe(fetched)
        lastRefresh = Date()
    }

    /// Fetch `/diskspace` from every target concurrently; a failing arr
    /// contributes nothing rather than aborting the sweep.
    private static func fetchAll(_ targets: [(ServiceKind, ServiceConfig)]) async -> [ArrDiskSpace] {
        await withTaskGroup(of: [ArrDiskSpace].self) { group in
            for (kind, cfg) in targets {
                group.addTask { (try? await client(kind, cfg).fetchDiskSpace()) ?? [] }
            }
            var all: [ArrDiskSpace] = []
            for await chunk in group { all += chunk }
            return all
        }
    }

    /// The four arrs share `ArrAPIClient`, so an existential is enough to call
    /// the protocol-extension `fetchDiskSpace()`.
    private static func client(_ kind: ServiceKind, _ cfg: ServiceConfig) -> any ArrAPIClient {
        ServiceHandles.arr(QueueItem.Source(rawValue: kind.rawValue) ?? .whisparr, config: cfg)
    }

    /// Different arrs sharing a mount report it identically — collapse by path
    /// (keeping the largest-capacity read), drop capacity-less mounts, and sort
    /// fullest-first so the disks that need attention lead.
    private static func dedupe(_ disks: [ArrDiskSpace]) -> [ArrDiskSpace] {
        var byPath: [String: ArrDiskSpace] = [:]
        for d in disks where d.isMeaningful {
            if let existing = byPath[d.mountPath], existing.capacity >= d.capacity { continue }
            byPath[d.mountPath] = d
        }
        return byPath.values.sorted { $0.usedFraction > $1.usedFraction }
    }
}
