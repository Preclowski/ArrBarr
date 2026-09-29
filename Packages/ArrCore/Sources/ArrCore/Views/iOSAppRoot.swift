#if os(iOS)
import SwiftUI
import CoreSpotlight

/// Root view for the iOS app target. Lives in ArrCore so it can reach the package's
/// internal section views without making their initialisers public.
public struct iOSAppRoot: View {
    @State private var viewModel: QueueViewModel
    private let configStore = ConfigStore.shared
    private var storeManager: StoreManager { .shared }
    /// Surfaces start the one live trailer; this root renders it.
    private var trailerSession: TrailerSession { .shared }
    @Environment(\.scenePhase) private var scenePhase
    @State private var searchVM: SearchViewModel
    /// Owned here so the queue's library-only search reads the same cache.
    @State private var libraryViewModel: LibraryViewModel
    /// Above the TabView because the quiz can be raised from any tab.
    @State private var chatHolder = ChatViewModelHolder()
    @State private var discoverViewModel = DiscoverViewModel.shared
    @State private var quizAddResult: SearchResult?
    /// `Router.detail` requests reach every listening stack; listeners check this so hidden tabs
    /// don't push a stale copy.
    @State private var selectedTab: RootTab = .queue
    /// Owned here so a tab switch can close it — only when empty, so a query isn't lost.
    @State private var searchPresented = false

    enum RootTab: Hashable { case queue, library, upcoming, chat, settings }

    /// Live queue rows and owned titles from every loaded library matching the query.
    private var localHits: [LocalHit] {
        guard searchVM.isActive else { return [] }
        return LocalHit.hits(
            queue: viewModel, library: libraryViewModel,
            sources: QueueItem.Source.allCases.filter { configStore.config(for: $0.serviceKind).isVisible },
            query: searchVM.query)
    }

    /// A chat turn: mood and shown titles are already in the conversation.
    private func requestMoreQuizPicks() {
        guard configStore.aiConfigured, !chatHolder.vm.isThinking else { return }
        let prompt = AppLocalized.string("discover.moreLikeThese.chatPrompt", locale: configStore.currentLocale)
        Task { await chatHolder.vm.send(prompt) }
    }

    public init() {
        self._viewModel = State(initialValue: .shared)
        let library = LibraryViewModel()
        let search = SearchViewModel()
        search.library = library
        self._libraryViewModel = State(initialValue: library)
        self._searchVM = State(initialValue: search)
    }

    public var body: some View {
        // Once per body, not once per tab.
        let localHits = localHits
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
                NavigationStack { SettingsTab() }
            } label: {
                Label { Text("common.settings.button", bundle: .module) } icon: { Image(systemName: "gearshape") }
            }
        }
        .environment(configStore)
        // Root-owned so the quiz's chat bridge works before the Chat tab was ever shown.
        .onAppear {
            chatHolder.reconfigure(store: configStore)
            searchVM.setup(store: configStore)
        }
        .onChange(of: ChatViewModelHolder.signature(store: configStore)) { _, _ in
            chatHolder.reconfigure(store: configStore)
        }
        .onChange(of: selectedTab) { _, _ in
            if !searchVM.isActive { searchPresented = false }
        }
        // macOS hosts the add panel in the popover; here the root must, or the quiz's and chat's
        // add actions do nothing.
        .onRequest(from: Router.searchAdd) { route in quizAddResult = route.result; return true }
        // Queue deletes ask through `ConfirmCenter`; without a host the question never shows.
        .confirmCenterHost()
        // Seeded by the `discover_in_quiz` tool or the chat resume card.
        .fullScreenCover(isPresented: $discoverViewModel.isPresented) {
            DiscoverTabView(
                viewModel: discoverViewModel,
                llmAvailable: configStore.aiConfigured,
                radarrAvailable: configStore.radarr.isVisible,
                // The top-up round is a chat turn, so the deck waits on the agent's thinking flag.
                moreInFlight: chatHolder.vm.isThinking,
                isObscured: quizAddResult != nil,
                onClose: { discoverViewModel.close() },
                onCancelLoading: {
                    chatHolder.vm.cancelTurn()
                    discoverViewModel.endLoading()
                },
                onRequestMore: requestMoreQuizPicks
            )
            .environment(configStore)
            .sheet(item: $quizAddResult) { result in
                NavigationStack {
                    SearchAddPanel(result: result, viewModel: searchVM) {
                        quizAddResult = nil
                    }
                }
                // A sheet inside a fullScreenCover doesn't inherit its environment; without this
                // `SearchAddPanel.loadCast` traps on a missing ConfigStore.
                .environment(configStore)
            }
            // The root's overlay renders under this cover (its own presentation context), so the deck
            // needs its own copy.
            .trailerOverlay(key: Binding(
                get: { trailerSession.key },
                set: { if $0 == nil { trailerSession.dismiss() } }
            ))
        }
        // Never live together with the cover's copy: the session hands out one WKWebView, so a
        // second overlay steals it and blanks the picture.
        .trailerOverlay(key: Binding(
            get: { discoverViewModel.isPresented ? nil : trailerSession.key },
            set: { if $0 == nil { trailerSession.dismiss() } }
        ))
        .fullScreenCover(isPresented: Binding(
            get: { storeManager.gatedFeature != nil },
            set: { if !$0 { storeManager.dismissPaywall() } }
        )) {
            PaywallView(context: storeManager.gatedFeature) {
                storeManager.dismissPaywall()
            }
        }
        // `effectiveFontScale` bumps the baseline on iOS; shared sizes read small on a phone.
        .appFontScale(configStore)
        // Dense queue rows hold up to here; past it they'd wrap into unreadable columns.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .preferredColorScheme(configStore.preferredColorScheme)
        // Stopped when backgrounded: iOS suspends the timer anyway, but this avoids a stale burst on resume.
        .onAppear {
            viewModel.startForegroundPolling()
            SpotlightIndexer.reindex(configStore: configStore)
            LibraryPosterSampler.warmUp(configStore: configStore)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                viewModel.startForegroundPolling()
                // Re-index on foreground so posters cached while browsing get picked up. Throttled inside.
                SpotlightIndexer.reindex(configStore: configStore)
            case .inactive, .background: viewModel.stopForegroundPolling()
            @unknown default: break
            }
        }
        .onOpenURL { url in
            switch WidgetDeepLink(url: url) {
            case .library: selectedTab = .library
            case .upcoming: selectedTab = .upcoming
            case nil: break
            }
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                  let ref = SpotlightIndexer.parse(id) else { return }
            // The Queue tab takes it once mounted, even on a cold launch.
            selectedTab = .queue
            DetailRequest.post(DetailRequest.syntheticItem(source: ref.source, entityId: ref.id, title: ""))
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
    @Environment(ConfigStore.self) var configStore
    @State private var detailItem: QueueItem?
    @State private var searchResult: SearchResult?
    @State private var selecting = false
    /// Reached from the queue's per-arr section header, as on macOS.
    @State private var historySource: QueueItem.Source?

    private var searchAvailable: Bool {
        QueueItem.Source.allCases.contains { configStore.config(for: $0.serviceKind).isVisible }
    }

    var body: some View {
        queueContent
        .refreshable { await viewModel.refresh() }
        // No nav-bar title — it only duplicated the tab-bar label.
        .navigationBarTitleDisplayMode(.inline)
        // Only while the whole stack is unreachable; pull-to-refresh and the chip both re-probe.
        .toolbar {
            if viewModel.isFullyOffline {
                ToolbarItem(placement: .topBarLeading) {
                    OfflineIndicator(viewModel: viewModel)
                }
            }
            // QueueListView puts Select all / Done in the bar during edit mode.
            if !selecting {
                ToolbarItem(placement: .topBarTrailing) { selectButton }
            }
        }
        // Hidden while editing, like Files and Mail: the bottom action bar needs the room.
        .toolbar(selecting ? .hidden : .visible, for: .tabBar)
        .onRequest(from: Router.searchQuery) { query in
            searchResult = nil
            searchVM.query = query
            return true
        }
        .navigationDestination(item: $detailItem) { item in
            DetailView(item: item, onBack: { detailItem = nil }, viewModel: viewModel)
        }
        .navigationDestination(item: $historySource) { source in
            HistoryTab(viewModel: viewModel, initialSource: source)
        }
        .onRequest(from: Router.detail) { item in
            guard isActive else { return false }
            detailItem = item
            return true
        }
    }

    @ViewBuilder
    private var queueContent: some View {
        if let result = searchResult {
            SearchAddPanel(result: result, viewModel: searchVM) {
                searchResult = nil
            }
        } else {
            // Hidden in edit mode: its magnifier otherwise wins the trailing slot over "Done".
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

    /// A single-item menu is a pointless extra tap, so the icon is the action.
    private var selectButton: some View {
        Button {
            selecting = true
        } label: {
            Label { Text("queue.select.button", bundle: .module) } icon: { Image(systemName: "checklist") }
        }
        .disabled(selecting)
        .accessibilityLabel(Text("queue.select.button", bundle: .module))
    }

    /// Arr-level rows have no queue detail; open that arr's queue page instead.
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

/// Hand-rolled: `.searchScopes` withholds the bar until the first keystroke, and
/// `.onSearchPresentation` drops it — scopes must show while the field is empty.
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

    /// Beside the scopes, not among them, because it combines with any of them.
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

/// Withdrawn while multi-select owns the toolbar, or its magnifier takes "Done"'s slot.
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
                // `SearchScopeBar` renders the scopes under it; `.searchScopes` can't.
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

/// Only supplies the add-panel slot the popover fills from `PopoverContentView`.
private struct LibraryTab: View {
    var searchVM: SearchViewModel
    var localHits: [LocalHit]
    var libraryViewModel: LibraryViewModel
    var viewModel: QueueViewModel
    var isActive: Bool
    @Binding var searchPresented: Bool
    @Environment(ConfigStore.self) var configStore
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
        // Library tiles post `DetailRequest`; without a listener the tap does nothing.
        .onRequest(from: Router.detail) { item in
            guard isActive else { return false }
            detailItem = item
            return true
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
    @Environment(ConfigStore.self) var configStore
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
        .onRequest(from: Router.detail) { item in
            guard isActive else { return false }
            detailItem = item
            return true
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
    @Environment(ConfigStore.self) var configStore
    /// Owned by the root: the quiz's "more picks" round-trip is a chat turn from any tab.
    var chatHolder: ChatViewModelHolder
    /// Pushed from here so back returns to the conversation.
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
    var body: some View {
        SettingsView(
            onSetDemoMode: { enable in
                Task { await DemoMode.switchLive(enable) }
                return true
            }
        )
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - History tab

/// Unlike macOS, iOS can widen to "All" and filter by event type from here.
private struct HistoryTab: View {
    var viewModel: QueueViewModel
    var initialSource: QueueItem.Source?
    @Environment(ConfigStore.self) var configStore
    @State private var selected: QueueItem.Source?
    @State private var didSeedSource = false
    /// nil = all. Types are unified across arrs, so one list serves every service.
    @State private var selectedType: HistoryItem.EventType?
    /// Pushed from here: the queue root's own detail destination would race this pushed view.
    @State private var detailItem: QueueItem?

    /// `.other` is the catch-all, so it's not offered.
    private let filterableTypes: [HistoryItem.EventType] = [.grabbed, .imported, .failed, .deleted]

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
                // `selected == nil` → All, merged across configured arrs.
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
                                        // A Menu only renders an `Image` for its item icon, not an arbitrary view.
                                        Image(src.brandIconName, bundle: .module)
                                            .renderingMode(.template)
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if let current = selected {
                                // ServiceIcon sizes the vector asset; a bare Image renders at its intrinsic SVG size.
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
