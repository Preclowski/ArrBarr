import Foundation

/// De-duplication between what the HOST already shows locally (live queue rows
/// or the browsed library) and the arr-lookup rows rendered under them. A row
/// the user can already see must not repeat below it — but ONLY that row drops.
///
/// Add-new hits, titles owned by a *different* arr, and owned titles the local
/// match missed all stay: hiding an owned title reads as "you don't own it",
/// the one wrong answer this app must never give.
nonisolated public enum SearchResultDedup {
    public static func removingLocalDuplicates(
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
