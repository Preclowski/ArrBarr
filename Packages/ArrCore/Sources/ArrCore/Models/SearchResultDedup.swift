import Foundation

/// De-duplication between the IN QUEUE and IN LIBRARY sections of
/// the status-grouped queue-search layout. A title that's actively
/// downloading is technically also in the library — surfacing it
/// twice (once per section) is the kind of double-encoding the
/// design explicitly avoids. Queue wins; library hit drops.
///
/// Callers pass single-source lists; matching is by `entityId` ↔
/// `inLibraryArrId`, source is implicit.
public enum SearchResultDedup {
    public static func removingQueueDuplicates(
        libraryResults: [SearchResult],
        queueRows: [QueueRowEntry]
    ) -> [SearchResult] {
        let queueEntityIds: Set<Int> = queueRows.reduce(into: Set<Int>()) { acc, entry in
            switch entry {
            case .single(let item):
                if let id = item.entityId { acc.insert(id) }
            case .group(let g):
                for item in g.items {
                    if let id = item.entityId { acc.insert(id) }
                }
            }
        }
        return libraryResults.filter { result in
            guard let id = result.inLibraryArrId else { return true }
            return !queueEntityIds.contains(id)
        }
    }

    /// De-duplication between the Library tab's cover grid (local alias
    /// matches for the browsed arr) and the arr-lookup rows appended under
    /// it. A row the grid already shows must not repeat below it — but
    /// ONLY that row drops. Add-new hits, titles owned by a *different*
    /// arr, and owned titles the local alias match missed all stay:
    /// hiding an owned title reads as "you don't own it", the one wrong
    /// answer this app must never give.
    ///
    /// `gridArrIds` are arr-internal record ids, which only mean anything
    /// within one arr — hence the `gridSource` gate before the id compare.
    public static func removingGridDuplicates(
        results: [SearchResult],
        gridSource: QueueItem.Source,
        gridArrIds: Set<Int>
    ) -> [SearchResult] {
        results.filter { result in
            guard result.source == gridSource, let id = result.inLibraryArrId else { return true }
            return !gridArrIds.contains(id)
        }
    }
}
