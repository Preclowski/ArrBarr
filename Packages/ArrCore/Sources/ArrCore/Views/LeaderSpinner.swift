import SwiftUI

/// ArrBarr's indeterminate spinner: a film leader countdown. A hand sweeps
/// once a second over the leader's rings and crosshair while the numeral
/// counts 3, 2, 1 and starts over. Drawn in `.secondary` with the numeral in
/// `.primary`; 36 pt by default, sized for empty surfaces rather than rows.
/// Reduce Motion holds the frame on "3" with the hand at twelve.
struct LeaderSpinner: View {
    var height: CGFloat = 36

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let unit: CGFloat = 44
    private static let period: TimeInterval = 3

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = reduceMotion ? 0
                : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
            let sweep = t.truncatingRemainder(dividingBy: 1)
            let numeral = 3 - Int(t)
            ZStack {
                Canvas { ctx, size in
                    let s = size.height / Self.unit
                    ctx.scaleBy(x: s, y: s)
                    let c = CGPoint(x: Self.unit / 2, y: Self.unit / 2)
                    let angle = Angle.degrees(sweep * 360 - 90)

                    var wedge = Path()
                    wedge.move(to: c)
                    wedge.addArc(center: c, radius: 20, startAngle: .degrees(-90), endAngle: angle, clockwise: false)
                    wedge.closeSubpath()
                    ctx.fill(wedge, with: .style(.secondary.opacity(0.10)))

                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 20, y: c.y - 20, width: 40, height: 40)),
                               with: .style(.secondary.opacity(0.55)), lineWidth: 1.4)
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 15, y: c.y - 15, width: 30, height: 30)),
                               with: .style(.secondary.opacity(0.3)), lineWidth: 1)
                    ctx.stroke(Self.ticks, with: .style(.secondary.opacity(0.55)), lineWidth: 1.2)

                    var hand = Path()
                    hand.move(to: c)
                    hand.addLine(to: CGPoint(x: c.x + 19 * cos(angle.radians), y: c.y + 19 * sin(angle.radians)))
                    ctx.stroke(hand, with: .style(.secondary),
                               style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                }
                Text(verbatim: String(numeral))
                    .font(.system(size: height * 0.42, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy(duration: 0.25), value: numeral)
            }
            .frame(width: height, height: height)
        }
        .accessibilityHidden(true)
    }

    private static let ticks: Path = {
        var p = Path()
        let c = unit / 2
        for (dx, dy) in [(0, -1), (0, 1), (-1, 0), (1, 0)] as [(CGFloat, CGFloat)] {
            p.move(to: CGPoint(x: c + dx * 20, y: c + dy * 20))
            p.addLine(to: CGPoint(x: c + dx * 15, y: c + dy * 15))
        }
        return p
    }()
}

/// The empty-surface loading state: spinner over a "Loading…" line. Replaces
/// the bare `ProgressView` wherever a whole tab or panel waits on first data.
struct LoadingStateView: View {
    var label: LocalizedStringKey? = "queue.loading.button"

    var body: some View {
        VStack(spacing: 10) {
            LeaderSpinner()
            if let label {
                Text(label, bundle: .module)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
