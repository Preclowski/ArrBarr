import SwiftUI

/// The app's capsule button, with a monochrome label. A primary action colours the background with `tint`
/// instead of its text (HIG, Liquid Glass colour); `fill` is how much of it, from the leading edge, so a
/// download's progress can fill the button. Flat by default; `glass` only for bars floating over content.
struct CTAButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var fill: Double = 1
    /// Waves run through the fill: the download behind it is live.
    var flowing: Bool = false
    var fullWidth: Bool = true
    var glass: Bool = false

    #if os(iOS)
    static let labelSize: CGFloat = 16
    private static let vPadding: CGFloat = 15
    #else
    static let labelSize: CGFloat = 13
    private static let vPadding: CGFloat = 10
    #endif

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, style: self)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let style: CTAButtonStyle
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            if style.glass {
                capsule.glassEffect(.clear.interactive(), in: .capsule)
            } else {
                capsule
            }
        }

        private var capsule: some View {
            configuration.label
                .scaledFont(size: CTAButtonStyle.labelSize, weight: .semibold)
                .foregroundStyle(.primary)
                .frame(maxWidth: style.fullWidth ? .infinity : nil)
                .padding(.vertical, CTAButtonStyle.vPadding)
                .padding(.horizontal, 14)
                .background {
                    if !style.glass { Capsule().fill(.quaternary) }
                    if let tint = style.tint { ProgressFill(progress: style.fill, tint: tint, flowing: style.flowing) }
                }
                .clipShape(.capsule)
                .contentShape(.capsule)
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
        }
    }
}

/// Tint sliding in from the leading edge, with a soft front instead of a hard bar end.
private struct ProgressFill: View {
    let progress: Double
    let tint: Color
    let flowing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let edge: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let span = geo.size.width + Self.edge
            // One fixed-width layer that slides: an offset animates smoothly where a resized gradient would jump.
            tint.opacity(0.35)
                .overlay {
                    if flowing && !reduceMotion {
                        FlowWaves().transition(.opacity)
                    }
                }
                .frame(width: span)
                .mask {
                    HStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: Self.edge)
                    }
                }
                .offset(x: (max(0, min(1, progress)) - 1) * span)
        }
        .animation(.smooth(duration: 0.6), value: progress)
        .allowsHitTesting(false)
    }
}

/// Lighter bands drifting left to right, so a slow download still reads as moving.
private struct FlowWaves: View {
    private static let wavelength: CGFloat = 90
    private static let speed: Double = 50

    var body: some View {
        GeometryReader { geo in
            let count = Int(geo.size.width / Self.wavelength) + 2
            TimelineView(.animation) { context in
                let shift = (context.date.timeIntervalSinceReferenceDate * Self.speed)
                    .truncatingRemainder(dividingBy: Double(Self.wavelength))
                HStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { _ in
                        LinearGradient(colors: [.white.opacity(0), .white.opacity(0.22), .white.opacity(0)],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: Self.wavelength)
                    }
                }
                .offset(x: CGFloat(shift) - Self.wavelength)
            }
        }
        .clipped()
    }
}
