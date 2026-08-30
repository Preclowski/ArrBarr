import SwiftUI

/// Shared metrics for the queue section headers and their item rows, so the
/// chevron column width and the item indent stay in lock-step.
enum QueueHeaderMetrics {
    static let chevronWidth: CGFloat = 10
    static let iconWidth: CGFloat = 16

    /// Leading inset that lines an item row's content up under the section icon
    /// (past the chevron column) — the "Next week" banner indents this way, so
    /// the Needs-you rows use it too for a matching slight left margin.
    static var contentIndent: CGFloat { Tokens.Spacing.queueRowH + chevronWidth + 6 }
}

/// The ONE collapsible section-header row shared by every queue group
/// (Next week / Needs you / each arr). A single component ⇒ identical chevron x,
/// icon footprint, text size, horizontal padding and height across all three.
/// Each host emits this as its own List row and its items as SIBLING rows, so
/// collapse animates as native row insert/remove.
/// Header type sizes. macOS keeps the compact popover values; iOS uses a real
/// section-header scale — 12pt secondary text reads as a caption on a phone,
/// not as the heading of everything under it.
private enum QueueHeaderType {
    #if os(iOS)
    static let title: CGFloat = 17
    static let count: CGFloat = 15
    static let chevron: CGFloat = 13
    static let vPad: CGFloat = 6
    static let titleStyle: HierarchicalShapeStyle = .primary
    #else
    static let title: CGFloat = 12
    static let count: CGFloat = 11
    static let chevron: CGFloat = 9
    static let vPad: CGFloat = 0
    static let titleStyle: HierarchicalShapeStyle = .secondary
    #endif
}

struct QueueHeaderRow<Trailing: View>: View {
    let icon: AnyView
    let title: String
    var count: Int? = nil
    let collapsed: Bool
    /// Hidden (slot preserved) for a genuine reachable arr error so the icon and
    /// label don't shift sideways.
    var showChevron: Bool = true
    let onToggle: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .scaledFont(size: QueueHeaderType.chevron, weight: .semibold)
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .frame(width: QueueHeaderMetrics.chevronWidth)
                .opacity(showChevron ? 1 : 0)
            // Fixed-width slot so every section's title starts at the same x,
            // whatever the icon glyph — and items can indent to align under it.
            icon
                .frame(width: QueueHeaderMetrics.iconWidth, alignment: .center)
            Text(verbatim: title)
                .scaledFont(size: QueueHeaderType.title, weight: .semibold)
                .foregroundStyle(QueueHeaderType.titleStyle)
            if let count {
                Text(verbatim: "\(count)")
                    .scaledFont(size: QueueHeaderType.count)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.horizontal, Tokens.Spacing.queueRowH)
        .padding(.vertical, QueueHeaderType.vPad)
        .textCase(nil)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }
}

extension QueueHeaderRow where Trailing == EmptyView {
    init(
        icon: AnyView,
        title: String,
        count: Int? = nil,
        collapsed: Bool,
        showChevron: Bool = true,
        onToggle: @escaping () -> Void
    ) {
        self.init(
            icon: icon, title: title, count: count, collapsed: collapsed,
            showChevron: showChevron, onToggle: onToggle, trailing: { EmptyView() }
        )
    }
}

/// "Show history ›" trailing link for section headers. Shared by the native
/// queue list and the search-mode section header so both get the same hover
/// affordance (accent tint + pointer feedback) — the list copy used to be a
/// static `.tertiary` label and read as dead text next to every other link.
struct ShowHistoryLink: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text("queue.showHistory.button", bundle: .module)
                Image(systemName: "chevron.right")
                    .scaledFont(size: 8, weight: .semibold)
                    .accessibilityHidden(true)
            }
            .scaledFont(size: 10)
            // Brighten, don't tint — every other inline link (LinkChevron)
            // answers hover by stepping up the gray ramp, not going accent.
            .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Text("queue.showHistory.button", bundle: .module))
    }
}
