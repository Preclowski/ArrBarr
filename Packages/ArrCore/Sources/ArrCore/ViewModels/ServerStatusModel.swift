import Foundation
import MediaKit

/// Settings → Status disk space; health and queue activity come from their shared singletons.
@Observable
final class ServerStatusModel {
    private(set) var disks: [ArrDiskSpace] = []
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?

    init() {}

    private var targets: [(ServiceKind, ServiceConfig)] {
        let store = ConfigStore.shared
        return [ServiceKind.radarr, .sonarr, .lidarr, .whisparr].compactMap { kind in
            let cfg = store.config(for: kind)
            guard cfg.isConfigured, !cfg.apiKey.isEmpty else { return nil }
            return (kind, cfg)
        }
    }

    func refresh() async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let fetched = await Self.fetchAll(targets)
        disks = Self.dedupe(fetched)
        lastRefresh = Date()
    }

    /// A failing arr contributes nothing rather than aborting the sweep.
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

    private static func client(_ kind: ServiceKind, _ cfg: ServiceConfig) -> any ArrAPIClient {
        ServiceHandles.arr(QueueItem.Source(rawValue: kind.rawValue) ?? .whisparr, config: cfg)
    }

    /// Arrs sharing a mount report it identically: collapse by path, keep the largest capacity, fullest first.
    private static func dedupe(_ disks: [ArrDiskSpace]) -> [ArrDiskSpace] {
        var byPath: [String: ArrDiskSpace] = [:]
        for d in disks where d.isMeaningful {
            if let existing = byPath[d.mountPath], existing.capacity >= d.capacity { continue }
            byPath[d.mountPath] = d
        }
        return byPath.values.sorted { $0.usedFraction > $1.usedFraction }
    }
}
