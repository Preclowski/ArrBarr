import SwiftUI
#if canImport(AppKit)
import AppKit  // NSEvent.modifierFlags — ⌘-click detection on macOS.
#endif

extension QueueListView {
    // MARK: - Multi-select

    #if os(iOS)
    /// Labelled buttons, not bare glyphs: greyed-out symbols with nothing
    /// selected gave no way to learn what they do.
    @ToolbarContentBuilder
    var selectionToolbar: some ToolbarContent {
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
        let rows = selectionRows
        return !rows.isEmpty && rows.allSatisfy { QueueSelection.isSelected($0, in: selected) }
    }

    private func selectAll() {
        selected = Set(selectionRows.joined().map(\.id))
    }
    #endif

    /// Opaque `.selectionModeBar()` pill: translucent glass melted into the
    /// popover's dark vibrancy.
    var selectionActionBar: some View {
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

    var selectionCountLabel: String {
        String.localizedStringWithFormat(
            NSLocalizedString("queue.selectedItemsCount", bundle: .module, comment: ""),
            QueueSelection.selectedEntries(rows: selectionRows, in: selected).count
        )
    }

    func selectionState(for entry: QueueRowEntry) -> RowSelectionState {
        selectionState(for: [entry])
    }

    func selectionState(for row: [QueueRowEntry]) -> RowSelectionState {
        guard selecting else { return .hidden }
        return QueueSelection.isSelected(row, in: selected) ? .selected : .unselected
    }

    func rowTapped(_ entry: QueueRowEntry, defaultTarget: QueueItem) {
        rowTapped([entry], defaultTarget: defaultTarget)
    }

    /// Selecting: tap toggles, ⇧-click extends from the anchor. Otherwise ⌘-click
    /// enters selecting with this row picked, a plain click opens the detail.
    func rowTapped(_ row: [QueueRowEntry], defaultTarget: QueueItem) {
        if selecting {
            #if os(macOS)
            if NSEvent.modifierFlags.contains(.shift), let anchor = lastAnchorID {
                selectRange(from: anchor, to: row)
                return
            }
            #endif
            selected = QueueSelection.toggled(row, in: selected)
            lastAnchorID = row[0].id
            return
        }
        #if os(macOS)
        if NSEvent.modifierFlags.contains(.command) {
            selected = Set(row.map(\.id))
            lastAnchorID = row[0].id
            withAnimation(.snappy(duration: 0.18)) { selecting = true }
            return
        }
        #endif
        onShowDetail(defaultTarget)
    }

    #if os(macOS)
    /// Additive like Finder; the anchor stays put so successive ⇧-clicks re-extend.
    /// With the anchor gone from the queue, it's a plain toggle.
    private func selectRange(from anchor: String, to row: [QueueRowEntry]) {
        if let ids = QueueSelection.ids(betweenRowsOf: anchor, and: row[0].id, rows: selectionRows) {
            selected.formUnion(ids)
        } else {
            selected = QueueSelection.toggled(row, in: selected)
            lastAnchorID = row[0].id
        }
    }
    #endif

    private func exitSelection() {
        // Setting the mode false clears `selected` via `onChange(of: selecting)`.
        withAnimation(.snappy(duration: 0.18)) { selecting = false }
    }

    /// Arr-section rows in display order.
    private var selectionRows: [[QueueRowEntry]] {
        orderedEntries.flatMap { entry -> [[QueueRowEntry]] in
            guard case .arr(let source) = entry else { return [] }
            return QueueSelection.rows(displayRows(for: source), isExpanded: isGroupExpanded)
        }
    }

    private func selectedItems() -> [QueueItem] {
        QueueSelection.selectedEntries(rows: selectionRows, in: selected).flatMap(\.allItems)
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
    func dragSelectGesture(row: [QueueRowEntry]) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                if dragAnchorID == nil {
                    dragBaseline = selected
                    dragAnchorID = row[0].id
                    dragPaintAdding = !QueueSelection.isSelected(row, in: selected)
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
        let rows = selectionRows
        guard let current = rowID(near: y, among: Set(rows.joined().map(\.id))),
              let ids = QueueSelection.ids(betweenRowsOf: anchor, and: current, rows: rows) else { return }
        var next = baseline
        for id in ids {
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
}
