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
                .scaledFont(size: 9, weight: .semibold)
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .frame(width: QueueHeaderMetrics.chevronWidth)
                .opacity(showChevron ? 1 : 0)
            // Fixed-width slot so every section's title starts at the same x,
            // whatever the icon glyph — and items can indent to align under it.
            icon
                .frame(width: QueueHeaderMetrics.iconWidth, alignment: .center)
            Text(verbatim: title)
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)
            if let count {
                Text(verbatim: "\(count)")
                    .scaledFont(size: 11)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.horizontal, Tokens.Spacing.queueRowH)
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
