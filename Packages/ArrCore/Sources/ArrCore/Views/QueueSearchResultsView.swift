import SwiftUI

/// Unified search-results surface shared by the macOS popover and iOS.
///
/// Typing filters the live queue **instantly** (local substring match on
/// title / episode / subtitle) and shows those rows on top, then a single
/// merged, relevance-sorted block of library + add-new hits from the arr
/// lookups underneath. Both platforms render this exact view so search
/// behaves identically everywhere.
struct QueueSearchResultsView: View {
    var viewModel: QueueViewModel
    var searchViewModel: SearchViewModel
    @EnvironmentObject var configStore: ConfigStore

    /// Narrow to a single arr (macOS scope chips). nil = every configured arr.
    var scope: QueueItem.Source? = nil
    /// Tap on a queue row (drills into detail).
    let onSelectQueueItem: (QueueItem) -> Void
    /// Tap on an add-new (not-in-library) result.
    let onSelectAddResult: (SearchResult) -> Void

    var body: some View {
        let queueRows = scopedSources.flatMap { entries(for: $0) }
        let rawLibrary = scopedSources.flatMap { libraryResults(for: $0) }
        let library = SearchResultDedup.removingQueueDuplicates(
            libraryResults: rawLibrary,
            queueRows: queueRows
        )
        let newOnes = scopedSources.flatMap { newResults(for: $0) }
        let combined = SearchRelevance.sortedByRelevance(library + newOnes, input: searchViewModel.parsedInput)

        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 2) {
                ForEach(queueRows) { entry in
                    switch entry {
                    case .single(let item):
                        QueueSearchRow(item: item) { onSelectQueueItem(item) }
                    case .group(let group):
                        QueueSearchRow(item: group.representative) { onSelectQueueItem(group.representative) }
                    }
                }
            }
            ForEach(combined) { r in
                SearchResultRow(result: r) {
                    if r.inLibraryArrId != nil {
                        DetailRequest.tap(r)
                    } else {
                        onSelectAddResult(r)
                    }
                }
            }
        }
    }

    // MARK: - Source / filtering helpers (mirror QueueTabContent)

    private func isConfigured(_ source: QueueItem.Source) -> Bool {
        switch source {
        case .sonarr:   return configStore.sonarr.isVisible
        case .radarr:   return configStore.radarr.isVisible
        case .lidarr:   return configStore.lidarr.isVisible
        case .whisparr: return configStore.whisparr.isVisible
        }
    }

    private var configuredSources: [QueueItem.Source] {
        QueueItem.Source.allCases.filter { isConfigured($0) }
    }

    private var scopedSources: [QueueItem.Source] {
        scope.map { [$0] } ?? configuredSources
    }

    private func matchesFilter(_ item: QueueItem) -> Bool {
        let q = searchViewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return true }
        let haystack = [item.title, item.episodeTitle ?? "", item.subtitle ?? ""]
            .joined(separator: " ")
        return haystack.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func entries(for source: QueueItem.Source) -> [QueueRowEntry] {
        let raw = viewModel.items(for: source).filter(matchesFilter)
        switch source {
        case .sonarr: return QueueGrouping.group(raw)
        default:      return raw.map { .single($0) }
        }
    }

    private func libraryResults(for source: QueueItem.Source) -> [SearchResult] {
        rawSearchResults(for: source).filter { $0.inLibraryArrId != nil }
    }

    private func newResults(for source: QueueItem.Source) -> [SearchResult] {
        rawSearchResults(for: source).filter { $0.inLibraryArrId == nil }
    }

    private func rawSearchResults(for source: QueueItem.Source) -> [SearchResult] {
        switch source {
        case .radarr:   return searchViewModel.radarrResults
        case .sonarr:   return searchViewModel.sonarrResults
        case .lidarr:   return searchViewModel.lidarrResults
        case .whisparr: return searchViewModel.whisparrResults
        }
    }
}
