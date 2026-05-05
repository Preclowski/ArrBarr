import Foundation

/// A row in the queue UI: either a single QueueItem, or a group of items
/// rendered as one row.
///
/// The only group flavour is `.pack` — Sonarr season packs where one
/// physical download surfaces in the queue as N expected-episode entries
/// sharing one `downloadId`. We collapse those because they really are
/// one thing: one progress bar, one pause, one delete.
///
/// We deliberately don't collapse independent same-series episodes that
/// merely share quality / release group / formats — those are N separate
/// downloads, and pretending they're one row meant the progress bar
/// became a weighted-by-size average and pause/resume secretly fanned
/// out to N actions. Each independent download now renders as its own
/// row, exactly like Radarr's movies do.
public enum QueueRowEntry: Identifiable {
    case single(QueueItem)
    case group(QueueGroup)

    public var id: String {
        switch self {
        case .single(let item): return "single.\(item.id)"
        case .group(let g): return "group.\(g.id)"
        }
    }
}

public struct QueueGroup: Identifiable, Equatable {
    /// Stable identity for the row — the shared `downloadId` of every
    /// member.
    public let id: String
    /// Members in their original order.
    let items: [QueueItem]

    var representative: QueueItem { items[0] }
    var memberCount: Int { items.count }
}

public enum QueueGrouping {
    /// Bucket Sonarr queue items by `downloadId`. Items in a bucket of ≥2
    /// form a `.pack` group (one physical download with multiple expected
    /// episodes). Singletons — including the previously "virtual"
    /// fingerprint-collapsed bundles — stay as their own rows.
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
}
