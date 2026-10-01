import SwiftUI

/// A one-shot fountain of paper bits. Each new `trigger` value fires a fresh burst; the first
/// value seen is the baseline, so reopening a surface never replays an old celebration.
struct ConfettiBurst: View {
    let trigger: Int
    var origin: UnitPoint = .bottom
    var originOffset: CGSize = .zero

    @State private var firedAt: Date?
    @State private var pieces: [Piece] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let lifetime: TimeInterval = 2.4
    private static let count = 90

    var body: some View {
        TimelineView(.animation(paused: firedAt == nil)) { timeline in
            Canvas { context, size in
                guard let firedAt else { return }
                let t = timeline.date.timeIntervalSince(firedAt)
                guard t < Self.lifetime else { return }
                let start = CGPoint(x: size.width * origin.x + originOffset.width,
                                    y: size.height * origin.y + originOffset.height)
                for piece in pieces {
                    piece.draw(in: context, from: start, at: t, lifetime: Self.lifetime)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) { _, _ in fire() }
    }

    private func fire() {
        guard !reduceMotion else { return }
        pieces = (0..<Self.count).map { _ in Piece.random() }
        let stamp = Date()
        firedAt = stamp
        Task {
            try? await Task.sleep(for: .seconds(Self.lifetime))
            // A second add inside the window restarted the clock; leave that burst running.
            if firedAt == stamp { firedAt = nil }
        }
    }

    private struct Piece {
        static let palette: [Color] = [.accentColor, .pink, .yellow, .mint, .orange, .purple, .cyan]
        /// Air drag: the launch speed bleeds off fast, then bits drift down at about g/k.
        static let drag = 4.2
        static let gravity = 1100.0

        let vx: Double
        let vy: Double
        let size: CGSize
        let spin: Double
        let flutter: Double
        let angle: Double
        let color: Color
        let round: Bool

        static func random() -> Piece {
            // A fan around straight up, wide enough to spill over both verdict buttons.
            let heading = -Double.pi / 2 + .random(in: -0.62...0.62)
            let speed = Double.random(in: 1100...2100)
            let w = Double.random(in: 5...9)
            return Piece(vx: cos(heading) * speed,
                         vy: sin(heading) * speed,
                         size: CGSize(width: w, height: w * .random(in: 0.45...0.8)),
                         spin: .random(in: -9...9),
                         flutter: .random(in: 6...14),
                         angle: .random(in: 0...(2 * .pi)),
                         color: palette.randomElement() ?? .accentColor,
                         round: Int.random(in: 0..<5) == 0)
        }

        func draw(in context: GraphicsContext, from start: CGPoint, at t: Double, lifetime: Double) {
            let k = Self.drag
            let decay = (1 - exp(-k * t)) / k
            let x = start.x + vx * decay
            let y = start.y + (vy + Self.gravity / k) * decay - Self.gravity / k * t
            var ctx = context
            ctx.opacity = min(1, (lifetime - t) / 0.6)
            ctx.translateBy(x: x, y: y)
            ctx.rotate(by: .radians(angle + spin * t))
            // Foreshortening fakes the paper turning over as it falls.
            ctx.scaleBy(x: 1, y: max(0.12, abs(cos(flutter * t))))
            let rect = CGRect(x: -size.width / 2, y: -size.height / 2,
                              width: size.width, height: size.height)
            let path = round ? Path(ellipseIn: rect.insetBy(dx: 0, dy: -1))
                             : Path(roundedRect: rect, cornerRadius: 1.2)
            ctx.fill(path, with: .color(color))
        }
    }
}
