import SwiftUI

struct PopoverContentView: View {
    @ObservedObject var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    @State private var selectedTab: Tab = .queue

    private let maxScrollHeight: CGFloat = 520

    private var sonarrConfigured: Bool { configStore.sonarr.isConfigured }
    private var radarrConfigured: Bool { configStore.radarr.isConfigured }
    private var anyArrConfigured: Bool { sonarrConfigured || radarrConfigured }

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

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                        .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .modifier(TabGlassHighlight(isSelected: selectedTab == tab))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Queue content

    private var queueContent: some View {
        ScrollView {
            if viewModel.isLoading && viewModel.radarr.isEmpty && viewModel.sonarr.isEmpty {
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
                            items: viewModel.sonarr,
                            error: viewModel.sonarrError,
                            viewModel: viewModel
                        )
                    }

                    if sonarrConfigured && radarrConfigured {
                        Divider().padding(.horizontal, 12)
                    }

                    if radarrConfigured {
                        QueueSectionView(
                            title: "Radarr",
                            symbol: "film",
                            items: viewModel.radarr,
                            error: viewModel.radarrError,
                            viewModel: viewModel
                        )
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: maxScrollHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Upcoming content

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
        .frame(maxHeight: maxScrollHeight)
        .fixedSize(horizontal: false, vertical: true)
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

// MARK: - Tab glass highlight

private struct TabGlassHighlight: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if isSelected {
                content
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 6))
            } else {
                content
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
        } else {
            content
                .background(
                    isSelected
                        ? RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                        : nil
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
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
