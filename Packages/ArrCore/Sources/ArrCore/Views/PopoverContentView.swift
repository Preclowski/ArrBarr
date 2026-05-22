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
    @State private var showSearch = false
    /// `true` when the search overlay was opened via a chat tap-to-add
    /// rather than the `+` button. Drives the Back behaviour in
    /// `SearchAddPanel` — back returns straight to chat instead of dropping
    /// into the search browser, which the user never asked to see.
    @State private var searchAddFromChat = false

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
                        showSearch = true
                    }
                }
                .keyboardShortcut("n", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
            }
            .onReceive(NotificationCenter.default.publisher(for: .arrBarrTriggerAdd)) { _ in
                if searchAvailable {
                    searchViewModel.reset()
                    showSearch = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .arrBarrOpenDetail)) { note in
                guard let item = note.userInfo?["item"] as? QueueItem else { return }
                showSearch = false
                historySource = nil
                withAnimation(.smooth(duration: 0.22)) { detailItem = item }
            }
            .onReceive(NotificationCenter.default.publisher(for: .arrBarrOpenSearchAdd)) { note in
                // User tapped a missing search result in chat. Open the full
                // SearchAddPanel overlay with that result pre-loaded.
                // `searchAddFromChat` lets the Back button skip the
                // intermediate SearchView and return straight to chat.
                guard let result = note.userInfo?["result"] as? SearchResult else { return }
                historySource = nil
                detailItem = nil
                searchAddFromChat = true
                searchResult = result
                showSearch = true
            }
    }

    private var mainContent: some View {
        // DetailView is rendered as a ZStack overlay so the underlying chat /
        // queue / upcoming view stays alive while it's on screen. That keeps
        // their scroll positions, lazy state, etc. intact — tapping Back lands
        // the user back in the same carousel offset they came from. Search +
        // History still use the swap pattern (they replace the surface fully
        // and don't share state worth preserving).
        ZStack {
            VStack(spacing: 0) {
                if showSearch {
                    searchOverlayContent
                } else if let historySource {
                    HistoryView(
                        source: historySource,
                        viewModel: viewModel,
                        refreshNonce: historyRefreshNonce,
                        onClose: { self.historySource = nil }
                    )
                } else if anyArrConfigured {
                    tabBar
                    Divider()
                    Group {
                        switch selectedTab {
                        case .queue: queueContent
                        case .upcoming: upcomingContent
                        case .chat:
                            chatTabContent
                        }
                    }
                } else {
                    emptyState
                }
            }

            if let detailItem {
                DetailView(
                    item: detailItem,
                    onBack: {
                        withAnimation(.smooth(duration: 0.22)) { self.detailItem = nil }
                    },
                    viewModel: viewModel
                )
                #if os(macOS)
                .background(Color(nsColor: .windowBackgroundColor))
                #else
                .background(Color(uiColor: .systemBackground))
                #endif
                .transition(.opacity)
            }
        }
        .frame(width: 400, height: 600)
        // The popover itself paints macOS 26's Liquid Glass for us now
        // (AppDelegate cleared the hosting view's background so the
        // system chrome shows through). What we add here is just the
        // depth — a thin top→bottom rim that reads as the edge of a
        // glass tile catching ambient light.
        //
        // Critical: `.screen` (or `.softLight`) survives NSPopover's
        // vibrancy. `.plusLighter` does NOT — it gets eaten by the
        // vibrancy filter and renders as nothing on dark desktops.
        // Corner radius 10pt matches NSPopover's outer chrome on macOS 26.
        .background(Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.55),
                            Color.white.opacity(0.08),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
                .blendMode(.screen)
                .allowsHitTesting(false)
        )
    }

    @ViewBuilder
    private var searchOverlayContent: some View {
        if let result = searchResult {
            SearchAddPanel(result: result, viewModel: searchViewModel) {
                // Chat-originated panels close the whole overlay so Back
                // takes the user back to the chat carousel — the search
                // browser was never part of their journey.
                if searchAddFromChat {
                    searchAddFromChat = false
                    searchResult = nil
                    showSearch = false
                } else {
                    searchResult = nil
                }
            }
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Button(action: closeSearch) {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Back", bundle: .module)
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text("Add new", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                SearchView(viewModel: searchViewModel) { result in
                    searchResult = result
                }
                .environmentObject(configStore)
            }
        }
    }

    private func closeSearch() {
        showSearch = false
        searchResult = nil
        searchViewModel.reset()
    }

    // MARK: - Tonight banner

    private var tonightBanner: some View {
        let items = viewModel.tonight
        let visible = viewModel.tonightExpanded ? items : Array(items.prefix(3))
        let overflow = items.count - visible.count
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 13))
                .foregroundStyle(.purple)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Upcoming", bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(visible) { item in
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
                    }
                }
                if overflow > 0 {
                    Button {
                        withAnimation(.smooth(duration: 0.22)) {
                            viewModel.setTonightExpanded(true)
                        }
                    } label: {
                        Text("+\(overflow) more")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.purple.opacity(0.06))
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
            case .chat:  return chatAvailable
            default:     return true
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            tabPills
                .frame(maxWidth: .infinity)
            accessoryButtons
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var tabPills: some View {
        HStack(spacing: 0) {
            ForEach(visibleTabs, id: \.self) { tab in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { selectedTab = tab }
                } label: {
                    Text(LocalizedStringKey(tab.rawValue))
                        .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                        .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            GeometryReader { geo in
                let count = CGFloat(visibleTabs.count)
                let segment = geo.size.width / count
                let index = CGFloat(visibleTabs.firstIndex(of: selectedTab) ?? 0)
                TabPillBackground()
                    .frame(width: segment - 4, height: geo.size.height - 4)
                    .offset(x: segment * index + 2, y: 2)
            }
        )
    }

    private var accessoryButtons: some View {
        HStack(spacing: 4) {
            if searchAvailable {
                Button {
                    searchViewModel.reset()
                    showSearch = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(Text("Add new", bundle: .module))
            }
            moreMenu
        }
    }

    private var moreMenu: some View {
        Menu {
            if let onOpenWindow {
                Button("Open Window…", action: onOpenWindow)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
            }
            Button("Settings…", action: onOpenSettings)
                .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button("Quit ArrBarr") { onQuit() }
                .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
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
                        Text("Loading…")
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
                        Text("Nothing upcoming")
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
                    Text("ArrBarr is not configured")
                        .font(.headline)
                    Text("Connect Radarr, Sonarr or Lidarr to get started.")
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

                Button("Open Settings…", action: onOpenSettings)
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
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.primary.opacity(0.10))
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
