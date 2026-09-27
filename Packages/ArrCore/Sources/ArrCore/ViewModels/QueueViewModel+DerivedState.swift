import Foundation

extension QueueViewModel {
    // MARK: - Derived state

    static func tonightSlice(from upcoming: [UpcomingItem], hours: Int) -> [UpcomingItem] {
        // From the start of today, like the Upcoming tab: date-only movie releases parse to midnight.
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let cutoff = Date().addingTimeInterval(TimeInterval(hours) * 3600)
        // Sorted here so the banner can never disagree with the Upcoming tab's ordering.
        return upcoming
            .filter { $0.airDate >= startOfToday && $0.airDate <= cutoff }
            .sorted { $0.airDate < $1.airDate }
    }

    static func computeNeedsYou(
        queues: [QueueItem.Source: [QueueItem]],
        errors: [QueueItem.Source: String],
        health: HealthResult,
        showWarnings: Bool,
        unreachable: Set<QueueItem.Source> = []
    ) -> [NeedsYouItem] {
        // Explicit loop in `Source.allCases` order for a stable list; the equivalent lazy chain cost ~250 ms
        // to type-check.
        var result: [NeedsYouItem] = []
        for source in QueueItem.Source.allCases {
            for item in queues[source] ?? [] where item.status == .failed || item.status == .warning {
                result.append(NeedsYouItem(item))
            }
            // One entry per problem; the trailing chip names the app. An unreachable source is the calm
            // away-from-LAN case, so its fetch error is dropped.
            if let error = errors[source], !unreachable.contains(source) {
                result.append(NeedsYouItem(arrIssue: source, id: "needsyou.fetch.\(source.rawValue)", message: error))
            }
            for record in health.records(for: source) {
                guard let message = record.message, !message.isEmpty else { continue }
                guard record.type?.lowercased() == "error" || showWarnings else { continue }
                result.append(NeedsYouItem(arrIssue: source, id: "needsyou.health.\(source.rawValue).\(message)", message: message))
            }
        }
        // A pack's "Manual import required" lands once per episode, so identical rows collapse into ×N, keeping
        // the first as the tap target. Control chars separate the fields so no title can forge a collision.
        var merged: [NeedsYouItem] = []
        var indexByKey: [String: Int] = [:]
        for entry in result {
            let key = [
                entry.source?.rawValue ?? "",
                entry.service?.id ?? "",
                entry.title,
                entry.subtitle,
                entry.detailLines.joined(separator: "\u{1F}"),
            ].joined(separator: "\u{1E}")
            if let idx = indexByKey[key] {
                merged[idx].count += 1
            } else {
                indexByKey[key] = merged.count
                merged.append(entry)
            }
        }
        return merged
    }
}
