import SwiftUI

/// Play/pause glyph in a progress ring. White by default for glass or dark
/// scrims; pass `tint` elsewhere.
struct DownloadProgressRing: View {
    let systemName: String
    let progress: Double
    let diameter: CGFloat
    var lineWidth: CGFloat = 1.5
    var tint: Color = .white

    var body: some View {
        let clamped = max(0, min(1, progress))
        // `play.fill` reads a hair left of centre in a tight ring (0.07·d over-corrected).
        let playNudge: CGFloat = systemName == "play.fill" ? diameter * 0.03 : 0
        return ZStack {
            Circle()
                .stroke(tint.opacity(0.30), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: systemName)
                .font(.system(size: diameter * 0.5, weight: .semibold))
                .foregroundStyle(tint)
                .offset(x: playNudge)
        }
        .frame(width: diameter, height: diameter)
        .animation(.easeInOut(duration: 0.3), value: clamped)
    }
}
