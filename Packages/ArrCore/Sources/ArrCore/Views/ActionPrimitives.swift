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
                    .scaledFont(size: 11, weight: .medium)
                Text(LocalizedStringKey(labelKey), bundle: .module)
                    .scaledFont(size: 11, weight: .medium)
            }
            .foregroundStyle(tint.opacity(isHovering ? 1.0 : 0.82))
            .padding(.horizontal, fillsWidth ? 0 : 10)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.07 : 0.025))
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        #if os(macOS)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
        }
        #endif
        .accessibilityLabel(Text(LocalizedStringKey(labelKey), bundle: .module))
    }
}

/// Bare-icon button used in every action surface — queue rows,
/// episode rows, detail clusters, header actions. 22pt hit area, no
/// chrome (no pill, no gradient, no inline label). Glyph fades from
/// `.secondary` to `tint` (default `.primary`) on hover. Tooltip via
/// the OS `.help()` modifier, matching Mail / Music / Finder toolbar
/// idiom. Inline-label / hover-expand variants were tried and pulled
/// — they shifted hit areas, trapped hover, and were not Apple-native.
public struct IconButton: View {
    @EnvironmentObject var configStore: ConfigStore
    let symbol: String
    let helpKey: String
    var accessibilityLabel: String
    var tint: Color?
    let action: () -> Void

    @State private var isHovering = false

    public init(symbol: String, helpKey: String, accessibilityLabel: String = "",
                tint: Color? = nil,
                action: @escaping () -> Void) {
        self.symbol = symbol
        self.helpKey = helpKey
        self.accessibilityLabel = accessibilityLabel
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .scaledFont(size: 13, weight: .medium)
                // Resting `.secondary` read too dim/muddy — a light primary
                // tint is clearly visible without shouting; hover goes full.
                .foregroundStyle(isHovering ? (tint ?? .primary) : Color.primary.opacity(0.72))
                .frame(width: 22, height: 22)
                // Clear hover affordance — a subtle rounded highlight behind
                // the glyph (the colour delta alone was too faint to read).
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill((tint ?? Color.primary).opacity(isHovering ? 0.14 : 0))
                )
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

// MARK: - Progress-fill CTA

/// Adds a progress indicator to a `GlassProminentButtonStyle` CTA
/// using a *multiply* blend mode overlay — instead of stacking a
/// separate dark "pill" on top (which read as a second capsule
/// inside the button), this darkens the rendered glass output on
/// the trailing portion. The glass sheen / refraction / chrome paint
/// through unchanged on the active side and get a uniform darkening
/// past the progress mark, so the user sees ONE button gradually
/// losing brightness on the right, not two stacked shapes.
public extension View {
    func progressFillCTA(progress: Double, tint: Color = .accentColor) -> some View {
        overlay(
            LinearGradient(
                stops: {
                    let p = max(0, min(1, progress))
                    return [
                        // white = identity under multiply (no change)
                        .init(color: .white, location: 0),
                        .init(color: .white, location: p),
                        // gray darkens uniformly past progress —
                        // lighter than the previous 0.45 so the
                        // white label stays readable over the dim
                        // portion (multiply darkens every pixel,
                        // including the text rendered by the button
                        // style underneath).
                        .init(color: Color(white: 0.65), location: p),
                        .init(color: Color(white: 0.65), location: 1),
                    ]
                }(),
                startPoint: .leading,
                endPoint: .trailing
            )
            .blendMode(.multiply)
            .allowsHitTesting(false)
        )
    }
}

// MARK: - Cluster backdrop

/// Subtle backdrop chip behind a row action cluster. Apple uses the
/// same idiom in Photos hover-cornerach, Quick Look thumbnails: a
/// material-tinted rounded rectangle that hugs the icons and gives
/// them stable contrast no matter what the row underneath is tinted
/// (status fill, hover wash, alternating bg). Replaces the previous
/// full-width gradient — same job, far smaller footprint.
public extension View {
    func rowActionBackdrop() -> some View {
        self
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
    }
}

// MARK: - Action overflow menu

/// Apple `ellipsis.circle` overflow — quiet glyph that opens a menu
/// of secondary actions. Same visual weight as `IconButton` so a
/// cluster like `[pause, ⋯]` reads as one row of bare icons. Tooltip
/// via `.help()`, menu indicator hidden (the glyph itself is the
/// indicator). Pattern lifted from Mail / Music / Podcasts — when a
/// row has more than one secondary action the standard treatment is
/// "primary direct + ⋯ for the rest".
public struct IconOverflowMenu<Content: View>: View {
    let helpKey: String
    let accessibilityLabel: String
    @ViewBuilder var menu: () -> Content

    @State private var isHovering = false

    public init(helpKey: String = "More",
                accessibilityLabel: String = "",
                @ViewBuilder menu: @escaping () -> Content) {
        self.helpKey = helpKey
        self.accessibilityLabel = accessibilityLabel
        self.menu = menu
    }

    public var body: some View {
        Menu(content: menu) {
            Image(systemName: "ellipsis")
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
