import SwiftUI

struct QueueTabContent: View {
    @ObservedObject var viewModel: QueueViewModel
    @ObservedObject var searchViewModel: SearchViewModel
    @EnvironmentObject var configStore: ConfigStore

    @Binding var queueFilter: String
    @Binding var queueScope: QueueItem.Source?
    var queueFilterFocused: FocusState<Bool>.Binding
    @Binding var detailItem: QueueItem?
    @Binding var historySource: QueueItem.Source?
    @Binding var searchResult: SearchResult?
    @Binding var bannerCollapseTask: Task<Void, Never>?

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
        // search/Spotlight direction). Same ZStack-not-safeAreaInset
        // recipe as `SearchView` — see the comment there for why
        // safeAreaInset re-mounts the TextField on every keystroke.
        // Bar does double duty: filters live queue rows AND fires the
        // arr search for library / add-new hits (rendered as separate
        // sections below the queue when the filter is non-empty).
        ZStack(alignment: .bottom) {
            ScrollView {
                Group {
                    if viewModel.isLoading {
                        VStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading…", bundle: .module)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    } else {
                        // Search-mode header — back chevron + screen
                        // title ("Wyszukiwanie" in PL). Mirrors the
                        // DetailView header pattern so the user
                        // reads the search surface as a navigation
                        // level, not just a filtered queue.
                        if isFiltering {
                            HStack(spacing: 6) {
                                FloatingBackButton {
                                    queueFilter = ""
                                }
                                Text("Searching", bundle: .module)
                                    .scaledFont(size: 15, weight: .semibold)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                            .animation(.easeInOut(duration: 0.18), value: isFiltering)
                        }
                        queueBody
                    }
                }
                // Leave room for the floating bar so the last row
                // doesn't sit under it. ~58pt = bar (~38pt) + padding
                // (~20pt). Filters live INSIDE the bar now (right
                // gutter), so no extra reserved height for chips.
                .padding(.bottom, 58)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)

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

    private var configuredSources: [QueueItem.Source] {
        QueueItem.Source.allCases.filter { isConfigured($0) }
    }

    /// Sources covered by the current scope — narrowed to a single
    /// arr when the user picked one, otherwise every configured arr.
    /// Drives both the per-kind counts and the type-grouped rendering.
    private var scopedSources: [QueueItem.Source] {
        queueScope.map { [$0] } ?? configuredSources
    }

    /// Raw queue rows for a source matching the substring filter,
    /// pre-grouping. Used for both rendering (`entries(for:)` groups
    /// these for Sonarr packs) and per-kind counts.
    private func filteredQueueItems(for source: QueueItem.Source) -> [QueueItem] {
        viewModel.items(for: source).filter(matchesFilter)
    }

    /// Library hits for a source — search results that the arr
    /// already owns. Empty when the search hasn't fired yet.
    private func libraryResults(for source: QueueItem.Source) -> [SearchResult] {
        rawSearchResults(for: source).filter { $0.inLibraryArrId != nil }
    }

    /// Add-new candidates for a source — search results NOT in the
    /// arr's library.
    private func newResults(for source: QueueItem.Source) -> [SearchResult] {
        rawSearchResults(for: source).filter { $0.inLibraryArrId == nil }
    }

    /// Raw, unfiltered search results per source — counts need the
    /// un-narrowed pool.
    private func rawSearchResults(for source: QueueItem.Source) -> [SearchResult] {
        switch source {
        case .radarr:   return searchViewModel.radarrResults
        case .sonarr:   return searchViewModel.sonarrResults
        case .lidarr:   return searchViewModel.lidarrResults
        case .whisparr: return searchViewModel.whisparrResults
        }
    }


    @ViewBuilder
    private var queueBody: some View {
        if !isFiltering {
            // Default surface — per-arr queue sections, tonight /
            // needsYou banners. No search axis to encode yet.
            queueSections
        } else {
            // Search surface — queue rows that still match the
            // substring filter, then a single merged block of
            // library + new search hits sorted by relevance with
            // Bayesian-quality tie-breaking. No type/sort knobs:
            // search is keyword lookup with one right answer, the
            // Discover tab is where listing-style filters live.
            searchResults
        }
        // Centred loading state — fires whenever a search is in
        // flight. Same "Loading…" copy + spinner the dropped Search
        // tab used; keeps the in-window feedback (not just a tiny
        // spinner in the bar) so the user knows arr lookups are
        // actually running.
        if isFiltering, searchAvailable, searchViewModel.isSearching {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading…", bundle: .module)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
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
        let queueRows: [QueueRowEntry] = scopedSources.flatMap { entries(for: $0) }
        let rawLibrary = scopedSources.flatMap { libraryResults(for: $0) }
        let library = SearchResultDedup.removingQueueDuplicates(
            libraryResults: rawLibrary,
            queueRows: queueRows
        )
        let newOnes = scopedSources.flatMap { newResults(for: $0) }
        let combined = SearchRelevance.sortedByRelevance(library + newOnes, query: queueFilter)

        VStack(alignment: .leading, spacing: 0) {
            compactQueueRowsList(entries: queueRows)
            ForEach(combined) { r in searchResultRow(r) }
        }
    }

    /// Compact-row variant of `queueRowsList` — emits `QueueSearchRow`
    /// instead of `QueueRowView`. Used wherever queue rows show up
    /// inside a search-driven layout.
    @ViewBuilder
    private func compactQueueRowsList(entries: [QueueRowEntry]) -> some View {
        VStack(spacing: 2) {
            ForEach(entries) { entry in
                switch entry {
                case .single(let item):
                    QueueSearchRow(item: item) { detailItem = item }
                case .group(let group):
                    QueueSearchRow(item: group.representative) { detailItem = group.representative }
                }
            }
        }
    }

    @ViewBuilder
    private func searchResultRow(_ r: SearchResult) -> some View {
        SearchResultRow(result: r) {
            if let arrId = r.inLibraryArrId {
                DetailRequest.post(
                    DetailRequest.syntheticItem(
                        source: r.source,
                        entityId: arrId,
                        title: r.title,
                        posterURL: r.posterURL,
                        posterRequiresAuth: false
                    )
                )
            } else {
                searchResult = r
            }
        }
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
            if searchAvailable, searchViewModel.isSearching, isFiltering {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 15, height: 15)
                    .transition(.opacity)
            } else {
                Image(systemName: "magnifyingglass")
                    .scaledFont(size: 15, weight: .medium)
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            }
            TextField("", text: $queueFilter, prompt:
                Text("Filter queue", bundle: .module)
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
                .accessibilityLabel(Text("Clear filter", bundle: .module))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isFiltering)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Capsule())
        .onTapGesture { queueFilterFocused.wrappedValue = true }
        .glassyFloatingBar()
    }

    /// Substring-match helper — case-insensitive, diacritic-insensitive
    /// (so „Pożeracz" matches „pozeracz"). Applied to title + episode
    /// title so an episode-specific filter still catches season packs.
    private func matchesFilter(_ item: QueueItem) -> Bool {
        let q = queueFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return true }
        let haystack = [item.title, item.episodeTitle ?? "", item.subtitle ?? ""]
            .joined(separator: " ")
        return haystack.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private enum SectionEntry: Hashable {
        case tonight
        case needsYou
        case arr(QueueItem.Source)
    }

    private var visibleSections: [SectionEntry] {
        let filtering = !queueFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return configStore.arrOrder.compactMap { key in
            // Tonight / Needs-You are status-curated sections — they
            // don't read as "search results" when the user is typing.
            // Hide them while a filter is active so the surface
            // collapses to just the matching queue rows.
            if key == ConfigStore.tonightOrderKey {
                guard !filtering, queueScope == nil,
                      configStore.showTonight && !viewModel.tonight.isEmpty else { return nil }
                return .tonight
            }
            if key == ConfigStore.needsYouOrderKey {
                guard !filtering, queueScope == nil,
                      configStore.showNeedsYou && !viewModel.needsYou.isEmpty else { return nil }
                return .needsYou
            }
            if let source = QueueItem.Source(rawValue: key), isConfigured(source) {
                // Scope chip in the filter bar narrows the sections —
                // pick `All` (nil) or a specific arr.
                if let scope = queueScope, scope != source { return nil }
                // Hide arr sections that don't have a matching row.
                // Showing an empty "Sonarr (0)" header — whether
                // during a filter or in the default view — adds
                // noise; the user wants to see only sources that
                // actually have something queued right now.
                if entries(for: source).isEmpty { return nil }
                return .arr(source)
            }
            return nil
        }
    }

    private var queueSections: some View {
        let entries = visibleSections
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element) { index, entry in
                if index > 0 {
                    Divider().padding(.horizontal, 12)
                }
                sectionView(for: entry)
            }
        }
    }

    @ViewBuilder
    private func sectionView(for entry: SectionEntry) -> some View {
        switch entry {
        case .tonight:
            tonightBanner
        case .needsYou:
            NeedsYouSectionView(
                items: viewModel.needsYou,
                isCollapsed: configStore.isCollapsed(ConfigStore.needsYouOrderKey),
                onToggleCollapse: {
                    withAnimation(.smooth(duration: 0.22)) {
                        configStore.toggleCollapsed(ConfigStore.needsYouOrderKey)
                    }
                },
                onItemTap: { needs in
                    let cfg = configStore.config(for: needs.source.serviceKind)
                    guard let url = ArrActivityURLBuilder.queueURL(forBase: cfg.baseURL),
                          let scheme = url.scheme?.lowercased(),
                          scheme == "http" || scheme == "https"
                    else { return }
                    PlatformURLOpener.open(url)
                }
            )
            .padding(.vertical, 12)
        case .arr(let source):
            let arrError = viewModel.error(for: source)
            QueueSectionView(
                title: source.displayName,
                symbol: source.symbol,
                entries: entries(for: source),
                error: arrError,
                health: health(for: source),
                isCollapsed: arrError == nil ? configStore.isCollapsed(source) : false,
                onToggleCollapse: arrError == nil ? {
                    withAnimation(.smooth(duration: 0.22)) {
                        configStore.toggleCollapsed(source)
                    }
                } : nil,
                viewModel: viewModel,
                onShowHistory: arrError == nil ? { historySource = source } : nil,
                onShowDetail: { item in
                    withAnimation(.smooth(duration: 0.22)) { detailItem = item }
                },
                // Skip the duplicate "Sonarr" header when the user
                // has explicitly scoped to this source via the chip
                // above — the chip already labels it.
                hideHeader: queueScope == source
            )
            .padding(.vertical, 12)
        }
    }

    private func isConfigured(_ source: QueueItem.Source) -> Bool {
        switch source {
        case .sonarr: return sonarrConfigured
        case .radarr: return radarrConfigured
        case .lidarr: return lidarrConfigured
        case .whisparr: return whisparrConfigured
        }
    }

    /// Sonarr items get bucketed by downloadId so a season pack collapses
    /// into one row matching the underlying download. Radarr / Lidarr stay
    /// one-row-per-item; grouping is sonarr-only for now.
    private func entries(for source: QueueItem.Source) -> [QueueRowEntry] {
        let raw = viewModel.items(for: source).filter(matchesFilter)
        switch source {
        case .sonarr: return QueueGrouping.group(raw)
        default:      return raw.map { .single($0) }
        }
    }

    private func health(for source: QueueItem.Source) -> [ArrHealthRecord] {
        guard configStore.showIndexerIssues else { return [] }
        return viewModel.health.records(for: source)
    }

    // MARK: - Tonight banner

    private var tonightBanner: some View {
        let items = viewModel.tonight
        // Header renamed "Upcoming" → "Next week" so it no longer
        // shadows the Upcoming tab label. Default visible count is 4
        // (was 3); overflow is gated by a chevron expander that
        // auto-collapses after 30s of inactivity — the banner is a
        // peek surface, not a destination, so it shouldn't sit
        // expanded forever.
        let visible = viewModel.tonightExpanded ? items : Array(items.prefix(4))
        let overflow = items.count - visible.count
        let collapsed = configStore.isCollapsed(ConfigStore.tonightOrderKey)
        return HStack(alignment: .top, spacing: 8) {
            // Section chevron mirroring QueueSectionView — keeps the
            // banner aligned with the rest of the popover's collapsible
            // sections (Sonarr / Radarr / Needs you) instead of being
            // the one panel you can't tuck away.
            Button {
                withAnimation(.smooth(duration: 0.22)) {
                    configStore.toggleCollapsed(ConfigStore.tonightOrderKey)
                }
            } label: {
                Image(systemName: "chevron.right")
                    .scaledFont(size: 9, weight: .semibold)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 10, height: 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 3)
            .accessibilityLabel(Text(collapsed ? "Expand section" : "Collapse section", bundle: .module))
            Image(systemName: "moon.stars.fill")
                .scaledFont(size: 13)
                .foregroundStyle(.purple)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Next week", bundle: .module)
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .onTapGesture {
                        withAnimation(.smooth(duration: 0.22)) {
                            configStore.toggleCollapsed(ConfigStore.tonightOrderKey)
                        }
                    }
                if !collapsed {
                ForEach(visible) { item in
                    Button {
                        openUpcomingDetail(item)
                    } label: {
                        HStack(spacing: 4) {
                            Text(Self.tonightTimeFormatter.string(from: item.airDate))
                                .scaledFont(size: 11, weight: .medium, monospacedDigit: true)
                                .foregroundStyle(.secondary)
                            Image(systemName: item.source.symbol)
                                .scaledFont(size: 10)
                                .foregroundStyle(.secondary)
                            Text(item.title)
                                .scaledFont(size: 12, weight: .medium)
                                .lineLimit(1)
                            if let subtitle = item.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .scaledFont(size: 11)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(item.entityId == nil)
                }
                if overflow > 0 && !viewModel.tonightExpanded {
                    Button {
                        withAnimation(.smooth(duration: 0.22)) {
                            viewModel.setTonightExpanded(true)
                        }
                        scheduleBannerCollapse()
                    } label: {
                        HStack(spacing: 3) {
                            Text("Show more", bundle: .module)
                                .scaledFont(size: 10)
                            Image(systemName: "chevron.down")
                                .scaledFont(size: 9, weight: .medium)
                        }
                        .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
                } // !collapsed
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.purple.opacity(0.06))
    }

    /// Sends the tonight-banner item into the detail-view pipeline.
    /// Same call shape as `UpcomingRowView.openDetail` — a synthetic
    /// `QueueItem` posted via `DetailRequest` so the existing
    /// `arrBarrOpenDetail` listener picks it up and renders DetailView.
    private func openUpcomingDetail(_ item: UpcomingItem) {
        guard let entityId = item.entityId else { return }
        DetailRequest.post(
            DetailRequest.syntheticItem(
                source: item.source,
                entityId: entityId,
                title: item.title,
                posterURL: item.posterURL,
                posterRequiresAuth: item.posterRequiresAuth
            )
        )
    }

    /// 30s auto-collapse for the expanded "Next week" banner. Any new
    /// expand cancels the prior timer and restarts the countdown, so a
    /// user who keeps re-engaging never gets surprised by the
    /// collapse.
    private func scheduleBannerCollapse() {
        bannerCollapseTask?.cancel()
        bannerCollapseTask = Task { @MainActor [viewModel] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if Task.isCancelled { return }
            withAnimation(.smooth(duration: 0.22)) {
                viewModel.setTonightExpanded(false)
            }
        }
    }

    private static let tonightTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}
