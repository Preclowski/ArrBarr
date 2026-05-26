import SwiftUI

public struct PopoverContentView: View {
    @ObservedObject var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore
    let onOpenSettings: () -> Void
    let onQuit: () -> Void
    /// Optional. When provided, the footer "More" menu shows an "Open Window…"
    /// item that hands off to a richer NSWindow-hosted view. Nil for the iOS
    /// build (no separate window concept) and the early macOS scaffold.
    let onOpenWindow: (() -> Void)?

    public init(
        viewModel: QueueViewModel,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onOpenWindow: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        self.onOpenWindow = onOpenWindow
    }

    @State private var selectedTab: Tab = .queue
    @State private var historySource: QueueItem.Source?
    @State private var historyRefreshNonce = 0
    @StateObject private var searchViewModel = SearchViewModel()
    @StateObject private var chatHolder = ChatViewModelHolder()
    @State private var searchResult: SearchResult?
    @State private var detailItem: QueueItem?
    /// Queue tab filter — substring match against item titles. Mirrors
    /// the search view's floating bar (same `.glassyFloatingBar()`
    /// chrome). When non-empty, tonight/needsYou sections collapse out
    /// (they're status-based, not search-targets) and every arr
    /// section drops rows whose title doesn't contain the substring.
    @State private var queueFilter: String = ""
    @FocusState private var queueFilterFocused: Bool
    /// Source scope for the queue filter / search bar. `nil` = all
    /// arrs; setting a concrete source narrows both the queue filter
    /// (rows from other arrs hidden) AND the search query (only that
    /// arr is asked for library / add-new hits).
    @State private var queueScope: QueueItem.Source? = nil
    /// Second-axis filter: which class of result to show. `.all`
    /// shows queue + library + new. `.inQueue` collapses to queue
    /// rows only (useful for "where's my Foo?" when the search would
    /// otherwise drown the list in add-new candidates). `.libraryOrNew`
    /// hides queue rows and surfaces only search results.
    @State private var queueResultType: QueueResultType = .all

    enum QueueResultType: Hashable, CaseIterable {
        case all
        case inQueue
        case inLibrary
        case new

        var labelKey: LocalizedStringKey {
            switch self {
            case .all: return "All"
            case .inQueue: return "In queue"
            case .inLibrary: return "In library"
            case .new: return "New"
            }
        }
    }
    /// `true` when the SearchAddPanel overlay was opened via a chat
    /// tap-to-add rather than the Add tab. Drives the Back behaviour in
    /// `SearchAddPanel` — back returns straight to chat instead of
    /// dropping the user on the Add tab they never asked to visit.
    @State private var searchAddFromChat = false
    /// Auto-collapse timer for the "Next week" banner — the banner
    /// snaps back to the 4-item peek 30s after the user expands it.
    @State private var bannerCollapseTask: Task<Void, Never>?

    private var sonarrConfigured: Bool { configStore.sonarr.isVisible }
    private var radarrConfigured: Bool { configStore.radarr.isVisible }
    private var lidarrConfigured: Bool { configStore.lidarr.isVisible }
    private var whisparrConfigured: Bool { configStore.whisparr.isVisible }
    private var anyArrConfigured: Bool { sonarrConfigured || radarrConfigured || lidarrConfigured || whisparrConfigured }

    private var searchAvailable: Bool { sonarrConfigured || radarrConfigured || lidarrConfigured || whisparrConfigured }

    private var chatAvailable: Bool {
        guard configStore.aiEnabled else { return false }
        switch configStore.chatProvider {
        case .foundationModels:
            if #available(macOS 26.0, iOS 26.0, *) { return true }
            return false
        case .openai:
            return configStore.openai.isConfigured
        }
    }

    @ViewBuilder
    private var chatTabContent: some View {
        if !chatHolder.vm.providerIsAvailable {
            ChatUnavailableView(reason: .providerUnavailable)
        } else {
            ChatView(viewModel: chatHolder.vm)
        }
    }

    enum Tab: String, CaseIterable {
        case queue = "Queue"
        case upcoming = "Upcoming"
        case chat = "Chat"
        // `.add` (Search) removed — the queue's floating filter bar
        // now doubles as a global search. Empty filter → queue rows;
        // typing → queue rows that match + library/add-new candidates
        // pulled via `SearchViewModel`. One surface, both jobs.
    }

    public var body: some View {
        mainContent
            .environment(\.locale, configStore.currentLocale)
            .onAppear {
                searchViewModel.setup(
                    radarrConfig: configStore.radarr,
                    sonarrConfig: configStore.sonarr,
                    lidarrConfig: configStore.lidarr,
                    whisparrConfig: configStore.whisparr
                )
                chatHolder.reconfigure(store: configStore)
            }
            .onChange(of: ChatViewModelHolder.signature(store: configStore)) { _, _ in
                chatHolder.reconfigure(store: configStore)
            }
            .onChange(of: chatAvailable) { _, available in
                if !available && selectedTab == .chat {
                    selectedTab = .queue
                }
            }
            .background {
                // Hidden keyboard shortcut for cmd+, (Settings). cmd+N
                // (Add) now lands on the Queue tab with the floating
                // filter bar focused — same end-state as the old Add
                // tab since search lives there now.
                Button("", action: onOpenSettings)
                    .keyboardShortcut(",", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                Button("") {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        selectedTab = .queue
                    }
                    queueFilterFocused = true
                }
                .keyboardShortcut("n", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
            }
            .onReceive(NotificationCenter.default.publisher(for: .arrBarrTriggerAdd)) { _ in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    selectedTab = .queue
                }
                queueFilterFocused = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .arrBarrOpenDetail)) { note in
                guard let item = note.userInfo?["item"] as? QueueItem else { return }
                searchResult = nil
                historySource = nil
                withAnimation(.smooth(duration: 0.22)) { detailItem = item }
            }
            .onReceive(NotificationCenter.default.publisher(for: .arrBarrOpenSearchAdd)) { note in
                // Chat tap-to-add — show the SearchAddPanel overlay
                // pre-loaded with the result. `searchAddFromChat` lets
                // Back return straight to chat instead of dropping the
                // user on the Add tab.
                guard let result = note.userInfo?["result"] as? SearchResult else { return }
                historySource = nil
                detailItem = nil
                searchAddFromChat = true
                searchResult = result
            }
    }

    private var mainContent: some View {
        // DetailView is rendered as a ZStack overlay so the underlying chat /
        // queue / upcoming view stays alive while it's on screen. That keeps
        // their scroll positions, lazy state, etc. intact — tapping Back lands
        // the user back in the same carousel offset they came from. Search +
        // History still use the swap pattern (they replace the surface fully
        // and don't share state worth preserving).
        // Search overlay used to live inside this if/else chain as a sibling
        // of the tab content — toggling `showSearch` unmounted the active
        // tab. That tore down ChatView's scroll position (and its tool-result
        // carousels' scroll positions), so coming back from SearchAddPanel
        // dropped the user at the top. Promoted to a ZStack overlay alongside
        // DetailView so chat / queue / upcoming all stay mounted underneath
        // and resume exactly where the user left them. Tab content is
        // opacity-hidden (and hit-testing-disabled) under the overlay so we
        // don't need an opaque background on the overlay itself — the
        // popover's native chrome shines through, matching the rest of the
        // app.
        ZStack {
            VStack(spacing: 0) {
                if let historySource {
                    HistoryView(
                        source: historySource,
                        viewModel: viewModel,
                        refreshNonce: historyRefreshNonce,
                        onClose: { self.historySource = nil }
                    )
                } else if anyArrConfigured {
                    tabBar
                    Group {
                        switch selectedTab {
                        case .queue: queueContent
                        case .upcoming: upcomingContent
                        case .chat:
                            chatTabContent
                        }
                    }
                } else {
                    emptyState
                }
            }
            // Tab content stays mounted under both overlays (SearchAddPanel
            // + DetailView) so scroll positions, expanded sections, and
            // other transient view-state survive a round-trip. Opacity-hide
            // keeps it visually out of the way; allowsHitTesting(false)
            // prevents stray clicks from leaking through to it.
            .opacity((searchResult != nil || detailItem != nil) ? 0 : 1)
            .allowsHitTesting(!(searchResult != nil || detailItem != nil))

            if searchResult != nil {
                searchAddOverlay
                    .transition(.opacity)
            }

            if let detailItem {
                // No opaque background here — chat / queue / upcoming
                // underneath are hidden via the opacity gate above, so
                // the popover's native chrome shows through and the
                // detail view feels tonally consistent with the rest of
                // the app instead of a flat dark rectangle pasted on top.
                DetailView(
                    item: detailItem,
                    onBack: {
                        withAnimation(.smooth(duration: 0.22)) { self.detailItem = nil }
                    },
                    // Origin label = whichever tab the user was on
                    // when they drilled into the detail. Reads as a
                    // breadcrumb in the header ("Nadchodzące",
                    // "Kolejka", etc.) instead of duplicating the
                    // item's own title.
                    originLabel: LocalizedStringKey(selectedTab.rawValue),
                    viewModel: viewModel
                )
                .transition(.opacity)
            }
        }
        .frame(width: 400, height: 600)
        // Transparent background lets NSPopover's native chrome show
        // through (AppDelegate clears the hosting view's layer too). We
        // used to paint a rim-light overlay here on top of this — meant
        // to approximate macOS 26's Liquid Glass edge — but the stroke
        // ran straight through where NSPopover's arrow attaches to the
        // frame, leaving a visible cut, and the arrow itself doesn't get
        // the overlay (it's outside our 400×600 SwiftUI surface). Without
        // bumping the deployment target to 26 the rim couldn't ever look
        // like real glass anyway, so it's gone — arrow + frame stay
        // visually consistent.
        .background(Color.clear)
    }

    /// Modal-feeling overlay for the result detail. Shown whenever
    /// `searchResult` is non-nil — whether the user got here by tapping
    /// a row on the Add tab or by tapping a missing-item suggestion in
    /// chat. Back behaviour branches on `searchAddFromChat` so chat
    /// origins return to chat rather than dumping the user on the Add
    /// tab they never visited.
    @ViewBuilder
    private var searchAddOverlay: some View {
        if let result = searchResult {
            SearchAddPanel(result: result, viewModel: searchViewModel) {
                if searchAddFromChat {
                    searchAddFromChat = false
                    searchResult = nil
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        selectedTab = .chat
                    }
                } else {
                    searchResult = nil
                }
            }
        }
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

    // MARK: - Tab bar

    private var visibleTabs: [Tab] {
        Tab.allCases.filter { tab in
            switch tab {
            case .chat: return chatAvailable
            default:    return true
            }
        }
    }

    /// Bare search list rendered as content for the Add tab. The result
    /// detail (SearchAddPanel) is still presented as an overlay over the
    /// whole popover — that view has its own internal back/forward
    /// navigation and we keep it modal so the user can't half-add a
    /// release by switching tabs underneath it.
    @ViewBuilder
    private var addTabContent: some View {
        SearchView(viewModel: searchViewModel) { result in
            // Library hit → drill into DetailView via the same
            // synthetic-item pipeline that Queue/Upcoming use. Addable
            // hit (no arrId) → open the SearchAddPanel form as before.
            // Single tap-handler keeps SearchView source-unaware.
            if let arrId = result.inLibraryArrId {
                DetailRequest.post(
                    DetailRequest.syntheticItem(
                        source: result.source,
                        entityId: arrId,
                        title: result.title,
                        posterURL: result.posterURL,
                        posterRequiresAuth: false
                    )
                )
            } else {
                searchResult = result
            }
        }
        .environmentObject(configStore)
        // Globally scale every `.scaledFont(size:)` site by the user's
        // preference (Default / Larger / Largest). Injected once at the
        // root so individual views just read `@Environment(\.fontScale)`.
        .environment(\.fontScale, configStore.fontScale)
    }

    private var tabBar: some View {
        // Two floating glass capsules: the tab cluster (Queue / Upcoming
        // / Chat / Add) and the kebab overflow menu. The cluster pill
        // stretches to fill all space up to the kebab; tabs inside keep
        // intrinsic widths and are evenly distributed by `Spacer`s, so
        // long labels (Polish "Nadchodzące") aren't squeezed but the
        // pill chrome still spans the whole row instead of orphaning a
        // dead empty strip between the last tab and the kebab.
        HStack(spacing: 8) {
            tabPills
                .frame(maxWidth: .infinity)
                .glassyFloatingBar()
            moreMenu
                .glassyFloatingBar()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// Reports each tab's frame in `tabPills`'s coordinate space so the
    /// rounded selection indicator can slide between them with the
    /// correct width. Equal-width segments worked when every label was a
    /// single short English word; once localized strings ranged from
    /// "Chat" (~25pt) to "Nadchodzące" (~80pt) the grid layout started
    /// truncating, so we switched to intrinsic widths + measured
    /// indicator geometry.
    private struct TabFrames: PreferenceKey {
        static var defaultValue: [Tab: CGRect] = [:]
        static func reduce(value: inout [Tab: CGRect], nextValue: () -> [Tab: CGRect]) {
            value.merge(nextValue()) { _, new in new }
        }
    }

    @State private var tabFrames: [Tab: CGRect] = [:]

    private var tabPills: some View {
        HStack(spacing: 0) {
            // Edge Spacer at start + between every tab gives n+1 evenly
            // sized flex slots — the cluster's extra width is split as
            // uniform gutters, so tabs visually breathe across the full
            // pill instead of clumping left.
            Spacer(minLength: 0)
            ForEach(Array(visibleTabs.enumerated()), id: \.element) { _, tab in
                Button {
                    // Re-tapping the active queue tab clears the
                    // filter + scope — gives the user a "reset to
                    // home" affordance that doesn't need its own
                    // chrome (Spotify / Apple Music tab-bar idiom).
                    if tab == .queue && selectedTab == .queue {
                        if isFiltering || queueScope != nil || queueResultType != .all {
                            withAnimation(.easeOut(duration: 0.18)) {
                                queueFilter = ""
                                queueScope = nil
                                queueResultType = .all
                            }
                        }
                    }
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { selectedTab = tab }
                } label: {
                    // Width stabiliser: an invisible always-semibold copy
                    // sets the tab's intrinsic width; the visible label
                    // overlays on top and switches weight/color with
                    // selection without resizing the tab. Without this,
                    // selecting a tab made it ~3-4pt wider (regular →
                    // semibold), which fired `onPreferenceChange` *out
                    // of band* from the spring transaction wrapping
                    // `selectedTab`, so the indicator's width snapped
                    // while its position animated — the "indicator
                    // living its own life" effect.
                    //
                    // Tab labels carry Tab.rawValue as a LocalizedStringKey;
                    // the explicit `bundle: .module` is mandatory because
                    // Text(LocalizedStringKey) without bundle defaults to
                    // Bundle.main, where the package's pl/de/es/fr
                    // translations don't live.
                    ZStack {
                        Text(LocalizedStringKey(tab.rawValue), bundle: .module)
                            .scaledFont(size: 12, weight: .semibold)
                            .opacity(0)
                            .accessibilityHidden(true)
                        Text(LocalizedStringKey(tab.rawValue), bundle: .module)
                            .scaledFont(size: 12, weight: selectedTab == tab ? .semibold : .regular)
                            .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    // Horizontal/vertical padding sets the breathing
                    // room INSIDE the selection pill — the pill is
                    // sized to the tab's bounds minus a 3pt rim, so
                    // text-to-pill-edge ends up ~15pt horizontal,
                    // ~6pt vertical. Earlier 14/7 had the pill
                    // hugging the text too closely; bumped for more
                    // air, closer to Music app's tab metrics.
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: TabFrames.self,
                                value: [tab: proxy.frame(in: .named("tabPills"))]
                            )
                        }
                    )
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
        }
        .coordinateSpace(name: "tabPills")
        .onPreferenceChange(TabFrames.self) { tabFrames = $0 }
        .background(
            // Indicator reads from `tabFrames` so it lines up exactly
            // with each label's intrinsic width — slides between tabs
            // *and* resizes when widths differ. The outer GeometryReader
            // pins the indicator's coordinate space to the same frame
            // as the tabPills HStack (the named "tabPills" space). An
            // earlier draft used `.background(ZStack).offset(...)` —
            // that quietly mis-aligned by one tab on macOS because the
            // implicit background ZStack's bounds didn't end up matching
            // the HStack's bounds in every layout pass; `.position()`
            // inside an explicit GeometryReader removes that ambiguity.
            GeometryReader { _ in
                if let frame = tabFrames[selectedTab] {
                    TabPillBackground()
                        .frame(width: max(0, frame.width - 6), height: max(0, frame.height - 6))
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        )
    }

    /// Canonical height for every floating pill in this toolbar. Tabs
    /// pill uses the same rule via its per-tab `.padding(.vertical, 7)`
    /// + 12pt font, which lands around 28pt. Keep this constant in sync
    /// if the tab metrics ever move.
    private static let pillHeight: CGFloat = 28

    /// Overflow menu — capsule of equal width and height = a perfect
    /// circle. The frame has to live OUTSIDE the Menu, not inside the
    /// label closure: `.fixedSize()` on a Menu collapses it to its
    /// label's *intrinsic* size (the bare ellipsis glyph, ~12×4pt),
    /// which made the wrapping glass capsule hug the tiny glyph instead
    /// of respecting the 28×28 frame we wanted. Putting `.frame(width:
    /// height:)` after `.menuStyle` forces the actual Menu bounding box
    /// to pill-height square, and the capsule glass then has a real
    /// circle to wrap.
    private var moreMenu: some View {
        Menu {
            if let onOpenWindow {
                Button { onOpenWindow() } label: { Text("Open Window…", bundle: .module) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
            }
            Button { onOpenSettings() } label: { Text("Settings…", bundle: .module) }
                .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button { onQuit() } label: { Text("Quit ArrBarr", bundle: .module) }
                .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "ellipsis")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: Self.pillHeight, height: Self.pillHeight)
        .contentShape(Capsule())
        .help(Text("More options", bundle: .module))
    }

    // MARK: - Queue content

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
                        if configuredSources.count > 1 || isFiltering {
                            HStack(spacing: 6) {
                                if configuredSources.count > 1 {
                                    scopeChipsRow
                                }
                                Spacer(minLength: 6)
                                if isFiltering {
                                    typeFilterPill
                                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
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
            // Clearing the search collapses the result-type axis —
            // there's nothing to scope by library/new once the
            // search is gone, and leaving the pill on a stale
            // narrow value would hide the queue. Snap back to All.
            if new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               queueResultType != .all {
                queueResultType = .all
            }
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

    /// Per-result-kind count scoped to the current source selection.
    /// Used by the type-filter pill menu ("In library (16)") and by
    /// the type-grouped section headers when scope is narrowed.
    private func count(for kind: QueueResultType) -> Int {
        let queueCount = scopedSources.reduce(0) { $0 + filteredQueueItems(for: $1).count }
        let libraryCount = scopedSources.reduce(0) { $0 + libraryResults(for: $1).count }
        let newCount = scopedSources.reduce(0) { $0 + newResults(for: $1).count }
        switch kind {
        case .all:       return queueCount + libraryCount + newCount
        case .inQueue:   return queueCount
        case .inLibrary: return libraryCount
        case .new:       return newCount
        }
    }

    @ViewBuilder
    private var queueBody: some View {
        if !isFiltering {
            // Default surface — per-arr queue sections, tonight /
            // needsYou banners. No search axis to encode yet.
            queueSections
        } else if queueResultType == .all {
            // Status-grouped — IN QUEUE / IN LIBRARY / NEW headers
            // are the only grouping level. Source axis demoted to
            // the row's source-glyph chip. Works the same whether
            // queueScope is nil (all configured arrs) or a single
            // arr (scope chips above already labelled it).
            statusGroupedSections
        } else if let scope = queueScope {
            // User narrowed to one kind via the type pill — flat
            // list, no header (redundant with the pill).
            flatList(for: scope)
        } else {
            // queueScope == nil, type pill narrowed to one kind —
            // flat list across all configured arrs.
            flatListAcrossSources
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

    /// IN QUEUE / IN LIBRARY / NEW renderer. Source-scope-agnostic
    /// — pulls from `scopedSources` (single arr if `queueScope` set,
    /// every configured arr otherwise). De-duplicates library hits
    /// against rows that already appear in IN QUEUE.
    @ViewBuilder
    private var statusGroupedSections: some View {
        let queueRows: [QueueRowEntry] = scopedSources.flatMap { entries(for: $0) }
        let rawLibrary: [SearchResult] = scopedSources.flatMap { libraryResults(for: $0) }
        let library = SearchResultDedup.removingQueueDuplicates(
            libraryResults: rawLibrary,
            queueRows: queueRows
        )
        let newOnes: [SearchResult] = scopedSources.flatMap { newResults(for: $0) }

        VStack(alignment: .leading, spacing: 0) {
            if !queueRows.isEmpty {
                typeSectionHeader(.inQueue, count: queueRows.reduce(0) { sum, e in
                    switch e {
                    case .single: return sum + 1
                    case .group(let g): return sum + g.memberCount
                    }
                })
                compactQueueRowsList(entries: queueRows)
            }
            if !library.isEmpty {
                typeSectionHeader(.inLibrary, count: library.count)
                ForEach(library) { r in searchResultRow(r) }
            }
            if !newOnes.isEmpty {
                typeSectionHeader(.new, count: newOnes.count)
                ForEach(newOnes) { r in searchResultRow(r) }
            }
        }
    }

    /// Flat list when the type pill narrows to a single kind and the
    /// scope is all configured arrs.
    @ViewBuilder
    private var flatListAcrossSources: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch queueResultType {
            case .inQueue:
                compactQueueRowsList(entries: scopedSources.flatMap { entries(for: $0) })
            case .inLibrary:
                let queueRows = scopedSources.flatMap { entries(for: $0) }
                let raw = scopedSources.flatMap { libraryResults(for: $0) }
                let lib = SearchResultDedup.removingQueueDuplicates(
                    libraryResults: raw, queueRows: queueRows
                )
                ForEach(lib) { r in searchResultRow(r) }
            case .new:
                ForEach(scopedSources.flatMap { newResults(for: $0) }) { r in searchResultRow(r) }
            case .all:
                EmptyView()
            }
        }
    }

    /// Single-source flat list — used when the user picked a scope
    /// AND a narrowed type. IN QUEUE rows use the new compact row
    /// for chrome consistency with library/new.
    @ViewBuilder
    private func flatList(for source: QueueItem.Source) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch queueResultType {
            case .inQueue:
                compactQueueRowsList(entries: entries(for: source))
            case .inLibrary:
                let queueRows = entries(for: source)
                let lib = SearchResultDedup.removingQueueDuplicates(
                    libraryResults: libraryResults(for: source),
                    queueRows: queueRows
                )
                ForEach(lib) { r in searchResultRow(r) }
            case .new:
                ForEach(newResults(for: source)) { r in searchResultRow(r) }
            case .all:
                EmptyView()
            }
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

    /// Mini-header used in type-grouped mode — small uppercase label
    /// + count, matches the "SEASONS" / "EPISODES" rhythm used in
    /// detail-view section breaks so it doesn't compete with the
    /// scope chips above as a navigation cue.
    @ViewBuilder
    private func typeSectionHeader(_ kind: QueueResultType, count: Int) -> some View {
        HStack(spacing: 4) {
            Text(kind.labelKey, bundle: .module)
                .scaledFont(size: 10, weight: .semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Text("(\(count))")
                .scaledFont(size: 10, weight: .medium)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func queueRowsList(entries: [QueueRowEntry]) -> some View {
        // Stripped-down version of QueueSectionView's row stack —
        // headerless, since the type-grouped header is provided by
        // `typeSectionHeader` upstream.
        VStack(spacing: 2) {
            ForEach(entries) { entry in
                switch entry {
                case .single(let item):
                    QueueRowView(
                        item: item,
                        onPause: { Task { await viewModel.pause(item) } },
                        onResume: { Task { await viewModel.resume(item) } },
                        onDelete: { Task { await viewModel.delete(item) } },
                        onShowDetail: { detailItem = item }
                    )
                case .group(let group):
                    QueueGroupRowView(
                        group: group,
                        onPause: { Task { await viewModel.pause(group.representative) } },
                        onResume: { Task { await viewModel.resume(group.representative) } },
                        onDelete: { Task { await viewModel.delete(group.representative) } },
                        onShowDetail: { detailItem = group.representative }
                    )
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

    /// Source scope chips pinned at the top of the queue scroll. Sits
    /// above the first arr section so the user always sees which
    /// arrs are configured and which one is currently focused.
    /// Permanent navigation — result-type chips below are contextual
    /// (only shown while the user is actively filtering).
    private var scopeChipsRow: some View {
        // No trailing Spacer here — the parent HStack lays this row
        // out next to the type-filter pill, so we want the chips to
        // hug their content. The parent inserts a Spacer between
        // them when needed.
        HStack(spacing: 4) {
            filterChip(label: "All", icon: nil, isSelected: queueScope == nil) {
                queueScope = nil
            }
            ForEach(configuredSources, id: \.self) { src in
                filterChip(
                    label: src.displayName,
                    icon: src.symbol,
                    isSelected: queueScope == src
                ) { queueScope = src }
            }
        }
    }

    /// Result-type pill — single capsule that opens a select menu.
    /// Sits to the right of the scope chips row when filtering;
    /// reads as "additional scope narrowing" without taking a whole
    /// second row of horizontal space (which the chips approach
    /// would burn once lidarr / whisparr added their source chips).
    private var typeFilterPill: some View {
        Menu {
            // Each pill option gets its scoped count appended —
            // "In library (16)" reads as "16 items match this
            // narrowing right now", saves a round-trip of picking
            // just to discover the set is empty.
            Picker(selection: $queueResultType) {
                ForEach(QueueResultType.allCases, id: \.self) { kind in
                    Text("\(Text(kind.labelKey, bundle: .module)) (\(count(for: kind)))")
                        .tag(kind)
                }
            } label: { EmptyView() }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 3) {
                Text(queueResultType.labelKey, bundle: .module)
                    .scaledFont(size: 11, weight: queueResultType == .all ? .medium : .semibold)
                Image(systemName: "chevron.down")
                    .scaledFont(size: 8, weight: .bold)
            }
            .foregroundStyle(queueResultType == .all ? Color.secondary : Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(queueResultType == .all
                    ? AnyShapeStyle(Color.primary.opacity(0.08))
                    : AnyShapeStyle(Color.accentColor))
            )
            .overlay(
                Capsule().stroke(queueResultType == .all
                    ? Color.clear
                    : Color.accentColor.opacity(0.4), lineWidth: 0.75)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private func filterChip(label: String, icon: String?,
                            isSelected: Bool,
                            action: @escaping () -> Void) -> some View {
        // Neutral palette for source navigation — selected just
        // brightens to .primary on a slightly denser fill, no accent.
        // Source filter is *where am I looking*, not *what's the
        // important action*; the accent stays reserved for the
        // type-filter pill (which IS an action narrowing).
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { action() }
        } label: {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .scaledFont(size: 10, weight: .semibold)
                }
                Text(LocalizedStringKey(label), bundle: .module)
                    .scaledFont(size: 11, weight: isSelected ? .semibold : .medium)
            }
            .foregroundStyle(isSelected ? Color.primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.primary.opacity(isSelected ? 0.14 : 0.06))
            )
            .overlay(
                Capsule().stroke(isSelected
                    ? Color.primary.opacity(0.18)
                    : Color.clear, lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
    }

    /// Inline filter pill used inside the floating filter bar. Always
    /// shows a label — either the placeholder for the filter
    /// dimension ("Source" / "Type") when unset or the picked
    /// value when narrowed — so the affordance reads as "filter X"
    /// instead of an inscrutable glyph. Icon-only chips lost users
    /// completely; the label keeps the surface self-documenting.
    private struct InlineFilterPill<Content: View>: View {
        let symbol: String?
        let label: LocalizedStringKey
        let isActive: Bool
        let help: LocalizedStringKey
        @ViewBuilder var menu: () -> Content

        var body: some View {
            Menu(content: menu) {
                HStack(spacing: 3) {
                    if let symbol {
                        Image(systemName: symbol)
                            .scaledFont(size: 10, weight: .semibold)
                    }
                    Text(label, bundle: .module)
                        .scaledFont(size: 11, weight: .medium)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .scaledFont(size: 8, weight: .bold)
                }
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(isActive
                        ? Color.accentColor.opacity(0.18)
                        : Color.primary.opacity(0.08))
                )
                .overlay(
                    Capsule().stroke(isActive
                        ? Color.accentColor.opacity(0.4)
                        : Color.clear, lineWidth: 0.75)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text(help, bundle: .module))
        }
    }

    private var queueFilterBar: some View {
        // Clean glass capsule — same `.glassyFloatingBar()` chrome as
        // the tab cluster above, so the bar reads as the same control
        // surface family. Loading spinner replaces the trailing icon
        // while a fresh search query is in flight (arr lookups are
        // ~200-500ms each, the spinner saves a "is anything
        // happening?" moment of doubt).
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 15, weight: .medium)
                .foregroundStyle(.tertiary)
            TextField("", text: $queueFilter, prompt:
                Text("Filter queue", bundle: .module)
            )
            .scaledFont(size: 14)
            .textFieldStyle(.plain)
            .focused($queueFilterFocused)
            if !queueFilter.isEmpty {
                Button { queueFilter = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 14)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Capsule())
        .onTapGesture { queueFilterFocused = true }
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
                // Showing an empty "Sonarr (0)" header during filter
                // adds noise — the user only wants to see hits.
                if filtering, entries(for: source).isEmpty { return nil }
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

    // MARK: - Upcoming content

    private var upcomingContent: some View {
        ScrollView {
            Group {
                if viewModel.upcoming.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "calendar")
                            .scaledFont(size: 24, weight: .light)
                            .foregroundStyle(.tertiary)
                        Text("Nothing upcoming", bundle: .module)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groupedUpcoming, id: \.date) { group in
                            Text(group.label)
                                .scaledFont(size: 11, weight: .semibold)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, group.isFirst ? 8 : 14)
                                .padding(.bottom, 4)

                            ForEach(group.items) { item in
                                UpcomingRowView(item: item)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: .infinity)
    }

    private var groupedUpcoming: [UpcomingGroup] {
        let calendar = Calendar.current
        var groups: [UpcomingGroup] = []
        var current: (date: DateComponents, items: [UpcomingItem])?

        for item in viewModel.upcoming {
            let dc = calendar.dateComponents([.year, .month, .day], from: item.airDate)
            if let c = current, c.date == dc {
                current?.items.append(item)
            } else {
                if let c = current, let first = c.items.first {
                    let y = c.date.year ?? 0, m = c.date.month ?? 0, d = c.date.day ?? 0
                    groups.append(UpcomingGroup(
                        date: "\(y)-\(m)-\(d)",
                        label: first.airDateFormatted(locale: configStore.currentLocale),
                        items: c.items,
                        isFirst: groups.isEmpty
                    ))
                }
                current = (dc, [item])
            }
        }
        if let c = current, let first = c.items.first {
            let y = c.date.year ?? 0, m = c.date.month ?? 0, d = c.date.day ?? 0
            groups.append(UpcomingGroup(
                date: "\(y)-\(m)-\(d)",
                label: first.airDateFormatted(locale: configStore.currentLocale),
                items: c.items,
                isFirst: groups.isEmpty
            ))
        }
        return groups
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 14) {
                Image(systemName: "gearshape.2")
                    .scaledFont(size: 28, weight: .light)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)

                VStack(spacing: 4) {
                    Text("ArrBarr is not configured", bundle: .module)
                        .font(.headline)
                    Text("Connect Radarr, Sonarr or Lidarr to get started.", bundle: .module)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 6) {
                    emptyStep(number: 1, text: "Open your arr's web UI → Settings → General")
                    emptyStep(number: 2, text: "Copy the API Key")
                    emptyStep(number: 3, text: "Paste it here, along with the URL")
                }
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

                Button { onOpenSettings() } label: { Text("Open Settings…", bundle: .module) }
                    .modifier(GlassProminentButtonStyle())
                    .controlSize(.regular)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            moreMenu
                .padding(8)
        }
    }

    private func emptyStep(number: Int, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: "\(number).")
                .scaledFont(size: 11, weight: .semibold, monospacedDigit: true)
                .foregroundStyle(.tertiary)
            Text(text)
        }
    }

}

private struct UpcomingGroup {
    let date: String
    let label: String
    let items: [UpcomingItem]
    let isFirst: Bool
}

// MARK: - Tab pill background

private struct TabPillBackground: View {
    public var body: some View {
        // Sits *inside* the outer glass capsule (the tabPills container),
        // so we can't go glass-on-glass — it would vanish. A soft solid
        // tint reads as the "selected slot" depression and lets the
        // outer capsule keep its translucent feel.
        Capsule()
            .fill(Color.primary.opacity(0.14))
    }
}


// MARK: - Shared button styles

public struct GlassButtonStyle: ViewModifier {
    public func body(content: Content) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

public struct GlassProminentButtonStyle: ViewModifier {
    public func body(content: Content) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}
