import SwiftUI

/// The queue rendered as a native `List` so every row is a real cell with
/// native swipe actions (swipe-left → Delete). Shared by the iOS tab and the
/// macOS popover; the host owns the surrounding chrome (search bar / filter
/// bar, nav).
///
/// Why a dedicated view instead of reusing `QueueSectionView`: `List` only
/// turns its *direct* children into rows. A section must therefore emit its
/// header and each row as separate List elements — which is exactly what this
/// view does via `Section { ForEach } header:`.
struct QueueListView: View {
    var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore

    /// Narrow to one arr (macOS scope chips). nil = every configured arr.
    var scope: QueueItem.Source? = nil
    let onShowDetail: (QueueItem) -> Void
    /// macOS opens the arr's queue page in the browser; iOS (nil) drills into
    /// the matching queue item's detail.
    var onNeedsYouTap: ((NeedsYouItem) -> Void)? = nil
    var onShowHistory: ((QueueItem.Source) -> Void)? = nil
    // The "Next week" banner is NOT a List row — the host pins it above the
    // List so it dodges macOS List row-inset margins we couldn't zero out.

    private enum Entry: Hashable {
        case needsYou
        case arr(QueueItem.Source)
    }

    /// Drives the rendered order from `arrOrder`, mirroring the old
    /// section-list logic so banners keep their user-chosen position.
    private var orderedEntries: [Entry] {
        if let scope { return isVisible(scope) ? [.arr(scope)] : [] }
        return configStore.arrOrder.compactMap { key -> Entry? in
            if key == ConfigStore.needsYouOrderKey {
                guard configStore.showNeedsYou, !viewModel.needsYou.isEmpty else { return nil }
                return .needsYou
            }
            if let source = QueueItem.Source(rawValue: key), isVisible(source) {
                return .arr(source)
            }
            return nil
        }
    }

    private var hideHeader: Bool { scope != nil }

    var body: some View {
        List {
            ForEach(orderedEntries, id: \.self) { entry in
                switch entry {
                case .needsYou:
                    Section { needsYouBanner.plainQueueRow() }
                case .arr(let source):
                    arrSection(source)
                }
            }
            if orderedEntries.isEmpty {
                Section { emptyState.plainQueueRow() }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        // macOS List indents scroll content by default; zero it so rows /
        // banners are genuinely full-width (each brings its own padding).
        // No placement filter — newer macOS adds horizontal margins beyond
        // `.scrollContent` alone, which read as oversized side gaps on rows.
        .contentMargins(.horizontal, 0)
        // Kill the top inset under the iOS search drawer + tighten the gap
        // above the first arr section header (the "dziura pod searchem").
        .contentMargins(.top, 0, for: .scrollContent)
        #if os(iOS)
        .listSectionSpacing(.compact)
        #endif
    }

    // MARK: - Sections

    @ViewBuilder
    private func arrSection(_ source: QueueItem.Source) -> some View {
        let arrError = viewModel.error(for: source)
        let collapsed = arrError == nil && configStore.isCollapsed(source)
        Section {
            if !collapsed, arrError == nil {
                let rows = entries(for: source)
                if rows.isEmpty {
                    Text("queue.queueEmpty.button", bundle: .module)
                        .scaledFont(size: 12)
                        .foregroundStyle(.tertiary)
                        .plainQueueRow(insets: EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                } else {
                    ForEach(rows) { entry in
                        rowView(for: entry)
                            .plainQueueRow()
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                // Icon-only, Apple-Mail style (no "Delete" text).
                                Button(role: .destructive) {
                                    deleteClosure(for: entry)()
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .accessibilityLabel(Text("queue.delete.button", bundle: .module))
                            }
                            // Leading swipe → pause/resume. Only when there's a
                            // configured download client (arrs can't control the
                            // download) AND the item is in a downloading/paused
                            // state, mirroring the row's hover/CTA gating.
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                let rep = repItem(for: entry)
                                if canControl(rep), rep.status == .downloading || rep.status == .paused {
                                    Button {
                                        pauseResumeClosure(for: entry)()
                                    } label: {
                                        Image(systemName: rep.isPaused ? "play.fill" : "pause.fill")
                                    }
                                    .tint(rep.isPaused ? .green : .orange)
                                    .accessibilityLabel(Text(rep.isPaused ? "Resume" : "Pause", bundle: .module))
                                }
                            }
                    }
                }
            }
        } header: {
            if !hideHeader {
                sectionHeader(source, error: arrError, collapsed: collapsed)
                    // Zero the platform section-header inset so the header
                    // aligns with the (also-zeroed) rows; both then carry their
                    // own `queueRowH` padding instead of the wider default.
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 4, trailing: 0))
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ source: QueueItem.Source, error: String?, collapsed: Bool) -> some View {
        let health = healthRecords(for: source)
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .scaledFont(size: 9, weight: .semibold)
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .frame(width: 10)
                .opacity(error == nil ? 1 : 0)
            ServiceIcon(source: source, size: 12)
                .foregroundStyle(.secondary)
            Text(verbatim: source.displayName)
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)
            if error == nil {
                Text(verbatim: "\(itemCount(source))")
                    .scaledFont(size: 11)
                    .foregroundStyle(.tertiary)
                if !health.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .scaledFont(size: 10)
                        .foregroundStyle(.orange)
                        // Without this the badge was a bare orange triangle with
                        // no explanation — the macOS QueueSectionView already
                        // showed the messages on hover; the native-List refactor
                        // dropped it. (Error-level health also now surfaces in
                        // the "Needs you" list via computeNeedsYou.)
                        .help(health.compactMap(\.message).joined(separator: "\n"))
                }
            }
            Spacer()
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(size: 11)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if let onShowHistory {
                Button { onShowHistory(source) } label: {
                    HStack(spacing: 2) {
                        Text("queue.showHistory.button", bundle: .module)
                        Image(systemName: "chevron.right").scaledFont(size: 8, weight: .semibold)
                    }
                    .scaledFont(size: 10)
                    .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Tokens.Spacing.queueRowH)
        .textCase(nil)
        .contentShape(Rectangle())
        .onTapGesture {
            guard error == nil else { return }
            withAnimation(.smooth(duration: 0.22)) { configStore.toggleCollapsed(source) }
        }
    }

    private var needsYouBanner: some View {
        NeedsYouSectionView(
            items: viewModel.needsYou,
            isCollapsed: configStore.isCollapsed(ConfigStore.needsYouOrderKey),
            onToggleCollapse: {
                withAnimation(.smooth(duration: 0.22)) {
                    configStore.toggleCollapsed(ConfigStore.needsYouOrderKey)
                }
            },
            onItemTap: { needs in
                if let onNeedsYouTap {
                    onNeedsYouTap(needs)
                } else if let itemId = needs.item?.id {
                    let match = QueueItem.Source.allCases.lazy
                        .compactMap { viewModel.items(for: $0).first(where: { $0.id == itemId }) }
                        .first
                    if let match { onShowDetail(match) }
                }
                // arr-level issue rows (needs.item == nil) have no queue
                // detail to push; the popover wires onNeedsYouTap to open the
                // arr's queue page instead.
            }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "gearshape.2")
                .scaledFont(size: 36, weight: .light)
                .foregroundStyle(.secondary)
            Text("common.arrbarrIsNotConfigured.label", bundle: .module)
                .font(.headline)
            Text("queue.connectRadarrSonarrOr.tooltip", bundle: .module)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 60)
    }

    // MARK: - Rows

    @ViewBuilder
    private func rowView(for entry: QueueRowEntry) -> some View {
        switch entry {
        case .single(let item):
            QueueRowView(
                item: item,
                onPause: { [weak viewModel] in Task { await viewModel?.pause(item) } },
                onResume: { [weak viewModel] in Task { await viewModel?.resume(item) } },
                onDelete: deleteClosure(for: entry),
                onShowDetail: { onShowDetail(item) }
            )
        case .group(let group):
            let rep = group.representative
            QueueGroupRowView(
                group: group,
                onPause: { [weak viewModel] in Task { await viewModel?.pause(rep) } },
                onResume: { [weak viewModel] in Task { await viewModel?.resume(rep) } },
                onDelete: deleteClosure(for: entry),
                // Season pack → open the series at this season (episode coords
                // stripped) so DetailView shows the season, not one episode.
                onShowDetail: { onShowDetail(rep.seasonContext()) }
            )
        }
    }

    private func deleteClosure(for entry: QueueRowEntry) -> () -> Void {
        switch entry {
        case .single(let item):
            return { [weak viewModel] in Task { await viewModel?.delete(item) } }
        case .group(let group):
            let items = group.items
            return { [weak viewModel] in Task { await viewModel?.deleteAll(items) } }
        }
    }

    /// Representative item for an entry (single → itself, group → rep). Used
    /// to gate the leading pause/resume swipe.
    private func repItem(for entry: QueueRowEntry) -> QueueItem {
        switch entry {
        case .single(let item): return item
        case .group(let group): return group.representative
        }
    }

    /// Mirrors QueueRowView.canControl — pause/resume is only possible with a
    /// configured download client for the item's protocol (arrs can't do it).
    private func canControl(_ item: QueueItem) -> Bool {
        switch item.downloadProtocol {
        case .usenet:
            return (configStore.sabnzbd.isConfigured && !configStore.sabnzbd.apiKey.isEmpty)
                || configStore.nzbget.isConfigured
        case .torrent:
            return configStore.qbittorrent.isConfigured
                || configStore.transmission.isConfigured
                || configStore.rtorrent.isConfigured
                || configStore.deluge.isConfigured
        case .unknown:
            return false
        }
    }

    /// Toggle pause/resume on the entry's representative (the whole download /
    /// season pack shares its downloadId, so acting on the rep covers it).
    private func pauseResumeClosure(for entry: QueueRowEntry) -> () -> Void {
        let item = repItem(for: entry)
        return { [weak viewModel] in
            Task {
                if item.isPaused { await viewModel?.resume(item) }
                else { await viewModel?.pause(item) }
            }
        }
    }

    // MARK: - Data

    private func isVisible(_ source: QueueItem.Source) -> Bool {
        configStore.config(for: source.serviceKind).isVisible
    }

    private func entries(for source: QueueItem.Source) -> [QueueRowEntry] {
        let raw = viewModel.items(for: source)
        switch source {
        case .sonarr: return QueueGrouping.group(raw)
        default:      return raw.map { .single($0) }
        }
    }

    private func itemCount(_ source: QueueItem.Source) -> Int {
        entries(for: source).reduce(0) { sum, entry in
            switch entry {
            case .single: return sum + 1
            case .group(let g): return sum + g.memberCount
            }
        }
    }

    private func healthRecords(for source: QueueItem.Source) -> [ArrHealthRecord] {
        guard configStore.showIndexerIssues else { return [] }
        switch source {
        case .sonarr: return viewModel.health.sonarr
        case .radarr: return viewModel.health.radarr
        case .lidarr: return viewModel.health.lidarr
        case .whisparr: return viewModel.health.whisparr
        }
    }
}

// MARK: - Row chrome helper

private extension View {
    /// Strip the default List cell chrome so queue rows look the same as the
    /// old ScrollView layout (full-bleed, transparent, no separators). Zero
    /// horizontal inset — each row/banner brings its own padding, so the List
    /// must not add more on top (that's what widened the rows + put side
    /// margins on the Tonight banner).
    func plainQueueRow(insets: EdgeInsets = EdgeInsets()) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(insets)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
