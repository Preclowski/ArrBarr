import SwiftUI

public struct PopoverContentView: View {
    var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore
    @ObservedObject private var storeManager = StoreManager.shared
    let onOpenSettings: () -> Void
    let onShowAbout: () -> Void
    let onQuit: () -> Void

    public init(
        viewModel: QueueViewModel,
        onOpenSettings: @escaping () -> Void,
        onShowAbout: @escaping () -> Void = {},
        onQuit: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.onOpenSettings = onOpenSettings
        self.onShowAbout = onShowAbout
        self.onQuit = onQuit
    }

    @State private var selectedTab: Tab = .queue
    @State private var historySource: QueueItem.Source?
    @State private var historyRefreshNonce = 0
    @State private var searchViewModel = SearchViewModel()
    @State private var chatHolder = ChatViewModelHolder()
    @State private var searchResult: SearchResult?
    @State private var detailItem: QueueItem?
    /// Pending confirmation payload — set by `.onReceive` listening
    /// for `arrBarrConfirmRequest`. Rendered as a panel-wide overlay
    /// at the end of body.
    @State private var pendingConfirm: PendingConfirm?
    /// Push-target for "open the series view" from inside an
    /// EpisodeQuickDetail. Registered as a sibling navigationDestination
    /// on the root NavigationStack so SwiftUI doesn't get confused
    /// about insertion order when the binding fires from a deeper view.
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

    /// `true` when the SearchAddPanel overlay was opened via a chat
    /// tap-to-add rather than the Add tab. Drives the Back behaviour in
    /// `SearchAddPanel` — back returns straight to chat instead of
    /// dropping the user on the Add tab they never asked to visit.
    @State private var searchAddFromChat = false
    /// Discover/Quiz overlay state. The view-model survives across opens
    /// (so accept/skip counters and the deck persist) and the overlay
    /// flag is flipped by the `arrBarrOpenDiscoverQuiz` notification
    /// posted by the `discover_in_quiz` chat tool.
    @State private var discoverViewModel = DiscoverViewModel.shared
    @State private var showDiscoverOverlay = false
    /// Auto-collapse timer for the "Next week" banner — the banner
    /// snaps back to the 4-item peek 30s after the user expands it.
    @State private var bannerCollapseTask: Task<Void, Never>?

    private var sonarrConfigured: Bool { configStore.sonarr.isVisible }
    private var radarrConfigured: Bool { configStore.radarr.isVisible }
    private var lidarrConfigured: Bool { configStore.lidarr.isVisible }
    private var whisparrConfigured: Bool { configStore.whisparr.isVisible }
    private var anyArrConfigured: Bool { sonarrConfigured || radarrConfigured || lidarrConfigured || whisparrConfigured }

    private var searchAvailable: Bool { sonarrConfigured || radarrConfigured || lidarrConfigured || whisparrConfigured }

    private var isFiltering: Bool {
        !queueFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Queue rows that are for a specific Sonarr episode (season pack
    /// items have `episodeNumber == nil`). These bypass DetailView's
    /// series chrome and push the episode directly via
    /// `EpisodeQuickDetail` — the series view is reachable from the
    /// episode hero's series-title tap.
    private func isSonarrEpisodeRow(_ item: QueueItem) -> Bool {
        item.source == .sonarr
            && (item.episodeNumber ?? 0) > 0
            && item.entityId != nil
    }

    private var chatAvailable: Bool {
        guard configStore.aiEnabled else { return false }
        // Demo mode uses DemoChatProvider, so the chat works without a key or
        // Apple Intelligence — show the tab regardless of provider/OS.
        if DemoMode.isActive { return true }
        switch configStore.chatProvider {
        case .foundationModels:
            if #available(macOS 26.0, iOS 26.0, *) { return true }
            return false
        case .openai:
            return configStore.openai.isConfigured
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
            // The menu-bar popover is its own scene root — without this every
            // `.scaledFont` in the popover falls back to 1.0 and the Text-size
            // preset has no effect here (it only worked in Settings, which
            // self-injects). See `appFontScale`.
            .appFontScale(configStore)
            .preferredColorScheme(configStore.preferredColorScheme)
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
                // ⌘R — manual refresh. The popover (the primary surface) had
                // no refresh affordance at all, so the only way to refresh was
                // to wait for the next poll.
                Button("") { Task { await viewModel.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
            }
            .onReceive(NotificationCenter.default.publisher(for: .arrBarrTriggerAdd)) { _ in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    selectedTab = .queue
                }
                queueFilterFocused = true
            }
            // Search-to-add App Intent. The menu-bar popover can't be opened
            // programmatically, so this stages the query for whenever it opens.
            .onReceive(NotificationCenter.default.publisher(for: .arrBarrSearchQuery)) { note in
                guard let q = note.userInfo?["query"] as? String else { return }
                selectedTab = .queue
                queueFilter = q
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
            .onReceive(NotificationCenter.default.publisher(for: .arrBarrOpenDiscoverQuiz)) { note in
                // Posted by the `discover_in_quiz` chat tool. userInfo carries
                // mood label + pre-resolved items + optional `append` flag
                // (extends an existing deck instead of replacing it).
                guard let mood = note.userInfo?["mood"] as? String,
                      let items = note.userInfo?["items"] as? [DiscoverItem] else { return }
                let append = (note.userInfo?["append"] as? Bool) ?? false
                let hasActiveSession = !discoverViewModel.sessionMatched.isEmpty
                    || !discoverViewModel.sessionSkipped.isEmpty
                    || discoverViewModel.current != nil
                    || !discoverViewModel.queue.isEmpty
                if append && hasActiveSession {
                    discoverViewModel.extend(items: items)
                } else {
                    discoverViewModel.seed(items: items, mood: mood)
                }
                searchResult = nil
                detailItem = nil
                historySource = nil
                showDiscoverOverlay = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .arrBarrConfirmRequest)) { note in
                if let payload = note.userInfo?["payload"] as? PendingConfirm {
                    pendingConfirm = payload
                }
            }
            .overlay {
                if let pending = pendingConfirm {
                    ModalConfirmOverlay(
                        title: pending.title,
                        message: pending.message ?? "",
                        confirmLabelKey: pending.confirmLabel,
                        cancelLabelKey: pending.cancelLabel,
                        destructive: pending.isDestructive,
                        onConfirm: {
                            pending.onConfirm()
                            pendingConfirm = nil
                        },
                        onCancel: { pendingConfirm = nil }
                    )
                }
            }
            // NOTE: the paywall is intentionally NOT presented here. This view
            // lives inside the MenuBarExtra panel, which auto-dismisses when it
            // resigns key (i.e. the instant StoreKit's purchase UI appears),
            // which would abort the purchase. On macOS the paywall is hosted in
            // a dedicated NSWindow by AppDelegate (observing
            // StoreManager.gatedFeature). `storeManager` is still observed here
            // for the Chat-tab lock badge + gate.
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
        NavigationStack {
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
                    // Tab bar hides while a queue-filter / search
                    // query is live — search becomes a full-size
                    // surface (back chevron in the top strip is the
                    // only nav affordance you need). Tabs reappear
                    // the moment the query clears.
                    if !(selectedTab == .queue && isFiltering) {
                        tabBar
                    }
                    Group {
                        switch selectedTab {
                        case .queue:
                            QueueTabContent(
                                viewModel: viewModel,
                                searchViewModel: searchViewModel,
                                queueFilter: $queueFilter,
                                queueScope: $queueScope,
                                queueFilterFocused: $queueFilterFocused,
                                detailItem: $detailItem,
                                historySource: $historySource,
                                searchResult: $searchResult,
                                bannerCollapseTask: $bannerCollapseTask
                            )
                        case .upcoming: UpcomingTabContent(viewModel: viewModel)
                        case .chat:
                            ChatTabContent(chatHolder: chatHolder)
                        }
                    }
                } else {
                    PopoverEmptyState(onOpenSettings: onOpenSettings) { moreMenu }
                }
            }
            // Tab content stays mounted under both overlays (SearchAddPanel
            // + DetailView) so scroll positions, expanded sections, and
            // other transient view-state survive a round-trip. Opacity-hide
            // keeps it visually out of the way; allowsHitTesting(false)
            // prevents stray clicks from leaking through to it.
            .opacity((searchResult != nil || detailItem != nil || showDiscoverOverlay) ? 0 : 1)
            .allowsHitTesting(!(searchResult != nil || detailItem != nil || showDiscoverOverlay))

            if showDiscoverOverlay {
                DiscoverTabView(
                    viewModel: discoverViewModel,
                    llmAvailable: chatAvailable,
                    radarrAvailable: radarrConfigured,
                    onAddToRadarr: { result in
                        // Reuse the existing search-add flow: post the
                        // tap-to-add notification and let SearchAddPanel
                        // overlay handle profile / folder defaults.
                        SearchAddRequest.post(result)
                    },
                    onAddToSonarr: { result in
                        SearchAddRequest.post(result)
                    },
                    onOpenDetail: { _, source, arrId in
                        DetailRequest.post(DetailRequest.syntheticItem(
                            source: source,
                            entityId: arrId,
                            title: ""
                        ))
                    },
                    onClose: {
                        withAnimation(.smooth(duration: 0.22)) { showDiscoverOverlay = false }
                    }
                )
                // Hide (but keep mounted) when SearchAddPanel or
                // DetailView opens on top — otherwise the picks list
                // bleeds through under the detail surface, which has
                // no opaque background of its own.
                .opacity((searchResult != nil || detailItem != nil) ? 0 : 1)
                .allowsHitTesting(!(searchResult != nil || detailItem != nil))
                .transition(.opacity)
            }

            if searchResult != nil {
                searchAddOverlay
                    .transition(.opacity)
            }

        }
        .navigationDestination(item: $detailItem) { item in
            // Sonarr queue rows that target a specific episode skip the
            // Series view and land the user on the episode directly.
            // The series view is reachable from the episode hero's
            // "series name >" tap which fires `seriesPushRequest`
            // (sibling destination below).
            if isSonarrEpisodeRow(item) {
                // EpisodeQuickDetail owns its own series-drill push, so
                // the series detail nests under the episode and "back"
                // returns to the episode (not straight to the queue).
                EpisodeQuickDetail(
                    item: item,
                    viewModel: viewModel,
                    originLabel: LocalizedStringKey(selectedTab.rawValue)
                )
            } else {
                DetailView(
                    item: item,
                    onBack: { self.detailItem = nil },
                    originLabel: LocalizedStringKey(selectedTab.rawValue),
                    viewModel: viewModel
                )
            }
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
                    if tab == .chat && !storeManager.isPro {
                        storeManager.gate(.chat)
                        return
                    }
                    // Re-tapping the active queue tab clears the
                    // filter + scope — gives the user a "reset to
                    // home" affordance that doesn't need its own
                    // chrome (Spotify / Apple Music tab-bar idiom).
                    if tab == .queue && selectedTab == .queue {
                        if isFiltering || queueScope != nil {
                            withAnimation(.easeOut(duration: 0.18)) {
                                queueFilter = ""
                                queueScope = nil
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
                    HStack(spacing: 3) {
                        ZStack {
                            Text(LocalizedStringKey(tab.rawValue), bundle: .module)
                                .scaledFont(size: 12, weight: .semibold)
                                .opacity(0)
                                .accessibilityHidden(true)
                            Text(LocalizedStringKey(tab.rawValue), bundle: .module)
                                .scaledFont(size: 12, weight: selectedTab == tab ? .semibold : .regular)
                                .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                        }
                        if tab == .chat && !storeManager.isPro {
                            Image(systemName: "lock.fill")
                                .scaledFont(size: 9, weight: .semibold)
                                .foregroundStyle(.secondary)
                        }
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
                    // Indicator pill spreads horizontally past the tab's
                    // text + padding box (+12 each side) so it reads as a
                    // real tab slot rather than a tight chip hugging the
                    // text. Vertically it must stay *inside* the tab's box —
                    // the surrounding glass bar is only as tall as the tab
                    // button, so any positive vertical growth makes the pill
                    // spill above/below the bar. Inset 6pt (3pt rim top and
                    // bottom) keeps it a clean capsule within the bar.
                    TabPillBackground()
                        .frame(width: max(0, frame.width + 24), height: max(0, frame.height - 6))
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
            // Manual refresh — mirrors the hidden ⌘R button above so the
            // shortcut is also discoverable in the menu (same dual-
            // registration pattern as Settings' ⌘,).
            Button { Task { await viewModel.refresh() } } label: { Text("common.refresh.button", bundle: .module) }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button { onOpenSettings() } label: { Text("Settings…", bundle: .module) }
                .keyboardShortcut(",", modifiers: .command)
            #if os(macOS)
            Button { onShowAbout() } label: { Text("settings.aboutArrbarr.button", bundle: .module) }
            // Shortcut to the Settings "Show in Dock as a window" toggle. Label
            // reflects current state so the same item detaches from the panel
            // and re-attaches from the detached window.
            Button { configStore.detachedWindow.toggle() } label: {
                Text(configStore.detachedWindow ? "Reattach to menu bar" : "Detach into a window", bundle: .module)
            }
            #endif
            Divider()
            Button { onQuit() } label: { Text("common.quitArrbarr.button", bundle: .module) }
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
        .help(Text("common.moreOptions.button", bundle: .module))
    }

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
