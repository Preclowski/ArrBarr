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
/// reach the package's section views (NeedsYouSectionView,
/// QueueSectionView, etc.) without us having to expose every
/// internal initialiser publicly.
public struct iOSAppRoot: View {
    @State private var viewModel: QueueViewModel
    @ObservedObject private var configStore: ConfigStore
    @ObservedObject private var storeManager = StoreManager.shared
    @Environment(\.scenePhase) private var scenePhase

    public init(viewModel: QueueViewModel? = nil, configStore: ConfigStore? = nil) {
        let vm = viewModel ?? QueueViewModel()
        let cs = configStore ?? .shared
        self._viewModel = State(initialValue: vm)
        self._configStore = ObservedObject(wrappedValue: cs)
    }

    public var body: some View {
        TabView {
            NavigationStack { QueueTab(viewModel: viewModel) }
                .tabItem { Label { Text("Queue", bundle: .module) } icon: { Image(systemName: "arrow.down.circle") } }

            NavigationStack { UpcomingTab(viewModel: viewModel) }
                .tabItem { Label { Text("Upcoming", bundle: .module) } icon: { Image(systemName: "calendar") } }

            NavigationStack { HistoryTab(viewModel: viewModel) }
                .tabItem { Label { Text("History", bundle: .module) } icon: { Image(systemName: "clock.arrow.circlepath") } }

            if configStore.aiConfigured {
                NavigationStack {
                    if storeManager.isPro {
                        ChatTab()
                    } else {
                        ChatLockedPlaceholder { storeManager.gate(.chat) }
                    }
                }
                .tabItem {
                    Label {
                        Text("Chat", bundle: .module)
                    } icon: {
                        Image(systemName: storeManager.isPro ? "sparkles" : "lock.fill")
                    }
                }
            }

            NavigationStack { SettingsTab(viewModel: viewModel) }
                .tabItem { Label { Text("Settings", bundle: .module) } icon: { Image(systemName: "gearshape") } }
        }
        .environmentObject(configStore)
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
            Text("Chat is a Pro feature", bundle: .module).font(.headline)
            Button { onUnlock() } label: { Text("Unlock ArrBarr Pro", bundle: .module) }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .onAppear { onUnlock() }
    }
}

// MARK: - Queue tab

private struct QueueTab: View {
    var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore
    @State private var detailItem: QueueItem?
    @State private var searchVM = SearchViewModel()
    @State private var searchResult: SearchResult?

    private var searchConfigured: Bool {
        configStore.sonarr.isVisible || configStore.radarr.isVisible ||
        configStore.lidarr.isVisible || configStore.whisparr.isVisible
    }

    private var isSearching: Bool { !searchVM.query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Group {
            if let result = searchResult {
                // A result was tapped — show the add/configure panel, same
                // flow the floating "+" sheet used to drive.
                SearchAddPanel(result: result, viewModel: searchVM) {
                    searchResult = nil
                }
            } else {
                ZStack {
                    queueList
                    // Typing the top search bar shows the same unified surface
                    // as macOS: live queue rows that still match the filter on
                    // top, arr library / add-new hits below.
                    if isSearching {
                        ScrollView {
                            QueueSearchResultsView(
                                viewModel: viewModel,
                                searchViewModel: searchVM,
                                scope: nil,
                                onSelectQueueItem: { detailItem = $0 },
                                onSelectAddResult: { searchResult = $0 }
                            )
                            .padding(.vertical, 8)
                            if searchVM.isSearching {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(.vertical, 16)
                            }
                        }
                        .background(Color(.systemBackground))
                    }
                }
            }
        }
        .refreshable { await viewModel.refresh() }
        // No nav-bar title — it only duplicated the tab-bar label below.
        .navigationBarTitleDisplayMode(.inline)
        // Search-to-add now lives in a persistent top search bar instead of
        // a floating "+" button.
        .searchable(
            text: $searchVM.query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text("Search movies and TV series", bundle: .module)
        )
        .autocorrectionDisabled(true)
        // Fire the arr lookups when the query changes — same trigger macOS
        // wires from its filter bar.
        .onChange(of: searchVM.query) { _, _ in searchVM.onQueryChange() }
        .navigationDestination(item: $detailItem) { item in
            DetailView(item: item, onBack: { detailItem = nil }, viewModel: viewModel)
        }
        // In-library search hits route through DetailRequest — listen for it
        // here so they push the detail (Upcoming tab does the same).
        .onReceive(NotificationCenter.default.publisher(for: .arrBarrOpenDetail)) { note in
            guard let item = note.userInfo?["item"] as? QueueItem else { return }
            detailItem = item
        }
        // Search-to-add App Intent → run the search here.
        .onReceive(NotificationCenter.default.publisher(for: .arrBarrSearchQuery)) { note in
            guard let q = note.userInfo?["query"] as? String else { return }
            searchResult = nil
            searchVM.query = q
            searchVM.onQueryChange()
        }
        .onAppear {
            searchVM.setup(
                radarrConfig: configStore.radarr,
                sonarrConfig: configStore.sonarr,
                lidarrConfig: configStore.lidarr,
                whisparrConfig: configStore.whisparr
            )
        }
    }

    private var queueList: some View {
        QueueListView(
            viewModel: viewModel,
            scope: nil,
            onShowDetail: { detailItem = $0 }
        )
    }
}

// MARK: - Upcoming tab

private struct UpcomingTab: View {
    var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore
    @State private var detailItem: QueueItem?

    var body: some View {
        Group {
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
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await viewModel.refresh() }
        .navigationDestination(item: $detailItem) { item in
            DetailView(item: item, onBack: { detailItem = nil }, viewModel: viewModel)
        }
        // UpcomingRowView's `openDetail()` posts a DetailRequest
        // notification — wire it to push DetailView, same pattern as
        // MainWindowView on macOS.
        .onReceive(NotificationCenter.default.publisher(for: .arrBarrOpenDetail)) { note in
            guard let item = note.userInfo?["item"] as? QueueItem else { return }
            detailItem = item
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
            Text("Nothing upcoming", bundle: .module)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Chat tab

private struct ChatTab: View {
    @EnvironmentObject var configStore: ConfigStore
    @State private var chatHolder = ChatViewModelHolder()

    var body: some View {
        Group {
            if !chatHolder.vm.providerIsAvailable {
                ChatUnavailableView(reason: .providerUnavailable)
            } else {
                ChatView(viewModel: chatHolder.vm)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { chatHolder.reconfigure(store: configStore) }
        .onChange(of: ChatViewModelHolder.signature(store: configStore)) { _, _ in
            chatHolder.reconfigure(store: configStore)
        }
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

private struct HistoryTab: View {
    var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore
    @State private var selected: QueueItem.Source?
    /// Event-type filter (nil = all). Types are unified across arrs
    /// (HistoryItem.EventType.parse maps both Sonarr + Radarr the same way),
    /// so one filter list works for every service.
    @State private var selectedType: HistoryItem.EventType?

    /// Event types offered in the filter (skip `.other`, the catch-all).
    private let filterableTypes: [HistoryItem.EventType] = [.grabbed, .imported, .failed, .deleted]

    /// Only arrs the user has actually set up can have history.
    private var available: [QueueItem.Source] {
        QueueItem.Source.allCases.filter { configStore.config(for: $0.serviceKind).isVisible }
    }

    var body: some View {
        Group {
            if available.isEmpty {
                Text("No history", bundle: .module)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // `selected == nil` → All (merged across configured arrs).
                HistoryView(
                    source: selected,
                    viewModel: viewModel,
                    refreshNonce: 0,
                    showHeader: false,
                    typeFilter: selectedType,
                    onClose: {}
                )
            }
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
                                Text("All", bundle: .module)
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
                                Text("All", bundle: .module)
                            }
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .font(.subheadline)
                    }
                    .accessibilityLabel(Text("Filter", bundle: .module))
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
                            Text("All", bundle: .module)
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
                .accessibilityLabel(Text("Filter", bundle: .module))
            }
        }
    }
}
#endif
