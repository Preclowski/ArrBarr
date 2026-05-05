#if os(iOS)
import SwiftUI

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
    @StateObject private var viewModel: QueueViewModel
    @ObservedObject private var configStore: ConfigStore

    public init(viewModel: QueueViewModel? = nil, configStore: ConfigStore? = nil) {
        let vm = viewModel ?? QueueViewModel()
        let cs = configStore ?? .shared
        self._viewModel = StateObject(wrappedValue: vm)
        self._configStore = ObservedObject(wrappedValue: cs)
    }

    public var body: some View {
        TabView {
            NavigationStack { QueueTab(viewModel: viewModel) }
                .tabItem { Label("Queue", systemImage: "arrow.down.circle") }

            NavigationStack { UpcomingTab(viewModel: viewModel) }
                .tabItem { Label("Upcoming", systemImage: "calendar") }

            NavigationStack { SearchTab(viewModel: viewModel) }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }

            NavigationStack { SettingsTab() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .environmentObject(configStore)
        .task { await viewModel.refresh() }
    }
}

// MARK: - Queue tab

private struct QueueTab: View {
    @ObservedObject var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore
    @State private var detailItem: QueueItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(visibleSections, id: \.self) { entry in
                    sectionView(for: entry)
                    Divider().padding(.horizontal, 14)
                }
                if visibleSections.isEmpty {
                    emptyState
                }
            }
            .padding(.vertical, 8)
        }
        .refreshable { await viewModel.refresh() }
        .navigationTitle("Queue")
        .navigationDestination(item: $detailItem) { item in
            DetailView(item: item, onBack: { detailItem = nil }, viewModel: viewModel)
                .navigationBarBackButtonHidden(true)
        }
    }

    private enum SectionEntry: Hashable {
        case needsYou
        case arr(QueueItem.Source)
    }

    private var visibleSections: [SectionEntry] {
        configStore.arrOrder.compactMap { key in
            if key == ConfigStore.needsYouOrderKey {
                guard configStore.showNeedsYou && !viewModel.needsYou.isEmpty else { return nil }
                return .needsYou
            }
            if key == ConfigStore.tonightOrderKey { return nil } // Tonight folded into Upcoming on iOS
            if let source = QueueItem.Source(rawValue: key), isConfigured(source) {
                return .arr(source)
            }
            return nil
        }
    }

    @ViewBuilder
    private func sectionView(for entry: SectionEntry) -> some View {
        switch entry {
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
                    if let item = viewModel.radarr.first(where: { $0.id == needs.item.id })
                        ?? viewModel.sonarr.first(where: { $0.id == needs.item.id })
                        ?? viewModel.lidarr.first(where: { $0.id == needs.item.id }) {
                        detailItem = item
                    }
                }
            )
            .padding(.vertical, 12)
        case .arr(let source):
            let arrError = error(for: source)
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
                onShowHistory: nil,
                onShowDetail: { item in detailItem = item }
            )
            .padding(.vertical, 12)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "gearshape.2")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("ArrBarr is not configured")
                .font(.headline)
            Text("Connect Radarr, Sonarr or Lidarr in Settings to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 60)
    }

    private func isConfigured(_ source: QueueItem.Source) -> Bool {
        configStore.config(for: source.serviceKind).isConfigured
    }

    private func items(for source: QueueItem.Source) -> [QueueItem] {
        switch source {
        case .sonarr: return viewModel.sonarr
        case .radarr: return viewModel.radarr
        case .lidarr: return viewModel.lidarr
        }
    }

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

// MARK: - Upcoming tab

private struct UpcomingTab: View {
    @ObservedObject var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore

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
        .navigationTitle("Upcoming")
        .refreshable { await viewModel.refresh() }
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
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing upcoming")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Search tab

private struct SearchTab: View {
    @ObservedObject var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore
    @StateObject private var searchVM = SearchViewModel()
    @State private var searchResult: SearchResult?

    var body: some View {
        Group {
            if let result = searchResult {
                SearchAddPanel(result: result, viewModel: searchVM) {
                    searchResult = nil
                }
            } else {
                SearchView(
                    viewModel: searchVM,
                    configuredSources: searchSources,
                    onSelectResult: { result in searchResult = result }
                )
            }
        }
        .navigationTitle("Search")
        .onAppear {
            searchVM.setup(
                radarrConfig: configStore.radarr,
                sonarrConfig: configStore.sonarr
            )
        }
    }

    private var searchSources: [QueueItem.Source] {
        var s: [QueueItem.Source] = []
        if configStore.sonarr.isConfigured { s.append(.sonarr) }
        if configStore.radarr.isConfigured { s.append(.radarr) }
        return s
    }
}

// MARK: - Settings tab

private struct SettingsTab: View {
    var body: some View {
        SettingsView()
            .navigationTitle("Settings")
    }
}
#endif
