import SwiftUI

// MARK: - Shared button style

/// The app's capsule button: clear glass with a monochrome label. A primary action stains the glass with
/// `tint` instead of colouring its text (HIG, Liquid Glass colour); `fill` is how much of it, from the
/// leading edge, so a download's progress can fill the button.
struct GlassCTAButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var fill: Double = 1
    var fullWidth: Bool = true

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
        let style: GlassCTAButtonStyle
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .scaledFont(size: GlassCTAButtonStyle.labelSize, weight: .semibold)
                .foregroundStyle(.primary)
                .frame(maxWidth: style.fullWidth ? .infinity : nil)
                .padding(.vertical, GlassCTAButtonStyle.vPadding)
                .padding(.horizontal, 14)
                .background {
                    if let tint = style.tint { ProgressFill(progress: style.fill, tint: tint) }
                }
                .clipShape(.capsule)
                .contentShape(.capsule)
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
                .glassEffect(.clear.interactive(), in: .capsule)
        }
    }
}

/// Tint sliding in from the leading edge, with a soft front instead of a hard bar end.
private struct ProgressFill: View {
    let progress: Double
    let tint: Color

    private static let edge: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let span = geo.size.width + Self.edge
            // One fixed-width layer that slides: an offset animates smoothly where a resized gradient would jump.
            HStack(spacing: 0) {
                tint.opacity(0.35)
                LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.edge)
            }
            .frame(width: span)
            .offset(x: (max(0, min(1, progress)) - 1) * span)
        }
        .animation(.smooth(duration: 0.6), value: progress)
        .allowsHitTesting(false)
    }
}
