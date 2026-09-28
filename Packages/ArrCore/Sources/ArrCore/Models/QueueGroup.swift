import Foundation

/// Only Sonarr season packs (N episode rows sharing one `downloadId`) collapse; independent
/// same-series episodes stay separate rows, since they are separate downloads with their own controls.
nonisolated public enum QueueRowEntry: Identifiable, Equatable {
    case single(QueueItem)
    case group(QueueGroup)

    public var id: String {
        switch self {
        case .single(let item): return "single.\(item.id)"
        case .group(let g): return "group.\(g.id)"
        }
    }

    /// A pack's members share size/progress, so its representative is the whole pack.
    var representativeItem: QueueItem {
        switch self {
        case .single(let item): return item
        case .group(let g): return g.representative
        }
    }

    var allItems: [QueueItem] {
        switch self {
        case .single(let item): return [item]
        case .group(let g): return g.items
        }
    }
}

nonisolated public struct QueueGroup: Identifiable, Equatable {
    public let id: String
    let items: [QueueItem]

    var representative: QueueItem { items[0] }
    var memberCount: Int { items.count }
}

/// `off` renders the flat list; the other two differ only in default disclosure state.
nonisolated public enum QueueTitleGroupingMode: String, CaseIterable, Sendable {
    case off, collapsed, expanded
}

/// Never merges downloads: children are the real entries with their own controls;
/// the container only adds a collapsible header.
nonisolated struct QueueTitleGroup: Identifiable, Equatable {
    /// Survives members joining/leaving, so disclosure state can be keyed on it.
    let id: String
    let entries: [QueueRowEntry]

    var representative: QueueItem { entries[0].representativeItem }
    /// A season pack counts as 1.
    var downloadCount: Int { entries.count }
    var allItems: [QueueItem] { entries.flatMap(\.allItems) }

    /// Size-weighted; honest only because the header also shows the download count.
    var aggregateProgress: Double {
        let total = allItems.reduce(Int64(0)) { $0 + $1.sizeTotal }
        let left = allItems.reduce(Int64(0)) { $0 + $1.sizeLeft }
        if total > 0 {
            return max(0, min(1, 1.0 - Double(left) / Double(total)))
        }
        let items = allItems
        guard !items.isEmpty else { return 0 }
        return items.reduce(0.0) { $0 + $1.progress } / Double(items.count)
    }

    /// Measured aggregate plus the interpolated delta: the measured figure comes from
    /// remaining bytes, more accurate than per-row percentages.
    func aggregateProgress(at date: Date, measuredAt: Date) -> Double {
        let items = allItems
        let total = items.reduce(Int64(0)) { $0 + $1.sizeTotal }
        guard total > 0 else { return aggregateProgress }
        let gained = items.reduce(0.0) { sum, item in
            let delta = item.interpolatedProgress(at: date, measuredAt: measuredAt) - item.progress
            return sum + delta * Double(item.sizeTotal)
        }
        return max(0, min(1, aggregateProgress + gained / Double(total)))
    }

    var isInterpolatingProgress: Bool { allItems.contains { $0.isInterpolatingProgress } }
}

nonisolated enum QueueDisplayRow: Identifiable {
    case entry(QueueRowEntry)
    case titleGroup(QueueTitleGroup)

    var id: String {
        switch self {
        case .entry(let e): return e.id
        case .titleGroup(let g): return "title.\(g.id)"
        }
    }
}

nonisolated enum QueueGrouping {
    static func group(_ items: [QueueItem]) -> [QueueRowEntry] {
        var packBuckets: [String: [QueueItem]] = [:]
        for item in items {
            guard let key = item.downloadId, !key.isEmpty else { continue }
            packBuckets[key, default: []].append(item)
        }

        var result: [QueueRowEntry] = []
        var emitted = Set<String>()
        for item in items {
            if let key = item.downloadId, !key.isEmpty,
               let members = packBuckets[key], members.count >= 2 {
                if emitted.insert(key).inserted {
                    result.append(.group(QueueGroup(id: key, items: members)))
                }
                continue
            }
            result.append(.single(item))
        }
        return result
    }

    /// Arr entity id, else the normalized title; source-prefixed so ids never collide across arrs.
    static func titleKey(for item: QueueItem) -> String {
        if let entityId = item.entityId {
            return "\(item.source.rawValue).id.\(entityId)"
        }
        return "\(item.source.rawValue).title.\(item.title.lowercased())"
    }

    /// Only buckets of ≥2 group; the group takes its first (best-ranked) member's position.
    static func groupByTitle(_ entries: [QueueRowEntry]) -> [QueueDisplayRow] {
        var counts: [String: Int] = [:]
        for entry in entries {
            counts[titleKey(for: entry.representativeItem), default: 0] += 1
        }

        var buckets: [String: [QueueRowEntry]] = [:]
        var result: [QueueDisplayRow] = []
        var emitted = Set<String>()
        for entry in entries {
            let key = titleKey(for: entry.representativeItem)
            guard counts[key, default: 0] >= 2 else {
                result.append(.entry(entry))
                continue
            }
            buckets[key, default: []].append(entry)
            if emitted.insert(key).inserted {
                result.append(.titleGroup(QueueTitleGroup(id: key, entries: [])))
            }
        }
        return result.map { row in
            if case .titleGroup(let g) = row, let members = buckets[g.id] {
                return .titleGroup(QueueTitleGroup(id: g.id, entries: members))
            }
            return row
        }
    }
}
