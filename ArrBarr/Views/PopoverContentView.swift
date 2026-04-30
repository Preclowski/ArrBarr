import SwiftUI

struct PopoverContentView: View {
    @ObservedObject var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    @State private var selectedTab: Tab = .queue
    @State private var historySource: QueueItem.Source?
    @State private var historyRefreshNonce = 0

    private let maxScrollHeight: CGFloat = 520

    private var sonarrConfigured: Bool { isVisible(configStore.sonarr) }
    private var radarrConfigured: Bool { isVisible(configStore.radarr) }
    private var lidarrConfigured: Bool { isVisible(configStore.lidarr) }
    private var anyArrConfigured: Bool { sonarrConfigured || radarrConfigured || lidarrConfigured }

    /// In demo mode, show an arr whenever it's enabled (the configs are seeded to
    /// `enabled = true` on first demo launch — see `DemoMode.seedConfigsIfNeeded`).
    /// Outside of demo mode, require a real configured connection.
    private func isVisible(_ config: ServiceConfig) -> Bool {
        DemoMode.isActive ? config.enabled : config.isConfigured
    }

    enum Tab: String, CaseIterable {
        case queue = "Queue"
        case upcoming = "Upcoming"
    }

    var body: some View {
        mainContent
            .environment(\.locale, configStore.currentLocale)
            .background {
                Button("", action: onOpenSettings)
                    .keyboardShortcut(",", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
            }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            if let historySource {
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
                    }
                }
            } else {
                emptyState
            }
            footer
        }
        .frame(width: 400)
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
                Text("Tonight")
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

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
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
                let count = CGFloat(Tab.allCases.count)
                let segment = geo.size.width / count
                let index = CGFloat(Tab.allCases.firstIndex(of: selectedTab) ?? 0)
                TabPillBackground()
                    .frame(width: segment - 4, height: geo.size.height - 4)
                    .offset(x: segment * index + 2, y: 2)
            }
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Queue content

    private var queueContent: some View {
        ScrollView {
            Group {
                if viewModel.isLoading && viewModel.radarr.isEmpty && viewModel.sonarr.isEmpty && viewModel.lidarr.isEmpty {
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
        .frame(maxHeight: maxScrollHeight)
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
                    NSWorkspace.shared.open(url)
                }
            )
            .padding(.vertical, 12)
        case .arr(let source):
            let arrError = error(for: source)
            QueueSectionView(
                title: source.displayName,
                symbol: source.symbol,
                items: items(for: source),
                error: arrError,
                health: health(for: source),
                isCollapsed: arrError == nil ? configStore.isCollapsed(source) : false,
                onToggleCollapse: arrError == nil ? {
                    withAnimation(.smooth(duration: 0.22)) {
                        configStore.toggleCollapsed(source)
                    }
                } : nil,
                viewModel: viewModel,
                onShowHistory: arrError == nil ? { historySource = source } : nil
            )
            .padding(.vertical, 12)
        }
    }

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
        .frame(maxHeight: maxScrollHeight)
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
    }

    private func emptyStep(number: Int, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: "\(number).")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
            Text(text)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            if let err = viewModel.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
            }
            Divider()
            HStack(spacing: 6) {
                Button(action: {
                    if historySource != nil {
                        historyRefreshNonce &+= 1
                    } else {
                        Task { await viewModel.refresh() }
                    }
                }) {
                    ZStack {
                        Image(systemName: "arrow.clockwise")
                            .opacity(viewModel.isRefreshing ? 0 : 1)
                        if viewModel.isRefreshing {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.7)
                        }
                    }
                    .frame(width: 14, height: 14)
                }
                .modifier(GlassButtonStyle())
                .controlSize(.small)
                .localizedHelp("Refresh", locale: configStore.currentLocale)
                .disabled(viewModel.isRefreshing && historySource == nil)

                Spacer()

                Menu {
                    Button("Settings…", action: onOpenSettings)
                        .keyboardShortcut(",", modifiers: .command)
                    Divider()
                    Button("Quit ArrBarr") { onQuit() }
                        .keyboardShortcut("q", modifiers: .command)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .localizedHelp("More options", locale: configStore.currentLocale)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.primary.opacity(0.10))
    }
}

// MARK: - Shared button styles

struct GlassButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

struct GlassProminentButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}
