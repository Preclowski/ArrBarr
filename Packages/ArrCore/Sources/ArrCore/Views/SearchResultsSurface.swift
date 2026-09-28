import SwiftUI
import MediaKit

/// The one search-results surface for the Queue and Library tabs on both
/// platforms; hosts differ only in `localHits`, which lookup rows are deduped against.
struct SearchResultsSurface: View {
    var searchVM: SearchViewModel
    var localHits: [LocalHit]
    /// Never called by hosts without queue rows (the Library tab).
    var onSelectQueueItem: (QueueItem) -> Void = { _ in }
    let onSelectAddResult: (SearchResult) -> Void
    var onSelectPerson: (PersonRef) -> Void = { _ in }

    var body: some View {
        let lookupRows = SearchRelevance.sortedByRelevance(
            SearchResultDedup.removingLocalDuplicates(
                results: allLookupResults, localHits: localHits),
            input: searchVM.parsedInput
        )
        // Keep the previous rows while refining so typing doesn't flicker to a spinner.
        let reloading = searchVM.isSearching && !lookupRows.isEmpty

        VStack(alignment: .leading, spacing: 0) {
            // Lazy: a broad query can yield hundreds of local hits.
            LazyVStack(spacing: 2) {
                ForEach(localHits) { hit in
                    localRow(hit)
                }
            }
            // In people mode the arr clients are gated off, so these are the whole result.
            if !searchVM.peopleResults.isEmpty {
                VStack(spacing: 2) {
                    ForEach(searchVM.peopleResults) { person in
                        personRow(person)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                // A full-name query means the person is the answer, so it leads; a single
                // token stays a footnote under the titles.
                if let starring = searchVM.starring, starring.isPrimary {
                    starringSection(starring)
                }
                ForEach(lookupRows) { r in
                    SearchResultRow(result: r) { route(r) }
                }
                if let starring = searchVM.starring, !starring.isPrimary {
                    starringSection(starring)
                }
            }
            .lookupReloadDim(reloading)

            // Without it a settled empty search reads as loading or broken.
            if showsEmptyState {
                SearchLookupEmptyState(errorMessage: searchVM.errorMessage)
            }
        }
    }

    private var allLookupResults: [SearchResult] {
        searchVM.radarrResults + searchVM.sonarrResults
            + searchVM.lidarrResults + searchVM.whisparrResults
    }

    /// `DetailRequest.tap` owns the Lidarr artist-vs-album branch.
    private func route(_ r: SearchResult) {
        if r.inLibraryArrId != nil {
            DetailRequest.tap(r)
        } else {
            onSelectAddResult(r)
        }
    }

    /// A queue hit keeps its download chrome; a library hit wears the owned-title row.
    @ViewBuilder
    private func localRow(_ hit: LocalHit) -> some View {
        switch hit {
        case .queue(let entry):
            let item = entry.representativeItem
            QueueSearchRow(item: item) { onSelectQueueItem(item) }
        case .library(let entry):
            let result = SearchResult(libraryEntry: entry)
            SearchResultRow(result: result) { DetailRequest.tap(result) }
        }
    }

    /// An in-flight search is the host's loading indicator, not empty.
    private var showsEmptyState: Bool {
        guard searchVM.isActive, !searchVM.isSearching else { return false }
        guard !searchVM.hasResults, searchVM.starring == nil else { return false }
        return localHits.isEmpty
    }

    // MARK: - People

    private func personRef(_ p: TMDBPerson) -> PersonRef {
        PersonRef(tmdbId: p.id, name: p.name, profilePath: p.profilePath)
    }

    private func personRow(_ p: TMDBPerson) -> some View {
        PosterMetadataRow(
            posterURL: p.profileURL,
            posterAPIKey: nil,
            posterSize: CGSize(width: 30, height: 30),
            posterCornerRadius: 15,
            posterBlurred: false,
            posterFallbackSymbol: "person.fill",
            title: p.name,
            metadataSegments: p.knownForDepartment.map { [$0] } ?? [],
            onTap: { onSelectPerson(personRef(p)) }
        ) { EmptyView() }
    }

    @ViewBuilder
    private func starringSection(_ section: SearchViewModel.StarringSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Leading the results, the person gets the full People row; the caption reads as a footer.
            if section.isPrimary {
                personRow(section.person)
            } else {
                Button { onSelectPerson(personRef(section.person)) } label: {
                    HStack(spacing: 8) {
                        RemotePoster(
                            url: section.person.profileURL, apiKey: nil, tier: .icon,
                            size: CGSize(width: 22, height: 22), cornerRadius: 11,
                            fallbackSymbol: "person.fill"
                        )
                        Text(String.localizedStringWithFormat(
                            NSLocalizedString(section.person.filmographyCaptionKey, bundle: .module, comment: ""),
                            section.person.name))
                            .scaledFont(size: 11, weight: .semibold)
                            .foregroundStyle(.secondary)
                        LinkChevron(size: 9)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }

            ForEach(section.titles) { r in
                SearchResultRow(result: r) { route(r) }
            }
        }
    }
}
