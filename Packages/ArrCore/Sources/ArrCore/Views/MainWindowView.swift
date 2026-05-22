#if os(macOS)
import SwiftUI

/// Desktop-window root for ArrBarr — a NavigationSplitView (sidebar + content
/// + detail) that mirrors the macOS desktop mock while only using shipped
/// features. Reuses every concrete sub-view that already exists in the
/// popover (`QueueSectionView`, `UpcomingRowView`, `SearchView`,
/// `HistoryView`, `DetailView`) so feature parity with the menu-bar popover
/// is by construction.
///
/// Layout:
///
///   [ Sidebar ──────────── ][ Content ─────── ][ Detail ──── ]
///   Library                  Queue / Upcoming    DetailView
///     · Queue                  / Search / per-     when an item
///     · Upcoming               source filtered     is selected,
///     · Search                 queue / History     placeholder
///   Sources                                        otherwise.
///     · Sonarr (badge)
///     · Radarr (badge)
///     · Lidarr (badge)
///
/// Identity with the popover:
///   – same `QueueViewModel` instance is passed in by AppDelegate
///   – same `ConfigStore` via environment
///   – clicking a queue row sets `detailItem` (DetailView in detail pane)
///   – clicking a section's history button sets `historySource` (HistoryView
///     replaces the queue list in the content pane, like the popover today)
public struct MainWindowView: View {
    @ObservedObject var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore
    let onOpenSettings: () -> Void

    public init(viewModel: QueueViewModel, onOpenSettings: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onOpenSettings = onOpenSettings
    }

    // MARK: - Sidebar destinations

    enum Destination: Hashable {
        /// All configured sources, grouped (parity with popover Queue tab).
        case allQueue
        case upcoming
        case search
        case chat
        /// Queue filtered to one source.
        case source(QueueItem.Source)
    }

    @State private var selection: Destination = .allQueue
    @State private var detailItem: QueueItem?
    @State private var historySource: QueueItem.Source?
    @State private var historyRefreshNonce = 0
    @StateObject private var searchViewModel = SearchViewModel()
    @StateObject private var chatViewModel = ChatViewModelFactory.makePlaceholder()
    @State private var searchResult: SearchResult?

    // MARK: - Visibility helpers (mirrored from PopoverContentView)

    private var sonarrConfigured: Bool { isVisible(configStore.sonarr) }
    private var radarrConfigured: Bool { isVisible(configStore.radarr) }
    private var lidarrConfigured: Bool { isVisible(configStore.lidarr) }
    private var anyArrConfigured: Bool { sonarrConfigured || radarrConfigured || lidarrConfigured }

    private var searchSources: [QueueItem.Source] {
        [
            sonarrConfigured ? QueueItem.Source.sonarr : nil,
            radarrConfigured ? QueueItem.Source.radarr : nil,
        ].compactMap { $0 }
    }
    private var searchConfigured: Bool { !searchSources.isEmpty }

    private var chatAvailable: Bool {
        guard configStore.chatEnabled else { return false }
        guard configStore.mcp.isConfigured else { return false }
        if #available(macOS 26.0, *) { return true }
        return false
    }

    private func isVisible(_ config: ServiceConfig) -> Bool {
        DemoMode.isActive ? config.enabled : config.isConfigured
    }

    // MARK: - Body

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } content: {
            contentPane
                .navigationSplitViewColumnWidth(min: 360, ideal: 460)
        } detail: {
            detailPane
        }
        .environment(\.locale, configStore.currentLocale)
        // Suppresses the long-hover tooltip on every queue row in the window
        // — the detail pane on the right already shows the same info, so the
        // tooltip would be redundant chrome. The popover keeps tooltips since
        // it has no detail pane.
        .environment(\.suppressRowTooltip, true)
        .onAppear {
            searchViewModel.setup(
                radarrConfig: configStore.radarr,
                sonarrConfig: configStore.sonarr
            )
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { Task { await viewModel.refresh() } }) {
                    if viewModel.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help(Text("Refresh"))
                .disabled(viewModel.isRefreshing)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                }
                .help(Text("Settings…"))
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        .navigationTitle(navigationTitle)
    }

    private var navigationTitle: String {
        switch selection {
        case .allQueue: return String(localized: "Queue")
        case .upcoming: return String(localized: "Upcoming")
        case .search:   return String(localized: "Search")
        case .chat:     return String(localized: "Chat")
        case .source(let s): return s.displayName
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                if anyArrConfigured {
                    Label("Queue", systemImage: "arrow.down.circle")
                        .tag(Destination.allQueue)
                    Label("Upcoming", systemImage: "calendar")
                        .tag(Destination.upcoming)
                }
                if searchConfigured {
                    Label("Search", systemImage: "magnifyingglass")
                        .tag(Destination.search)
                }
                if chatAvailable {
                    Label("Chat", systemImage: "sparkles")
                        .tag(Destination.chat)
                }
            } header: {
                Text("Library")
            }

            if anyArrConfigured {
                Section {
                    if sonarrConfigured { sourceRow(.sonarr) }
                    if radarrConfigured { sourceRow(.radarr) }
                    if lidarrConfigured { sourceRow(.lidarr) }
                } header: {
                    Text("Sources")
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func sourceRow(_ source: QueueItem.Source) -> some View {
        let count = items(for: source).count
        Label {
            HStack {
                Text(source.displayName)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
        } icon: {
            Image(systemName: source.symbol)
                .foregroundStyle(sourceTint(source))
        }
        .tag(Destination.source(source))
    }

    private func sourceTint(_ source: QueueItem.Source) -> Color {
        switch source {
        case .sonarr: return .indigo
        case .radarr: return .red
        case .lidarr: return .green
        }
    }

    // MARK: - Content pane

    @ViewBuilder
    private var contentPane: some View {
        if let historySource {
            HistoryView(
                source: historySource,
                viewModel: viewModel,
                refreshNonce: historyRefreshNonce,
                onClose: { self.historySource = nil }
            )
        } else if !anyArrConfigured {
            emptyState
        } else {
            switch selection {
            case .allQueue:
                queueScroll(sources: configuredSources)
            case .source(let s):
                queueScroll(sources: [s])
            case .upcoming:
                upcomingContent
            case .search:
                searchContent
            case .chat:
                ChatView(viewModel: chatViewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var configuredSources: [QueueItem.Source] {
        configStore.arrOrder.compactMap { key in
            guard let s = QueueItem.Source(rawValue: key), isConfigured(s) else { return nil }
            return s
        }
    }

    private func queueScroll(sources: [QueueItem.Source]) -> some View {
        ScrollView {
            if viewModel.isLoading
                && viewModel.radarr.isEmpty
                && viewModel.sonarr.isEmpty
                && viewModel.lidarr.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sources.enumerated()), id: \.element) { index, source in
                        if index > 0 { Divider().padding(.horizontal, 16) }
                        QueueSectionView(
                            title: source.displayName,
                            symbol: source.symbol,
                            entries: entries(for: source),
                            error: error(for: source),
                            health: health(for: source),
                            isCollapsed: false,
                            onToggleCollapse: nil,
                            viewModel: viewModel,
                            onShowHistory: error(for: source) == nil
                                ? { self.historySource = source }
                                : nil,
                            onShowDetail: { item in
                                withAnimation(.smooth(duration: 0.22)) {
                                    detailItem = item
                                }
                            }
                        )
                        .padding(.vertical, 14)
                        .padding(.horizontal, 4)
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private var searchContent: some View {
        if let result = searchResult {
            SearchAddPanel(result: result, viewModel: searchViewModel) {
                searchResult = nil
            }
        } else {
            SearchView(
                viewModel: searchViewModel,
                configuredSources: searchSources
            ) { result in
                searchResult = result
            }
        }
    }

    private var upcomingContent: some View {
        ScrollView {
            if viewModel.upcoming.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Nothing upcoming")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.upcoming) { item in
                        UpcomingRowView(item: item)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let detailItem {
            DetailView(
                item: detailItem,
                onBack: {
                    withAnimation(.smooth(duration: 0.22)) { self.detailItem = nil }
                },
                viewModel: viewModel
            )
        } else {
            detailPlaceholder
        }
    }

    private var detailPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Select an item")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Click a row in the queue to see its details, episodes, and existing files.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "gearshape.2")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
            Text("ArrBarr is not configured")
                .font(.headline)
            Text("Connect Radarr, Sonarr or Lidarr in Settings to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings…", action: onOpenSettings)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Data helpers (mirrored from PopoverContentView)

    private func isConfigured(_ source: QueueItem.Source) -> Bool {
        switch source {
        case .sonarr: return sonarrConfigured
        case .radarr: return radarrConfigured
        case .lidarr: return lidarrConfigured
        }
    }

    private func items(for source: QueueItem.Source) -> [QueueItem] {
        switch source {
        case .sonarr: return viewModel.sonarr
        case .radarr: return viewModel.radarr
        case .lidarr: return viewModel.lidarr
        }
    }

    /// Sonarr items get bucketed by downloadId so a season pack collapses
    /// into one row matching the underlying download. Same rule as the popover.
    private func entries(for source: QueueItem.Source) -> [QueueRowEntry] {
        let raw = items(for: source)
        switch source {
        case .sonarr: return QueueGrouping.group(raw)
        default:      return raw.map { .single($0) }
        }
    }

    private func error(for source: QueueItem.Source) -> String? {
        switch source {
        case .sonarr: return viewModel.sonarrError
        case .radarr: return viewModel.radarrError
        case .lidarr: return viewModel.lidarrError
        }
    }

    private func health(for source: QueueItem.Source) -> [ArrHealthRecord] {
        guard configStore.showIndexerIssues else { return [] }
        switch source {
        case .sonarr: return viewModel.health.sonarr
        case .radarr: return viewModel.health.radarr
        case .lidarr: return viewModel.health.lidarr
        }
    }
}
#endif
