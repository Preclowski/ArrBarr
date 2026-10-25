import Foundation

/// Rows the app already knows about, handed to the search surface: a live download or an owned title.
/// The same context on every tab.
nonisolated public enum LocalHit: Identifiable {
    case queue(QueueRowEntry)
    /// Several downloads of one series, shown as the series.
    case queueSeries(QueueTitleGroup)
    case library(LibraryEntry)

    public var id: String {
        switch self {
        case .queue(let entry):   return "queue.\(entry.id)"
        case .queueSeries(let g): return "queueSeries.\(g.id)"
        case .library(let entry): return "library.\(entry.id)"
        }
    }

    /// A queue group answers for every item it packs, so the series row underneath would be a duplicate.
    var ownershipKeys: [OwnershipKey] {
        switch self {
        case .queue(let entry):
            return entry.allItems.compactMap { item in
                item.entityId.map { OwnershipKey(source: item.source, arrId: $0) }
            }
        case .queueSeries(let group):
            return group.allItems.compactMap { item in
                item.entityId.map { OwnershipKey(source: item.source, arrId: $0) }
            }
        case .library(let entry):
            return [OwnershipKey(source: entry.source, arrId: entry.arrId)]
        }
    }
}

/// Arr record ids only mean something within one arr: without the source, Radarr #42 would hide Sonarr #42.
nonisolated struct OwnershipKey: Hashable, Sendable {
    let source: QueueItem.Source
    let arrId: Int

    init(source: QueueItem.Source, arrId: Int) {
        self.source = source
        self.arrId = arrId
    }
}

nonisolated public extension LocalHit {
    /// Libraries not loaded yet contribute nothing; the lookup rows still carry their ownership badge.
    @MainActor
    static func hits(queue: QueueViewModel,
                     library: LibraryViewModel,
                     sources: [QueueItem.Source],
                     query: String) -> [LocalHit] {
        let queueRows = queueHits(viewModel: queue, sources: sources, query: query)
        guard !TitleMatch.fold(query).isEmpty else { return queueRows }
        let owned = Set(queueRows.flatMap(\.ownershipKeys))
        let libraryRows = sources.flatMap { source -> [LocalHit] in
            guard let entries = library.entries[source] else { return [] }
            return TitleMatch.indexedFilter(entries, query: query, index: \.searchIndex)
                .filter { !owned.contains(OwnershipKey(source: $0.source, arrId: $0.arrId)) }
                .map(LocalHit.library)
        }
        return queueRows + libraryRows
    }

    /// Folding per keystroke is fine: queue lists are tens of rows, not thousands.
    @MainActor
    static func queueHits(viewModel: QueueViewModel,
                          sources: [QueueItem.Source],
                          query: String) -> [LocalHit] {
        // A query with no letters or digits folds to nothing, which the matcher treats as keep-everything.
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
            return queueRows(matched, source: source)
        }
    }

    /// A series answers once, however many of its episodes matched.
    static func queueRows(_ matched: [QueueItem], source: QueueItem.Source) -> [LocalHit] {
        guard source == .sonarr else { return matched.map { .queue(.single($0)) } }
        return QueueGrouping.groupBySeries(QueueGrouping.group(matched)).map { entries in
            entries.count == 1
                ? .queue(entries[0])
                : .queueSeries(QueueTitleGroup(id: QueueGrouping.seriesKey(for: entries[0].representativeItem), entries: entries))
        }
    }
}
