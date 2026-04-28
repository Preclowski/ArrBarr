import SwiftUI

struct PopoverContentView: View {
    @ObservedObject var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    @State private var selectedTab: Tab = .queue
    @State private var searchText = ""

    private let maxScrollHeight: CGFloat = 520

    private func filter(_ items: [QueueItem]) -> [QueueItem] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.title.lowercased().contains(q)
                || ($0.subtitle?.lowercased().contains(q) ?? false)
        }
    }

    private var sonarrConfigured: Bool { DemoMode.isActive || configStore.sonarr.isConfigured }
    private var radarrConfigured: Bool { DemoMode.isActive || configStore.radarr.isConfigured }
    private var lidarrConfigured: Bool { DemoMode.isActive || configStore.lidarr.isConfigured }
    private var anyArrConfigured: Bool { sonarrConfigured || radarrConfigured || lidarrConfigured }

    enum Tab: String, CaseIterable {
        case queue = "Queue"
        case upcoming = "Upcoming"
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer {
                mainContent
            }
        } else {
            mainContent
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            if anyArrConfigured {
                tabBar
                Divider()
                searchBar
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

    private var hasAnyItems: Bool {
        switch selectedTab {
        case .queue: return !(viewModel.radarr.isEmpty && viewModel.sonarr.isEmpty && viewModel.lidarr.isEmpty)
        case .upcoming: return !viewModel.upcoming.isEmpty
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Filter…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04))
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { selectedTab = tab }
                } label: {
                    Text(tab.rawValue)
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
                VStack(alignment: .leading, spacing: 16) {
                    if sonarrConfigured {
                        QueueSectionView(
                            title: "Sonarr",
                            symbol: "tv",
                            items: filter(viewModel.sonarr),
                            error: viewModel.sonarrError,
                            health: viewModel.health.sonarr,
                            viewModel: viewModel
                        )
                    }

                    if sonarrConfigured && (radarrConfigured || lidarrConfigured) {
                        Divider().padding(.horizontal, 12)
                    }

                    if radarrConfigured {
                        QueueSectionView(
                            title: "Radarr",
                            symbol: "film",
                            items: filter(viewModel.radarr),
                            error: viewModel.radarrError,
                            health: viewModel.health.radarr,
                            viewModel: viewModel
                        )
                    }

                    if lidarrConfigured && (sonarrConfigured || radarrConfigured) {
                        Divider().padding(.horizontal, 12)
                    }

                    if lidarrConfigured {
                        QueueSectionView(
                            title: "Lidarr",
                            symbol: "music.note",
                            items: filter(viewModel.lidarr),
                            error: viewModel.lidarrError,
                            health: viewModel.health.lidarr,
                            viewModel: viewModel
                        )
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: maxScrollHeight)
    }

    // MARK: - Upcoming content

    private var upcomingContent: some View {
        ScrollView {
            if filteredUpcoming.isEmpty {
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
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: maxScrollHeight)
    }

    private var filteredUpcoming: [UpcomingItem] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return viewModel.upcoming }
        return viewModel.upcoming.filter {
            $0.title.lowercased().contains(q)
                || ($0.subtitle?.lowercased().contains(q) ?? false)
        }
    }

    private var groupedUpcoming: [UpcomingGroup] {
        let calendar = Calendar.current
        var groups: [UpcomingGroup] = []
        var current: (date: DateComponents, items: [UpcomingItem])?

        for item in filteredUpcoming {
            let dc = calendar.dateComponents([.year, .month, .day], from: item.airDate)
            if let c = current, c.date == dc {
                current?.items.append(item)
            } else {
                if let c = current, let first = c.items.first {
                    let y = c.date.year ?? 0, m = c.date.month ?? 0, d = c.date.day ?? 0
                    groups.append(UpcomingGroup(
                        date: "\(y)-\(m)-\(d)",
                        label: first.airDateFormatted,
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
                label: first.airDateFormatted,
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
                Text("Add your Radarr or Sonarr connection to get started.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("Open Settings…", action: onOpenSettings)
                .modifier(GlassProminentButtonStyle())
                .controlSize(.regular)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
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
                Button(action: { Task { await viewModel.refresh() } }) {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(viewModel.isLoading ? 360 : 0))
                        .animation(
                            viewModel.isLoading
                                ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                                : .default,
                            value: viewModel.isLoading
                        )
                }
                .modifier(GlassButtonStyle())
                .controlSize(.small)
                .help("Refresh")
                .disabled(viewModel.isLoading)

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
                .help("More options")
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
