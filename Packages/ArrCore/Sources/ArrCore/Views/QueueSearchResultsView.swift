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
    /// Tap on a person row / "Full filmography" — host pushes the person view.
    var onSelectPerson: (PersonRef) -> Void = { _ in }

    var body: some View {
        let queueRows = scopedSources.flatMap { entries(for: $0) }
        let rawLibrary = scopedSources.flatMap { libraryResults(for: $0) }
        let library = SearchResultDedup.removingQueueDuplicates(
            libraryResults: rawLibrary,
            queueRows: queueRows
        )
        let newOnes = scopedSources.flatMap { newResults(for: $0) }
        let combined = SearchRelevance.sortedByRelevance(library + newOnes, input: searchViewModel.parsedInput)
        // Refining a query ("matrix" → "matrix 2") keeps the previous rows up
        // while the new lookups run — deliberately, so typing doesn't flicker
        // list ↔ spinner. But those rows still answer the *old* query, and a
        // loader appended under them lands below the fold. Fade them and float
        // a spinner over their top edge instead: no layout shift, and a
        // re-search always reads as "these are being replaced".
        let reloading = searchViewModel.isSearching && !combined.isEmpty

        VStack(alignment: .leading, spacing: 0) {
            // Queue rows filter locally on every keystroke, so they are never
            // stale — they stay at full opacity while the lookups catch up.
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
            // People rows (people scope / `person:` prefix) sit above the
            // titles — in that mode the arr clients are gated off, so `combined`
            // is empty and these are the whole result.
            if !searchViewModel.peopleResults.isEmpty {
                VStack(spacing: 2) {
                    ForEach(searchViewModel.peopleResults) { person in
                        personRow(person)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                // "Starring X" — an all-scope person match and their top
                // titles. A full-name query ("rhea seehorn") means the person
                // IS the result, so that section leads; a single-token match
                // ("hanks") stays a footnote under the titles it annotates.
                if let starring = searchViewModel.starring, starring.isPrimary {
                    starringSection(starring)
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
                if let starring = searchViewModel.starring, !starring.isPrimary {
                    starringSection(starring)
                }
            }
            .opacity(reloading ? 0.3 : 1)
            .overlay(alignment: .top) {
                if reloading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 14)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: reloading)

            // Settled empty search: every bucket came back empty and the
            // lookups are done. Without this the surface is just blank rows
            // of nothing, which reads as "still loading" or "broken".
            // An error state is NOT an empty state — when a lookup failed
            // the message says so instead of pretending there are no hits.
            if showsEmptyState {
                VStack(spacing: 8) {
                    Image(systemName: searchViewModel.errorMessage == nil
                          ? "magnifyingglass" : "exclamationmark.triangle")
                        .scaledFont(size: 22)
                        .foregroundStyle(.tertiary)
                    if let error = searchViewModel.errorMessage {
                        Text("search.error.title", bundle: .module)
                            .scaledFont(size: 13, weight: .semibold)
                        Text(error)
                            .scaledFont(size: 11)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("search.noResults.title", bundle: .module)
                            .scaledFont(size: 13, weight: .semibold)
                        Text("search.noResults.message", bundle: .module)
                            .scaledFont(size: 11)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
            }
        }
    }

    /// True when the query has settled with nothing to show in ANY bucket —
    /// no queue matches, no lookup hits, no people. Requires a non-empty
    /// query (an empty field legitimately shows nothing) and no in-flight
    /// search (that case is the host's loading indicator).
    private var showsEmptyState: Bool {
        let query = searchViewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !searchViewModel.isSearching else { return false }
        guard !searchViewModel.hasResults, searchViewModel.starring == nil else { return false }
        // Local queue matches still count as results.
        return scopedSources.allSatisfy { entries(for: $0).isEmpty }
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
                            NSLocalizedString("search.starring", bundle: .module, comment: ""), section.person.name))
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
                SearchResultRow(result: r) {
                    if r.inLibraryArrId != nil { DetailRequest.tap(r) } else { onSelectAddResult(r) }
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
