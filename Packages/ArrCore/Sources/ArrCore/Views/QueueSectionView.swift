import SwiftUI

public struct QueueSectionView: View {
    let title: String
    let symbol: String
    let entries: [QueueRowEntry]
    var error: String?
    var health: [ArrHealthRecord] = []
    var isCollapsed: Bool = false
    var onToggleCollapse: (() -> Void)? = nil
    var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore
    var onShowHistory: (() -> Void)? = nil
    var onShowDetail: ((QueueItem) -> Void)? = nil
    /// Skip rendering the `[chevron] [icon] [title] [count]` header
    /// row. Used by the queue view when the user has narrowed the
    /// source scope to a single arr — the chip above already says
    /// "Sonarr", so repeating it as a section header is just chrome
    /// the user has to scroll past.
    var hideHeader: Bool = false
    @State private var hoveringHistory = false

    /// Total individual queue items represented by this section's entries.
    /// Singletons count as 1; groups contribute their member count.
    private var itemCount: Int {
        entries.reduce(0) { sum, entry in
            switch entry {
            case .single: return sum + 1
            case .group(let g): return sum + g.memberCount
            }
        }
    }

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 6) {
            if onToggleCollapse != nil {
                // Disclosure state is already spelled out by the header's
                // Expand/Collapse hint below.
                Image(systemName: "chevron.right")
                    .scaledFont(size: 9, weight: .semibold)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 10)
                    .accessibilityHidden(true)
            } else {
                Color.clear.frame(width: 10, height: 10)
            }
            // Decorative service glyph — `title` right next to it names the arr.
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)
            if error == nil {
                Text(verbatim: "\(itemCount)")
                    .scaledFont(size: 11)
                    .foregroundStyle(.tertiary)
                if !health.isEmpty { healthBadge }
            }
            Spacer()
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(size: 11)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(error)
            } else if let onShowHistory {
                Button(action: onShowHistory) {
                    HStack(spacing: 2) {
                        Text("queue.showHistory.button", bundle: .module)
                        Image(systemName: "chevron.right")
                            .scaledFont(size: 8, weight: .semibold)
                            .accessibilityHidden(true)
                    }
                    .scaledFont(size: 10)
                    .foregroundStyle(hoveringHistory ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.plain)
                .onHover { hoveringHistory = $0 }
                .help(Text("queue.showHistory.button", bundle: .module))
            }
        }
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture { onToggleCollapse?() }
        // Whole HStack is tappable but isn't a Button — VoiceOver wouldn't
        // know it's interactive without an explicit trait. Combine the
        // children so VO reads the section as one element.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(onToggleCollapse != nil ? .isButton : [])
        .accessibilityHint(
            onToggleCollapse != nil
                ? Text(isCollapsed ? "Expand section" : "Collapse section", bundle: .module)
                : Text(verbatim: "")
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !hideHeader {
                headerRow
            }
            if (!isCollapsed || hideHeader) && error == nil {
                if entries.isEmpty {
                    Text("queue.queueEmpty.button", bundle: .module)
                        .scaledFont(size: 12)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 2) {
                        ForEach(entries) { entry in
                            rowView(for: entry)
                                .queueSwipeToDelete(onDelete: deleteClosure(for: entry))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(for entry: QueueRowEntry) -> some View {
        switch entry {
        case .single(let item):
            QueueRowView(
                item: item,
                onPause: { [weak viewModel] in Task { await viewModel?.pause(item) } },
                onResume: { [weak viewModel] in Task { await viewModel?.resume(item) } },
                onDelete: deleteClosure(for: entry),
                onShowDetail: onShowDetail.map { cb in { cb(item) } }
            )
        case .group(let group):
            // A `.group` is now always a real season pack: every member
            // shares one downloadId, so pausing the representative
            // affects every sibling at the arr level. Delete still goes
            // through `deleteAll(_:)` because the aggregator wants the
            // member list to figure out per-call `removeFromClient`.
            let rep = group.representative
            QueueGroupRowView(
                group: group,
                onPause: { [weak viewModel] in Task { await viewModel?.pause(rep) } },
                onResume: { [weak viewModel] in Task { await viewModel?.resume(rep) } },
                onDelete: deleteClosure(for: entry),
                onShowDetail: onShowDetail.map { cb in { cb(rep) } }
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

    private var healthBadge: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .scaledFont(size: 10)
            .foregroundStyle(.orange)
            .help(health.compactMap(\.message).joined(separator: "\n"))
            // Orange triangle + hover tooltip is a mouse-only signal; give
            // VoiceOver the same warning text as the badge's value.
            .accessibilityLabel(Text("queue.serviceProblem.button", bundle: .module))
            .accessibilityValue(Text(verbatim: health.compactMap(\.message).joined(separator: ", ")))
    }
}
