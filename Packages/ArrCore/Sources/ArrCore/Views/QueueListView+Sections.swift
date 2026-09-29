import SwiftUI

extension QueueListView {
    // MARK: - Sections

    private static let staleRowOpacity: Double = 0.5
    private static let hiddenRowOpacity: Double = 0.35

    private func rowOpacity(isStale: Bool, items: [QueueItem]) -> Double {
        (isStale ? Self.staleRowOpacity : 1) * (queueUI.areHidden(items) ? Self.hiddenRowOpacity : 1)
    }

    @ViewBuilder
    func arrSection(_ source: QueueItem.Source) -> some View {
        let arrError = viewModel.error(for: source)
        // A failed refresh keeps the last-good snapshot; show it dimmed and read-only
        // rather than blanking the section.
        let isStale = arrError != nil
        // Unreachable (transport / 502 / split-DNS) is the calm away case; a reachable
        // error (401/500) stays a loud, actionable problem.
        let isUnreachable = viewModel.lastUnreachable.contains(source)
        let collapsed = (arrError == nil || isUnreachable) && queueUI.isCollapsed(source)
        sectionHeader(source, error: arrError, isUnreachable: isUnreachable, collapsed: collapsed)
            .plainQueueRow(insets: Self.headerRowInsets)
        if !collapsed {
                let rows = displayRows(for: source)
                if rows.isEmpty {
                    if isUnreachable {
                        Text("queue.serverUnreachable.label", bundle: .module)
                            .scaledFont(size: 12)
                            .foregroundStyle(.tertiary)
                            .plainQueueRow(insets: EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                    } else if !isStale {
                        Text("queue.queueEmpty.button", bundle: .module)
                            .scaledFont(size: 12)
                            .foregroundStyle(.tertiary)
                            .plainQueueRow(insets: EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                    }
                    // A reachable error with nothing cached renders nothing; the header badge explains it.
                } else {
                    ForEach(rows) { display in
                        displayRowView(display, isStale: isStale)
                    }
                }
            }
    }

    @ViewBuilder
    private func displayRowView(_ display: QueueDisplayRow, isStale: Bool) -> some View {
        switch display {
        case .entry(let entry):
            swipeableRow(for: entry, isStale: isStale)
        case .titleGroup(let group):
            titleGroupHeader(group, isStale: isStale)
            if isGroupExpanded(group) {
                ForEach(group.entries) { entry in
                    swipeableRow(for: entry, isStale: isStale, indented: true)
                }
            }
        }
    }

    @ViewBuilder
    private func titleGroupHeader(_ group: QueueTitleGroup, isStale: Bool) -> some View {
        let header = QueueTitleGroupRowView(
            group: group,
            isExpanded: isGroupExpanded(group),
            onToggle: {
                withAnimation(.smooth(duration: 0.22)) { toggleTitleGroup(group) }
            },
            // Episode coords stripped so DetailView opens the title, whose download
            // section lists every sibling.
            onShowDetail: { onShowDetail(group.representative.seasonContext()) },
            onPauseAll: { [weak viewModel] in
                let items = group.allItems
                Task { for item in items { await viewModel?.pause(item) } }
            },
            onResumeAll: { [weak viewModel] in
                let items = group.allItems
                Task { for item in items { await viewModel?.resume(item) } }
            },
            onDeleteAll: { [weak viewModel] in
                let items = group.allItems
                Task { await viewModel?.deleteAll(items) }
            }
        )
        .environment(\.queueOffline, viewModel.isFullyOffline || isStale)
        .opacity(rowOpacity(isStale: isStale, items: group.allItems))
        #if os(iOS)
        header
            .plainQueueRow()
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if !viewModel.isFullyOffline, !isStale {
                    Button(role: .destructive) {
                        requestGroupDeleteConfirm(group)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel(Text("queue.delete.button", bundle: .module))
                }
            }
        #else
        header.plainQueueRow()
        #endif
    }

    #if os(iOS)
    /// The swipe button must not hard-delete N downloads without the header's confirm.
    private func requestGroupDeleteConfirm(_ group: QueueTitleGroup) {
        let items = group.allItems
        ConfirmCenter.request(.removeAllDownloads(count: group.downloadCount, locale: configStore.currentLocale) { [weak viewModel] in
            Task { await viewModel?.deleteAll(items) }
        })
    }
    #endif

    /// Native `.swipeActions` are iOS-only: on macOS swipe-to-delete on a `List` crashes
    /// in an `NSTableView` layout exception. No full swipe, so delete never auto-commits.
    @ViewBuilder
    private func swipeableRow(for entry: QueueRowEntry, isStale: Bool, indented: Bool = false) -> some View {
        let content = rowView(for: entry)
            // Per-section offline: the List-level value only covers all-arrs being down.
            .environment(\.queueOffline, viewModel.isFullyOffline || isStale)
            .opacity(rowOpacity(isStale: isStale, items: entry.allItems))
            // Group members keep the shared leading edge; a trailing inset marks them as children.
            .padding(.trailing, indented ? 24 : 0)
        #if os(iOS)
        let row = content.plainQueueRow()
        row
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if !viewModel.isFullyOffline, !isStale {
                    Button(role: .destructive) {
                        deleteClosure(for: entry)()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel(Text("queue.delete.button", bundle: .module))
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                let rep = repItem(for: entry)
                if !viewModel.isFullyOffline, !isStale, canControl(rep), rep.status == .downloading || rep.status == .paused {
                    Button {
                        pauseResumeClosure(for: entry)()
                    } label: {
                        Image(systemName: rep.isPaused ? "play.fill" : "pause.fill")
                    }
                    .tint(rep.isPaused ? .green : .orange)
                    .accessibilityLabel(Text(rep.isPaused ? "Resume" : "Pause", bundle: .module))
                }
            }
        #else
        if selecting {
            content
                // Direct state write: preferences don't reliably climb out of the
                // List's per-row hosting cells on macOS.
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    rowFrames[entry.id] = frame
                }
                .plainQueueRow()
                .simultaneousGesture(dragSelectGesture(anchor: entry.id))
        } else {
            content.plainQueueRow()
        }
        #endif
    }

    @ViewBuilder
    private func sectionHeader(_ source: QueueItem.Source, error: String?, isUnreachable: Bool, collapsed: Bool) -> some View {
        QueueHeaderRow(
            icon: AnyView(ServiceIcon(source: source, size: 12).foregroundStyle(.secondary)),
            title: source.displayName,
            count: error == nil ? itemCount(source) : nil,
            hiddenCount: error == nil ? hiddenCount(source) : 0,
            onToggleHidden: {
                withAnimation(.smooth(duration: 0.22)) { queueUI.showHiddenQueueItems.toggle() }
            },
            collapsed: collapsed,
            showChevron: error == nil || isUnreachable,
            onToggle: {
                guard error == nil || isUnreachable else { return }
                withAnimation(.smooth(duration: 0.22)) { queueUI.toggleCollapsed(source) }
            }
        ) {
            if isUnreachable {
                Label { Text("offline.indicator.label", bundle: .module).textCase(.lowercase) } icon: { Image(systemName: "network.slash") }
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(size: 11)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if let onShowHistory {
                ShowHistoryLink { onShowHistory(source) }
            }
        }
    }

    var emptyState: some View {
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
                onShowDetail: { rowTapped(entry, defaultTarget: item) },
                selectionState: selectionState(for: entry)
            )
        case .group(let group):
            let rep = group.representative
            QueueGroupRowView(
                group: group,
                onPause: { [weak viewModel] in Task { await viewModel?.pause(rep) } },
                onResume: { [weak viewModel] in Task { await viewModel?.resume(rep) } },
                onDelete: deleteClosure(for: entry),
                onShowDetail: { rowTapped(entry, defaultTarget: rep.seasonContext()) },
                selectionState: selectionState(for: entry)
            )
        }
    }

    private func deleteClosure(for entry: QueueRowEntry) -> @MainActor () -> Void {
        switch entry {
        case .single(let item):
            return { [weak viewModel] in Task { await viewModel?.delete(item) } }
        case .group(let group):
            let items = group.items
            return { [weak viewModel] in Task { await viewModel?.deleteAll(items) } }
        }
    }

    // Only the iOS row renders swipe actions; on macOS these would warn as unused.
    #if os(iOS)
    private func repItem(for entry: QueueRowEntry) -> QueueItem {
        switch entry {
        case .single(let item): return item
        case .group(let group): return group.representative
        }
    }

    private func canControl(_ item: QueueItem) -> Bool { configStore.canControlDownload(item) }

    /// A season pack shares its downloadId, so acting on the rep covers it.
    private func pauseResumeClosure(for entry: QueueRowEntry) -> () -> Void {
        let item = repItem(for: entry)
        return { [weak viewModel] in
            Task {
                if item.isPaused { await viewModel?.resume(item) }
                else { await viewModel?.pause(item) }
            }
        }
    }
    #endif
}
