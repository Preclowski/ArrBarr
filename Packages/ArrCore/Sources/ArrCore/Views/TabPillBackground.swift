import SwiftUI

// MARK: - Tab pill background

/// Selection lens: the only real glass in the tab bar, drawn over the labels so it refracts them.
struct TabPillBackground: View, Animatable {
    var cornerRadius: CGFloat

    // Re-runs `body` per frame, so glass, sheen and rim reshape together.
    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: max(0, cornerRadius), style: .continuous) }

    var body: some View {
        shape
            .fill(.clear)
            .glassEffect(.clear.tint(.white.opacity(0.06)), in: shape)
            // Sheen on the upper half, the cue that it bulges.
            .overlay(
                shape.fill(
                    LinearGradient(colors: [.white.opacity(0.22), .clear],
                                   startPoint: .top, endPoint: .center)
                )
                .padding(1.5)
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.8), .white.opacity(0.08), .white.opacity(0.4)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
            )
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
    }
}

extension View {
    /// Real clear glass the lens sits on; the lens is a separate glass layer above the labels.
    func flatTabTrack(circular: Bool = false) -> some View {
        Group {
            if circular {
                glassEffect(.clear, in: .circle)
            } else {
                glassEffect(.clear, in: .capsule)
            }
        }
    }
}
