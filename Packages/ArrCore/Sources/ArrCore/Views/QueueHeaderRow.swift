import SwiftUI

enum QueueHeaderMetrics {
    static let chevronWidth: CGFloat = 10
    static let iconWidth: CGFloat = 16

    static var contentIndent: CGFloat { Tokens.Spacing.queueRowH + chevronWidth + 6 }
}

/// iOS uses a real section-header scale: 12pt secondary reads as a caption on a phone.
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
    // `.primary`: the popover's text is vibrant, so a secondary heading reads as half-transparent.
    static let titleStyle: HierarchicalShapeStyle = .primary
    #endif
}

/// Shared by every queue group so chevron, icon and text line up. Items are SIBLING List rows,
/// so collapse animates as native row insert/remove.
struct QueueHeaderRow<Trailing: View>: View {
    let icon: AnyView
    let title: String
    var count: Int? = nil
    var hiddenCount: Int = 0
    var onToggleHidden: (() -> Void)? = nil
    let collapsed: Bool
    /// Hidden, slot preserved, so the icon and label don't shift sideways.
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
                .accessibilityHidden(true)
            // Fixed-width slot so every title starts at the same x whatever the glyph.
            icon
                .frame(width: QueueHeaderMetrics.iconWidth, alignment: .center)
            Text(verbatim: title)
                .scaledFont(size: QueueHeaderType.title, weight: .semibold)
                .foregroundStyle(QueueHeaderType.titleStyle)
                // The row's tap target isn't reachable by VoiceOver; the heading carries the toggle.
                .accessibilityAddTraits([.isHeader, .isButton])
                .accessibilityAction { onToggle() }
            if let count {
                Text(verbatim: "\(count)")
                    .scaledFont(size: QueueHeaderType.count)
                    .foregroundStyle(.tertiary)
            }
            if hiddenCount > 0 {
                Button { onToggleHidden?() } label: {
                    Text("queue.hiddenCount \(hiddenCount)", bundle: .module)
                        .scaledFont(size: QueueHeaderType.count)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .disabled(onToggleHidden == nil)
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
            // Brighten, don't tint — inline links answer hover by stepping up the gray ramp.
            .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Text("queue.showHistory.button", bundle: .module))
    }
}
