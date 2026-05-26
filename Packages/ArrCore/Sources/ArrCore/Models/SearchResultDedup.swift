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
}
