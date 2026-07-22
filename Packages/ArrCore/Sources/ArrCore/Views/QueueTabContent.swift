import SwiftUI

struct QueueTabContent: View {
    var viewModel: QueueViewModel
    var searchViewModel: SearchViewModel
    @EnvironmentObject var configStore: ConfigStore

    @Binding var queueFilter: String
    @Binding var queueScope: QueueItem.Source?
    var queueFilterFocused: FocusState<Bool>.Binding
    @Binding var detailItem: QueueItem?
    @Binding var historySource: QueueItem.Source?
    @Binding var searchResult: SearchResult?
    /// Queue multi-select mode — owned by PopoverContentView (toggled from its
    /// "⋯" menu), threaded down to the native-`List` queue.
    @Binding var selecting: Bool

    private var sonarrConfigured: Bool { configStore.sonarr.isVisible }
    private var radarrConfigured: Bool { configStore.radarr.isVisible }
    private var lidarrConfigured: Bool { configStore.lidarr.isVisible }
    private var whisparrConfigured: Bool { configStore.whisparr.isVisible }
    private var searchAvailable: Bool { sonarrConfigured || radarrConfigured || lidarrConfigured || whisparrConfigured }

    var body: some View {
        queueContent
    }

    private var queueContent: some View {
        // Filter bar + scope chips float at the bottom (Apple's recent
        // search/Spotlight direction). ZStack and not `safeAreaInset`:
        // the inset modifier reacts to any identity change in the parent
        // tree — and the results branch below re-renders on every
        // keystroke — which re-mounts the TextField and drops focus
        // mid-typing. `ChatView` carries the long-form note.
        // Bar does double duty: filters live queue rows AND fires the
        // arr search for library / add-new hits (rendered as separate
        // sections below the queue when the filter is non-empty).
        ZStack(alignment: .bottom) {
            queueOrSearch
            queueFilterBar
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .onChange(of: queueFilter) { _, new in
            // Mirror the typed query into the shared SearchViewModel
            // so library / add-new hits update in lockstep with the
            // queue filter.
            searchViewModel.query = new
            searchViewModel.onQueryChange()
        }
        .onChange(of: queueScope) { _, _ in
            // Source-scope change doesn't reset the query — just
            // narrows which arr's results render. SearchViewModel
            // queries every configured arr in parallel and we filter
            // by scope at render time below.
        }
    }

    private var isFiltering: Bool {
        !queueFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Non-filtering → native `List` (QueueListView, native swipe). Filtering →
    /// search surface in a ScrollView. Initial load → spinner.
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
        } else if isFiltering {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    searchModeHeader
                    searchResults
                    // Only while nothing is rendered yet. With rows up this
                    // spinner sits below the fold and the user sees no
                    // loading state at all on a re-search — that case is
                    // covered inside QueueSearchResultsView instead.
                    if searchAvailable, searchViewModel.isSearching, !searchViewModel.hasResults {
                        loadingIndicator
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
                .padding(.bottom, 58)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
        } else {
            QueueListView(
                viewModel: viewModel,
                scope: queueScope,
                onShowDetail: { item in
                    withAnimation(.smooth(duration: 0.22)) { detailItem = item }
                },
                onNeedsYouTap: { needs in openNeedsYouQueue(needs) },
                onShowHistory: { source in historySource = source },
                selecting: $selecting
            )
            // Keep the last row clear of the floating filter bar.
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

    @ViewBuilder
    private var searchModeHeader: some View {
        HStack(spacing: 6) {
            FloatingBackButton { queueFilter = "" }
            Text("queue.searching.button", bundle: .module)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
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

    /// The one search-results surface. Queue rows that still match
    /// the substring filter sit at the top (live downloads with
    /// progress + action chrome — they don't flatten well into a
    /// search row), then a single merged + cross-source-sorted block
    /// of library + new hits. The library/new distinction is read
    /// per-row from the trailing affordance: chevron + InLibraryBadge
    /// for already-owned, `+` for addable. No section divider; this
    /// IS the search result list.
    @ViewBuilder
    private var searchResults: some View {
        // Delegates to the shared surface so macOS and iOS render search
        // identically. Scope chips still narrow via `queueScope`.
        QueueSearchResultsView(
            viewModel: viewModel,
            searchViewModel: searchViewModel,
            scope: queueScope,
            onSelectQueueItem: { detailItem = $0 },
            onSelectAddResult: { searchResult = $0 }
        )
    }

    private var queueFilterBar: some View {
        // Clean glass capsule — same `.glassyFloatingBar()` chrome as
        // the tab cluster above, so the bar reads as the same control
        // surface family. Loading spinner replaces the leading icon
        // while a fresh search query is in flight (arr lookups are
        // ~200-500ms each, the spinner saves a "is anything
        // happening?" moment of doubt). Critically inline-in-the-bar
        // and not just bottom-of-list — once results render they push
        // any bottom loader below the fold, so on the *second* search
        // the user gets no visible feedback unless we anchor the
        // spinner here.
        HStack(spacing: 8) {
            // Fixed-size ZStack slot — swapping the leading icon via
            // if/else used to shift the TextField by ~1pt because
            // ProgressView and the SF magnifyingglass don't render
            // at identical intrinsic widths. Both layers always
            // exist; only opacity changes, so the layout doesn't
            // twitch while typing.
            let showSpinner = searchAvailable && searchViewModel.isSearching && isFiltering
            ZStack {
                Image(systemName: "magnifyingglass")
                    .scaledFont(size: 15, weight: .medium)
                    .foregroundStyle(.tertiary)
                    .opacity(showSpinner ? 0 : 1)
                ProgressView()
                    .controlSize(.small)
                    .opacity(showSpinner ? 1 : 0)
            }
            .frame(width: 15, height: 15)
            .animation(.easeInOut(duration: 0.12), value: showSpinner)
            TextField("", text: $queueFilter, prompt:
                Text("queue.filterQueue.button", bundle: .module)
            )
            .scaledFont(size: 14)
            .textFieldStyle(.plain)
            .focused(queueFilterFocused)
            if !queueFilter.isEmpty {
                Button { queueFilter = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 14)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("queue.clearFilter.button", bundle: .module))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isFiltering)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Capsule())
        .onTapGesture { queueFilterFocused.wrappedValue = true }
        .glassyFloatingBar(focused: queueFilterFocused.wrappedValue)
    }

}

