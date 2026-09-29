import SwiftUI

/// The queue as a native `List`. `List` only turns its direct children into rows,
/// so each header and row is emitted as its own element.
struct QueueListView: View {
    var viewModel: QueueViewModel
    @Environment(ConfigStore.self) var configStore
    /// Read off the singleton, not the environment, so the widget / hosting-view
    /// boundaries that re-inject `configStore` by hand stay out of it.
    var queueUI: QueueUIState { .shared }

    let onShowDetail: (QueueItem) -> Void
    /// macOS opens the arr's queue page in the browser; iOS (nil) drills into
    /// the matching queue item's detail.
    var onNeedsYouTap: ((NeedsYouItem) -> Void)? = nil
    var onShowHistory: ((QueueItem.Source) -> Void)? = nil

    #if os(macOS)
    /// 30s auto-collapse timer for the expanded "Next week" peek.
    @State var bannerCollapseTask: Task<Void, Never>?
    #endif

    /// Selection is driven by us (checkbox semantics): macOS `List(selection:)`
    /// replaces the selection on a plain click instead of toggling.
    @Binding var selecting: Bool
    @State var selected = Set<String>()
    /// By-title groups toggled away from the mode's default disclosure state,
    /// keyed by title so it survives members joining/leaving on refresh.
    @State private var toggledTitleGroups = Set<String>()
    /// Anchor a ⇧-click extends from (Finder semantics).
    @State var lastAnchorID: String?

    #if os(macOS)
    /// Row frames in GLOBAL coordinates: macOS `List` hosts each row in its own
    /// AppKit cell, so a named coordinate space or PreferenceKey doesn't resolve there.
    @State var rowFrames: [String: CGRect] = [:]
    /// Selection snapshot at drag start; every change re-derives from it so
    /// dragging back un-paints rows. nil ⇒ no drag in flight.
    @State var dragBaseline: Set<String>?
    @State var dragAnchorID: String?
    /// Starting on a selected row makes the drag deselect instead of add.
    @State var dragPaintAdding = true
    #endif

    /// Explicit and non-all-zero: macOS plain List substitutes a ~16pt leading
    /// for an all-zero `EdgeInsets()` but honors `leading: 0` here.
    static let headerRowInsets = EdgeInsets(top: 6, leading: 0, bottom: 4, trailing: 0)

    enum Entry: Hashable {
        #if os(macOS)
        case tonight
        #endif
        case needsYou
        case arr(QueueItem.Source)
    }

    var orderedEntries: [Entry] {
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

    func displayRows(for source: QueueItem.Source) -> [QueueDisplayRow] {
        let base = entries(for: source)
        guard queueUI.queueTitleGrouping != .off else {
            return base.map { .entry($0) }
        }
        return QueueGrouping.groupByTitle(base)
    }

    func isGroupExpanded(_ group: QueueTitleGroup) -> Bool {
        let defaultExpanded = queueUI.queueTitleGrouping == .expanded
        return toggledTitleGroups.contains(group.id) ? !defaultExpanded : defaultExpanded
    }

    func toggleTitleGroup(_ group: QueueTitleGroup) {
        if toggledTitleGroups.contains(group.id) { toggledTitleGroups.remove(group.id) }
        else { toggledTitleGroups.insert(group.id) }
    }

    func itemCount(_ source: QueueItem.Source) -> Int {
        viewModel.items(for: source).count - hiddenCount(source)
    }

    func hiddenCount(_ source: QueueItem.Source) -> Int {
        viewModel.items(for: source).count(where: queueUI.isHidden)
    }

}

// MARK: - Row chrome helper

extension View {
    /// Zero horizontal inset: each row brings its own padding.
    func plainQueueRow(insets: EdgeInsets = EdgeInsets()) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(insets)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
