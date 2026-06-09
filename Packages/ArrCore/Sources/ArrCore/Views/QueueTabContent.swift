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
                    if searchAvailable, searchViewModel.isSearching {
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
            VStack(spacing: 0) {
                // "Next week" banner pinned above the List (full-width — it's a
                // normal view, not a List row, so no macOS row-inset margins).
                if queueScope == nil, configStore.showTonight, !viewModel.tonight.isEmpty {
                    tonightBanner
                        .padding(.vertical, 6)
                }
                QueueListView(
                    viewModel: viewModel,
                    scope: queueScope,
                    onShowDetail: { item in
                        withAnimation(.smooth(duration: 0.22)) { detailItem = item }
                    },
                    onNeedsYouTap: { needs in openNeedsYouQueue(needs) },
                    onShowHistory: { source in historySource = source }
                )
                // Keep the last row clear of the floating filter bar.
                .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 58) }
            }
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
        let cfg = configStore.config(for: needs.source.serviceKind)
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
        .glassyFloatingBar()
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
        return HStack(alignment: .top, spacing: 6) {
            // Section chevron mirroring QueueSectionView — keeps the
            // banner aligned with the rest of the popover's collapsible
            // sections (Sonarr / Radarr / Needs you) instead of being
            // the one panel you can't tuck away.
            tonightChevron(collapsed: collapsed)
            VStack(alignment: .leading, spacing: 2) {
                // Moon glyph inlined with the header text instead of a
                // separate left-column icon — content rows now start
                // right after the chevron, matching the indent in
                // Needs You / queue sections.
                tonightHeaderLabel
                if !collapsed {
                    ForEach(visible) { item in
                        TonightBannerRow(
                            item: item,
                            timeString: Self.tonightTimeFormatter.string(from: item.airDate),
                            onTap: { openUpcomingDetail(item) }
                        )
                    }
                    if overflow > 0 && !viewModel.tonightExpanded {
                        tonightShowMoreButton
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.purple.opacity(0.06))
    }

    /// Collapse/expand chevron for the banner — rotates 0°→90° on expand,
    /// mirroring QueueSectionView's section headers.
    private func tonightChevron(collapsed: Bool) -> some View {
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
    }

    /// "🌙 Next week" header — tapping it toggles collapse, same as the chevron.
    private var tonightHeaderLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: "moon.stars.fill")
                .scaledFont(size: 11)
                .foregroundStyle(.purple)
            Text("queue.nextWeek.button", bundle: .module)
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.smooth(duration: 0.22)) {
                configStore.toggleCollapsed(ConfigStore.tonightOrderKey)
            }
        }
    }

    /// Overflow expander — reveals the hidden upcoming rows and arms the
    /// 30s auto-collapse timer.
    private var tonightShowMoreButton: some View {
        Button {
            withAnimation(.smooth(duration: 0.22)) {
                viewModel.setTonightExpanded(true)
            }
            scheduleBannerCollapse()
        } label: {
            HStack(spacing: 3) {
                Text("queue.showMore.button", bundle: .module)
                    .scaledFont(size: 10)
                Image(systemName: "chevron.down")
                    .scaledFont(size: 9, weight: .medium)
            }
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
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

/// A single row in the "Next week" banner: air time, source glyph, title,
/// optional subtitle. Extracted from `tonightBanner`'s `ForEach` closure so
/// the banner getter stays under the 100ms type-check warn threshold.
private struct TonightBannerRow: View {
    let item: UpcomingItem
    let timeString: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Text(timeString)
                    .scaledFont(size: 11, weight: .medium, monospacedDigit: true)
                    .foregroundStyle(.secondary)
                ServiceIcon(source: item.source, size: 10)
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
}
