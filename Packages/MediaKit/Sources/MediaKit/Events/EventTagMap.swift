import Foundation

/// The one place an event becomes invalidation tags.
public struct EventTagMap: Sendable {
    public init() {}

    public func tags(for event: DataEvent, lastCounts: QueueCounts?) -> Set<InvalidationTag> {
        switch event {
        case let .queueChanged(i):
            return [.collection(.queue, i)]
        case let .queueStatus(i, counts):
            return counts == lastCounts ? [] : [.collection(.queue, i)]
        case let .fileImported(i, kind, id):
            var tags: Set<InvalidationTag> = [.collection(.queue, i), .collection(.library, i), .collection(.history, i), .collection(.calendar, i)]
            if let id { tags.insert(.entity(i, kind, id)) }
            return tags
        case let .entityChanged(i, kind, id):
            var tags: Set<InvalidationTag> = [.collection(.library, i), .collection(.calendar, i)]
            if let id { tags.insert(.entity(i, kind, id)) }
            return tags
        case let .healthChanged(i):
            return [.collection(.health, i)]
        case let .calendarChanged(i):
            return [.collection(.calendar, i)]
        case let .commandFinished(i, name):
            let lowered = name.lowercased()
            let touchesQueue = lowered.contains("search") || lowered.contains("grab") || lowered.contains("download")
            return touchesQueue ? [.collection(.commands, i), .collection(.queue, i)] : [.collection(.commands, i)]
        case .other:
            return []
        }
    }
}
