import SwiftUI

/// An SF Symbol glyph (play/pause) wrapped in a circular progress ring that
/// fills with download progress. Default white strokes + glyph — designed to
/// sit on a tinted-glass CTA or a dark poster scrim; pass `tint` for surfaces
/// with no dark backdrop. Shared by the detail download control
/// (`PauseResumeButton`), the queue rows' on-poster hover control and the
/// multi-download list's inline controls.
struct DownloadProgressRing: View {
    let systemName: String
    let progress: Double
    let diameter: CGFloat
    var lineWidth: CGFloat = 1.5
    var tint: Color = .white

    var body: some View {
        let clamped = max(0, min(1, progress))
        // `play.fill` is already optically balanced by SF Symbols, but inside a
        // tight ring its triangle still reads a hair left-of-centre — a small
        // right nudge fixes it. (0.07·d over-corrected, pushing it visibly right.)
        // `pause.fill` is symmetric and needs no nudge.
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
