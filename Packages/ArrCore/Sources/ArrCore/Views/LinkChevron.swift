import SwiftUI

extension EnvironmentValues {
    /// Lights a `LinkChevron` whenever the cursor is over the row, not only the 9pt glyph.
    @Entry var linkRowHovering = false
}

public extension View {
    /// macOS-only: iOS has no hover, so the chevron stays static there.
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

/// Drill-in chevron whose hover is driven by the enclosing `.linkRowHover()` row.
/// Disclosure chevrons don't use this: they rotate for open/closed and aren't links.
struct LinkChevron: View {
    var size: CGFloat
    @Environment(\.linkRowHovering) private var rowHovering

    init(size: CGFloat = 9) {
        self.size = size
    }

    var body: some View {
        Image(systemName: "chevron.right")
            .scaledFont(size: size, weight: .semibold)
            .foregroundStyle(rowHovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .offset(x: rowHovering ? 1.5 : 0)
            .animation(.easeInOut(duration: 0.12), value: rowHovering)
            .accessibilityHidden(true)
    }
}
