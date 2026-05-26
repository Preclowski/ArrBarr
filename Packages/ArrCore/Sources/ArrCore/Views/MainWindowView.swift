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
        case chat
        /// Queue filtered to one source.
        case source(QueueItem.Source)
    }

    @State private var selection: Destination = .allQueue
    @State private var detailItem: QueueItem?
    @State private var historySource: QueueItem.Source?
    @State private var historyRefreshNonce = 0
    @StateObject private var searchViewModel = SearchViewModel()
    @StateObject private var chatHolder = ChatViewModelHolder()
    @State private var searchResult: SearchResult?
    @State private var showSearch = false

    // MARK: - Visibility helpers (mirrored from PopoverContentView)

    private var sonarrConfigured: Bool { configStore.sonarr.isVisible }
    private var radarrConfigured: Bool { configStore.radarr.isVisible }
    private var lidarrConfigured: Bool { configStore.lidarr.isVisible }
    private var whisparrConfigured: Bool { configStore.whisparr.isVisible }
    private var anyArrConfigured: Bool { sonarrConfigured || radarrConfigured || lidarrConfigured || whisparrConfigured }

    private var searchConfigured: Bool { sonarrConfigured || radarrConfigured || lidarrConfigured || whisparrConfigured }

    private var chatAvailable: Bool {
        guard configStore.aiEnabled else { return false }
        switch configStore.chatProvider {
        case .foundationModels:
            if #available(macOS 26.0, *) { return true }
            return false
        case .openai:
            return configStore.openai.isConfigured
        }
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
                sonarrConfig: configStore.sonarr,
                lidarrConfig: configStore.lidarr,
                whisparrConfig: configStore.whisparr
            )
            chatHolder.reconfigure(store: configStore)
        }
        .onChange(of: ChatViewModelHolder.signature(store: configStore)) { _, _ in
            chatHolder.reconfigure(store: configStore)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { Task { await viewModel.refresh() } }) {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(viewModel.isRefreshing ? 360 : 0))
                        .animation(viewModel.isRefreshing
                                   ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                                   : .default,
                                   value: viewModel.isRefreshing)
                }
                .help(Text("Refresh", bundle: .module))
                .disabled(viewModel.isRefreshing)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: { searchViewModel.reset(); showSearch = true }) {
                    Image(systemName: "plus")
                }
                .help(Text("Add new", bundle: .module))
                .disabled(!searchConfigured)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                }
                .help(Text("Settings…", bundle: .module))
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        .sheet(isPresented: $showSearch) {
            NavigationStack {
                if let result = searchResult {
                    SearchAddPanel(result: result, viewModel: searchViewModel) {
                        searchResult = nil
                        showSearch = false
                    }
                } else {
                    SearchView(viewModel: searchViewModel) { result in
                        searchResult = result
                    }
                    .environmentObject(configStore)
                }
            }
            .frame(minWidth: 480, minHeight: 560)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        showSearch = false
                        searchResult = nil
                        searchViewModel.reset()
                    } label: { Text("Cancel", bundle: .module) }
                }
            }
        }
        .navigationTitle(navigationTitle)
        .onReceive(NotificationCenter.default.publisher(for: .arrBarrOpenDetail)) { note in
            guard let item = note.userInfo?["item"] as? QueueItem else { return }
            withAnimation(.smooth(duration: 0.22)) { detailItem = item }
        }
    }

    private var navigationTitle: String {
        switch selection {
        case .allQueue: return String(localized: "Queue")
        case .upcoming: return String(localized: "Upcoming")
        case .chat:     return String(localized: "Chat")
        case .source(let s): return s.displayName
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                if anyArrConfigured {
                    Label { Text("Queue", bundle: .module) } icon: { Image(systemName: "arrow.down.circle") }
                        .tag(Destination.allQueue)
                    Label { Text("Upcoming", bundle: .module) } icon: { Image(systemName: "calendar") }
                        .tag(Destination.upcoming)
                }
                if chatAvailable {
                    Label { Text("Chat", bundle: .module) } icon: { Image(systemName: "sparkles") }
                        .tag(Destination.chat)
                }
            } header: {
                Text("Library", bundle: .module)
            }

            if anyArrConfigured {
                Section {
                    if sonarrConfigured { sourceRow(.sonarr) }
                    if radarrConfigured { sourceRow(.radarr) }
                    if lidarrConfigured { sourceRow(.lidarr) }
                    if whisparrConfigured { sourceRow(.whisparr) }
                } header: {
                    Text("Sources", bundle: .module)
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func sourceRow(_ source: QueueItem.Source) -> some View {
        let count = viewModel.items(for: source).count
        Label {
            HStack {
                Text(source.displayName)
                Spacer()
                if count > 0 {
                    Text(verbatim: "\(count)")
                        .scaledFont(size: 10, weight: .semibold, monospacedDigit: true)
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
        case .whisparr: return .pink
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
            case .chat:
                chatContent
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
            if viewModel.isLoading {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading…", bundle: .module).font(.subheadline).foregroundStyle(.secondary)
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
                            error: viewModel.error(for: source),
                            health: health(for: source),
                            isCollapsed: false,
                            onToggleCollapse: nil,
                            viewModel: viewModel,
                            onShowHistory: viewModel.error(for: source) == nil
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
    private var chatContent: some View {
        if !chatHolder.vm.providerIsAvailable {
            ChatUnavailableView(reason: .providerUnavailable)
        } else {
            ChatView(viewModel: chatHolder.vm)
        }
    }

    private var upcomingContent: some View {
        ScrollView {
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
                .scaledFont(size: 28, weight: .light)
                .foregroundStyle(.tertiary)
            Text("Select an item", bundle: .module)
                .scaledFont(size: 13)
                .foregroundStyle(.secondary)
            Text("Click a row in the queue to see its details, episodes, and existing files.", bundle: .module)
                .scaledFont(size: 11)
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
                .scaledFont(size: 28, weight: .light)
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
            Text("ArrBarr is not configured", bundle: .module)
                .font(.headline)
            Text("Connect Radarr, Sonarr or Lidarr in Settings to get started.", bundle: .module)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { onOpenSettings() } label: { Text("Open Settings…", bundle: .module) }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Data helpers

    private func isConfigured(_ source: QueueItem.Source) -> Bool {
        configStore.serviceConfig(for: source).isVisible
    }

    /// Sonarr items get bucketed by downloadId so a season pack collapses
    /// into one row matching the underlying download. Same rule as the popover.
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
}
#endif
