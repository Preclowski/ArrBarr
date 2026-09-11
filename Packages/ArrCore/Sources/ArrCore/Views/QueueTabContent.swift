import SwiftUI

struct QueueTabContent: View {
    var viewModel: QueueViewModel
    var searchViewModel: SearchViewModel
    @EnvironmentObject var configStore: ConfigStore

    var searchFieldFocused: FocusState<Bool>.Binding
    @Binding var detailItem: QueueItem?
    @Binding var historySource: QueueItem.Source?
    @Binding var searchResult: SearchResult?
    /// Queue multi-select mode — owned by PopoverContentView (toggled from its
    /// "⋯" menu), threaded down to the native-`List` queue.
    @Binding var selecting: Bool
    /// Person-view push from a search person row / "Starring X" section.
    @State private var personRef: PersonRef?

    private var configuredSources: [QueueItem.Source] {
        QueueItem.Source.allCases.filter { configStore.config(for: $0.serviceKind).isVisible }
    }

    private var searchAvailable: Bool { !configuredSources.isEmpty }

    var body: some View {
        // The capsule floats at the bottom (Apple's recent search/Spotlight
        // direction). ZStack and not `safeAreaInset`: the inset modifier reacts
        // to any identity change in the parent tree — and the results branch
        // re-renders on every keystroke — which re-mounts the TextField and
        // drops focus mid-typing. `ChatView` carries the long-form note.
        ZStack(alignment: .bottom) {
            queueOrSearch
            SearchCapsule(searchVM: searchViewModel, focused: searchFieldFocused)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
    }

    /// Non-searching → native `List` (QueueListView, native swipe). Searching →
    /// the shared takeover. Initial load → spinner.
    @ViewBuilder
    private var queueOrSearch: some View {
        if viewModel.isLoading {
            ScrollView {
                loadingIndicator
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .padding(.bottom, 58)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
        } else if searchViewModel.isActive {
            SearchTakeoverView(searchVM: searchViewModel, searchAvailable: searchAvailable) {
                searchResults
            }
        } else {
            QueueListView(
                viewModel: viewModel,
                onShowDetail: { item in
                    withAnimation(.smooth(duration: 0.22)) { detailItem = item }
                },
                onNeedsYouTap: { needs in openNeedsYouQueue(needs) },
                onShowHistory: { source in historySource = source },
                selecting: $selecting
            )
            // Keep the last row clear of the floating capsule.
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 58) }
        }
    }

    private var loadingIndicator: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("queue.loading.button", bundle: .module)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func openNeedsYouQueue(_ needs: NeedsYouItem) {
        // Non-arr connection issues (download client / AI) have no arr queue
        // page to open — the user fixes those in Settings.
        guard let source = needs.source else { return }
        let cfg = configStore.config(for: source.serviceKind)
        guard let url = ArrActivityURLBuilder.queueURL(forBase: cfg.baseURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return }
        PlatformURLOpener.open(url)
    }

    /// The one search-results surface. Live queue rows that still match sit at
    /// the top (downloads with progress + action chrome — they don't flatten
    /// into a search row), then a single merged, cross-source-sorted block of
    /// library + add-new hits. No section divider; this IS the result list.
    @ViewBuilder
    private var searchResults: some View {
        SearchResultsSurface(
            searchVM: searchViewModel,
            localHits: localHits,
            onSelectQueueItem: { detailItem = $0 },
            onSelectAddResult: { searchResult = $0 },
            onSelectPerson: { personRef = $0 }
        )
        .personDestination($personRef)
    }

    /// This tab's local context: the live queue, matched with the same folder
    /// the library grid uses (so "wall e" finds WALL·E here too).
    private var localHits: [LocalHit] {
        guard searchViewModel.isActive else { return [] }
        return LocalHit.queueHits(viewModel: viewModel,
                                  sources: configuredSources,
                                  query: searchViewModel.query)
    }
}
