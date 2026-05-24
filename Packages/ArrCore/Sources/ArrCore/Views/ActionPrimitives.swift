import SwiftUI

// MARK: - Action button primitives
//
// Two button styles used everywhere queue/detail surfaces need an
// action affordance. Lifted out of QueueRowView.swift — the row
// file is overloaded with chrome that has nothing to do with the
// row's own layout.

/// Apple-HIG-sized labeled button used inside queue tooltips and
/// the detail view's download actions. Material-light backdrop
/// (low-opacity primary) with a hover brighten — sits cleanly on
/// popover chrome, echoes Music/AppStore detail sheets.
///
/// `tint` colors both the glyph and the label; `.red` makes
/// destructive actions read as destructive without a separate
/// variant.
public struct TooltipActionButton: View {
    let symbol: String
    let labelKey: String
    let tint: Color
    /// When `true` (default) the button stretches to fill available
    /// width — what the tooltip's narrow left column wants. Detail
    /// view passes `false` so the cluster hugs its labels.
    let fillsWidth: Bool
    let action: () -> Void

    @State private var isHovering = false

    public init(symbol: String, labelKey: String, tint: Color = .primary,
                fillsWidth: Bool = true, action: @escaping () -> Void) {
        self.symbol = symbol
        self.labelKey = labelKey
        self.tint = tint
        self.fillsWidth = fillsWidth
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                Text(LocalizedStringKey(labelKey), bundle: .module)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(tint.opacity(isHovering ? 1.0 : 0.65))
            .padding(.horizontal, fillsWidth ? 0 : 10)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.07 : 0.025))
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        #if os(macOS)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
        }
        #endif
        .accessibilityLabel(Text(LocalizedStringKey(labelKey), bundle: .module))
    }
}

/// Bare-icon button used in row-level hover overlays (queue rows,
/// episode rows). 22pt hit area, no chrome — the glyph fades from
/// `.secondary` to `tint` (default `.primary`) on hover.
public struct IconButton: View {
    @EnvironmentObject var configStore: ConfigStore
    let symbol: String
    let helpKey: String
    var accessibilityLabel: String
    var tint: Color?
    let action: () -> Void

    @State private var isHovering = false

    public init(symbol: String, helpKey: String, accessibilityLabel: String = "",
                tint: Color? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.helpKey = helpKey
        self.accessibilityLabel = accessibilityLabel
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHovering ? (tint ?? .primary) : .secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
        }
        #endif
        .help(Text(LocalizedStringKey(helpKey), bundle: .module))
        .accessibilityLabel(
            accessibilityLabel.isEmpty
                ? Text(LocalizedStringKey(helpKey), bundle: .module)
                : Text(verbatim: accessibilityLabel)
        )
    }
}
