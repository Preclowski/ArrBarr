import SwiftUI

/// An SF Symbol glyph (play/pause) wrapped in a circular progress ring that
/// fills with download progress. White strokes + glyph — designed to sit on a
/// tinted-glass CTA or a dark poster scrim. Shared by the detail download
/// control (`PauseResumeButton`) and the queue rows' on-poster hover control.
struct DownloadProgressRing: View {
    let systemName: String
    let progress: Double
    let diameter: CGFloat
    var lineWidth: CGFloat = 1.5

    var body: some View {
        let clamped = max(0, min(1, progress))
        // `play.fill` is already optically balanced by SF Symbols, but inside a
        // tight ring its triangle still reads a hair left-of-centre — a small
        // right nudge fixes it. (0.07·d over-corrected, pushing it visibly right.)
        // `pause.fill` is symmetric and needs no nudge.
        let playNudge: CGFloat = systemName == "play.fill" ? diameter * 0.03 : 0
        return ZStack {
            Circle()
                .stroke(Color.white.opacity(0.30), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(Color.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: systemName)
                .font(.system(size: diameter * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .offset(x: playNudge)
        }
        .frame(width: diameter, height: diameter)
        .animation(.easeInOut(duration: 0.3), value: clamped)
    }
}
