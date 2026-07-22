import SwiftUI
#if canImport(AppKit)
import AppKit  // NSEvent.modifierFlags — ⌘-click detection on macOS.
#endif

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

    #if os(macOS)
    /// 30s auto-collapse timer for the expanded "Next week" peek. Local to the
    /// list now (was a binding threaded from PopoverContentView); it survives
    /// body re-evals while the queue list stays mounted.
    @State private var bannerCollapseTask: Task<Void, Never>?
    #endif

    /// Queue multi-select. The native `List` stays the container, but selection
    /// is driven by us (tap-to-toggle, checkbox semantics) — macOS `List(selection:)`
    /// *replaces* the selection on a plain click instead of toggling. The mode flag
    /// is host-owned (toggled from the tab "⋯" menu); `selected` holds the chosen
    /// `QueueRowEntry.id`s (a season-pack group row selects its whole pack).
    ///
    /// Three ways in / around a selection (macOS):
    ///   • ⋯ menu → "Select multiple" flips `selecting` (0 selected to start).
    ///   • ⌘-click a row (normal mode) enters selecting *and* selects that row —
    ///     the standard Finder/Mail affordance, no menu detour (`rowTapped`).
    ///   • Click-drag down a run of rows paints a contiguous range
    ///     (`dragSelectGesture`). macOS click-drag never scrolls (that's the
    ///     wheel / two-finger event stream), so the paint gesture and scrolling
    ///     don't fight — which is what keeps this solid rather than a hack.
    @Binding var selecting: Bool
    @State private var selected = Set<String>()

    #if os(macOS)
    /// Live frame of every selectable row in `Self.listSpace`, harvested via a
    /// `PreferenceKey`. Drives which row the drag is currently over. Only
    /// populated while `selecting` (the reporter is gated), empty otherwise.
    @State private var rowFrames: [String: CGRect] = [:]
    /// Drag-to-select scratch state. `dragBaseline` is the selection snapshot at
    /// the drag's start — every change re-derives from it, so dragging back up
    /// *un-paints* rows instead of leaving a smear. nil ⇒ no drag in flight.
    @State private var dragBaseline: Set<String>?
    @State private var dragAnchorID: String?
    /// Add vs. remove for this drag, decided by the anchor row's state at the
    /// start: begin on an unselected row → painting *adds*; on a selected row →
    /// painting *removes* (drag-to-deselect).
    @State private var dragPaintAdding = true

    /// Named coordinate space shared by the row-frame reporter and the drag
    /// gesture so `value.location` and the harvested frames are in one system.
    private static let listSpace = "queueList"
    #endif

    /// The ONE listRowInsets every section header uses. Explicit + non-all-zero
    /// (the macOS plain List substitutes a default ~16pt leading for an all-zero
    /// `EdgeInsets()`, but honors this verbatim including `leading: 0`). Combined
    /// with each header's `.padding(.horizontal, queueRowH)`, this puts every
    /// chevron at exactly `queueRowH` — they line up.
    static let headerRowInsets = EdgeInsets(top: 6, leading: 0, bottom: 4, trailing: 0)

    private enum Entry: Hashable {
        #if os(macOS)
        case tonight
        #endif
        case needsYou
        case arr(QueueItem.Source)
    }

    /// Drives the rendered order from `arrOrder`, mirroring the old
    /// section-list logic so banners keep their user-chosen position.
    private var orderedEntries: [Entry] {
        if let scope { return isVisible(scope) ? [.arr(scope)] : [] }
        return configStore.arrOrder.compactMap { key -> Entry? in
            #if os(macOS)
            // "Next week" peek — macOS-only (iOS has a dedicated Upcoming tab).
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

    private var hideHeader: Bool { scope != nil }

    var body: some View {
        // Native multi-select: bind the List's own selection while in selecting
        // mode (nil otherwise, so a normal click still opens the detail).
        List {
            // No Sections — every header + row is a plain List row. macOS List
            // gives Sections inconsistent spacing / leading insets / expand
            // animations (different for single-row groups like Needs-you vs
            // multi-row arr groups), which is exactly what skewed the chevrons,
            // the closed-section heights and the open animation. Flat rows are
            // uniform.
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
        // Tear down the "Next week" auto-collapse timer when the list unmounts
        // (tab switch / filtering swaps this view out) so it can't fire a stray
        // collapse off-screen or strand an uncancellable task across remounts.
        .onDisappear { bannerCollapseTask?.cancel(); bannerCollapseTask = nil }
        #endif
        .listStyle(.plain)
        // No separator lines anywhere — rows hide theirs via `plainQueueRow`; this
        // also kills the section-boundary line between arrs.
        .listSectionSeparator(.hidden)
        .scrollContentBackground(.hidden)
        // Propagate the away-from-LAN state so each row hides its mutating
        // controls (the header chip is the single explanation).
        .environment(\.queueOffline, viewModel.isFullyOffline)
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
        // Multi-select action bar pinned under the host toolbar (top), shown
        // only while selecting. Entry is the tab "⋯" menu (host owns `selecting`).
        .safeAreaInset(edge: .top, spacing: 0) {
            if selecting { selectionActionBar }
        }
        // Drop the selection set whenever selecting mode ends (menu toggle,
        // Cancel, or the queue emptying out from under us).
        .onChange(of: selecting) { _, on in if !on { selected.removeAll() } }
        .onChange(of: viewModel.activeCount) { _, count in
            if count == 0, selecting { selecting = false }
        }
        #if os(macOS)
        // Establish the space the drag gesture + row-frame reporter both use,
        // then keep `rowFrames` in sync as rows lay out / scroll. Same
        // `.coordinateSpace(name:)` + preference recipe as the tab-pill bar.
        .coordinateSpace(name: Self.listSpace)
        .onPreferenceChange(RowFramePreferenceKey.self) { rowFrames = $0 }
        #endif
    }

    // MARK: - Multi-select

    /// Floating action bar shown while selecting: cancel · count · resume ·
    /// pause · delete, all acting on the current selection (actions no-op / dim
    /// at 0). The count reads as a proper sentence ("3 items selected") rather
    /// than a bare number, and the bar wears the bright, opaque
    /// `.selectionModeBar()` pill so it's obvious at a glance that the queue is
    /// in multi-select mode — the earlier translucent glass melted into the
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
            // Uniform white glyphs on the frosted glass (was green/orange/red) —
            // the shapes carry the meaning; colour read as noise on the pill.
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

    /// Localized, correctly-pluralized "N items selected" (Polish gets the full
    /// one/few/many/other spread from the catalog).
    private var selectionCountLabel: String {
        String.localizedStringWithFormat(
            NSLocalizedString("queue.selectedItemsCount", bundle: .module, comment: ""),
            selected.count
        )
    }

    /// Per-row selection state driving the circle that replaces the poster.
    private func selectionState(for entry: QueueRowEntry) -> RowSelectionState {
        guard selecting else { return .hidden }
        return selected.contains(entry.id) ? .selected : .unselected
    }

    /// Toggle this row's membership in the selection — checkbox semantics, so a
    /// plain click (no ⌘) adds or removes it. We drive `selected` ourselves
    /// rather than `List(selection:)`, whose macOS single-click *replaces* the
    /// selection (Finder-style) instead of toggling.
    private func toggleSelection(_ entry: QueueRowEntry) {
        if selected.contains(entry.id) { selected.remove(entry.id) }
        else { selected.insert(entry.id) }
    }

    /// Central row-tap router. In selecting mode any tap toggles. Outside it, a
    /// ⌘-click (macOS) *enters* selecting with this row already picked — the
    /// standard Finder/Mail affordance — while a plain click opens the detail.
    private func rowTapped(_ entry: QueueRowEntry, defaultTarget: QueueItem) {
        if selecting {
            toggleSelection(entry)
            return
        }
        #if os(macOS)
        if NSEvent.modifierFlags.contains(.command) {
            selected = [entry.id]
            withAnimation(.snappy(duration: 0.18)) { selecting = true }
            return
        }
        #endif
        onShowDetail(defaultTarget)
    }

    private func exitSelection() {
        // Setting the mode false clears `selected` via `onChange(of: selecting)`.
        withAnimation(.snappy(duration: 0.18)) { selecting = false }
    }

    /// Every selectable row in display order — arr-section rows only (headers,
    /// Needs-you and Next-week rows aren't selectable). One source of truth for
    /// both `selectedItems()` and the drag range math.
    private var orderedSelectableEntries: [QueueRowEntry] {
        orderedEntries.flatMap { entry -> [QueueRowEntry] in
            if case .arr(let source) = entry { return self.entries(for: source) }
            return []
        }
    }

    /// Resolve the selected `QueueRowEntry.id`s to their underlying items
    /// (a group row contributes its whole pack).
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

    /// Run an async per-item action over the selection, then leave selecting mode.
    private func bulk(_ action: @escaping (QueueItem) async -> Void) {
        let items = selectedItems()
        exitSelection()
        Task { for item in items { await action(item) } }
    }

    // MARK: - Drag-to-select (macOS)

    #if os(macOS)
    /// Paint a contiguous range of rows as the pointer drags down (or up) a run
    /// of them. Attached per-row so the anchor is known without hit-testing the
    /// start point; the *current* row is resolved from the harvested frame map.
    ///
    /// Robustness comes from re-deriving the whole selection from `dragBaseline`
    /// on every change (drag reversal un-paints) and from macOS click-drag not
    /// being the scroll gesture — so this never has to arm-wrestle the List for
    /// the drag stream. `minimumDistance: 6` keeps a plain click a tap (toggle),
    /// not a zero-length paint.
    private func dragSelectGesture(anchor: String) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.listSpace))
            .onChanged { value in
                if dragAnchorID == nil {
                    dragBaseline = selected
                    dragAnchorID = anchor
                    dragPaintAdding = !selected.contains(anchor)
                }
                applyDragSelection(to: value.location.y)
            }
            .onEnded { _ in
                dragAnchorID = nil
                dragBaseline = nil
            }
    }

    /// Re-derive `selected` = baseline ± the anchor…current row range.
    private func applyDragSelection(to y: CGFloat) {
        guard let anchor = dragAnchorID, let baseline = dragBaseline else { return }
        let ids = orderedSelectableEntries.map(\.id)
        guard let ai = ids.firstIndex(of: anchor),
              let current = rowID(near: y),
              let ci = ids.firstIndex(of: current) else { return }
        var next = baseline
        for id in ids[min(ai, ci)...max(ai, ci)] {
            if dragPaintAdding { next.insert(id) } else { next.remove(id) }
        }
        selected = next
    }

    /// Row whose vertical band contains `y`; if `y` sits in a gap (a section
    /// header between two arr groups), the nearest row by edge distance — so the
    /// range never collapses just because the pointer crossed a header.
    private func rowID(near y: CGFloat) -> String? {
        var nearest: (id: String, dist: CGFloat)?
        for (id, rect) in rowFrames {
            if y >= rect.minY, y <= rect.maxY { return id }
            let d = min(abs(y - rect.minY), abs(y - rect.maxY))
            if nearest == nil || d < nearest!.dist { nearest = (id, d) }
        }
        return nearest?.id
    }

    /// Transparent backing that reports a row's frame into `rowFrames`.
    private func rowFrameReporter(_ id: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: RowFramePreferenceKey.self,
                value: [id: proxy.frame(in: .named(Self.listSpace))]
            )
        }
    }
    #endif

    // MARK: - Sections

    @ViewBuilder
    private func arrSection(_ source: QueueItem.Source) -> some View {
        let arrError = viewModel.error(for: source)
        // A failed refresh keeps the last-good snapshot (QueueViewModel
        // `freshOrKept`). Show it here — dimmed, read-only — instead of
        // blanking the section; the header carries the error and explains the
        // staleness. Whether the failure is an outage, a 502 from a reverse
        // proxy, or split-DNS junk while away, the user still sees what was
        // last there rather than an empty list.
        let isStale = arrError != nil
        // Unreachable (transport / 502 / split-DNS) is the calm away case; a
        // *reachable* error (401/500 — the arr answered) stays a loud, actionable
        // problem. The two get different chrome below.
        let isUnreachable = viewModel.lastUnreachable.contains(source)
        // Offline sections stay collapsible (chevron + tap), unlike a genuine error.
        let collapsed = (arrError == nil || isUnreachable) && configStore.isCollapsed(source)
        // Header + rows as plain List rows (no Section wrapper). Same inset and
        // mechanism as the Needs-you / Next-week headers → chevrons line up.
        if !hideHeader {
            sectionHeader(source, error: arrError, isUnreachable: isUnreachable, collapsed: collapsed)
                .plainQueueRow(insets: Self.headerRowInsets)
        }
        if !collapsed {
                let rows = entries(for: source)
                if rows.isEmpty {
                    if isUnreachable {
                        // Calm "can't reach this server" line instead of a blank
                        // body — quiet, no error styling.
                        Text("queue.serverUnreachable.label", bundle: .module)
                            .scaledFont(size: 12)
                            .foregroundStyle(.tertiary)
                            .plainQueueRow(insets: EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                    } else if !isStale {
                        // "Queue empty" only when the arr actually answered.
                        Text("queue.queueEmpty.button", bundle: .module)
                            .scaledFont(size: 12)
                            .foregroundStyle(.tertiary)
                            .plainQueueRow(insets: EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                    }
                    // A reachable error with nothing cached → render nothing; the
                    // header badge already explains it.
                } else {
                    ForEach(rows) { entry in
                        swipeableRow(for: entry, isStale: isStale)
                    }
                }
            }
    }

    /// A queue row plus its swipe actions. Native `.swipeActions` are **iOS-only**:
    /// on macOS the same SwiftUI `List` + swipe-to-delete throws an AppKit
    /// `NSTableView` layout exception when the deleted row's batch update comes
    /// out inconsistent (confirmed from a crash report — `_NSViewLayout` →
    /// `_crashOnException`). macOS already deletes via the row's hover action, so
    /// the swipe there was both crashy and redundant. `allowsFullSwipe: false` so
    /// a full swipe *reveals* the button instead of auto-committing a destructive
    /// delete (also dodges the same auto-commit race on iOS).
    @ViewBuilder
    private func swipeableRow(for entry: QueueRowEntry, isStale: Bool) -> some View {
        let content = rowView(for: entry)
            // Per-section offline: a stale/unreachable arr's rows can't be acted
            // on, so block their right-click menu (and poster control) even when
            // only THIS arr is down — the List-level value only covers all-arrs.
            .environment(\.queueOffline, viewModel.isFullyOffline || isStale)
        #if os(iOS)
        let row = content.plainQueueRow()
        row
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                // Icon-only, Apple-Mail style. Hidden when fully offline OR this
                // arr's data is stale — the delete can't reach the arr.
                if !viewModel.isFullyOffline, !isStale {
                    Button(role: .destructive) {
                        deleteClosure(for: entry)()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel(Text("queue.delete.button", bundle: .module))
                }
            }
            // Leading swipe → pause/resume: only with a configured download
            // client AND a downloading/paused item, mirroring the row's hover/CTA
            // gating; suppressed when fully offline or stale.
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
        // macOS: no native swipe — delete / pause live in the row's hover actions.
        // While selecting, the row also reports its frame (drag hit-testing) and
        // carries the drag-to-paint gesture. Both are dropped in normal mode so
        // they can't interfere with the detail-tap / hover affordances.
        if selecting {
            content
                .background { rowFrameReporter(entry.id) }
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
            // Count only when healthy; per-arr health surfaces as "Needs you"
            // rows now (not a hover badge here).
            count: error == nil ? itemCount(source) : nil,
            collapsed: collapsed,
            // Offline is a collapsible state like any other — only a genuine
            // (reachable) error hides the chevron.
            showChevron: error == nil || isUnreachable,
            onToggle: {
                guard error == nil || isUnreachable else { return }
                withAnimation(.smooth(duration: 0.22)) { configStore.toggleCollapsed(source) }
            }
        ) {
            if isUnreachable {
                // Calm, muted "offline" — the expected away/proxy case, not an
                // alarm. No orange, no HTTP code; the body shows the last state.
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
    }

    /// "Needs you" as a header row + one sibling row per entry (like arr
    /// sections) — so collapse animates as native row insert/remove instead of
    /// one growing cell (kills the "content slides from the top" jump), and the
    /// header chevron lines up with the others.
    @ViewBuilder
    private func needsYouSection() -> some View {
        let collapsed = configStore.isCollapsed(ConfigStore.needsYouOrderKey)
        NeedsYouHeader(
            count: viewModel.needsYou.count,
            isCollapsed: collapsed,
            onToggle: {
                withAnimation(.smooth(duration: 0.22)) {
                    configStore.toggleCollapsed(ConfigStore.needsYouOrderKey)
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
        // arr-level issue rows (needs.item == nil) have no queue detail to push;
        // the popover wires onNeedsYouTap to open the arr's queue page instead.
    }

    #if os(macOS)
    /// "Next week" peek — a header row + each upcoming item as a SIBLING List row
    /// (like the arr / Needs-you sections), so collapse animates as native row
    /// insert/remove instead of one growing cell sliding content in from the top.
    @ViewBuilder
    private func tonightSection() -> some View {
        let items = viewModel.tonight
        let visible = viewModel.tonightExpanded ? items : Array(items.prefix(4))
        let overflow = items.count - visible.count
        let collapsed = configStore.isCollapsed(ConfigStore.tonightOrderKey)
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
                    configStore.toggleCollapsed(ConfigStore.tonightOrderKey)
                }
            }
        )
        .plainQueueRow(insets: Self.headerRowInsets)
        if !collapsed {
            ForEach(Array(visible.enumerated()), id: \.element.id) { offset, item in
                TonightBannerRow(
                    item: item,
                    timeString: Self.tonightTimeFormatter.string(from: item.airDate),
                    onTap: { openUpcomingDetail(item) }
                )
                // A little air between the header and the first content row.
                .padding(.top, offset == 0 ? 4 : 0)
                // Align the rows under the moon, past the chevron column.
                .padding(.leading, QueueHeaderMetrics.contentIndent)
                .padding(.trailing, Tokens.Spacing.queueRowH)
                .plainQueueRow()
            }
            if overflow > 0 && !viewModel.tonightExpanded {
                tonightShowMoreButton
                    .padding(.leading, QueueHeaderMetrics.contentIndent)
                    .plainQueueRow()
            }
        }
    }

    /// Overflow expander — reveals the hidden upcoming rows and arms the 30s
    /// auto-collapse timer.
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

    /// Sends the tonight-banner item into the detail pipeline — a synthetic
    /// `QueueItem` posted via `DetailRequest`, picked up by the popover's
    /// `arrBarrOpenDetail` listener (same shape as `UpcomingRowView.openDetail`).
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

    /// 30s auto-collapse for the expanded "Next week" peek. Any new expand
    /// cancels the prior timer and restarts the countdown.
    private func scheduleBannerCollapse() {
        bannerCollapseTask?.cancel()
        bannerCollapseTask = Task { @MainActor [viewModel] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if Task.isCancelled { return }
            withAnimation(.smooth(duration: 0.22)) {
                viewModel.setTonightExpanded(false)
            }
        }
    }

    private static let tonightTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
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
                // Row tap is routed through `rowTapped`: toggle while selecting,
                // ⌘-click to enter-and-select, plain click opens the detail.
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
                // Same routing as the single row; the plain-click target is the
                // season context (episode coords stripped) — DetailView shows the
                // season, not one episode.
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

    // Swipe-only helpers — only the iOS row renders swipe actions; macOS uses
    // hover actions, so these would otherwise warn as unused there.
    #if os(iOS)
    /// Representative item for an entry (single → itself, group → rep). Used
    /// to gate the leading pause/resume swipe.
    private func repItem(for entry: QueueRowEntry) -> QueueItem {
        switch entry {
        case .single(let item): return item
        case .group(let group): return group.representative
        }
    }

    /// Mirrors QueueRowView.canControl — pause/resume needs a download client
    /// that's configured AND reachable (the action bypasses the arr and goes
    /// straight to the client), so a `.down` client hides the swipe.
    private func canControl(_ item: QueueItem) -> Bool {
        guard let kind = configStore.selectedDownloadClient(for: item.downloadProtocol) else { return false }
        if case .down = ConnectionHealth.shared.state(for: .arr(kind)) { return false }
        return true
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
    #endif

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

}

// MARK: - Drag-select frame harvesting

#if os(macOS)
/// Collects each selectable row's frame (in the list's named coordinate space)
/// so the drag-to-select gesture can tell which row the pointer is currently
/// over. Last writer wins per id — a row that re-lays-out overwrites its own
/// entry.
private struct RowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
#endif

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

#if os(macOS)
/// A single row in the "Next week" peek: air time, source glyph, title,
/// optional subtitle. Its own view so the `tonightSection` builder stays under
/// the 100ms type-check warn threshold.
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
    }
}
#endif
