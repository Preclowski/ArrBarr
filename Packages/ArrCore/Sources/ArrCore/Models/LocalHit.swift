import Foundation

/// One row the HOST already knows about, handed to the search surface as its
/// local context. The tabs differ in exactly this: the Queue tab supplies live
/// download rows, the Library tab supplies owned titles from the browsed
/// library. Everything below this line looks and behaves identically.
public enum LocalHit: Identifiable {
    /// A live download — progress and action chrome, rendered by `QueueSearchRow`.
    case queue(QueueRowEntry)
    /// An owned title from the browsed library, rendered as an owned search row.
    case library(LibraryEntry)

    public var id: String {
        switch self {
        case .queue(let entry):   return "queue.\(entry.id)"
        case .library(let entry): return "library.\(entry.id)"
        }
    }

    /// Every `(source, arr record id)` this hit already answers for. A queue
    /// group answers for every item it packs — a season pack on screen means
    /// the series row underneath it would be a duplicate.
    var ownershipKeys: [OwnershipKey] {
        switch self {
        case .queue(let entry):
            return entry.allItems.compactMap { item in
                item.entityId.map { OwnershipKey(source: item.source, arrId: $0) }
            }
        case .library(let entry):
            return [OwnershipKey(source: entry.source, arrId: entry.arrId)]
        }
    }
}

/// Arr-internal record ids only mean anything within one arr, so the source
/// travels with the id. Without it, a Radarr movie #42 on screen would hide a
/// Sonarr series #42 from the results — the one wrong answer this app must
/// never give.
public struct OwnershipKey: Hashable, Sendable {
    public let source: QueueItem.Source
    public let arrId: Int

    public init(source: QueueItem.Source, arrId: Int) {
        self.source = source
        self.arrId = arrId
    }
}

public extension LocalHit {
    /// The Queue tab's local context: every configured source's live rows that
    /// still match the query, Sonarr's grouped into packs.
    ///
    /// Matching is `TitleMatch.indexedFilter` over a per-item fold of title +
    /// episode title + subtitle — the same matcher the library grid uses, so
    /// "wall e" finds WALL·E in a queue row too. Folding per keystroke is fine
    /// here: queue lists are tens of rows, not thousands.
    @MainActor
    static func queueHits(viewModel: QueueViewModel,
                          sources: [QueueItem.Source],
                          query: String) -> [LocalHit] {
        // A query with no letters or digits in it folds to nothing, and the
        // matcher answers that by keeping every candidate — the whole queue.
        guard !TitleMatch.fold(query).isEmpty else { return [] }
        return sources.flatMap { source -> [LocalHit] in
            let matched = TitleMatch.indexedFilter(
                viewModel.items(for: source),
                query: query,
                index: { item in
                    [item.title, item.episodeTitle ?? "", item.subtitle ?? ""]
                        .filter { !$0.isEmpty }
                        .map(TitleMatch.fold)
                        .joined(separator: "\n")
                }
            )
            let rows: [QueueRowEntry] = source == .sonarr
                ? QueueGrouping.group(matched)
                : matched.map { .single($0) }
            return rows.map(LocalHit.queue)
        }
    }
}
