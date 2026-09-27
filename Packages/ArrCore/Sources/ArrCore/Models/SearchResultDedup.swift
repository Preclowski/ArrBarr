import Foundation

/// Drops only the lookup rows the host already shows locally. Owned titles the local match
/// missed must stay: hiding one reads as "you don't own it".
nonisolated enum SearchResultDedup {
    static func removingLocalDuplicates(
        results: [SearchResult],
        localHits: [LocalHit]
    ) -> [SearchResult] {
        guard !localHits.isEmpty else { return results }
        let keys = Set(localHits.flatMap(\.ownershipKeys))
        return results.filter { result in
            guard let arrId = result.inLibraryArrId else { return true }
            return !keys.contains(OwnershipKey(source: result.source, arrId: arrId))
        }
    }
}
