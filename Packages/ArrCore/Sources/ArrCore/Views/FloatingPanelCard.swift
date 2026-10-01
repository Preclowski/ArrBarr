import SwiftUI

extension View {
    /// The add and edit forms float as an opaque card above the popover's bottom edge. Opaque on purpose:
    /// inside the menu-bar popover glass and materials composite to a flat grey slab.
    func floatingPanelCard() -> some View { modifier(FloatingPanelCard()) }
}

private struct FloatingPanelCard: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(colorScheme == .dark ? Color(white: 0.17) : Color(white: 0.98))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.1 : 0.6), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
            }
            .padding(8)
    }
}
