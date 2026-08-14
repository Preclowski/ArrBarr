import SwiftUI

public struct PopoverContentView: View {
    var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore
    @ObservedObject private var storeManager = StoreManager.shared
    let onOpenSettings: () -> Void
    let onShowAbout: () -> Void
    let onQuit: () -> Void
    /// Closes the detached window. `nil` in the menu-bar panel (nothing to close).
    /// When set AND we're in the detached window, an × is shown as the last item
    /// of the tab bar's right island (the native traffic lights are hidden).
    var onCloseWindow: (() -> Void)? = nil
    @Environment(\.isDetachedWindow) private var isDetachedWindow
    /// Closes the MenuBarExtra popover. No-op in the detached NSWindow (it has no
    /// presenting container); used to dismiss the menu-bar panel right after the
    /// user detaches, so it doesn't linger behind the new window.
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
    /// Drives the ⌘-number hints on the tab pills — see `commandHint(for:)`.
    @State private var commandKey = CommandKeyMonitor()
    #endif
    /// Queue multi-select mode, entered from the "⋯" menu and threaded into
    /// QueueTabContent → QueueListView (the native-`List` selection).
    @State private var queueSelecting = false
    @State private var historySource: QueueItem.Source?
    @State private var historyRefreshNonce = 0
    @State private var searchViewModel = SearchViewModel()
    /// Library tab's per-arr cache — owned here (not inside the tab view) so
    /// switching tabs doesn't drop the fetched libraries.
    @State private var libraryViewModel = LibraryViewModel()
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

    private var sonarrConfigured: Bool { configStore.sonarr.isVisible }
    private var radarrConfigured: Bool { configStore.radarr.isVisible }
    private var lidarrConfigured: Bool { configStore.lidarr.isVisible }
    private var whisparrConfigured: Bool { configStore.whisparr.isVisible }
    private var anyArrConfigured: Bool { sonarrConfigured || radarrConfigured || lidarrConfigured || whisparrConfigured }

    /// An overlay is up, so the tab content behind it is parked — see the four
    /// modifiers at the call site.
    private var tabContentParked: Bool {
        searchResult != nil || detailItem != nil || showDiscoverOverlay
    }

    /// Same, one layer up: Discover parks under SearchAddPanel / DetailView but
    /// *not* under itself.
    private var discoverParked: Bool {
        searchResult != nil || detailItem != nil
    }

    private var isFiltering: Bool {
        !queueFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Put the caret in the tab's text field so the panel is typeable the
    /// instant it opens.
    ///
    /// Queue only — its floating bar is the global search. Upcoming has no
    /// field to focus, and Chat focuses its own on appear (the field lives
    /// inside `ChatView`, and it appears both on open and on tab switch, so
    /// driving it from here would just be a second owner of the same state).
    ///
    /// Hopped to the next main-actor turn rather than set inline: on the
    /// `onAppear` pass the field isn't in the responder chain yet, and an
    /// assignment made before it is there is silently dropped.
    private func focusInputForCurrentTab() {
        guard selectedTab == .queue else { return }
        Task { @MainActor in queueFilterFocused = true }
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
        case library = "Library"
        case upcoming = "Upcoming"
        case chat = "Chat"
        // `.add` (Search) removed — the queue's floating filter bar
        // now doubles as a global search. Empty filter → queue rows;
        // typing → queue rows that match + library/add-new candidates
        // pulled via `SearchViewModel`. One surface, both jobs.

        /// Every tab renders as its glyph by default; only the ACTIVE tab
        /// expands to its text label. Four labels ("Nadchodzące",
        /// "Warteschlange") never fit the 400 pt bar side by side — one
        /// label + three glyphs always do.
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
            // Dropping onto the open panel is the most discoverable route, but
            // it deliberately does NOT get its own inline UI: the URLs are
            // handed to AppDelegate, which opens the same add window that Dock
            // drops, "Open With" and magnet clicks use. One add surface, four
            // ways in. (A drop the app can't download is filtered out there,
            // not here — this side has no business knowing what a client takes.)
            .dropDestination(for: URL.self) { urls, _ in
                // Deferred for the same reason the menu-bar drop defers: this
                // runs inside the drag handling, and opening a window from
                // there can leave the drag session's tracking loop wedged.
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .arrBarrDropDownloads,
                        object: nil,
                        userInfo: ["urls": urls]
                    )
                }
                return true
            }
            #endif
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
                    whisparrConfig: configStore.whisparr,
                    tmdbApiKey: configStore.tmdbApiKey
                )
                chatHolder.reconfigure(store: configStore)
                // The panel is on screen (menu-bar popover opened, or the
                // detached window is visible) — poll at the fast foreground
                // cadence and refresh right now. macOS had no foreground tier
                // before: it sat on the 30 s background timer even while open.
                viewModel.startForegroundPolling()
                focusInputForCurrentTab()
                #if os(macOS)
                commandKey.start()
                #endif
            }
            .onDisappear {
                // Panel closed — drop back to the background cadence so we're
                // not hammering the arrs every few seconds while hidden.
                viewModel.stopForegroundPolling()
                #if os(macOS)
                commandKey.stop()
                #endif
            }
            .onChange(of: ChatViewModelHolder.signature(store: configStore)) { _, _ in
                chatHolder.reconfigure(store: configStore)
            }
            .onChange(of: chatAvailable) { _, available in
                if !available && selectedTab == .chat {
                    selectedTab = .queue
                }
            }
            // Switching tabs clears any pushed detail / search / history so a
            // detail opened on one tab (e.g. an Upcoming item in the detached
            // window) can't leave its title chrome lingering on another tab.
            // Mirrors iOS's per-tab NavigationStack isolation.
            .onChange(of: selectedTab) { _, _ in
                detailItem = nil
                searchResult = nil
                historySource = nil
                focusInputForCurrentTab()
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
                // ⌘1 / ⌘2 / ⌘3 — jump straight to a tab, the same numbering
                // Safari / Finder / Mail use. Keyed off `visibleTabs`, NOT
                // `Tab.allCases`, so the numbers always match the pills the
                // user is looking at: with chat unavailable there is no third
                // pill, and ⌘3 correctly does nothing rather than landing on a
                // tab that isn't on screen. Capped at 9 — ⌘0 means something
                // else everywhere.
                ForEach(Array(visibleTabs.prefix(9).enumerated()), id: \.element) { index, tab in
                    Button("") { selectTab(tab) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                }
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
        // Named because each parked layer states the same condition four times
        // over, once per mechanism, and a four-line stack of raw `!=  nil ||`
        // chains hides the one that's missing.
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
                                selecting: $queueSelecting
                            )
                        case .library:
                            LibraryTabContent(viewModel: libraryViewModel)
                        case .upcoming: UpcomingTabContent(viewModel: viewModel)
                        case .chat:
                            ChatTabContent(chatHolder: chatHolder)
                        }
                    }
                } else {
                    PopoverEmptyState(onOpenSettings: onOpenSettings) { moreMenu }
                }
            }
            // Tab content stays mounted under the overlays (SearchAddPanel,
            // DetailView, Discover) so scroll positions, expanded sections and
            // other transient view-state survive a round-trip.
            //
            // Parking it takes all four: invisible, unclickable, inert, and out
            // of the accessibility tree. They are four independent mechanisms,
            // and skipping one leaks in a way the others hide. `.disabled` is
            // the one that silences the queue filter TextField's pointer
            // region — neither opacity nor hit-testing touches the cursor, so
            // an invisible field kept handing the I-beam to whatever was drawn
            // over it, which is exactly where SearchAddPanel puts its Add CTAs.
            .opacity(tabContentParked ? 0 : 1)
            .allowsHitTesting(!tabContentParked)
            .disabled(tabContentParked)
            .accessibilityHidden(tabContentParked)

            if showDiscoverOverlay {
                DiscoverTabView(
                    viewModel: discoverViewModel,
                    llmAvailable: chatAvailable,
                    radarrAvailable: radarrConfigured,
                    // The top-up round IS a chat turn, so the agent's own
                    // thinking flag is what the deck should wait on.
                    moreInFlight: chatHolder.vm.isThinking,
                    onClose: {
                        withAnimation(.smooth(duration: 0.22)) { showDiscoverOverlay = false }
                    },
                    onRequestMore: { mood, kept, skipped in
                        requestMoreQuizPicks(mood: mood, kept: kept, skipped: skipped)
                    }
                )
                // Parked (but kept mounted) when SearchAddPanel or DetailView
                // opens on top — otherwise the picks list bleeds through under
                // the detail surface, which has no opaque background of its
                // own. Same four as above: Discover doesn't own a TextField
                // today, so nothing leaks *yet*, but a half-parked layer is
                // how this bug arrived in the first place.
                .opacity(discoverParked ? 0 : 1)
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

    /// Switch tabs the way the tab pill does — same Pro gate, same spring —
    /// so ⌘1/2/3 and a click are genuinely the same action. Kept next to
    /// `visibleTabs` because the two have to agree on what's reachable.
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
            case .chat: return chatAvailable
            default:    return true
            }
        }
    }

    /// Services the Quiz's "More picks like these" button. A chat-seeded deck
    /// IS the session (see `DiscoverViewModel.seed`) — fresh picks can only come
    /// from the agent, so "more" round-trips through the chat: this prompt makes
    /// the model call `discover_in_quiz` again with `append: true`, which extends
    /// the live deck via the `.arrBarrOpenDiscoverQuiz` handler. `mood` + the
    /// already-shown picks live in the chat history, so the model has the "like
    /// these" context without us stuffing every title into the visible message.
    /// Without this wiring the button fell back to `onRequestMore`'s no-op
    /// default and did nothing.
    private func requestMoreQuizPicks(mood: String, kept: [DiscoverItem], skipped: [DiscoverItem]) {
        // No LLM, or a turn already running → the round-trip can't land; skip
        // rather than queue a message that silently never resolves.
        guard chatAvailable, !chatHolder.vm.isThinking else { return }
        // In-app language, not the process language — see AppLocalized. Otherwise
        // the sent message (and the model's whole reply) lags a live language
        // switch until relaunch.
        let prompt = AppLocalized.string("discover.moreLikeThese.chatPrompt", locale: configStore.currentLocale)
        Task { await chatHolder.vm.send(prompt) }
    }

    private var tabBar: some View {
        // A row of floating glass capsules, all the SAME height: the tab cluster
        // (Queue / Upcoming / Chat / Add) sets the height via its natural size;
        // the optional windowed-mode close island (far left), the optional
        // offline chip, and the accessory island (detach toggle + kebab) match it
        // through `pillHeight`. The cluster pill stretches to fill all space
        // between, so long labels (Polish "Nadchodzące") aren't squeezed and the
        // chrome spans the whole row.
        HStack(spacing: 8) {
            // Detached mode uses the real macOS traffic lights (floating top-left,
            // only the red × active) instead of a custom in-bar close dot, so the
            // tab bar is now identical in both surfaces — no leading close island.
            tabPills
                .frame(maxWidth: .infinity)
                .glassyFloatingBar()
            // Quiet "you've left the LAN" chip — only present while the whole
            // stack is unreachable, slotted between the tabs and the kebab so
            // it reads as ambient status, not an alert.
            if viewModel.isFullyOffline {
                OfflineIndicator(viewModel: viewModel)
                    .padding(.horizontal, 12)
                    .frame(height: Self.pillHeight)
                    .glassyFloatingBar()
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            // One island: the detach/attach toggle sits left of the kebab,
            // both inside a single glass capsule (like the tab cluster nests
            // its buttons in one capsule).
            HStack(spacing: 0) {
                #if os(macOS)
                detachToggleButton
                #endif
                moreMenu
                #if os(macOS)
                // Detached window's close affordance: last item of the right
                // island (the native traffic lights are hidden). Absent in the
                // menu-bar panel, which dismisses itself on focus loss.
                if isDetachedWindow, let onCloseWindow {
                    windowCloseButton(action: onCloseWindow)
                }
                #endif
            }
            // Small horizontal breathing room so the island's glyphs don't sit
            // flush against the capsule rim (read as cramped otherwise).
            .padding(.horizontal, 4)
            .glassyFloatingBar()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isFullyOffline)
    }

    #if os(macOS)
    /// The detached window's × close button — styled like the detach + kebab
    /// glyphs it sits beside (bare secondary glyph in the shared island capsule).
    private func windowCloseButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: Self.pillHeight, height: Self.pillHeight)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(Text("Close window", bundle: .module))
        .accessibilityLabel(Text("Close window", bundle: .module))
    }
    #endif

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

    /// While ⌘ is held the tab labels crossfade to their ⌘-number, so the
    /// shortcut is discoverable without a menu (the numbering is the same one
    /// the hidden ⌘1…⌘9 buttons register — both read `visibleTabs`).
    /// `nil` on iOS / when the tab is past the ninth (no shortcut to show).
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
            // Edge Spacer at start + between every tab gives n+1 evenly
            // sized flex slots — the cluster's extra width is split as
            // uniform gutters, so tabs visually breathe across the full
            // pill instead of clumping left. (The windowed-mode close
            // button now lives in its OWN island left of the cluster — see
            // `tabBar` — not as a pseudo-tab here.)
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
                        // Active tab = its text label; every other tab = its
                        // glyph. The selection indicator resizes from the
                        // measured `tabFrames`, so the icon→text width jump
                        // animates inside the same selection spring.
                        // Explicit `.transition(.opacity)` on both branches:
                        // without it the freshly-inserted Text picks up the
                        // default insertion transition inside the animated
                        // HStack relayout and reads as "the label slides in
                        // from the left" instead of a crossfade-in-place.
                        if selectedTab == tab {
                            Text(LocalizedStringKey(tab.rawValue), bundle: .module)
                                .scaledFont(size: 12, weight: .semibold)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: true, vertical: false)
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
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    // Horizontal/vertical padding sets the breathing room INSIDE
                    // the selection pill. The tab cluster's resulting natural
                    // height (~32 at default scale) is the canonical bar height;
                    // the accessory / close / offline islands grow to match it
                    // via `pillHeight` (they don't shrink the tabs).
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    // ⌘-number sits *beside* the label, parked in the pill's own
                    // 18pt trailing padding — an overlay, so it never enters the
                    // layout and can't resize a tab (which would jolt the
                    // selection indicator mid-spring, see the stabiliser above).
                    .overlay(alignment: .trailing) {
                        if let hint = commandHint(for: tab) {
                            Text(hint)
                                .scaledFont(size: 9, weight: .semibold)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .padding(.trailing, 3)
                                .transition(.opacity)
                                .accessibilityHidden(true)
                        }
                    }
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
            // The icon⇄text swap moves EVERY tab's frame (the old active tab
            // narrows, the new one widens, everything downstream shifts).
            // This preference fires OUT OF BAND from the selection spring, so
            // an unanimated assignment made the indicator snap to the new
            // geometry mid-flight — selecting rightward it read as the pill
            // teleporting left and sliding back in from the window edge.
            // (Leftward looked fine only because the target tab sits before
            // the width change, so its minX barely moves.) Animating the
            // assignment with the SAME spring folds the correction into one
            // continuous glide. First layout populates without animation —
            // there's nothing on screen to glide from yet.
            if tabFrames.isEmpty {
                tabFrames = newFrames
            } else {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    tabFrames = newFrames
                }
            }
        }
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
            GeometryReader { geo in
                if let rect = selectionPillRect(in: geo.size) {
                    TabPillBackground()
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        )
    }

    /// Geometry for the selected-tab indicator. Fills the tab's *slot* — its
    /// label box plus ~half the gutter to each neighbour — so the pill reads as a
    /// full segment in both surfaces. This replaced a fixed `width + 24`, which
    /// under-filled the roomy popover gutters yet over-filled (spilled past the
    /// bar) when the detached close-island squeezed the tabs. Measuring the real
    /// gaps from `tabFrames` makes the fill mode-agnostic.
    private func selectionPillRect(in container: CGSize) -> CGRect? {
        guard let frame = tabFrames[selectedTab] else { return nil }
        let ordered = visibleTabs
            .compactMap { tab in tabFrames[tab].map { (tab, $0) } }
            .sorted { $0.1.minX < $1.1.minX }
        guard let idx = ordered.firstIndex(where: { $0.0 == selectedTab }) else { return nil }

        // Breathing room kept between adjacent pills so they don't visually touch.
        let gap: CGFloat = 3
        // Inner edges meet a neighbour: stop halfway across the gutter (minus the
        // breathing gap). Outer edges of the end tabs reach halfway to the bar's
        // inner edge, so every pill is symmetric regardless of gutter size.
        let leftEdge = idx > 0
            ? (ordered[idx - 1].1.maxX + frame.minX) / 2 + gap
            : frame.minX / 2
        let rightEdge = idx < ordered.count - 1
            ? (ordered[idx + 1].1.minX + frame.maxX) / 2 - gap
            : (frame.maxX + container.width) / 2

        // Vertically inset 6pt (3pt rim top + bottom) to stay a clean capsule
        // inside the bar, which is only as tall as the tab button.
        let height = max(0, frame.height - 6)
        return CGRect(x: leftEdge, y: frame.midY - height / 2,
                      width: max(0, rightEdge - leftEdge), height: height)
    }

    /// Height of the accessory / close / offline islands — set to MATCH the tab
    /// cluster's natural height (its per-tab `.padding(.vertical, 9)` + 12pt font
    /// lands around 32pt), so every capsule in the toolbar is the same height
    /// (the tabs keep their natural size; these grow up to them). Keep in sync if
    /// the tab vertical padding / font ever moves.
    private static let pillHeight: CGFloat = 32

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
            // Queue multi-select — only on the Queue tab, and only with rows to act on.
            if selectedTab == .queue, viewModel.activeCount > 0 {
                Button { queueSelecting = true } label: {
                    Label { Text("queue.selectMultiple.button", bundle: .module) } icon: { Image(systemName: "checkmark.circle") }
                }
                Divider()
            }
            // No "Refresh" item — the queue refreshes itself and ⌘R (the
            // hidden button above) stays for power users; a manual refresh
            // verb in the menu just suggested the app needs babysitting.
            Button { onOpenSettings() } label: { Text("common.settings2.button", bundle: .module) }
                .keyboardShortcut(",", modifiers: .command)
            #if os(macOS)
            Button { onShowAbout() } label: { Text("settings.aboutArrbarr.button", bundle: .module) }
            // The detach/re-attach toggle now lives in the header island next to
            // the kebab (see detachToggleButton), so it's dropped from here.
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

    #if os(macOS)
    /// Detach the popover into a free-floating window — or, when already
    /// detached, re-attach it to the menu bar. Pure data toggle on the shared
    /// ConfigStore; AppDelegate observes `$detachedWindow` and opens/closes the
    /// window. Glyph + tooltip flip on `isDetachedWindow`. Bare (no glass) — the
    /// wrapping island capsule supplies the chrome.
    private var detachToggleButton: some View {
        Button {
            let wasInPopover = !isDetachedWindow
            configStore.detachedWindow.toggle()
            // Detaching from the menu-bar panel: dismiss the popover so it doesn't
            // hang around behind the freshly-opened window. (Re-attaching from the
            // window is handled by AppDelegate closing the NSWindow.)
            if wasInPopover { dismiss() }
        } label: {
            Image(systemName: isDetachedWindow ? "menubar.arrow.up.rectangle" : "macwindow.on.rectangle")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: Self.pillHeight, height: Self.pillHeight)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(Text(isDetachedWindow ? "common.reattachToMenuBar.button" : "common.detachIntoAWindow.button", bundle: .module))
        .accessibilityLabel(Text(isDetachedWindow ? "common.reattachToMenuBar.button" : "common.detachIntoAWindow.button", bundle: .module))
    }
    #endif

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
        // Capsule to match GlassProminentButtonStyle — the secondary "Add to
        // Radarr" next to a capsule "Add and search" read as a leftover
        // rectangle otherwise.
        if #available(macOS 26.0, iOS 26.0, *) {
            content.buttonStyle(.glass).buttonBorderShape(.capsule)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }
}

public struct GlassProminentButtonStyle: ViewModifier {
    public func body(content: Content) -> some View {
        // Capsule everywhere — one shape decision for every prominent CTA.
        // Labels get an explicit solid white: glassProminent renders its
        // default label with vibrancy blending, which reads as translucent
        // text (and made the red trash glyph illegible on gray glass).
        // Call sites with a semantic glyph colour (the red trash) override
        // it locally — an inner foregroundStyle wins over this outer one.
        if #available(macOS 26.0, iOS 26.0, *) {
            content
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .foregroundStyle(.white)
        } else {
            content
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .foregroundStyle(.white)
        }
    }
}
