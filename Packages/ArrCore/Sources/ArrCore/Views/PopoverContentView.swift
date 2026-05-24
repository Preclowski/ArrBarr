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
        /// Renamed Add → Search now that the panel shows both library
        /// hits (drill into DetailView) and addable candidates (open
        /// SearchAddPanel). "Add" was honest when we filtered library
        /// items out; "Search" is the honest verb now that we don't.
        /// The case name stays `.add` for source-compat with the
        /// existing routing tables — only the rawValue / label moves.
        case add = "Search"
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
            .onChange(of: searchAvailable) { _, available in
                if !available && selectedTab == .add {
                    selectedTab = .queue
                }
            }
            .background {
                // Hidden keyboard shortcuts so cmd+N (Add) and cmd+, (Settings)
                // work globally inside the popover, not just inside the More menu.
                Button("", action: onOpenSettings)
                    .keyboardShortcut(",", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                Button("") {
                    if searchAvailable {
                        searchViewModel.reset()
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            selectedTab = .add
                        }
                    }
                }
                .keyboardShortcut("n", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
            }
            .onReceive(NotificationCenter.default.publisher(for: .arrBarrTriggerAdd)) { _ in
                if searchAvailable {
                    searchViewModel.reset()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        selectedTab = .add
                    }
                }
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
                        case .add:
                            addTabContent
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
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 10, height: 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 3)
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 13))
                .foregroundStyle(.purple)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Next week", bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
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
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                            Image(systemName: item.source.symbol)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(item.title)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            if let subtitle = item.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.system(size: 11))
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
                                .font(.system(size: 10))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .medium))
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
            case .add:  return searchAvailable
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
                            .font(.system(size: 12, weight: .semibold))
                            .opacity(0)
                            .accessibilityHidden(true)
                        Text(LocalizedStringKey(tab.rawValue), bundle: .module)
                            .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                            .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    // Horizontal padding sets the breathing room INSIDE
                    // the selection pill — the pill is sized to the
                    // tab's bounds minus a 3pt rim, so text-to-pill-edge
                    // ends up ~11pt. Matches Music/TestFlight segmented
                    // controls' generosity.
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
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
                .font(.system(size: 12, weight: .semibold))
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
                    queueSections
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: .infinity)
    }

    private enum SectionEntry: Hashable {
        case tonight
        case needsYou
        case arr(QueueItem.Source)
    }

    private var visibleSections: [SectionEntry] {
        configStore.arrOrder.compactMap { key in
            if key == ConfigStore.tonightOrderKey {
                guard configStore.showTonight && !viewModel.tonight.isEmpty else { return nil }
                return .tonight
            }
            if key == ConfigStore.needsYouOrderKey {
                guard configStore.showNeedsYou && !viewModel.needsYou.isEmpty else { return nil }
                return .needsYou
            }
            if let source = QueueItem.Source(rawValue: key), isConfigured(source) {
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
                }
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
        let raw = viewModel.items(for: source)
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
                            .font(.system(size: 24, weight: .light))
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
                                .font(.system(size: 11, weight: .semibold))
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
                    .font(.system(size: 28, weight: .light))
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
                .font(.system(size: 11))
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
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
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
