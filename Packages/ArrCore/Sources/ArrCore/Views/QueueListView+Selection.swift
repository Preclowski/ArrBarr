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
        let ids = orderedSelectableEntries.map(\.id)
        return !ids.isEmpty && selected.count == ids.count
    }

    private func selectAll() {
        selected = Set(orderedSelectableEntries.map(\.id))
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
            selected.count
        )
    }

    func selectionState(for entry: QueueRowEntry) -> RowSelectionState {
        guard selecting else { return .hidden }
        return selected.contains(entry.id) ? .selected : .unselected
    }

    private func toggleSelection(_ entry: QueueRowEntry) {
        if selected.contains(entry.id) { selected.remove(entry.id) }
        else { selected.insert(entry.id) }
    }

    /// Selecting: tap toggles, ⇧-click extends from the anchor. Otherwise ⌘-click
    /// enters selecting with this row picked, a plain click opens the detail.
    func rowTapped(_ entry: QueueRowEntry, defaultTarget: QueueItem) {
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
    func dragSelectGesture(anchor: String) -> some Gesture {
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
}
