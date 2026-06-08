import SwiftUI

/// Drives a `LinkChevron`'s hover affordance from an ancestor row's
/// hover state. A row applies `.linkRowHover()`; any `LinkChevron`
/// inside it then lights up whenever the cursor is over the *row*, not
/// only over the 9pt glyph.
private struct LinkRowHoveringKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var linkRowHovering: Bool {
        get { self[LinkRowHoveringKey.self] }
        set { self[LinkRowHoveringKey.self] = newValue }
    }
}

public extension View {
    /// Mark this view as a "link row": its hover state is published to
    /// descendant `LinkChevron`s so they brighten when the cursor is
    /// anywhere over the row. macOS-only — iOS has no hover, so the
    /// chevron stays static and the whole row is the tap target.
    func linkRowHover() -> some View {
        modifier(LinkRowHoverModifier())
    }
}

private struct LinkRowHoverModifier: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .environment(\.linkRowHovering, hovering)
            .onHover { h in
                withAnimation(.easeInOut(duration: 0.12)) { hovering = h }
            }
        #else
        content
        #endif
    }
}

/// Drill-in chevron for tappable rows — queue rows, season-pack rows,
/// search-result rows, the episode→series link, "Needs you" items.
///
/// Its hover affordance is driven by the enclosing row (via
/// `.linkRowHover()`), NOT by the cursor sitting on the glyph itself:
/// when the row is hovered, the chevron brightens from `.tertiary` to
/// `.secondary` and nudges a hair rightward, reading as an interactive
/// link. Without a `.linkRowHover()` ancestor (e.g. iOS) it renders as
/// a plain static `.tertiary` chevron.
///
/// Disclosure chevrons (section collapse, season expand) deliberately
/// do NOT use this — they rotate to show open/closed state and aren't
/// navigation links.
public struct LinkChevron: View {
    var size: CGFloat
    @Environment(\.linkRowHovering) private var rowHovering

    public init(size: CGFloat = 9) {
        self.size = size
    }

    public var body: some View {
        Image(systemName: "chevron.right")
            .scaledFont(size: size, weight: .semibold)
            .foregroundStyle(rowHovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .offset(x: rowHovering ? 1.5 : 0)
            .animation(.easeInOut(duration: 0.12), value: rowHovering)
    }
}
