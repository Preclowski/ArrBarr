import SwiftUI

// MARK: - Shared button styles

struct GlassButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        // Capsule to match GlassProminentButtonStyle next to it.
        content.buttonStyle(.glass).buttonBorderShape(.capsule)
    }
}

/// Tinted glass that keeps showing what's behind it — for CTAs over artwork that shouldn't shout.
struct GlassTintedButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.buttonStyle(.glass).buttonBorderShape(.capsule)
    }
}

struct GlassProminentButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        // Explicit white labels: glassProminent's default vibrancy makes text translucent. An inner
        // foregroundStyle (the red trash) still wins.
        content
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .foregroundStyle(.white)
    }
}
