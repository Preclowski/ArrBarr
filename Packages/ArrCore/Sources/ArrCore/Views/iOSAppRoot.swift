#if os(iOS)
import SwiftUI
import CoreSpotlight

/// Root view for the iOS app target.
///
/// Apple's HIG points iOS apps at a `TabView` for top-level navigation
/// rather than the segmented control + popover pattern used on macOS.
/// This view assembles the same data the menu-bar popover shows, but
/// arranged across four tabs (Queue / Upcoming / Search / Settings)
/// each with its own `NavigationStack` for drill-down.
///
/// Construction lives inside `ArrCore` so the iOS app target can
/// reach the package's section views (NeedsYouHeader / NeedsYouRow,
/// QueueListView, etc.) without us having to expose every
/// internal initialiser publicly.
public struct iOSAppRoot: View {
    @State private var viewModel: QueueViewModel
    @ObservedObject private var configStore: ConfigStore
    @ObservedObject private var storeManager = StoreManager.shared
    /// The one live trailer — surfaces (DetailView / SearchAddPanel / Quiz)
    /// start it, this root renders it. See `TrailerSession`.
    @ObservedObject private var trailerSession = TrailerSession.shared
    @Environment(\.scenePhase) private var scenePhase
    /// Shared by the Queue and Library surfaces.
    @State private var searchVM: SearchViewModel
    /// The Library tab's cache, owned up here so the queue's library-only
    /// search reads the same one instead of loading a second copy.
    @State private var libraryViewModel: LibraryViewModel
    /// The quiz deck is raised by a notification from ANY tab (chat's CTA, the
    /// resume card), so its state and its chat bridge live above the TabView —
    /// the same place `PopoverContentView` keeps them on macOS.
    @State private var chatHolder = ChatViewModelHolder()
    @State private var discoverViewModel = DiscoverViewModel.shared
    @State private var quizAddResult: SearchResult?
    /// Which tab is on screen. `DetailRouter` is published to by surfaces that
    /// live in several stacks at once (library tiles, chat cards, Spotlight), and
    /// every stack that listens would push its own copy — leaving a stale detail
    /// waiting behind the tabs the user never looked at. Listeners check this.
    @State private var selectedTab: RootTab = .queue
    /// Whether the queue's search field is open. Owned here so leaving the tab
    /// can close it — but only when it is empty: a field showing results is
    /// state the user built, and dropping it on a tab switch loses their query.
    @State private var searchPresented = false

    enum RootTab: Hashable { case queue, library, upcoming, chat, settings }

    /// What the app already knows about that matches the query — live queue
    /// rows and owned titles from every loaded library. The same on every tab.
    private var localHits: [LocalHit] {
        guard searchVM.isActive else { return [] }
        return LocalHit.hits(
            queue: viewModel, library: libraryViewModel,
            sources: QueueItem.Source.allCases.filter { configStore.config(for: $0.serviceKind).isVisible },
            query: searchVM.query)
    }

    /// "More picks like these" is a chat turn — the mood and the already-shown
    /// titles are in the conversation, so the model has the context without us
    /// stuffing them into the visible message.
    private func requestMoreQuizPicks() {
        guard configStore.aiConfigured, !chatHolder.vm.isThinking else { return }
        let prompt = AppLocalized.string("discover.moreLikeThese.chatPrompt", locale: configStore.currentLocale)
        Task { await chatHolder.vm.send(prompt) }
    }

    public init(viewModel: QueueViewModel? = nil, configStore: ConfigStore? = nil) {
        let vm = viewModel ?? QueueViewModel(configStore: .shared)
        let cs = configStore ?? .shared
        self._viewModel = State(initialValue: vm)
        self._configStore = ObservedObject(wrappedValue: cs)
        let library = LibraryViewModel()
        let search = SearchViewModel()
        search.library = library
        self._libraryViewModel = State(initialValue: library)
        self._searchVM = State(initialValue: search)
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            Tab(value: RootTab.queue) {
                NavigationStack { QueueTab(viewModel: viewModel, searchVM: searchVM, localHits: localHits, isActive: selectedTab == .queue, searchPresented: $searchPresented) }
            } label: {
                Label { Text("paywall.queue.button", bundle: .module) } icon: { Image(systemName: "arrow.down.circle") }
            }

            Tab(value: RootTab.library) {
                NavigationStack { LibraryTab(searchVM: searchVM, localHits: localHits, libraryViewModel: libraryViewModel, viewModel: viewModel, isActive: selectedTab == .library, searchPresented: $searchPresented) }
            } label: {
                Label { Text("Library", bundle: .module) } icon: { Image(systemName: "books.vertical") }
            }

            Tab(value: RootTab.upcoming) {
                NavigationStack { UpcomingTab(viewModel: viewModel, searchVM: searchVM, localHits: localHits, isActive: selectedTab == .upcoming, searchPresented: $searchPresented) }
            } label: {
                Label { Text("queue.upcoming.button", bundle: .module) } icon: { Image(systemName: "calendar") }
            }

            if configStore.aiConfigured {
                Tab(value: RootTab.chat) {
                    NavigationStack {
                        if storeManager.isPro {
                            ChatTab(chatHolder: chatHolder)
                        } else {
                            ChatLockedPlaceholder { storeManager.gate(.chat) }
                        }
                    }
                } label: {
                    Label {
                        Text("paywall.chat.button", bundle: .module)
                    } icon: {
                        Image(systemName: storeManager.isPro ? "sparkles" : "lock.fill")
                    }
                }
            }

            Tab(value: RootTab.settings) {
                NavigationStack { SettingsTab(viewModel: viewModel) }
            } label: {
                Label { Text("common.settings.button", bundle: .module) } icon: { Image(systemName: "gearshape") }
            }
        }
        .environmentObject(configStore)
        // Root-owned so the quiz's chat bridge works even before the Chat tab
        // has ever been shown.
        .onAppear {
            chatHolder.reconfigure(store: configStore)
            searchVM.setup(store: configStore)
        }
        .onChange(of: ChatViewModelHolder.signature(store: configStore)) { _, _ in
            chatHolder.reconfigure(store: configStore)
        }
        // Root-owned as well, and re-run on a config edit: the search clients
        // are built once from the config, and the Queue tab's `onAppear` fires
        // only the first time that tab is built — a server changed in Settings
        // afterwards left every search talking to the old one.
        .onChange(of: SearchViewModel.configSignature(store: configStore)) { _, _ in
            searchVM.setup(store: configStore)
        }
        // An empty search field left open behind a tab switch is just chrome
        // taking a row; one with a query is a result set worth returning to.
        .onChange(of: selectedTab) { _, _ in
            if !searchVM.isActive { searchPresented = false }
        }
        // Swiping a not-in-library pick right asks for the add panel. macOS
        // hosts it in the popover; without this the whole "add" half of the
        // quiz — and chat's "add this missing title" cards — did nothing here.
        .onSearchAddRequest { result, _ in quizAddResult = result }
        // Queue rows raise their delete through `ConfirmCenter` on both
        // platforms; without a host here the long-press "Remove from queue"
        // asked a question nobody ever showed.
        .confirmCenterHost()
        // The deck decides when it is on screen (`DiscoverViewModel.open`) —
        // seeded by the `discover_in_quiz` tool or the chat resume card.
        .fullScreenCover(isPresented: $discoverViewModel.isPresented) {
            DiscoverTabView(
                viewModel: discoverViewModel,
                llmAvailable: configStore.aiConfigured,
                radarrAvailable: configStore.radarr.isVisible,
                // The top-up round IS a chat turn, so the agent's own thinking
                // flag is what the deck should wait on.
                moreInFlight: chatHolder.vm.isThinking,
                isObscured: quizAddResult != nil,
                onClose: { discoverViewModel.isPresented = false },
                onCancelLoading: {
                    chatHolder.vm.cancelTurn()
                    discoverViewModel.endLoading()
                },
                onRequestMore: { _, _, _ in requestMoreQuizPicks() }
            )
            .environmentObject(configStore)
            .sheet(item: $quizAddResult) { result in
                NavigationStack {
                    SearchAddPanel(result: result, viewModel: searchVM) {
                        quizAddResult = nil
                    }
                }
                // A sheet nested inside a fullScreenCover starts a fresh
                // presentation context and does NOT inherit the cover's
                // environment: without this `SearchAddPanel.loadCast` traps on
                // a missing ConfigStore the moment a right-swipe opens it.
                .environmentObject(configStore)
            }
            // The root's overlay renders *under* this cover — a fullScreenCover
            // is its own presentation context — so the deck needs its own copy
            // or the trailer button opens nothing. Same shared session, so only
            // one clip can ever be playing.
            .trailerOverlay(key: Binding(
                get: { trailerSession.key },
                set: { newValue in
                    if let newValue { trailerSession.present(newValue) } else { trailerSession.dismiss() }
                }
            ))
        }
        // The trailer overlay for the tab tree. The quiz cover carries its own
        // (a fullScreenCover is a separate presentation context), and the two
        // must never be live at once: both would build a `TrailerWebView` for
        // the same key, and since the session hands out ONE WKWebView the second
        // steals it from the first — which is what blanked the picture on
        // rotation. While the deck is up, the deck's copy owns the clip.
        .trailerOverlay(key: Binding(
            get: { discoverViewModel.isPresented ? nil : trailerSession.key },
            set: { newValue in
                if let newValue { trailerSession.present(newValue) } else { trailerSession.dismiss() }
            }
        ))
        .fullScreenCover(isPresented: Binding(
            get: { storeManager.gatedFeature != nil },
            set: { if !$0 { storeManager.dismissPaywall() } }
        )) {
            PaywallView(context: storeManager.gatedFeature) {
                storeManager.dismissPaywall()
            }
        }
        // Slightly larger baseline type on iOS — the shared sizes read small
        // on phone. (macOS uses the preset unchanged.) `effectiveFontScale`
        // applies the iOS bump; see `appFontScale`.
        .appFontScale(configStore)
        .preferredColorScheme(configStore.preferredColorScheme)
        // Foreground polling while the app is open (fixed 5s — see
        // ConfigStore). startForegroundPolling() also fires an immediate
        // refresh. Stopped when backgrounded; iOS suspends the timer anyway,
        // but stopping avoids a stale burst the instant we resume.
        .onAppear {
            viewModel.startForegroundPolling()
            // Index the library into Spotlight (fire-and-forget, batched).
            SpotlightIndexer.reindex(configStore: configStore)
            // Warm the chat empty-state poster deck so it's instant on entry.
            LibraryPosterSampler.warmUp(configStore: configStore)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                viewModel.startForegroundPolling()
                // Re-index on foreground so posters cached while browsing get
                // picked up (cached-only thumbnails). Throttled inside reindex.
                SpotlightIndexer.reindex(configStore: configStore)
            case .inactive, .background: viewModel.stopForegroundPolling()
            @unknown default: break
            }
        }
        // Tapping a Spotlight result opens the item's detail in the app.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                  let ref = SpotlightIndexer.parse(id) else { return }
            // Small delay so the (cold-launched) Queue tab's detail listener is
            // mounted before we post — otherwise the notification is missed.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                DetailRequest.post(DetailRequest.syntheticItem(source: ref.source, entityId: ref.id, title: ""))
            }
        }
    }
}

// MARK: - Chat locked placeholder

private struct ChatLockedPlaceholder: View {
    let onUnlock: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
            Text("common.chatIsAPro.button", bundle: .module).font(.headline)
            Button { onUnlock() } label: { Text("settings.unlockArrbarrPro.button", bundle: .module) }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .onAppear { onUnlock() }
    }
}

// MARK: - Queue tab

private struct QueueTab: View {
    var viewModel: QueueViewModel
    var searchVM: SearchViewModel
    var localHits: [LocalHit]
    var isActive: Bool
    @Binding var searchPresented: Bool
    @EnvironmentObject var configStore: ConfigStore
    @State private var detailItem: QueueItem?
    @State private var searchResult: SearchResult?
    @State private var selecting = false
    /// History is reached from the queue's per-arr section header, the way the
    /// macOS popover does it — it no longer owns a tab of its own.
    @State private var historySource: QueueItem.Source?

    private var searchAvailable: Bool {
        QueueItem.Source.allCases.contains { configStore.config(for: $0.serviceKind).isVisible }
    }

    var body: some View {
        queueContent
        .refreshable { await viewModel.refresh() }
        // No nav-bar title — it only duplicated the tab-bar label below.
        .navigationBarTitleDisplayMode(.inline)
        // Quiet offline chip where the (absent) title would sit. Only present
        // while the whole stack is unreachable — pull-to-refresh and tapping
        // the chip both re-probe.
        .toolbar {
            if viewModel.isFullyOffline {
                ToolbarItem(placement: .topBarLeading) {
                    OfflineIndicator(viewModel: viewModel)
                }
            }
            // Edit mode owns the bar: QueueListView puts Select all / Done
            // there, so our own actions step aside rather than crowd them.
            if !selecting {
                ToolbarItem(placement: .topBarTrailing) { selectButton }
            }
        }
        // Files and Mail both drop the tab bar while editing — it is the only
        // way the bottom action bar has anywhere to draw, and it stops the tab
        // bar offering navigation away from a half-made selection.
        .toolbar(selecting ? .hidden : .visible, for: .tabBar)
        // Search-to-add App Intent → run the search here.
        .onMessage(AppMessages.SearchQuery.self) { message in
            searchResult = nil
            searchVM.query = message.query
        }
        .navigationDestination(item: $detailItem) { item in
            DetailView(item: item, onBack: { detailItem = nil }, viewModel: viewModel)
        }
        .navigationDestination(item: $historySource) { source in
            HistoryTab(viewModel: viewModel, initialSource: source)
        }
        // In-library search hits route through `DetailRouter` — listen for it
        // here so they push the detail (Upcoming tab does the same).
        .onDetailRequest { item in
            guard isActive else { return }
            detailItem = item
        }
    }

    @ViewBuilder
    private var queueContent: some View {
        if let result = searchResult {
            SearchAddPanel(result: result, viewModel: searchVM) {
                searchResult = nil
            }
        } else {
            // Search steps aside entirely in edit mode: its magnifier otherwise
            // competes with "Done" for the trailing slot and wins, leaving no
            // way out of the mode. Mail and Files drop their search bar there too.
            SearchHost(
                searchVM: searchVM,
                localHits: localHits,
                searchAvailable: searchAvailable,
                enabled: !selecting,
                isPresented: $searchPresented,
                onSelectQueueItem: { detailItem = $0 },
                onSelectAddResult: { searchResult = $0 }
            ) {
                QueueListView(
                    viewModel: viewModel,
                    onShowDetail: { detailItem = $0 },
                    onNeedsYouTap: { needs in openNeedsYouQueue(needs) },
                    onShowHistory: { historySource = $0 },
                    selecting: $selecting
                )
            }
        }
    }

    /// Multi-select entry, beside the collapsed search button. A menu holding a
    /// single item is a pointless extra tap — the icon IS the action, the way
    /// Photos and Files put "Select" straight in the bar.
    private var selectButton: some View {
        Button {
            selecting = true
        } label: {
            Label { Text("queue.select.button", bundle: .module) } icon: { Image(systemName: "checklist") }
        }
        .disabled(selecting)
        .accessibilityLabel(Text("queue.select.button", bundle: .module))
    }

    /// Arr-level "Needs you" rows have no queue detail to push — open that arr's
    /// own queue page instead, the same handler the macOS popover wires.
    private func openNeedsYouQueue(_ needs: NeedsYouItem) {
        guard let source = needs.source else { return }
        let cfg = configStore.config(for: source.serviceKind)
        guard let url = ArrActivityURLBuilder.queueURL(forBase: cfg.baseURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return }
        PlatformURLOpener.open(url)
    }
}

/// The scope bar, hand-rolled. `.searchScopes` cannot do what we need here:
/// with `.toolbar` placement `.automatic` withholds the bar until the first
/// keystroke, and `.onSearchPresentation` — which reads like the fix — drops it
/// altogether. Scopes say WHERE the search will look, so they have to be on
/// screen while the field is still empty and the user is deciding.
struct SearchScopeBar: View {
    @Bindable var searchVM: SearchViewModel
    let scopes: [SearchScope]
    @Environment(\.isSearching) private var isSearching

    var body: some View {
        if isSearching {
            HStack(spacing: 8) {
                if scopes.count > 1 {
                    Picker("", selection: $searchVM.scope) {
                        ForEach(scopes) { s in
                            Text(LocalizedStringKey(s.labelKey), bundle: .module).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } else {
                    Spacer(minLength: 0)
                }
                libraryOnlyToggle
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    /// "In library" — narrows the search to titles the user owns. Beside the
    /// scopes rather than among them because it combines with any of them;
    /// a glyph because the segmented scopes already fill the row.
    private var libraryOnlyToggle: some View {
        Button { searchVM.libraryOnly.toggle() } label: {
            Image(systemName: searchVM.libraryOnly ? "books.vertical.fill" : "books.vertical")
                .foregroundStyle(searchVM.libraryOnly ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("search.libraryOnly.toggle", bundle: .module))
        .accessibilityAddTraits(searchVM.libraryOnly ? .isSelected : [])
    }
}

/// The one iOS search field, used by the Queue and Library tabs. Withdrawn
/// while multi-select owns the toolbar: its magnifier otherwise competes with
/// "Done" for the trailing slot and wins, leaving no way out of the mode.
struct SearchField: ViewModifier {
    @Bindable var searchVM: SearchViewModel
    let enabled: Bool
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .searchable(
                    text: $searchVM.query,
                    isPresented: $isPresented,
                    placement: .toolbar,
                    prompt: Text("search.global.prompt", bundle: .module)
                )
                // iOS 26 collapses the field into a toolbar magnifier that
                // expands on tap, so search shares a row with the other actions
                // instead of a permanent drawer stealing one from the list.
                // `SearchScopeBar` renders the scopes under it; `.searchScopes`
                // can't, see that type's note.
                .modifier(MinimizedSearchToolbar())
                .autocorrectionDisabled(true)
        } else {
            content
        }
    }
}

struct MinimizedSearchToolbar: ViewModifier {
    func body(content: Content) -> some View {
        content.searchToolbarBehavior(.minimize)
    }
}

// MARK: - Library tab

/// Same surface macOS shows in its `.library` tab, under the same `SearchHost`.
/// This wrapper only supplies the add-panel slot the popover fills from
/// `PopoverContentView`.
private struct LibraryTab: View {
    var searchVM: SearchViewModel
    var localHits: [LocalHit]
    var libraryViewModel: LibraryViewModel
    var viewModel: QueueViewModel
    var isActive: Bool
    @Binding var searchPresented: Bool
    @EnvironmentObject var configStore: ConfigStore
    @State private var searchResult: SearchResult?
    @State private var detailItem: QueueItem?

    var body: some View {
        Group {
            if let result = searchResult {
                SearchAddPanel(result: result, viewModel: searchVM) {
                    searchResult = nil
                }
            } else {
                SearchHost(
                    searchVM: searchVM,
                    localHits: localHits,
                    searchAvailable: QueueItem.Source.allCases.contains { configStore.config(for: $0.serviceKind).isVisible },
                    isPresented: $searchPresented,
                    onSelectQueueItem: { detailItem = $0 },
                    onSelectAddResult: { searchResult = $0 }
                ) {
                    LibraryTabContent(viewModel: libraryViewModel)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $detailItem) { item in
            DetailView(item: item, onBack: { detailItem = nil }, viewModel: viewModel)
        }
        // Library tiles open through `DetailRequest.post`, same as queue rows.
        // Without this the tap posted into a tab that wasn't listening and
        // nothing happened.
        .onDetailRequest { item in
            guard isActive else { return }
            detailItem = item
        }
    }
}

// MARK: - Upcoming tab

private struct UpcomingTab: View {
    var viewModel: QueueViewModel
    var searchVM: SearchViewModel
    var localHits: [LocalHit]
    var isActive: Bool
    @Binding var searchPresented: Bool
    @EnvironmentObject var configStore: ConfigStore
    @State private var detailItem: QueueItem?
    @State private var searchResult: SearchResult?

    var body: some View {
        Group {
            if let result = searchResult {
                SearchAddPanel(result: result, viewModel: searchVM) {
                    searchResult = nil
                }
            } else {
                SearchHost(
                    searchVM: searchVM,
                    localHits: localHits,
                    searchAvailable: QueueItem.Source.allCases.contains { configStore.config(for: $0.serviceKind).isVisible },
                    isPresented: $searchPresented,
                    onSelectQueueItem: { detailItem = $0 },
                    onSelectAddResult: { searchResult = $0 }
                ) {
                    upcomingList
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if viewModel.isFullyOffline {
                ToolbarItem(placement: .topBarLeading) {
                    OfflineIndicator(viewModel: viewModel)
                }
            }
        }
        .refreshable { await viewModel.refresh() }
        .navigationDestination(item: $detailItem) { item in
            DetailView(item: item, onBack: { detailItem = nil }, viewModel: viewModel)
        }
        // UpcomingRowView's `openDetail()` publishes on `DetailRouter` —
        // wire it to push DetailView, same pattern as the macOS panel.
        .onDetailRequest { item in
            guard isActive else { return }
            detailItem = item
        }
    }

    @ViewBuilder
    private var upcomingList: some View {
        if viewModel.upcoming.isEmpty {
            emptyState
        } else {
            List {
                ForEach(grouped, id: \.label) { group in
                    Section(group.label) {
                        ForEach(group.items) { item in
                            UpcomingRowView(item: item)
                                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private struct UpcomingGroup {
        let label: String
        let items: [UpcomingItem]
    }

    private var grouped: [UpcomingGroup] {
        let calendar = Calendar.current
        var groups: [UpcomingGroup] = []
        var current: (date: DateComponents, items: [UpcomingItem])?
        for item in viewModel.upcoming {
            let dc = calendar.dateComponents([.year, .month, .day], from: item.airDate)
            if let c = current, c.date == dc {
                current?.items.append(item)
            } else {
                if let c = current, let first = c.items.first {
                    groups.append(UpcomingGroup(
                        label: first.airDateFormatted(locale: configStore.currentLocale),
                        items: c.items
                    ))
                }
                current = (dc, [item])
            }
        }
        if let c = current, let first = c.items.first {
            groups.append(UpcomingGroup(
                label: first.airDateFormatted(locale: configStore.currentLocale),
                items: c.items
            ))
        }
        return groups
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar")
                .scaledFont(size: 36, weight: .light)
                .foregroundStyle(.tertiary)
            Text("common.nothingUpcoming.button", bundle: .module)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Chat tab

private struct ChatTab: View {
    @EnvironmentObject var configStore: ConfigStore
    /// Owned by the root: the quiz overlay's "more picks" round-trip is a chat
    /// turn, and it can be raised from any tab.
    var chatHolder: ChatViewModelHolder
    /// Person cards and `arrbarr://person/…` links in replies push from here, so
    /// back returns to the conversation.
    @State private var personRef: PersonRef?

    var body: some View {
        Group {
            if !chatHolder.vm.providerIsAvailable {
                ChatUnavailableView(reason: .providerUnavailable)
            } else {
                ChatView(viewModel: chatHolder.vm)
            }
        }
        .personDestination($personRef)
        .onMessage(AppMessages.OpenPerson.self) { personRef = $0.ref }
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Settings tab

private struct SettingsTab: View {
    var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore

    var body: some View {
        SettingsView(
            onSetDemoMode: { enable in
                // iOS can't relaunch itself. Persist the flag, re-point the
                // ConfigStore to the demo suite (so demo edits never reach the
                // real profile), seed on enable, wipe the demo suite on disable.
                UserDefaults.standard.set(enable, forKey: DemoMode.key)
                configStore.useDemoStore(enable)
                if enable {
                    DemoMode.seedConfigsIfNeeded(configStore)
                } else {
                    DemoMode.resetDemoStore()
                }
                Task { await viewModel.refresh() }
                return true
            }
        )
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - History tab

/// Pushed from a queue section header (the macOS route), pre-scoped to that
/// arr. The source picker stays: unlike macOS, iOS can widen to "All" and
/// filter by event type from here.
private struct HistoryTab: View {
    var viewModel: QueueViewModel
    var initialSource: QueueItem.Source?
    @EnvironmentObject var configStore: ConfigStore
    @State private var selected: QueueItem.Source?
    @State private var didSeedSource = false
    /// Event-type filter (nil = all). Types are unified across arrs
    /// (HistoryItem.EventType.parse maps both Sonarr + Radarr the same way),
    /// so one filter list works for every service.
    @State private var selectedType: HistoryItem.EventType?
    /// A title opened from a history row. Pushed from here, on top of this
    /// view — the queue root's own detail destination would race the history
    /// destination it already has pushed.
    @State private var detailItem: QueueItem?

    /// Event types offered in the filter (skip `.other`, the catch-all).
    private let filterableTypes: [HistoryItem.EventType] = [.grabbed, .imported, .failed, .deleted]

    /// Only arrs the user has actually set up can have history.
    private var available: [QueueItem.Source] {
        QueueItem.Source.allCases.filter { configStore.config(for: $0.serviceKind).isVisible }
    }

    var body: some View {
        Group {
            if available.isEmpty {
                Text("common.noHistory.button", bundle: .module)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // `selected == nil` → All (merged across configured arrs).
                HistoryView(
                    source: selected,
                    viewModel: viewModel,
                    showHeader: false,
                    typeFilter: selectedType,
                    onOpenDetail: { detailItem = $0 },
                    onClose: {}
                )
            }
        }
        .navigationDestination(item: $detailItem) { item in
            DetailView(item: item, onBack: { detailItem = nil }, viewModel: viewModel)
        }
        .onAppear {
            guard !didSeedSource else { return }
            didSeedSource = true
            selected = initialSource
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if available.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            selected = nil
                        } label: {
                            Label {
                                Text("search.all.button", bundle: .module)
                            } icon: {
                                Image(systemName: selected == nil ? "checkmark" : "square.stack")
                            }
                        }
                        ForEach(available, id: \.self) { src in
                            Button {
                                selected = src
                            } label: {
                                Label {
                                    Text(src.displayName)
                                } icon: {
                                    if selected == src {
                                        Image(systemName: "checkmark")
                                    } else {
                                        // Plain template Image (not ServiceIcon) — a Menu only
                                        // renders an `Image` for its item icon, not an arbitrary view.
                                        Image(src.brandIconName, bundle: .module)
                                            .renderingMode(.template)
                                    }
                                }
                            }
                        }
                    } label: {
                        // Show the active filter (icon + name) as the dropdown
                        // label instead of a bare filter glyph — a lone filter
                        // icon didn't say what it filtered or what's selected.
                        HStack(spacing: 4) {
                            if let current = selected {
                                // ServiceIcon (vs a raw template Image) sizes
                                // the vector asset — a bare Image rendered at
                                // its intrinsic SVG size and blew up to fill
                                // the bar.
                                ServiceIcon(source: current, size: 15)
                                Text(verbatim: current.displayName)
                            } else {
                                Image(systemName: "square.stack")
                                Text("search.all.button", bundle: .module)
                            }
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .font(.subheadline)
                    }
                    .accessibilityLabel(Text("common.filter.button", bundle: .module))
                }
            }
            // Second filter: event type (Grabbed / Imported / Failed /
            // Deleted). Compact — icon-only when "All", icon + name when a
            // specific type is picked.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        selectedType = nil
                    } label: {
                        Label {
                            Text("search.all.button", bundle: .module)
                        } icon: {
                            Image(systemName: selectedType == nil ? "checkmark" : "line.3.horizontal.decrease")
                        }
                    }
                    ForEach(filterableTypes, id: \.self) { type in
                        Button {
                            selectedType = type
                        } label: {
                            Label {
                                Text(verbatim: type.displayName)
                            } icon: {
                                Image(systemName: selectedType == type ? "checkmark" : type.symbol)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if let t = selectedType {
                            Image(systemName: t.symbol)
                            Text(verbatim: t.displayName)
                        } else {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .font(.subheadline)
                }
                .accessibilityLabel(Text("common.filter.button", bundle: .module))
            }
        }
    }
}
#endif
