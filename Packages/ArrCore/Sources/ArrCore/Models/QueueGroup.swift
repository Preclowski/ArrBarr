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
public enum QueueRowEntry: Identifiable, Equatable {
    case single(QueueItem)
    case group(QueueGroup)

    public var id: String {
        switch self {
        case .single(let item): return "single.\(item.id)"
        case .group(let g): return "group.\(g.id)"
        }
    }

    /// The item that stands for this entry in aggregate contexts (a pack's
    /// members share size/progress, so its representative is the whole pack).
    var representativeItem: QueueItem {
        switch self {
        case .single(let item): return item
        case .group(let g): return g.representative
        }
    }

    /// Every underlying queue item.
    var allItems: [QueueItem] {
        switch self {
        case .single(let item): return [item]
        case .group(let g): return g.items
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

/// User preference for the by-title layer on top of the queue list.
/// `off` renders the flat list; the other two group same-title entries and
/// differ only in the default disclosure state.
public enum QueueTitleGroupingMode: String, CaseIterable, Sendable {
    case off, collapsed, expanded
}

/// A visual container bundling every queue entry of one title (series /
/// movie / album). Unlike the old removed "virtual bundles", this never
/// merges downloads into one row — its children are the real entries, each
/// with its own controls; the container only adds a collapsible header.
public struct QueueTitleGroup: Identifiable, Equatable {
    /// Stable identity — the shared title key of every member (survives
    /// members joining/leaving, so disclosure state can be keyed on it).
    public let id: String
    /// Members in their original queue order (singles and season packs).
    let entries: [QueueRowEntry]

    var representative: QueueItem { entries[0].representativeItem }
    /// Number of physical downloads (a season pack counts as 1).
    var downloadCount: Int { entries.count }
    var allItems: [QueueItem] { entries.flatMap(\.allItems) }

    /// Size-weighted completion across every member — honest only because
    /// the header also shows the download count, so the bar reads as "the
    /// batch as a whole", never as one download's progress.
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
}

/// A row in the queue list after the optional by-title pass: either a
/// pass-through entry or a title group wrapping ≥2 of them.
public enum QueueDisplayRow: Identifiable {
    case entry(QueueRowEntry)
    case titleGroup(QueueTitleGroup)

    public var id: String {
        switch self {
        case .entry(let e): return e.id
        case .titleGroup(let g): return "title.\(g.id)"
        }
    }
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

    /// Identity a queue item groups under for the by-title pass. Prefers the
    /// arr entity id (Sonarr series / Radarr movie / Lidarr album); falls back
    /// to the normalized display title for rows that lack one. Prefixed with
    /// the source so ids never collide across arrs.
    static func titleKey(for item: QueueItem) -> String {
        if let entityId = item.entityId {
            return "\(item.source.rawValue).id.\(entityId)"
        }
        return "\(item.source.rawValue).title.\(item.title.lowercased())"
    }

    /// Second grouping pass: bundle entries sharing a title key into a
    /// `QueueTitleGroup`. Only buckets with ≥2 entries group — singletons pass
    /// through untouched, so a typical queue renders exactly as before. The
    /// group takes the list position of its first member (the best-ranked one
    /// under the incoming order).
    public static func groupByTitle(_ entries: [QueueRowEntry]) -> [QueueDisplayRow] {
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
        // Second pass materializes each group with its full member list —
        // placeholders were appended at first-occurrence position above.
        return result.map { row in
            if case .titleGroup(let g) = row, let members = buckets[g.id] {
                return .titleGroup(QueueTitleGroup(id: g.id, entries: members))
            }
            return row
        }
    }
}
