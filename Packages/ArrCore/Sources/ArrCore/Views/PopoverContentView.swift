import SwiftUI

public struct PopoverContentView: View {
    var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore
    @ObservedObject private var storeManager = StoreManager.shared
    let onOpenSettings: () -> Void
    let onShowAbout: () -> Void
    let onQuit: () -> Void
    /// `nil` in the menu-bar panel; in the detached window an × ends the tab bar (traffic lights are hidden).
    var onCloseWindow: (() -> Void)? = nil
    @Environment(\.isDetachedWindow) private var isDetachedWindow
    /// Closes the MenuBarExtra popover; a no-op in the detached NSWindow.
    @Environment(\.dismiss) private var dismiss

    public init(
        viewModel: QueueViewModel,
        onOpenSettings: @escaping () -> Void,
        onShowAbout: @escaping () -> Void = {},
        onQuit: @escaping () -> Void,
        onCloseWindow: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onOpenSettings = onOpenSettings
        self.onShowAbout = onShowAbout
        self.onQuit = onQuit
        self.onCloseWindow = onCloseWindow
    }

    @State private var selectedTab: Tab = .queue
    #if os(macOS)
    @State private var commandKey = CommandKeyMonitor()
    #endif
    @State private var queueSelecting = false
    @State private var historySource: QueueItem.Source?
    @State private var searchViewModel = SearchViewModel()
    /// Owned here so switching tabs doesn't drop the fetched libraries.
    @State private var libraryViewModel = LibraryViewModel()
    @State private var chatHolder = ChatViewModelHolder()
    @State private var searchResult: SearchResult?
    @State private var detailItem: QueueItem?
    /// Detail surfaces own their person destination; chat has none, so the root hosts it.
    @State private var personRef: PersonRef?
    /// Owned here because ⌘N and the Add/search intents aim at it from outside any tab.
    @FocusState private var searchFieldFocused: Bool

    /// Opened from chat: Back returns to chat instead of the Add tab.
    @State private var searchAddFromChat = false
    /// Deck and presentation live in the view-model, which outlives this view — the panel
    /// rebuilds constantly and a chat turn can open the quiz while it's shut.
    @State private var discoverViewModel = DiscoverViewModel.shared
    /// Outlives this view, so a playing clip is re-presented when the popover reopens.
    @ObservedObject private var trailerSession = TrailerSession.shared

    private var sonarrConfigured: Bool { configStore.sonarr.isVisible }
    private var radarrConfigured: Bool { configStore.radarr.isVisible }
    private var lidarrConfigured: Bool { configStore.lidarr.isVisible }
    private var whisparrConfigured: Bool { configStore.whisparr.isVisible }
    private var anyArrConfigured: Bool { sonarrConfigured || radarrConfigured || lidarrConfigured || whisparrConfigured }

    /// A hair above zero on purpose: at exactly 0 AppKit drops the selectable-text layers in
    /// chat bubbles and they come back invisible on unpark.
    static let parkedOpacity: Double = 0.001

    private var tabContentParked: Bool {
        searchResult != nil || detailItem != nil || discoverViewModel.isPresented
    }

    /// Discover parks under SearchAddPanel / DetailView but not under itself.
    private var discoverParked: Bool {
        searchResult != nil || detailItem != nil
    }

    /// Hopped to the next main-actor turn: on `onAppear` the field isn't in the responder
    /// chain yet and an inline assignment is silently dropped.
    private func focusInputForCurrentTab() {
        guard selectedTab.hostsSearch else { return }
        Task { searchFieldFocused = true }
    }

    /// Live queue rows and owned titles from every loaded library matching the query.
    private var localHits: [LocalHit] {
        guard searchViewModel.isActive else { return [] }
        return LocalHit.hits(
            queue: viewModel, library: libraryViewModel,
            sources: QueueItem.Source.allCases.filter { configStore.config(for: $0.serviceKind).isVisible },
            query: searchViewModel.query)
    }

    /// Episode rows (packs have `episodeNumber == nil`) skip the series chrome and open
    /// `EpisodeQuickDetail`.
    private func isSonarrEpisodeRow(_ item: QueueItem) -> Bool {
        item.source == .sonarr
            && (item.episodeNumber ?? 0) > 0
            && item.entityId != nil
    }


    enum Tab: String, CaseIterable {
        case queue = "Queue"
        case library = "Library"
        case upcoming = "Upcoming"
        case chat = "Chat"

        var hostsSearch: Bool { self != .chat }

        /// Only the active tab shows its label: four labels ("Nadchodzące", "Warteschlange")
        /// never fit the 400 pt bar.
        var symbol: String {
            switch self {
            case .queue: return "arrow.down.circle"
            case .library: return "books.vertical"
            case .upcoming: return "calendar"
            case .chat: return "bubble.left.and.bubble.right"
            }
        }
    }

    public var body: some View {
        mainContent
            .environment(\.locale, configStore.currentLocale)
            #if os(macOS)
            // No inline UI: the URLs go to AppDelegate's add window, the same one Dock drops, "Open
            // With" and magnet clicks use; it filters out what can't be downloaded.
            .dropDestination(for: URL.self) { urls, _ in
                // Deferred: opening a window inside drag handling can wedge the drag tracking loop.
                DispatchQueue.main.async { AppMessages.post(AppMessages.DropDownloads(urls: urls)) }
                return true
            }
            #endif
            // The popover is its own scene root — without this `.scaledFont` falls back to 1.0 here.
            .appFontScale(configStore)
            .preferredColorScheme(configStore.preferredColorScheme)
            .onAppear {
                searchViewModel.setup(store: configStore)
                searchViewModel.library = libraryViewModel
                chatHolder.reconfigure(store: configStore)
                viewModel.startForegroundPolling()
                focusInputForCurrentTab()
                #if os(macOS)
                commandKey.start()
                #endif
            }
            .onDisappear {
                viewModel.stopForegroundPolling()
                #if os(macOS)
                commandKey.stop()
                #endif
            }
            .onChange(of: ChatViewModelHolder.signature(store: configStore)) { _, _ in
                chatHolder.reconfigure(store: configStore)
            }
            .onChange(of: configStore.aiConfigured) { _, available in
                if !available && selectedTab == .chat {
                    selectedTab = .queue
                }
            }
            // Clear pushed surfaces so one tab's detail chrome can't linger on another.
            .onChange(of: selectedTab) { _, _ in
                detailItem = nil
                searchResult = nil
                historySource = nil
                focusInputForCurrentTab()
            }
            .background { hiddenShortcuts }
            // The popover can't be opened programmatically, so this stages the query for when it opens.
            .onMessage(AppMessages.SearchQuery.self) { message in
                selectedTab = .queue
                // The `didSet` runs the search.
                searchViewModel.query = message.query
            }
            .onDetailRequest { item in
                searchResult = nil
                historySource = nil
                if detailItem == nil {
                    withAnimation(.smooth(duration: 0.22)) { detailItem = item }
                } else {
                    // Replacing a pushed detail in place orphans a person view pushed above it (Back goes
                    // dead), so unwind the branch first and push on the next runloop pass.
                    detailItem = nil
                    Task {
                        withAnimation(.smooth(duration: 0.22)) { detailItem = item }
                    }
                }
            }
            .onMessage(AppMessages.OpenPerson.self) { message in
                searchResult = nil
                historySource = nil
                detailItem = nil
                personRef = message.ref
            }
            .onSearchAddRequest { result, origin in
                // Back returns to chat only for the chat origin; a quiz card returns to the parked deck.
                historySource = nil
                detailItem = nil
                searchAddFromChat = origin == .chat
                searchResult = result
            }
            // The deck seeds itself (`DiscoverViewModel.open`); this only clears what it comes up over.
            .onChange(of: discoverViewModel.isPresented) { _, presented in
                guard presented else { return }
                searchResult = nil
                detailItem = nil
                historySource = nil
            }
            // Rendered at the root, not in the surfaces that start it, so a clip survives the popover
            // rebuilding per open. Below the confirm overlay: a confirmation outranks entertainment.
            .trailerOverlay(key: Binding(
                get: { trailerSession.key },
                set: { if $0 == nil { trailerSession.dismiss() } }
            ))
            .confirmCenterHost()
            // No paywall here: the MenuBarExtra panel resigns key when StoreKit's UI appears and
            // would abort the purchase. AppDelegate hosts it in an NSWindow.
    }

    /// Lifted out of `body`, which is already at the type-checker's limit.
    @ViewBuilder
    private var hiddenShortcuts: some View {
        Button("", action: onOpenSettings)
            .keyboardShortcut(",", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
        Button("") {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                selectedTab = .queue
            }
            searchFieldFocused = true
        }
        .keyboardShortcut("n", modifiers: .command)
        .opacity(0)
        .frame(width: 0, height: 0)
        Button("") { Task { await viewModel.refresh() } }
            .keyboardShortcut("r", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
        // Keyed off `visibleTabs`, not `Tab.allCases`, so numbers match the pills on screen.
        // Capped at 9 — ⌘0 means something else everywhere.
        ForEach(Array(visibleTabs.prefix(9).enumerated()), id: \.element) { index, tab in
            Button("") { selectTab(tab) }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
    }

    private var mainContent: some View {
        // Overlays sit in a ZStack so the tab content stays mounted and keeps its scroll
        // positions; History still swaps the surface.
        NavigationStack {
        ZStack {
            VStack(spacing: 0) {
                if let historySource {
                    HistoryView(
                        source: historySource,
                        viewModel: viewModel,
                        // Not through `DetailRouter`, whose handler drops the history surface — Back must land here.
                        onOpenDetail: { item in
                            withAnimation(.smooth(duration: 0.22)) { detailItem = item }
                        },
                        onClose: { self.historySource = nil }
                    )
                } else if anyArrConfigured {
                    // A live query makes search a full-size surface; its back chevron is the nav.
                    Group {
                        if selectedTab == .chat {
                            ChatTabContent(chatHolder: chatHolder)
                        } else {
                            SearchHost(
                                searchVM: searchViewModel,
                                localHits: localHits,
                                searchAvailable: anyArrConfigured,
                                focused: $searchFieldFocused,
                                onSelectQueueItem: { detailItem = $0 },
                                onSelectAddResult: { searchResult = $0 }
                            ) {
                                switch selectedTab {
                                case .queue:
                                    QueueTabContent(
                                        viewModel: viewModel,
                                        detailItem: $detailItem,
                                        historySource: $historySource,
                                        selecting: $queueSelecting
                                    )
                                case .library:
                                    LibraryTabContent(viewModel: libraryViewModel)
                                case .upcoming, .chat:
                                    UpcomingTabContent(viewModel: viewModel)
                                }
                            }
                        }
                    }
                    // In the safe area, not a VStack row: the list scrolls under the glass and the system draws
                    // its soft scroll-edge blur (with `.scrollEdgeEffectStyle(.soft)` on each tab).
                    .safeAreaBar(edge: .top, spacing: 0) {
                        if !(searchViewModel.isActive && selectedTab.hostsSearch) {
                            tabBar
                        }
                    }
                } else {
                    PopoverEmptyState(onOpenSettings: onOpenSettings) { moreMenu }
                }
            }
            // Parking takes all four mechanisms; skipping one leaks. `.disabled` is what stops an
            // invisible TextField handing its I-beam to the overlay drawn over it.
            .opacity(tabContentParked ? Self.parkedOpacity : 1)
            .allowsHitTesting(!tabContentParked)
            .disabled(tabContentParked)
            .accessibilityHidden(tabContentParked)

            if discoverViewModel.isPresented {
                DiscoverTabView(
                    viewModel: discoverViewModel,
                    llmAvailable: configStore.aiConfigured,
                    radarrAvailable: radarrConfigured,
                    // The top-up round is a chat turn, so the deck waits on the agent's thinking flag.
                    moreInFlight: chatHolder.vm.isThinking,
                    isObscured: discoverParked,
                    onClose: {
                        withAnimation(.smooth(duration: 0.22)) { discoverViewModel.isPresented = false }
                    },
                    onCancelLoading: {
                        chatHolder.vm.cancelTurn()
                        discoverViewModel.endLoading()
                    },
                    onRequestMore: requestMoreQuizPicks
                )
                // Parked with all four mechanisms too; the detail surface has no opaque background.
                .opacity(discoverParked ? Self.parkedOpacity : 1)
                .allowsHitTesting(!discoverParked)
                .disabled(discoverParked)
                .accessibilityHidden(discoverParked)
                .transition(.opacity)
            }

            if searchResult != nil {
                searchAddOverlay
                    .transition(.opacity)
            }

        }
        // The view model opens the deck (possibly mid-rebuild), so the fade lives here rather
        // than in a `withAnimation` around the flag.
        .animation(.smooth(duration: 0.22), value: discoverViewModel.isPresented)
        .personDestination($personRef)
        .navigationDestination(item: $detailItem) { item in
            // Episode rows open the episode; the series is reachable via its "series name >" tap.
            if isSonarrEpisodeRow(item) {
                // EpisodeQuickDetail owns the series push, so back returns to the episode.
                EpisodeQuickDetail(
                    item: item,
                    viewModel: viewModel,
                    onBack: { self.detailItem = nil }
                )
            } else {
                DetailView(
                    item: item,
                    onBack: { self.detailItem = nil },
                    viewModel: viewModel
                )
            }
        }
        }
        .frame(width: 400, height: 600)
        // Transparent so NSPopover's native chrome shows through, one step darker than the backdrop.
        // A rim-light overlay cut through where the popover's arrow attaches.
        .background(Color.black.opacity(0.10))
    }

    /// Back branches on `searchAddFromChat`: chat origins return to chat.
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

    /// Same Control gate and spring as the tab pill, so ⌘1/2/3 and a click are the same action.
    private func selectTab(_ tab: Tab) {
        if tab == .chat && !storeManager.isPro {
            storeManager.gate(.chat)
            return
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { selectedTab = tab }
    }

    private var visibleTabs: [Tab] {
        Tab.allCases.filter { tab in
            switch tab {
            case .chat: return configStore.aiConfigured
            default:    return true
            }
        }
    }

    /// "More picks" can only come from the agent: this prompt makes it call `discover_in_quiz`
    /// with `append: true`; mood and shown picks are already in the chat history.
    private func requestMoreQuizPicks() {
        // No LLM, or a turn already running: the message would never resolve.
        guard configStore.aiConfigured, !chatHolder.vm.isThinking else { return }
        // In-app language, not the process one (see AppLocalized), or the prompt lags a live switch.
        let prompt = AppLocalized.string("discover.moreLikeThese.chatPrompt", locale: configStore.currentLocale)
        Task { await chatHolder.vm.send(prompt) }
    }

    private var tabBar: some View {
        // One container so the islands morph together. `spacing: 0` because the container fuses
        // glass within its spacing — at 8 the two islands became one blob.
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 8) {
                tabPills
                    .frame(maxWidth: .infinity)
                    .glassyFloatingBar()
                    .glassEffectID("tabs", in: barGlass)
                accessoryIsland
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// Sized from the tab cluster's measured height so the two capsules cannot drift apart.
    private var accessoryIsland: some View {
        #if os(macOS)
        let hasClose = isDetachedWindow && onCloseWindow != nil
        #else
        let hasClose = false
        #endif
        let side = barHeight
        return HStack(spacing: 0) {
            moreMenu
            #if os(macOS)
            // The traffic lights are hidden; the menu-bar panel dismisses itself on focus loss.
            if isDetachedWindow, let onCloseWindow {
                windowCloseButton(action: onCloseWindow)
            }
            #endif
        }
        .frame(width: hasClose ? side * 2 : side, height: side)
        // Explicit circle: the glass pads its bounds and a capsule re-derives its radius from that.
        .glassyFloatingBar(circular: !hasClose)
        .glassEffectID("accessory", in: barGlass)
    }

    private var barHeight: CGFloat {
        tabFrames.values.map(\.height).max() ?? 32
    }

    #if os(macOS)
    private func windowCloseButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: Self.glyphButton, height: Self.glyphButton)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(Text("Close window", bundle: .module))
        .accessibilityLabel(Text("Close window", bundle: .module))
    }
    #endif

    /// Measured frames, because localized labels range from "Chat" (~25 pt) to "Nadchodzące"
    /// (~80 pt) and equal-width segments truncated.
    private struct TabFrames: PreferenceKey {
        static var defaultValue: [Tab: CGRect] = [:]
        static func reduce(value: inout [Tab: CGRect], nextValue: () -> [Tab: CGRect]) {
            value.merge(nextValue()) { _, new in new }
        }
    }

    @State private var tabFrames: [Tab: CGRect] = [:]

    @Namespace private var barGlass

    private var commandHeld: Bool {
        #if os(macOS)
        commandKey.isHeld
        #else
        false
        #endif
    }

    private func commandHint(for tab: Tab) -> String? {
        #if os(macOS)
        guard commandKey.isHeld, let index = visibleTabs.firstIndex(of: tab), index < 9 else { return nil }
        return "⌘\(index + 1)"
        #else
        return nil
        #endif
    }

    private var tabPills: some View {
        HStack(spacing: 0) {
            // Edge spacers split the extra width into uniform gutters instead of clumping tabs left.
            Spacer(minLength: 0)
            ForEach(Array(visibleTabs.enumerated()), id: \.element) { _, tab in
                Button {
                    if tab == .chat && !storeManager.isPro {
                        storeManager.gate(.chat)
                        return
                    }
                    // Re-tapping the active tab clears the query. Not from Chat: it doesn't show the field.
                    if tab == selectedTab, tab.hostsSearch, searchViewModel.isActive {
                        withAnimation(.easeOut(duration: 0.18)) {
                            searchViewModel.query = ""
                        }
                    }
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { selectedTab = tab }
                } label: {
                    // Invisible semibold copy fixes the width, or the regular→semibold switch resizes the tab
                    // out of band from the selection spring and the indicator's width snaps.
                    HStack(spacing: 3) {
                        // Explicit `.transition(.opacity)`: otherwise the inserted Text slides in from the left
                        // inside the animated relayout instead of crossfading.
                        if selectedTab == tab && !commandHeld {
                            // No `fixedSize`: an incompressible "Nadchodzące" pill pushed the detached bar past the
                            // 400 pt panel and the content bled past the window edges.
                            Text(LocalizedStringKey(tab.rawValue), bundle: .module)
                                .scaledFont(size: 12, weight: .semibold)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                // 0.75: the squeeze needs ~20 pt back; a higher floor makes SwiftUI truncate instead of scale.
                                .minimumScaleFactor(0.75)
                                .transition(.opacity)
                        } else {
                            Image(systemName: tab.symbol)
                                .scaledFont(size: 13, weight: .medium)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(Text(LocalizedStringKey(tab.rawValue), bundle: .module))
                                .help(Text(LocalizedStringKey(tab.rawValue), bundle: .module))
                                .transition(.opacity)
                        }
                        if tab == .chat && !storeManager.isPro {
                            Image(systemName: "lock.fill")
                                .scaledFont(size: 9, weight: .semibold)
                                .foregroundStyle(.secondary)
                        }
                        // In the layout rather than an overlay: every pill reshapes while ⌘ is held anyway, and
                        // the animated `tabFrames` glide absorbs it.
                        if let hint = commandHint(for: tab) {
                            Text(hint)
                                .scaledFont(size: 9, weight: .semibold)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .padding(.leading, 4)
                                .transition(.opacity)
                                .accessibilityHidden(true)
                        }
                    }
                    // No `fixedSize` either — same overflow as the label above.
                    .padding(.horizontal, 18)
                    // Padding, not a fixed height, so the bar grows with the user's text size.
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
        #if os(macOS)
        .animation(.easeOut(duration: 0.12), value: commandKey.isHeld)
        #endif
        .onPreferenceChange(TabFrames.self) { newFrames in
            // This preference fires out of band from the selection spring; animating with the same
            // spring stops the indicator snapping mid-flight. First layout has nothing to glide from.
            if tabFrames.isEmpty {
                tabFrames = newFrames
            } else {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    tabFrames = newFrames
                }
            }
        }
        .background(
            // `.position()` in an explicit GeometryReader: a `.background(ZStack).offset` mis-aligned by
            // one tab on macOS when the implicit ZStack's bounds didn't match the HStack's.
            GeometryReader { geo in
                if let rect = selectionPillRect(in: geo.size) {
                    TabPillBackground()
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        )
    }

    /// Fills the tab's slot (label plus half of each gutter) measured from `tabFrames`, so it
    /// neither under-fills the popover nor spills when the detached × squeezes the tabs.
    private func selectionPillRect(in container: CGSize) -> CGRect? {
        guard let frame = tabFrames[selectedTab] else { return nil }
        let ordered = visibleTabs
            .compactMap { tab in tabFrames[tab].map { (tab, $0) } }
            .sorted { $0.1.minX < $1.1.minX }
        guard let idx = ordered.firstIndex(where: { $0.0 == selectedTab }) else { return nil }

        let gap: CGFloat = 3
        // Outer edges reach halfway to the bar's inner edge, so every pill is symmetric.
        let leftEdge = idx > 0
            ? (ordered[idx - 1].1.maxX + frame.minX) / 2 + gap
            : frame.minX / 2
        let rightEdge = idx < ordered.count - 1
            ? (ordered[idx + 1].1.minX + frame.maxX) / 2 - gap
            : (frame.maxX + container.width) / 2

        let height = max(0, frame.height - 6)
        return CGRect(x: leftEdge, y: frame.midY - height / 2,
                      width: max(0, rightEdge - leftEdge), height: height)
    }

    /// Shorter than the tab labels, so a glyph can never stretch the bar.
    private static let glyphButton: CGFloat = 28

    /// The frame must sit outside the Menu: `.fixedSize()` collapses a Menu to its bare glyph
    /// (~12×4 pt) and the glass capsule hugs that instead of a circle.
    private var moreMenu: some View {
        Menu {
            if selectedTab == .queue, viewModel.activeCount > 0 {
                Button { queueSelecting = true } label: {
                    Label { Text("queue.selectMultiple.button", bundle: .module) } icon: { Image(systemName: "checkmark.circle") }
                }
            }
            if selectedTab == .queue, !QueueUIState.shared.hiddenQueueItems.isEmpty {
                Toggle(isOn: Bindable(QueueUIState.shared).showHiddenQueueItems) {
                    Label { Text("queue.showHidden.button", bundle: .module) } icon: { Image(systemName: "eye") }
                }
            }
            if selectedTab == .queue, viewModel.activeCount > 0 || !QueueUIState.shared.hiddenQueueItems.isEmpty {
                Divider()
            }
            // No "Refresh" item: the queue refreshes itself and ⌘R stays.
            Button { onOpenSettings() } label: { Text("common.settings2.button", bundle: .module) }
                .keyboardShortcut(",", modifiers: .command)
            #if os(macOS)
            Button { onShowAbout() } label: { Text("settings.aboutArrbarr.button", bundle: .module) }
            // In the menu, not its own glyph: the detached bar has no width to spare. AppDelegate
            // observes `$detachedWindow` and opens/closes the window.
            Button {
                let wasInPopover = !isDetachedWindow
                configStore.detachedWindow.toggle()
                // Re-attaching is handled by AppDelegate closing the NSWindow.
                if wasInPopover { dismiss() }
            } label: {
                Text(isDetachedWindow ? "common.reattachToMenuBar.button" : "common.detachIntoAWindow.button", bundle: .module)
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
        .frame(width: Self.glyphButton, height: Self.glyphButton)
        .contentShape(Capsule())
        .help(Text("common.moreOptions.button", bundle: .module))
    }

}

// MARK: - Tab pill background

private struct TabPillBackground: View {
    var body: some View {
        // Inside the outer glass capsule, and glass-on-glass would vanish.
        Capsule()
            .fill(Color.primary.opacity(0.14))
    }
}


// MARK: - Shared button styles

struct GlassButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        // Capsule to match GlassProminentButtonStyle next to it.
        content.buttonStyle(.glass).buttonBorderShape(.capsule)
    }
}

/// Tinted glass that keeps showing what's behind it — for CTAs over artwork that shouldn't shout.
struct GlassTintedButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.buttonStyle(.glass).buttonBorderShape(.capsule)
    }
}

struct GlassProminentButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        // Explicit white labels: glassProminent's default vibrancy makes text translucent. An inner
        // foregroundStyle (the red trash) still wins.
        content
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .foregroundStyle(.white)
    }
}
