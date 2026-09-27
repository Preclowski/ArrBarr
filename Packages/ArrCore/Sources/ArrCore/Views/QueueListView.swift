import SwiftUI
#if canImport(AppKit)
import AppKit  // NSEvent.modifierFlags — ⌘-click detection on macOS.
#endif

/// The queue as a native `List`. `List` only turns its direct children into rows,
/// so each header and row is emitted as its own element.
struct QueueListView: View {
    var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore
    /// Read off the singleton, not the environment, so the widget / hosting-view
    /// boundaries that re-inject `configStore` by hand stay out of it.
    private var queueUI: QueueUIState { .shared }

    let onShowDetail: (QueueItem) -> Void
    /// macOS opens the arr's queue page in the browser; iOS (nil) drills into
    /// the matching queue item's detail.
    var onNeedsYouTap: ((NeedsYouItem) -> Void)? = nil
    var onShowHistory: ((QueueItem.Source) -> Void)? = nil

    #if os(macOS)
    /// 30s auto-collapse timer for the expanded "Next week" peek.
    @State private var bannerCollapseTask: Task<Void, Never>?
    #endif

    /// Selection is driven by us (checkbox semantics): macOS `List(selection:)`
    /// replaces the selection on a plain click instead of toggling.
    @Binding var selecting: Bool
    @State private var selected = Set<String>()
    /// By-title groups toggled away from the mode's default disclosure state,
    /// keyed by title so it survives members joining/leaving on refresh.
    @State private var toggledTitleGroups = Set<String>()
    /// Anchor a ⇧-click extends from (Finder semantics).
    @State private var lastAnchorID: String?

    #if os(macOS)
    /// Row frames in GLOBAL coordinates: macOS `List` hosts each row in its own
    /// AppKit cell, so a named coordinate space or PreferenceKey doesn't resolve there.
    @State private var rowFrames: [String: CGRect] = [:]
    /// Selection snapshot at drag start; every change re-derives from it so
    /// dragging back un-paints rows. nil ⇒ no drag in flight.
    @State private var dragBaseline: Set<String>?
    @State private var dragAnchorID: String?
    /// Starting on a selected row makes the drag deselect instead of add.
    @State private var dragPaintAdding = true
    #endif

    /// Explicit and non-all-zero: macOS plain List substitutes a ~16pt leading
    /// for an all-zero `EdgeInsets()` but honors `leading: 0` here.
    static let headerRowInsets = EdgeInsets(top: 6, leading: 0, bottom: 4, trailing: 0)

    private enum Entry: Hashable {
        #if os(macOS)
        case tonight
        #endif
        case needsYou
        case arr(QueueItem.Source)
    }

    private var orderedEntries: [Entry] {
        configStore.arrOrder.compactMap { key -> Entry? in
            #if os(macOS)
            // macOS-only; iOS has a dedicated Upcoming tab.
            if key == ConfigStore.tonightOrderKey {
                guard configStore.showTonight, !viewModel.tonight.isEmpty else { return nil }
                return .tonight
            }
            #endif
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

    var body: some View {
        List {
            // No Sections: macOS List gives them inconsistent spacing, insets and
            // expand animations per group size; flat rows stay uniform.
            ForEach(orderedEntries, id: \.self) { entry in
                switch entry {
                #if os(macOS)
                case .tonight:
                    tonightSection()
                #endif
                case .needsYou:
                    needsYouSection()
                case .arr(let source):
                    arrSection(source)
                }
            }
            if orderedEntries.isEmpty {
                emptyState.plainQueueRow()
            }
        }
        #if os(macOS)
        // Cancel the auto-collapse timer so it can't fire off-screen or leak across remounts.
        .onDisappear { bannerCollapseTask?.cancel(); bannerCollapseTask = nil }
        #endif
        .listStyle(.plain)
        .listSectionSeparator(.hidden)
        .scrollContentBackground(.hidden)
        .environment(\.queueOffline, viewModel.isFullyOffline)
        // 1, not 0: macOS backs `List` with an `NSTableView` whose rowHeight must be
        // positive; 0 made AppKit reject it and the list re-render at display rate.
        .environment(\.defaultMinListRowHeight, 1)
        // No placement filter: newer macOS adds horizontal margins beyond
        // `.scrollContent` alone.
        .contentMargins(.horizontal, 0)
        .contentMargins(.top, 0, for: .scrollContent)
        #if os(iOS)
        .listSectionSpacing(.compact)
        #endif
        #if os(iOS)
        .navigationTitle(selecting ? selectionCountLabel : "")
        .toolbar { if selecting { selectionToolbar } }
        #else
        // A bar, not an inset: the list's top edge blurs softly under it instead of cutting hard.
        .safeAreaBar(edge: .top, spacing: 0) {
            if selecting { selectionActionBar }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        #endif
        .onChange(of: selecting) { _, on in
            if !on {
                selected.removeAll()
                lastAnchorID = nil
                #if os(macOS)
                rowFrames.removeAll()
                #endif
            }
        }
        .onChange(of: viewModel.activeCount) { _, count in
            if count == 0, selecting { selecting = false }
        }
        #if os(macOS)
        .onModifierKeysChanged(mask: .option) { _, keys in
            queueUI.optionKeyHeld = keys.contains(.option)
        }
        .onDisappear { queueUI.optionKeyHeld = false }
        #endif
    }

    // MARK: - Multi-select

    #if os(iOS)
    /// Labelled buttons, not bare glyphs: greyed-out symbols with nothing
    /// selected gave no way to learn what they do.
    @ToolbarContentBuilder
    private var selectionToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                if allSelected { selected.removeAll() } else { selectAll() }
            } label: {
                Text(allSelected ? "queue.deselectAll.button" : "queue.selectAll.button", bundle: .module)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { exitSelection() } label: {
                Text("common.done.button", bundle: .module).fontWeight(.semibold)
            }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button { bulk { await viewModel.resume($0) } } label: {
                Text("queue.resume.button", bundle: .module)
            }
            .disabled(selected.isEmpty)
            Spacer()
            Button { bulk { await viewModel.pause($0) } } label: {
                Text("queue.pause.button", bundle: .module)
            }
            .disabled(selected.isEmpty)
            Spacer()
            Button(role: .destructive) {
                let items = selectedItems(); exitSelection()
                Task { await viewModel.deleteAll(items) }
            } label: {
                Text("queue.delete.button", bundle: .module)
            }
            .disabled(selected.isEmpty)
            .tint(.red)
        }
    }

    private var allSelected: Bool {
        let ids = orderedSelectableEntries.map(\.id)
        return !ids.isEmpty && selected.count == ids.count
    }

    private func selectAll() {
        selected = Set(orderedSelectableEntries.map(\.id))
    }
    #endif

    /// Opaque `.selectionModeBar()` pill: translucent glass melted into the
    /// popover's dark vibrancy.
    private var selectionActionBar: some View {
        HStack(spacing: 14) {
            Button { exitSelection() } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("common.cancel.button", bundle: .module))

            Text(verbatim: selectionCountLabel)
                .scaledFont(size: 13, weight: .semibold, monospacedDigit: true)
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: selected.count)
                .lineLimit(1)

            Spacer(minLength: 8)

            Group {
                Button { bulk { await viewModel.resume($0) } } label: {
                    Image(systemName: "play.fill")
                }
                .accessibilityLabel(Text("queue.resume.button", bundle: .module))
                Button { bulk { await viewModel.pause($0) } } label: {
                    Image(systemName: "pause.fill")
                }
                .accessibilityLabel(Text("queue.pause.button", bundle: .module))
                Button(role: .destructive) {
                    let items = selectedItems(); exitSelection()
                    Task { await viewModel.deleteAll(items) }
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel(Text("queue.delete.button", bundle: .module))
            }
            .buttonStyle(.plain)
            // Uniform white: the shapes carry the meaning; colour read as noise on the pill.
            .foregroundStyle(.white)
            .scaledFont(size: 15, weight: .semibold)
            .disabled(selected.isEmpty)
            .opacity(selected.isEmpty ? 0.4 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .selectionModeBar()
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private var selectionCountLabel: String {
        String.localizedStringWithFormat(
            NSLocalizedString("queue.selectedItemsCount", bundle: .module, comment: ""),
            selected.count
        )
    }

    private func selectionState(for entry: QueueRowEntry) -> RowSelectionState {
        guard selecting else { return .hidden }
        return selected.contains(entry.id) ? .selected : .unselected
    }

    private func toggleSelection(_ entry: QueueRowEntry) {
        if selected.contains(entry.id) { selected.remove(entry.id) }
        else { selected.insert(entry.id) }
    }

    /// Selecting: tap toggles, ⇧-click extends from the anchor. Otherwise ⌘-click
    /// enters selecting with this row picked, a plain click opens the detail.
    private func rowTapped(_ entry: QueueRowEntry, defaultTarget: QueueItem) {
        if selecting {
            #if os(macOS)
            if NSEvent.modifierFlags.contains(.shift), let anchor = lastAnchorID {
                selectRange(from: anchor, to: entry.id)
                return
            }
            #endif
            toggleSelection(entry)
            lastAnchorID = entry.id
            return
        }
        #if os(macOS)
        if NSEvent.modifierFlags.contains(.command) {
            selected = [entry.id]
            lastAnchorID = entry.id
            withAnimation(.snappy(duration: 0.18)) { selecting = true }
            return
        }
        #endif
        onShowDetail(defaultTarget)
    }

    #if os(macOS)
    /// Additive like Finder; the anchor stays put so successive ⇧-clicks re-extend.
    private func selectRange(from anchor: String, to target: String) {
        let ids = orderedSelectableEntries.map(\.id)
        guard let ai = ids.firstIndex(of: anchor), let ti = ids.firstIndex(of: target) else {
            toggleSelection(target: target)
            return
        }
        selected.formUnion(ids[min(ai, ti)...max(ai, ti)])
    }

    /// Fallback when the anchor left the queue mid-selection.
    private func toggleSelection(target: String) {
        if selected.contains(target) { selected.remove(target) }
        else { selected.insert(target) }
        lastAnchorID = target
    }
    #endif

    private func exitSelection() {
        // Setting the mode false clears `selected` via `onChange(of: selecting)`.
        withAnimation(.snappy(duration: 0.18)) { selecting = false }
    }

    /// Arr-section rows in display order. Headers and a collapsed group's
    /// hidden children aren't selectable.
    private var orderedSelectableEntries: [QueueRowEntry] {
        orderedEntries.flatMap { entry -> [QueueRowEntry] in
            guard case .arr(let source) = entry else { return [] }
            return displayRows(for: source).flatMap { display -> [QueueRowEntry] in
                switch display {
                case .entry(let e): return [e]
                case .titleGroup(let g): return isGroupExpanded(g) ? g.entries : []
                }
            }
        }
    }

    private func selectedItems() -> [QueueItem] {
        orderedSelectableEntries
            .filter { selected.contains($0.id) }
            .flatMap { entry -> [QueueItem] in
                switch entry {
                case .single(let item): return [item]
                case .group(let group): return group.items
                }
            }
    }

    private func bulk(_ action: @escaping (QueueItem) async -> Void) {
        let items = selectedItems()
        exitSelection()
        Task { for item in items { await action(item) } }
    }

    // MARK: - Drag-to-select (macOS)

    #if os(macOS)
    /// Global coordinates are the one space that means the same inside and outside
    /// the List's per-row cells. macOS click-drag never scrolls, so this doesn't fight the List.
    private func dragSelectGesture(anchor: String) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                if dragAnchorID == nil {
                    dragBaseline = selected
                    dragAnchorID = anchor
                    dragPaintAdding = !selected.contains(anchor)
                }
                applyDragSelection(to: value.location.y)
            }
            .onEnded { _ in
                lastAnchorID = dragAnchorID
                dragAnchorID = nil
                dragBaseline = nil
            }
    }

    private func applyDragSelection(to y: CGFloat) {
        guard let anchor = dragAnchorID, let baseline = dragBaseline else { return }
        let ids = orderedSelectableEntries.map(\.id)
        guard let ai = ids.firstIndex(of: anchor),
              let current = rowID(near: y, among: Set(ids)),
              let ci = ids.firstIndex(of: current) else { return }
        var next = baseline
        for id in ids[min(ai, ci)...max(ai, ci)] {
            if dragPaintAdding { next.insert(id) } else { next.remove(id) }
        }
        selected = next
    }

    /// Nearest row when `y` falls in a header gap. Only `valid` ids count:
    /// `rowFrames` can keep a stale entry for a row that left mid-drag.
    private func rowID(near y: CGFloat, among valid: Set<String>) -> String? {
        var nearest: (id: String, dist: CGFloat)?
        for (id, rect) in rowFrames where valid.contains(id) {
            if y >= rect.minY, y <= rect.maxY { return id }
            let d = min(abs(y - rect.minY), abs(y - rect.maxY))
            if nearest == nil || d < nearest!.dist { nearest = (id, d) }
        }
        return nearest?.id
    }

    #endif

    // MARK: - Sections

    private static let staleRowOpacity: Double = 0.5
    private static let hiddenRowOpacity: Double = 0.35

    private func rowOpacity(isStale: Bool, items: [QueueItem]) -> Double {
        (isStale ? Self.staleRowOpacity : 1) * (queueUI.areHidden(items) ? Self.hiddenRowOpacity : 1)
    }

    @ViewBuilder
    private func arrSection(_ source: QueueItem.Source) -> some View {
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
        ConfirmCenter.request(PendingConfirm(
            title: "Remove \(group.downloadCount) downloads?",
            message: "This will remove every download of this title from the client.",
            confirmLabel: "Remove All",
            isDestructive: true,
            onConfirm: { [weak viewModel] in Task { await viewModel?.deleteAll(items) } }
        ))
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

    /// Header row plus sibling rows so collapse animates as native row
    /// insert/remove instead of one growing cell.
    @ViewBuilder
    private func needsYouSection() -> some View {
        let collapsed = queueUI.isCollapsed(ConfigStore.needsYouOrderKey)
        NeedsYouHeader(
            count: viewModel.needsYou.count,
            isCollapsed: collapsed,
            onToggle: {
                withAnimation(.smooth(duration: 0.22)) {
                    queueUI.toggleCollapsed(ConfigStore.needsYouOrderKey)
                }
            }
        )
        .plainQueueRow(insets: Self.headerRowInsets)
        if !collapsed {
            ForEach(viewModel.needsYou) { needs in
                NeedsYouRow(needs: needs, onTap: { needsYouItemTapped(needs) })
                    .plainQueueRow()
            }
        }
    }

    private func needsYouItemTapped(_ needs: NeedsYouItem) {
        if let onNeedsYouTap {
            onNeedsYouTap(needs)
        } else if let itemId = needs.item?.id {
            let match = QueueItem.Source.allCases.lazy
                .compactMap { viewModel.items(for: $0).first(where: { $0.id == itemId }) }
                .first
            if let match { onShowDetail(match) }
        }
    }

    #if os(macOS)
    /// Sibling rows, like `needsYouSection`, so collapse animates as row insert/remove.
    @ViewBuilder
    private func tonightSection() -> some View {
        let items = viewModel.tonight
        // 0 = "always show all" (Settings).
        let limit = configStore.tonightVisibleCount
        let visible = (viewModel.tonightExpanded || limit == 0) ? items : Array(items.prefix(limit))
        let overflow = items.count - visible.count
        let collapsed = queueUI.isCollapsed(ConfigStore.tonightOrderKey)
        QueueHeaderRow(
            icon: AnyView(
                Image(systemName: "calendar")
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
            ),
            title: String(localized: "queue.nextWeek.button", bundle: .module),
            collapsed: collapsed,
            onToggle: {
                withAnimation(.smooth(duration: 0.22)) {
                    queueUI.toggleCollapsed(ConfigStore.tonightOrderKey)
                }
            }
        )
        .plainQueueRow(insets: Self.headerRowInsets)
        if !collapsed {
            ForEach(Array(visible.enumerated()), id: \.element.id) { offset, item in
                TonightBannerRow(
                    item: item,
                    timeString: item.airDateCompact(locale: configStore.currentLocale),
                    onTap: { openUpcomingDetail(item) }
                )
                .padding(.top, offset == 0 ? 4 : 0)
                .padding(.leading, QueueHeaderMetrics.contentIndent)
                .padding(.trailing, Tokens.Spacing.queueRowH)
                .plainQueueRow()
            }
            if overflow > 0 && !viewModel.tonightExpanded {
                tonightShowMoreButton
                    .padding(.leading, QueueHeaderMetrics.contentIndent)
                    .plainQueueRow()
            } else if viewModel.tonightExpanded && limit != 0 && items.count > limit {
                tonightShowLessButton
                    .padding(.leading, QueueHeaderMetrics.contentIndent)
                    .plainQueueRow()
            }
        }
    }

    private var tonightShowMoreButton: some View {
        Button {
            withAnimation(.smooth(duration: 0.22)) {
                viewModel.setTonightExpanded(true)
            }
            scheduleBannerCollapse()
        } label: {
            HStack(spacing: 3) {
                Text("queue.showMore.button", bundle: .module)
                    .scaledFont(size: 10)
                Image(systemName: "chevron.down")
                    .scaledFont(size: 9, weight: .medium)
            }
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    private var tonightShowLessButton: some View {
        Button {
            bannerCollapseTask?.cancel()
            withAnimation(.smooth(duration: 0.22)) {
                viewModel.setTonightExpanded(false)
            }
        } label: {
            HStack(spacing: 3) {
                Text("discover.showLess.button", bundle: .module)
                    .scaledFont(size: 10)
                Image(systemName: "chevron.up")
                    .scaledFont(size: 9, weight: .medium)
            }
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    /// Picked up by the popover's `DetailRouter` observer.
    private func openUpcomingDetail(_ item: UpcomingItem) {
        guard let entityId = item.entityId else { return }
        DetailRequest.post(
            DetailRequest.syntheticItem(
                source: item.source,
                entityId: entityId,
                title: item.title,
                posterURL: item.posterURL,
                posterRequiresAuth: item.posterRequiresAuth
            )
        )
    }

    private func scheduleBannerCollapse() {
        bannerCollapseTask?.cancel()
        bannerCollapseTask = Task { [viewModel] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if Task.isCancelled { return }
            withAnimation(.smooth(duration: 0.22)) {
                viewModel.setTonightExpanded(false)
            }
        }
    }

    #endif

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

    private func deleteClosure(for entry: QueueRowEntry) -> () -> Void {
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

    private func canControl(_ item: QueueItem) -> Bool { configStore.canControlDownload(item.downloadProtocol) }

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

    // MARK: - Data

    private func isVisible(_ source: QueueItem.Source) -> Bool {
        configStore.config(for: source.serviceKind).isVisible
    }

    private func entries(for source: QueueItem.Source) -> [QueueRowEntry] {
        var raw = viewModel.items(for: source)
        if !queueUI.revealsHiddenQueueItems {
            raw.removeAll(where: queueUI.isHidden)
        }
        switch source {
        case .sonarr: return QueueGrouping.group(raw)
        default:      return raw.map { .single($0) }
        }
    }

    private func displayRows(for source: QueueItem.Source) -> [QueueDisplayRow] {
        let base = entries(for: source)
        guard queueUI.queueTitleGrouping != .off else {
            return base.map { .entry($0) }
        }
        return QueueGrouping.groupByTitle(base)
    }

    private func isGroupExpanded(_ group: QueueTitleGroup) -> Bool {
        let defaultExpanded = queueUI.queueTitleGrouping == .expanded
        return toggledTitleGroups.contains(group.id) ? !defaultExpanded : defaultExpanded
    }

    private func toggleTitleGroup(_ group: QueueTitleGroup) {
        if toggledTitleGroups.contains(group.id) { toggledTitleGroups.remove(group.id) }
        else { toggledTitleGroups.insert(group.id) }
    }

    private func itemCount(_ source: QueueItem.Source) -> Int {
        viewModel.items(for: source).count - hiddenCount(source)
    }

    private func hiddenCount(_ source: QueueItem.Source) -> Int {
        viewModel.items(for: source).count(where: queueUI.isHidden)
    }

}

// MARK: - Row chrome helper

private extension View {
    /// Zero horizontal inset: each row brings its own padding.
    func plainQueueRow(insets: EdgeInsets = EdgeInsets()) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(insets)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

#if os(macOS)
    /// Its own view to keep `tonightSection` under the type-check warn threshold.
private struct TonightBannerRow: View {
    let item: UpcomingItem
    let timeString: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Text(timeString)
                    .scaledFont(size: 11, weight: .medium, monospacedDigit: true)
                    .foregroundStyle(.secondary)
                ServiceIcon(source: item.source, size: 10)
                    .foregroundStyle(.secondary)
                Text(item.title)
                    .scaledFont(size: 12, weight: .medium)
                    .lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .scaledFont(size: 11)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.entityId == nil)
        .upcomingTooltip(item: item)
    }
}
#endif
