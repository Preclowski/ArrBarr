import Foundation

/// A row in the queue UI: either a single QueueItem, or a group of items
/// rendered as one row.
///
/// Two flavours of group exist (see `QueueGroup.Kind`):
///   - `.pack` — Sonarr season packs: one physical download whose Sonarr
///     queue surfaces as N expected-episode entries sharing one `downloadId`.
///   - `.virtual` — N independent downloads (distinct `downloadId`s) that
///     happen to share series, season, release group, quality, and custom
///     formats. The user's manually-assembled "season" of separate
///     per-episode releases reads as one bundle even though the download
///     client sees N torrents.
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
    enum Kind: Equatable {
        /// All members share one `downloadId` — one physical download.
        case pack
        /// Members are independent downloads sharing release-fingerprint
        /// metadata; actions must fan out to every member.
        case virtual
    }

    /// Stable identity for the row.
    /// - For `.pack`: the shared `downloadId`.
    /// - For `.virtual`: a synthetic key derived from the fingerprint, so
    ///   the row keeps the same identity across refreshes as long as the
    ///   bundle composition is stable.
    let id: String
    /// Members in their original order.
    let items: [QueueItem]
    let kind: Kind

    var representative: QueueItem { items[0] }
    var memberCount: Int { items.count }
}

enum QueueGrouping {
    /// Minimum number of episodes a virtual bundle needs before we collapse
    /// it. Two near-identical rows is "I happened to grab two episodes" —
    /// not noisy enough to hide. Three starts to look intentional.
    static let virtualGroupMinimumMemberCount = 3

    /// Two-pass grouping:
    ///   1. Bucket by `downloadId` — items in a bucket of ≥2 form a `.pack`
    ///      group (true season pack or any shared physical download).
    ///   2. From the leftover Sonarr singletons, bucket by
    ///      (series title, season number, release group, quality, sorted
    ///      custom formats). Buckets with ≥`virtualGroupMinimumMemberCount`
    ///      members form a `.virtual` group; smaller buckets stay singletons.
    /// Order is preserved by each bucket's first occurrence.
    static func group(_ items: [QueueItem]) -> [QueueRowEntry] {
        // Pass 1 — downloadId buckets (real packs).
        var packBuckets: [String: [QueueItem]] = [:]
        for item in items {
            guard let key = item.downloadId, !key.isEmpty else { continue }
            packBuckets[key, default: []].append(item)
        }

        // Pass 2 — fingerprint buckets over leftovers from pass 1.
        // An item is a "leftover" if its downloadId bucket has only one
        // member (or it has no downloadId at all).
        var virtualBuckets: [String: [QueueItem]] = [:]
        for item in items {
            guard isVirtualEligible(item, packBuckets: packBuckets),
                  let fp = virtualFingerprint(for: item)
            else { continue }
            virtualBuckets[fp, default: []].append(item)
        }
        // Drop buckets below threshold so they don't get collapsed.
        virtualBuckets = virtualBuckets.filter { $0.value.count >= virtualGroupMinimumMemberCount }

        // Emit pass — walk input once, dispatching each item to the row it
        // belongs to and emitting groups at the position of their first
        // member so order is stable.
        var result: [QueueRowEntry] = []
        var emittedPacks = Set<String>()
        var emittedVirtuals = Set<String>()
        for item in items {
            if let key = item.downloadId, !key.isEmpty,
               let members = packBuckets[key], members.count >= 2 {
                if emittedPacks.insert(key).inserted {
                    result.append(.group(QueueGroup(id: key, items: members, kind: .pack)))
                }
                continue
            }
            if let fp = virtualFingerprint(for: item),
               let members = virtualBuckets[fp] {
                if emittedVirtuals.insert(fp).inserted {
                    result.append(.group(QueueGroup(id: "virtual.\(fp)", items: members, kind: .virtual)))
                }
                continue
            }
            result.append(.single(item))
        }
        return result
    }

    private static func isVirtualEligible(_ item: QueueItem, packBuckets: [String: [QueueItem]]) -> Bool {
        guard item.source == .sonarr else { return false }
        guard let key = item.downloadId, !key.isEmpty else { return true }
        return (packBuckets[key]?.count ?? 0) < 2
    }

    /// Fingerprint that decides whether two Sonarr items belong to the same
    /// virtual season bundle. Returns nil when any required component is
    /// missing — without a stable fingerprint we can't safely group.
    private static func virtualFingerprint(for item: QueueItem) -> String? {
        guard item.source == .sonarr else { return nil }
        guard let group = item.releaseGroup, !group.isEmpty else { return nil }
        guard let quality = item.quality, !quality.isEmpty else { return nil }
        guard let season = parseSeason(from: item.subtitle) else { return nil }
        let title = item.title
        guard !title.isEmpty else { return nil }
        let cfs = item.customFormats.sorted().joined(separator: "|")
        return "\(title)|S\(season)|\(group)|\(quality)|\(cfs)"
    }

    private static func parseSeason(from subtitle: String?) -> Int? {
        guard let s = subtitle else { return nil }
        let pattern = "S(\\d+)E\\d+"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let range = Range(match.range(at: 1), in: s)
        else { return nil }
        return Int(s[range])
    }
}
