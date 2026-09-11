import SwiftUI

/// The one search-results surface, shared by the Queue tab, the Library tab
/// and both platforms.
///
/// Section order: local hits → people rows → primary "Starring X" → one
/// merged, relevance-sorted block of library + add-new lookup rows → secondary
/// "Starring X" → settled-empty state.
///
/// `localHits` is the ONLY thing the hosts differ in: the Queue tab hands in
/// its live download rows, the Library tab the browsed library's matches. They
/// arrive already filtered and ordered by the host, render at full opacity
/// (they are recomputed per keystroke, so they are never stale), and the
/// lookup rows below them are deduped against them.
///
/// Narrowing is `searchVM.scope` and nothing else: lookup results for an
/// unconfigured arr are already empty, and `SearchScope.allows` gates the
/// clients before a request is made.
struct SearchResultsSurface: View {
    var searchVM: SearchViewModel
    /// Host-supplied local context, already filtered and ordered.
    var localHits: [LocalHit]
    /// Tap on a live queue row (drills into detail).
    let onSelectQueueItem: (QueueItem) -> Void
    /// Tap on an add-new (not-in-library) result.
    let onSelectAddResult: (SearchResult) -> Void
    /// Tap on a person row / "Starring X" — host pushes the person view.
    var onSelectPerson: (PersonRef) -> Void = { _ in }

    var body: some View {
        let lookupRows = SearchRelevance.sortedByRelevance(
            SearchResultDedup.removingLocalDuplicates(
                results: allLookupResults, localHits: localHits),
            input: searchVM.parsedInput
        )
        // Refining a query ("matrix" → "matrix 2") keeps the previous rows up
        // while the new lookups run — deliberately, so typing doesn't flicker
        // list ↔ spinner. See `lookupReloadDim` for what those stale rows
        // wear meanwhile.
        let reloading = searchVM.isSearching && !lookupRows.isEmpty

        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 2) {
                ForEach(localHits) { hit in
                    localRow(hit)
                }
            }
            // People rows (people scope / `person:` prefix) sit above the
            // titles — in that mode the arr clients are gated off, so
            // `lookupRows` is empty and these are the whole result.
            if !searchVM.peopleResults.isEmpty {
                VStack(spacing: 2) {
                    ForEach(searchVM.peopleResults) { person in
                        personRow(person)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                // "Starring X" — an all-scope person match and their top
                // titles. A full-name query ("rhea seehorn") means the person
                // IS the result, so that section leads; a single-token match
                // ("hanks") stays a footnote under the titles it annotates.
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

            // Settled empty search: every bucket came back empty and the
            // lookups are done. Without this the surface is just blank rows
            // of nothing, which reads as "still loading" or "broken".
            if showsEmptyState {
                SearchLookupEmptyState(errorMessage: searchVM.errorMessage)
            }
        }
    }

    private var allLookupResults: [SearchResult] {
        searchVM.radarrResults + searchVM.sonarrResults
            + searchVM.lidarrResults + searchVM.whisparrResults
    }

    /// Owned → the detail; addable → the add panel. `DetailRequest.tap` owns
    /// the Lidarr artist-vs-album branch.
    private func route(_ r: SearchResult) {
        if r.inLibraryArrId != nil {
            DetailRequest.tap(r)
        } else {
            onSelectAddResult(r)
        }
    }

    /// A queue hit keeps its download chrome (progress, actions — it doesn't
    /// flatten into a search row); a library hit is an owned title and wears
    /// the same row every other owned result does, routed the same way.
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

    /// True when the query has settled with nothing to show in ANY bucket —
    /// no local hits, no lookup rows, no people. Requires a live query (an
    /// empty field legitimately shows nothing) and no in-flight search (that
    /// case is the host's loading indicator).
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
            // Leading the results, the person gets the same full-weight row the
            // People scope uses — the muted "Starring X" caption is sized to
            // annotate titles above it, and reads as a footer when it's the
            // answer to the query.
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
