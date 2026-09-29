import Foundation
import os
import MediaKit

/// The upcoming list outside the app's queue: the Up Next widget and the calendar tool.
public actor UpcomingService {
    nonisolated private static let log = Logger(category: "Widget")
    public init() {}

    public func upcoming(
        radarr: ServiceConfig,
        sonarr: ServiceConfig,
        lidarr: ServiceConfig,
        whisparr: ServiceConfig,
        limit: Int = 8
    ) async -> [UpcomingItem] {
        let targets = [(QueueItem.Source.radarr, radarr), (.sonarr, sonarr), (.lidarr, lidarr), (.whisparr, whisparr)].filter { $0.1.isVisible }
        let (fresh, failures) = await Self.calendars(targets)
        // Away from the home LAN every fetch fails; the app's last snapshot beats "Nothing coming up".
        let failed = Set(failures.map(\.0))
        let snapshot = failed.isEmpty ? [] : WidgetDataStore.loadUpcoming().filter { failed.contains($0.source) }
        return Self.curate(fresh + snapshot, limit: limit)
    }

    /// The demo calendar for `sources`, from the bundled fixtures (the widget's demo mode).
    public static func demo(sources: Set<UpcomingItem.Source>, limit: Int) async -> [UpcomingItem] {
        let gateway = await MainActor.run { ServiceGateway.demo(kinds: Set(sources.map(\.serviceKind))) }
        var all: [UpcomingItem] = []
        for source in sources {
            let base = ServiceGateway.demoURL(source.serviceKind.instanceKind).absoluteString
            all += await log.attempt("demo calendar") { try await ArrQueueLoader.upcoming(source: source, gateway: gateway, baseURL: base) } ?? []
        }
        await gateway.kit.stop()
        return curate(all, limit: limit)
    }

    /// Soonest first, from the start of today, trimmed to `limit`.
    public static func curate(_ items: [UpcomingItem], limit: Int = .max) -> [UpcomingItem] {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return Array(items.filter { $0.airDate >= startOfToday }.sorted { $0.airDate < $1.airDate }.prefix(limit))
    }

    /// Every target's calendar in parallel; an arr that isn't set up adds nothing, one that fails is named.
    nonisolated static func calendars(_ targets: [(QueueItem.Source, ServiceConfig)]) async -> (items: [UpcomingItem], failures: [(QueueItem.Source, any Error)]) {
        await withTaskGroup(of: (QueueItem.Source, Result<[UpcomingItem], any Error>).self) { group in
            for (source, config) in targets {
                group.addTask {
                    do { return (source, .success(try await ServiceHandles.arr(source, config: config).fetchCalendar())) }
                    catch MediaKitError.notConfigured { return (source, .success([])) }
                    catch { return (source, .failure(error)) }
                }
            }
            var items: [UpcomingItem] = [], failures: [(QueueItem.Source, any Error)] = []
            for await (source, outcome) in group {
                switch outcome {
                case let .success(rows): items += rows
                case let .failure(error): failures.append((source, error))
                }
            }
            return (items, failures)
        }
    }
}
