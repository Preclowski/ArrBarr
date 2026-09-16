import SwiftUI

// MARK: - Action primitives
//
// Shared chrome for the action affordances on queue / detail surfaces.

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
