import SwiftUI

public struct PopoverContentView: View {
    var viewModel: QueueViewModel
    @Environment(ConfigStore.self) var configStore
    var storeManager: StoreManager { .shared }
    let onOpenSettings: () -> Void
    let onShowAbout: () -> Void
    let onQuit: () -> Void
    /// `nil` in the menu-bar panel; in the detached window an × ends the tab bar (traffic lights are hidden).
    var onCloseWindow: (() -> Void)? = nil
    @Environment(\.isDetachedWindow) var isDetachedWindow
    @Environment(\.colorScheme) var colorScheme
    /// Closes the MenuBarExtra popover; a no-op in the detached NSWindow.
    @Environment(\.dismiss) var dismiss

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

    @State var selectedTab: Tab = .queue
    #if os(macOS)
    @State var commandKey = CommandKeyMonitor()
    #endif
    @State var queueSelecting = false
    @State var historySource: QueueItem.Source?
    @State var searchViewModel = SearchViewModel()
    /// Owned here so switching tabs doesn't drop the fetched libraries.
    @State var libraryViewModel = LibraryViewModel()
    @State var chatHolder = ChatViewModelHolder()
    @State var searchResult: SearchResult?
    @State var detailItem: QueueItem?
    /// Detail surfaces own their person destination; chat has none, so the root hosts it.
    @State var personRef: PersonRef?
    /// Owned here because ⌘N and the Add/search intents aim at it from outside any tab.
    @FocusState var searchFieldFocused: Bool

    /// Opened from chat: Back returns to chat instead of the Add tab.
    @State var searchAddFromChat = false
    /// Deck and presentation live in the view-model, which outlives this view — the panel
    /// rebuilds constantly and a chat turn can open the quiz while it's shut.
    @State var discoverViewModel = DiscoverViewModel.shared
    /// Outlives this view, so a playing clip is re-presented when the popover reopens.
    private var trailerSession: TrailerSession { .shared }

    private var sonarrConfigured: Bool { configStore.sonarr.isVisible }
    var radarrConfigured: Bool { configStore.radarr.isVisible }
    private var lidarrConfigured: Bool { configStore.lidarr.isVisible }
    private var whisparrConfigured: Bool { configStore.whisparr.isVisible }
    var anyArrConfigured: Bool { sonarrConfigured || radarrConfigured || lidarrConfigured || whisparrConfigured }

    /// A hair above zero on purpose: at exactly 0 AppKit drops the selectable-text layers in
    /// chat bubbles and they come back invisible on unpark.
    static let parkedOpacity: Double = 0.001

    var tabContentParked: Bool {
        searchResult != nil || detailItem != nil || discoverViewModel.isPresented
    }

    /// Discover parks under SearchAddPanel / DetailView but not under itself.
    var discoverParked: Bool {
        searchResult != nil || detailItem != nil
    }

    /// Hopped to the next main-actor turn: on `onAppear` the field isn't in the responder
    /// chain yet and an inline assignment is silently dropped.
    private func focusInputForCurrentTab() {
        guard selectedTab.hostsSearch else { return }
        Task { searchFieldFocused = true }
    }

    /// Live queue rows and owned titles from every loaded library matching the query.
    var localHits: [LocalHit] {
        guard searchViewModel.isActive else { return [] }
        return LocalHit.hits(
            queue: viewModel, library: libraryViewModel,
            sources: QueueItem.Source.allCases.filter { configStore.config(for: $0.serviceKind).isVisible },
            query: searchViewModel.query)
    }


    enum Tab: String, CaseIterable {
        case queue = "Queue"
        case library = "Library"
        case shelf = "Shelf"
        case upcoming = "Upcoming"
        case chat = "Chat"

        var hostsSearch: Bool { self != .chat && self != .shelf }

        /// Only the active tab shows its label: four labels ("Nadchodzące", "Warteschlange")
        /// never fit the 400 pt bar.
        var symbol: String {
            switch self {
            case .queue: return "arrow.down.circle"
            case .library: return "books.vertical"
            case .shelf: return "photo.stack"
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

    @State var tabFrames: [Tab: CGRect] = [:]

    @Namespace var barGlass

}
