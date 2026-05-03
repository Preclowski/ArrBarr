import Foundation

/// A row in the queue UI: either a single QueueItem, or a group of items
/// that share the same physical download (`downloadId`).
///
/// Sonarr season packs surface as one queue entry per expected episode,
/// even though the download itself is one torrent/nzb. Grouping by
/// `downloadId` matches what the user sees in their download client and
/// reduces the noise of N near-identical rows for one file.
enum QueueRowEntry: Identifiable {
    case single(QueueItem)
    case group(QueueGroup)

    var id: String {
        switch self {
        case .single(let item): return "single.\(item.id)"
        case .group(let g): return "group.\(g.id)"
        }
    }
}

struct QueueGroup: Identifiable, Equatable {
    /// The shared downloadId.
    let id: String
    /// Members in their original order.
    let items: [QueueItem]

    var representative: QueueItem { items[0] }
    var memberCount: Int { items.count }
}

enum QueueGrouping {
    /// Buckets items by `downloadId`. Items with no downloadId, or whose
    /// bucket has only one member, stay as `.single`. Order is preserved by
    /// each bucket's first occurrence in `items`.
    static func group(_ items: [QueueItem]) -> [QueueRowEntry] {
        // First pass: bucket index by downloadId, preserve first-seen order.
        var buckets: [String: [QueueItem]] = [:]
        var orderedKeys: [String] = []
        var keylessSinglesInOrder: [(index: Int, item: QueueItem)] = []

        for (index, item) in items.enumerated() {
            guard let key = item.downloadId, !key.isEmpty else {
                keylessSinglesInOrder.append((index, item))
                continue
            }
            if buckets[key] == nil { orderedKeys.append(key) }
            buckets[key, default: []].append(item)
        }

        // Second pass: walk the original input, emitting each bucket once at
        // its first occurrence, and emitting keyless items inline.
        var emitted = Set<String>()
        var result: [QueueRowEntry] = []
        for item in items {
            if let key = item.downloadId, !key.isEmpty {
                guard !emitted.contains(key) else { continue }
                emitted.insert(key)
                let members = buckets[key] ?? []
                if members.count == 1 {
                    result.append(.single(members[0]))
                } else {
                    result.append(.group(QueueGroup(id: key, items: members)))
                }
            } else {
                result.append(.single(item))
            }
        }
        return result
    }
}
