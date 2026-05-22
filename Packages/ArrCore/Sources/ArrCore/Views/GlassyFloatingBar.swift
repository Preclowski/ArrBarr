import SwiftUI

/// Floating "Liquid Glass" pill chrome used by the chat input bar and the
/// search query field — both want the same Apple-26 feel: rounded capsule,
/// translucent material, soft shadow, sits over the content rather than
/// inside its own structural row.
///
/// On macOS 26+ uses the system `.glassEffect(_:in:)` modifier. On earlier
/// versions falls back to `.regularMaterial` inside a capsule, which gives
/// the same general look without the dynamic refraction.
public extension View {
    func glassyFloatingBar() -> some View {
        modifier(GlassyFloatingBarModifier())
    }
}

private struct GlassyFloatingBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: .capsule)
                .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(
                    Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
        }
        #else
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: .capsule)
                .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(
                    Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
        }
        #endif
    }
}
