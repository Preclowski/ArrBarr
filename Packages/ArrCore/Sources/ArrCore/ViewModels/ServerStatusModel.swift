import Foundation
import MediaKit

/// Settings → Status disk space; health and queue activity come from their shared singletons.
@Observable
final class ServerStatusModel {
    private(set) var disks: [ArrDiskSpace] = []
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    /// Arrs whose `/diskspace` read failed, with the reason; their mounts are missing, not full.
    private(set) var failures: [(kind: ServiceKind, message: String)] = []

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

        let (fetched, failed) = await Self.fetchAll(targets)
        disks = Self.dedupe(fetched)
        failures = failed.sorted { $0.kind.displayName < $1.kind.displayName }
        lastRefresh = Date()
    }

    /// A failing arr is reported and skipped rather than aborting the sweep.
    private static func fetchAll(_ targets: [(ServiceKind, ServiceConfig)]) async -> ([ArrDiskSpace], [(kind: ServiceKind, message: String)]) {
        await withTaskGroup(of: (ServiceKind, Result<[ArrDiskSpace], any Error>).self) { group in
            for (kind, cfg) in targets {
                group.addTask {
                    do { return (kind, .success(try await client(kind, cfg).fetchDiskSpace())) }
                    catch { return (kind, .failure(error)) }
                }
            }
            var all: [ArrDiskSpace] = [], failed: [(kind: ServiceKind, message: String)] = []
            for await (kind, outcome) in group {
                switch outcome {
                case let .success(disks): all += disks
                case let .failure(error): failed.append((kind, error.localizedDescription))
                }
            }
            return (all, failed)
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
